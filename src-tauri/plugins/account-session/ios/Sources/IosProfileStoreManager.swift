import Foundation
import Network
import UIKit
import WebKit

private struct PersistedCookieRecord: Codable {
  let name: String
  let value: String
  let domain: String
  let path: String
  let isSecure: Bool
  let isHTTPOnly: Bool
  let expiresAt: Double?
  let sameSite: String?
  let version: Int
}

private final class CookieStoreObserverBox: NSObject, WKHTTPCookieStoreObserver {
  let uuid: String
  weak var owner: IosProfileStoreManager?

  init(uuid: String, owner: IosProfileStoreManager) {
    self.uuid = uuid
    self.owner = owner
    super.init()
  }

  func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
    owner?.scheduleCookiePersist(uuid: uuid, store: cookieStore)
  }
}

final class LocalStorageSyncScriptHandler: NSObject, WKScriptMessageHandler {
  static let handlerName = "maamLocalStorageSync"

  func userContentController(
    _ userContentController: WKUserContentController,
    didReceive message: WKScriptMessage
  ) {
    guard message.name == Self.handlerName else { return }
    IosProfileStoreManager.shared.handleLocalStorageSyncMessage(message.body)
  }
}

final class IosProfileStoreManager {
  static let shared = IosProfileStoreManager()

  private var nonPersistentStores: [String: WKWebsiteDataStore] = [:]
  private var cookieObservers: [String: CookieStoreObserverBox] = [:]
  private var pendingPersistWorkItems: [String: DispatchWorkItem] = [:]
  private var localStorageCache: [String: [String: [String: String]]] = [:]
  private let ioQueue = DispatchQueue(label: "com.ldjx.accountmanager.ios-profile-io", qos: .utility)

  private init() {
    let center = NotificationCenter.default
    for name in [
      UIApplication.willResignActiveNotification,
      UIApplication.didEnterBackgroundNotification,
      UIApplication.willTerminateNotification,
    ] {
      center.addObserver(
        self,
        selector: #selector(handleAppLifecycleFlush),
        name: name,
        object: nil
      )
    }
  }

  @objc private func handleAppLifecycleFlush() {
    DispatchQueue.main.async {
      if #available(iOS 17.0, *) {
        return
      }
      for (uuid, store) in self.nonPersistentStores {
        self.flushCookiesNow(uuid: uuid, store: store.httpCookieStore)
      }
    }
  }

  private func profilesRootUrl() -> URL {
    let base =
      FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? FileManager.default.temporaryDirectory
    return base
      .appendingPathComponent("com.ldjx.accountmanager", isDirectory: true)
      .appendingPathComponent("ios-profiles", isDirectory: true)
  }

  private func profileDirUrl(for uuid: String) -> URL {
    profilesRootUrl().appendingPathComponent(uuid.lowercased(), isDirectory: true)
  }

  private func ensureProfileMarkerSync(uuid: String) {
    let dir = profileDirUrl(for: uuid)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let metaPath = dir.appendingPathComponent("meta.json")
    if !FileManager.default.fileExists(atPath: metaPath.path) {
      let payload = "{\"uuid\":\"\(uuid.lowercased())\"}\n"
      try? payload.data(using: .utf8)?.write(to: metaPath, options: .atomic)
    }
  }

  func fetchAllProfileIdentifiers(completion: @escaping ([String]) -> Void) {
    DispatchQueue.main.async {
      if #available(iOS 17.0, *) {
        WKWebsiteDataStore.fetchAllDataStoreIdentifiers { uuids in
          let names = uuids.map { $0.uuidString.lowercased() }
          completion(names)
        }
        return
      }

      let inMemoryKeys = Set(self.nonPersistentStores.keys)
      let root = self.profilesRootUrl()
      self.ioQueue.async {
        var found = inMemoryKeys
        if let items = try? FileManager.default.contentsOfDirectory(
          at: root,
          includingPropertiesForKeys: [.isDirectoryKey],
          options: [.skipsHiddenFiles]
        ) {
          for url in items {
            let name = url.lastPathComponent.lowercased()
            if UUID(uuidString: name) != nil {
              found.insert(name)
            }
          }
        }
        let sorted = Array(found).sorted()
        DispatchQueue.main.async {
          completion(sorted)
        }
      }
    }
  }

  func hasPersistedProfile(uuid: UUID, completion: @escaping (Bool) -> Void) {
    let norm = uuid.uuidString.lowercased()
    fetchAllProfileIdentifiers { names in
      completion(names.contains(norm))
    }
  }

  func prepareDataStore(
    uuid: UUID,
    proxyUrl: String?,
    createMarkerIfNeeded: Bool = true,
    completion: @escaping (WKWebsiteDataStore) -> Void
  ) {
    DispatchQueue.main.async {
      if #available(iOS 17.0, *) {
        let store = WKWebsiteDataStore(forIdentifier: uuid)
        Self.applyProxyIfSupported(to: store, rawProxy: proxyUrl)
        completion(store)
        return
      }

      let norm = uuid.uuidString.lowercased()
      if let existing = self.nonPersistentStores[norm] {
        if createMarkerIfNeeded {
          self.ioQueue.async { self.ensureProfileMarkerSync(uuid: norm) }
        }
        completion(existing)
        return
      }

      let store = WKWebsiteDataStore.nonPersistent()
      self.nonPersistentStores[norm] = store

      let dir = self.profileDirUrl(for: norm)
      self.ioQueue.async {
        if createMarkerIfNeeded {
          self.ensureProfileMarkerSync(uuid: norm)
        }
        let cookiesUrl = dir.appendingPathComponent("cookies.json")
        let lsUrl = dir.appendingPathComponent("localstorage.json")

        var loadedRecords: [PersistedCookieRecord] = []
        if let data = try? Data(contentsOf: cookiesUrl),
           let decoded = try? JSONDecoder().decode([PersistedCookieRecord].self, from: data) {
          loadedRecords = decoded
        }

        var loadedLocalStorage: [String: [String: String]] = [:]
        if let lsData = try? Data(contentsOf: lsUrl),
           let decodedLs = try? JSONDecoder().decode([String: [String: String]].self, from: lsData) {
          loadedLocalStorage = decodedLs
        }

        let nowTs = Date().timeIntervalSince1970
        var restoredCookies: [HTTPCookie] = []
        for rec in loadedRecords {
          if let exp = rec.expiresAt, exp <= nowTs {
            continue
          }
          if let cookie = Self.makeHttpCookie(from: rec) {
            restoredCookies.append(cookie)
          }
        }

        DispatchQueue.main.async {
          if self.localStorageCache[norm] == nil && !loadedLocalStorage.isEmpty {
            self.localStorageCache[norm] = loadedLocalStorage
          }
          let group = DispatchGroup()
          for cookie in restoredCookies {
            group.enter()
            store.httpCookieStore.setCookie(cookie) {
              group.leave()
            }
          }
          group.notify(queue: .main) {
            self.attachCookieObserverIfNeeded(uuid: norm, store: store)
            completion(store)
          }
        }
      }
    }
  }

  func getAllCookies(uuid: UUID, completion: @escaping ([HTTPCookie]) -> Void) {
    prepareDataStore(uuid: uuid, proxyUrl: nil, createMarkerIfNeeded: false) { store in
      store.httpCookieStore.getAllCookies { cookies in
        completion(cookies)
      }
    }
  }

  func setCookies(uuid: UUID, cookies: [HTTPCookie], completion: @escaping () -> Void) {
    prepareDataStore(uuid: uuid, proxyUrl: nil, createMarkerIfNeeded: true) { store in
      let group = DispatchGroup()
      for cookie in cookies {
        group.enter()
        store.httpCookieStore.setCookie(cookie) {
          group.leave()
        }
      }
      group.notify(queue: .main) {
        if #unavailable(iOS 17.0) {
          self.flushCookiesNow(uuid: uuid.uuidString.lowercased(), store: store.httpCookieStore)
        }
        completion()
      }
    }
  }

  func removeProfile(uuid: UUID, completion: @escaping (Error?) -> Void) {
    DispatchQueue.main.async {
      if #available(iOS 17.0, *) {
        WKWebsiteDataStore.fetchAllDataStoreIdentifiers { uuids in
          guard uuids.contains(uuid) else {
            completion(nil)
            return
          }
          WKWebsiteDataStore.remove(forIdentifier: uuid) { err in
            completion(err)
          }
        }
        return
      }

      let norm = uuid.uuidString.lowercased()
      self.pendingPersistWorkItems.removeValue(forKey: norm)?.cancel()
      let obs = self.cookieObservers.removeValue(forKey: norm)
      let store = self.nonPersistentStores.removeValue(forKey: norm)
      self.localStorageCache.removeValue(forKey: norm)

      let finishDiskCleanup = {
        let dir = self.profileDirUrl(for: norm)
        self.ioQueue.async {
          try? FileManager.default.removeItem(at: dir)
          DispatchQueue.main.async {
            completion(nil)
          }
        }
      }

      if let store = store {
        if let obs = obs {
          store.httpCookieStore.remove(obs)
        }
        store.fetchDataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes()) { records in
          store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), for: records) {
            finishDiskCleanup()
          }
        }
      } else {
        finishDiskCleanup()
      }
    }
  }

  func localStorageInitScript(for uuid: String) -> String? {
    if #available(iOS 17.0, *) {
      return nil
    }
    let norm = uuid.lowercased()
    let originMap = localStorageCache[norm] ?? [:]
    let uuidJson = Self.jsonStringLiteral(norm)
    let mapJson: String
    if let data = try? JSONEncoder().encode(originMap),
       let str = String(data: data, encoding: .utf8) {
      mapJson = str
    } else {
      mapJson = "{}"
    }

    return """
    (() => {
      try {
        if (location.protocol !== 'https:') return;
        const PROFILE_UUID = \(uuidJson);
        const SAVED_BY_ORIGIN = \(mapJson);
        const origin = location.origin;
        if (!origin || origin === 'null') return;
        const initial = SAVED_BY_ORIGIN[origin];
        if (initial && typeof initial === 'object') {
          for (const k of Object.keys(initial)) {
            try {
              if (window.localStorage.getItem(k) === null) {
                window.localStorage.setItem(k, String(initial[k]));
              }
            } catch (_) {}
          }
        }
        if (window.__maamLsSyncInstalled) return;
        window.__maamLsSyncInstalled = true;
        let timer = null;
        const postSnapshot = () => {
          timer = null;
          try {
            const bridge = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.\(LocalStorageSyncScriptHandler.handlerName);
            if (!bridge || typeof bridge.postMessage !== 'function') return;
            const entries = {};
            let totalChars = 0;
            for (let i = 0; i < window.localStorage.length && i < 200; i++) {
              const key = window.localStorage.key(i);
              if (!key) continue;
              const val = window.localStorage.getItem(key);
              if (typeof val !== 'string') continue;
              if (totalChars + key.length + val.length > 524288) break;
              totalChars += key.length + val.length;
              entries[key] = val;
            }
            bridge.postMessage({ uuid: PROFILE_UUID, origin, entries });
          } catch (_) {}
        };
        const scheduleSync = () => {
          if (timer) return;
          timer = setTimeout(postSnapshot, 280);
        };
        const origSet = Storage.prototype.setItem;
        const origRemove = Storage.prototype.removeItem;
        const origClear = Storage.prototype.clear;
        Storage.prototype.setItem = function(k, v) {
          const r = origSet.apply(this, arguments);
          if (this === window.localStorage) scheduleSync();
          return r;
        };
        Storage.prototype.removeItem = function(k) {
          const r = origRemove.apply(this, arguments);
          if (this === window.localStorage) scheduleSync();
          return r;
        };
        Storage.prototype.clear = function() {
          const r = origClear.apply(this, arguments);
          if (this === window.localStorage) scheduleSync();
          return r;
        };
        window.addEventListener('pagehide', postSnapshot);
      } catch (_) {}
    })();
    """
  }

  func handleLocalStorageSyncMessage(_ body: Any) {
    if #available(iOS 17.0, *) {
      return
    }
    guard let dict = body as? [String: Any],
          let rawUuid = dict["uuid"] as? String,
          let origin = dict["origin"] as? String,
          origin.lowercased().hasPrefix("https://"),
          let rawEntries = dict["entries"] as? [String: Any] else {
      return
    }
    let norm = rawUuid.lowercased()
    guard UUID(uuidString: norm) != nil else { return }

    var cleanEntries: [String: String] = [:]
    for (k, v) in rawEntries {
      if let str = v as? String {
        cleanEntries[k] = str
      }
    }

    DispatchQueue.main.async {
      guard self.nonPersistentStores[norm] != nil else { return }
      var perOrigin = self.localStorageCache[norm] ?? [:]
      perOrigin[origin] = cleanEntries
      self.localStorageCache[norm] = perOrigin
      let snapshot = perOrigin
      let dir = self.profileDirUrl(for: norm)
      self.ioQueue.async {
        self.ensureProfileMarkerSync(uuid: norm)
        let lsUrl = dir.appendingPathComponent("localstorage.json")
        if let data = try? JSONEncoder().encode(snapshot) {
          try? data.write(to: lsUrl, options: .atomic)
        }
      }
    }
  }

  private func attachCookieObserverIfNeeded(uuid: String, store: WKWebsiteDataStore) {
    guard cookieObservers[uuid] == nil else { return }
    let box = CookieStoreObserverBox(uuid: uuid, owner: self)
    cookieObservers[uuid] = box
    store.httpCookieStore.add(box)
  }

  fileprivate func scheduleCookiePersist(uuid: String, store: WKHTTPCookieStore) {
    DispatchQueue.main.async {
      guard self.nonPersistentStores[uuid] != nil else { return }
      self.pendingPersistWorkItems[uuid]?.cancel()
      let item = DispatchWorkItem { [weak self, weak store] in
        guard let self = self, let store = store else { return }
        self.pendingPersistWorkItems.removeValue(forKey: uuid)
        self.flushCookiesNow(uuid: uuid, store: store)
      }
      self.pendingPersistWorkItems[uuid] = item
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: item)
    }
  }

  func flushCookiesForUuid(_ uuid: String) {
    if #available(iOS 17.0, *) {
      return
    }
    let norm = uuid.lowercased()
    DispatchQueue.main.async {
      if let store = self.nonPersistentStores[norm] {
        self.flushCookiesNow(uuid: norm, store: store.httpCookieStore)
      }
    }
  }

  private func flushCookiesNow(uuid: String, store: WKHTTPCookieStore) {
    guard nonPersistentStores[uuid] != nil else { return }
    store.getAllCookies { [weak self] cookies in
      guard let self = self else { return }
      guard self.nonPersistentStores[uuid] != nil else { return }
      let now = Date()
      var records: [PersistedCookieRecord] = []
      records.reserveCapacity(cookies.count)
      for c in cookies {
        if let exp = c.expiresDate, exp <= now {
          continue
        }
        records.append(
          PersistedCookieRecord(
            name: c.name,
            value: c.value,
            domain: c.domain,
            path: c.path.isEmpty ? "/" : c.path,
            isSecure: c.isSecure,
            isHTTPOnly: c.isHTTPOnly,
            expiresAt: c.expiresDate?.timeIntervalSince1970,
            sameSite: c.sameSitePolicy?.rawValue,
            version: c.version
          )
        )
      }
      let dir = self.profileDirUrl(for: uuid)
      self.ioQueue.async {
        self.ensureProfileMarkerSync(uuid: uuid)
        let cookiesUrl = dir.appendingPathComponent("cookies.json")
        if let data = try? JSONEncoder().encode(records) {
          try? data.write(to: cookiesUrl, options: .atomic)
        }
      }
    }
  }

  private static func makeHttpCookie(from rec: PersistedCookieRecord) -> HTTPCookie? {
    var props: [HTTPCookiePropertyKey: Any] = [
      .name: rec.name,
      .value: rec.value,
      .domain: rec.domain,
      .path: rec.path.isEmpty ? "/" : rec.path,
      .version: String(rec.version),
    ]
    if rec.isSecure {
      props[.secure] = "TRUE"
    }
    if rec.isHTTPOnly {
      props[HTTPCookiePropertyKey("HttpOnly")] = "TRUE"
    }
    if let exp = rec.expiresAt {
      props[.expires] = Date(timeIntervalSince1970: exp)
    }
    if let ss = rec.sameSite, !ss.isEmpty {
      props[.sameSitePolicy] = HTTPCookieStringPolicy(rawValue: ss)
    }
    return HTTPCookie(properties: props)
  }

  private static func jsonStringLiteral(_ value: String) -> String {
    if let data = try? JSONEncoder().encode(value),
       let str = String(data: data, encoding: .utf8) {
      return str
    }
    return "\"\""
  }

  @available(iOS 17.0, *)
  static func applyProxyIfSupported(to store: WKWebsiteDataStore, rawProxy: String?) {
    if let raw = rawProxy?.trimmingCharacters(in: .whitespacesAndNewlines),
       !raw.isEmpty,
       let cfg = buildHttpConnectProxyConfig(raw: raw) {
      store.proxyConfigurations = [cfg]
    } else {
      store.proxyConfigurations = []
    }
  }

  @available(iOS 17.0, *)
  private static func buildHttpConnectProxyConfig(raw: String) -> ProxyConfiguration? {
    guard let url = URL(string: raw),
          url.scheme?.lowercased() == "http",
          let host = url.host,
          !host.isEmpty else {
      return nil
    }
    let portVal = UInt16(url.port ?? 80)
    guard let nwPort = NWEndpoint.Port(rawValue: portVal) else {
      return nil
    }
    let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: nwPort)
    return ProxyConfiguration(httpCONNECTProxy: endpoint)
  }
}
