// Created by csjoyxy in 2026 for iOS 16.0+ multi-profile persistence in https://github.com/csjoyxy/multi-agent-account-manager-ios (Apache-2.0, derived from https://github.com/ldjx7/multi-agent-account-manager).
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
  let isHostOnly: Bool?
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
  private var hydratedUuids: Set<String> = []
  private var pendingStoreWaiters: [String: [(WKWebsiteDataStore) -> Void]] = [:]
  private var cookieObservers: [String: CookieStoreObserverBox] = [:]
  private var pendingPersistWorkItems: [String: DispatchWorkItem] = [:]
  private var lastThrottledFlushAt: [String: TimeInterval] = [:]
  private var localStorageCache: [String: [String: [String: String]]] = [:]
  private let ioQueue = DispatchQueue(label: "com.ldjx.accountmanager.ios-profile-io", qos: .userInitiated)

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
    if #available(iOS 17.0, *) {
      return
    }
    let app = UIApplication.shared
    var bgTask: UIBackgroundTaskIdentifier = .invalid
    bgTask = app.beginBackgroundTask(withName: "maam-ios16-profile-flush") {
      if bgTask != .invalid {
        app.endBackgroundTask(bgTask)
        bgTask = .invalid
      }
    }

    DispatchQueue.main.async {
      let activePairs = self.nonPersistentStores.filter { self.hydratedUuids.contains($0.key) }
      guard !activePairs.isEmpty else {
        if bgTask != .invalid {
          app.endBackgroundTask(bgTask)
          bgTask = .invalid
        }
        return
      }
      let group = DispatchGroup()
      for (uuid, store) in activePairs {
        self.pendingPersistWorkItems.removeValue(forKey: uuid)?.cancel()
        group.enter()
        self.flushCookiesNow(
          uuid: uuid,
          store: store.httpCookieStore,
          allowEmptyOverwrite: false
        ) {
          group.leave()
        }
      }
      group.notify(queue: .main) {
        if bgTask != .invalid {
          app.endBackgroundTask(bgTask)
          bgTask = .invalid
        }
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

      let inMemoryKeys = Set(self.nonPersistentStores.keys).union(self.pendingStoreWaiters.keys)
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
      if let existing = self.nonPersistentStores[norm], self.hydratedUuids.contains(norm) {
        if createMarkerIfNeeded {
          self.ioQueue.async { self.ensureProfileMarkerSync(uuid: norm) }
        }
        completion(existing)
        return
      }

      if self.pendingStoreWaiters[norm] != nil {
        self.pendingStoreWaiters[norm]?.append(completion)
        if createMarkerIfNeeded {
          self.ioQueue.async { self.ensureProfileMarkerSync(uuid: norm) }
        }
        return
      }

      self.pendingStoreWaiters[norm] = [completion]
      let store = self.nonPersistentStores[norm] ?? WKWebsiteDataStore.nonPersistent()
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
          guard self.nonPersistentStores[norm] === store else {
            let waiters = self.pendingStoreWaiters.removeValue(forKey: norm) ?? []
            for cb in waiters {
              cb(store)
            }
            return
          }
          if !loadedLocalStorage.isEmpty {
            var merged = loadedLocalStorage
            if let existingLs = self.localStorageCache[norm] {
              for (origin, entries) in existingLs where !entries.isEmpty {
                merged[origin] = entries
              }
            }
            self.localStorageCache[norm] = merged
          }
          let group = DispatchGroup()
          for cookie in restoredCookies {
            group.enter()
            store.httpCookieStore.setCookie(cookie) {
              group.leave()
            }
          }
          group.notify(queue: .main) {
            if self.nonPersistentStores[norm] === store {
              self.hydratedUuids.insert(norm)
              self.attachCookieObserverIfNeeded(uuid: norm, store: store)
            }
            let waiters = self.pendingStoreWaiters.removeValue(forKey: norm) ?? []
            for cb in waiters {
              cb(store)
            }
          }
        }
      }
    }
  }

  func rehydrateCookiesIntoMemoryStore(uuid: String, completion: @escaping () -> Void) {
    if #available(iOS 17.0, *) {
      completion()
      return
    }
    let norm = uuid.lowercased()
    DispatchQueue.main.async {
      guard let store = self.nonPersistentStores[norm] else {
        completion()
        return
      }
      let cookiesUrl = self.profileDirUrl(for: norm).appendingPathComponent("cookies.json")
      self.ioQueue.async {
        var loadedRecords: [PersistedCookieRecord] = []
        if let data = try? Data(contentsOf: cookiesUrl),
           let decoded = try? JSONDecoder().decode([PersistedCookieRecord].self, from: data) {
          loadedRecords = decoded
        }
        let nowTs = Date().timeIntervalSince1970
        var restored: [HTTPCookie] = []
        for rec in loadedRecords {
          if let exp = rec.expiresAt, exp <= nowTs {
            continue
          }
          if let ck = Self.makeHttpCookie(from: rec) {
            restored.append(ck)
          }
        }
        DispatchQueue.main.async {
          guard !restored.isEmpty, self.nonPersistentStores[norm] === store else {
            completion()
            return
          }
          let group = DispatchGroup()
          for ck in restored {
            group.enter()
            store.httpCookieStore.setCookie(ck) {
              group.leave()
            }
          }
          group.notify(queue: .main) {
            self.hydratedUuids.insert(norm)
            completion()
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
          self.flushCookiesNow(
            uuid: uuid.uuidString.lowercased(),
            store: store.httpCookieStore,
            allowEmptyOverwrite: false
          ) {
            completion()
          }
        } else {
          completion()
        }
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
      self.pendingStoreWaiters.removeValue(forKey: norm)
      self.hydratedUuids.remove(norm)
      self.lastThrottledFlushAt.removeValue(forKey: norm)
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
        let explicitlyRemovedOrCleared = false;
        let lastDigest = '';
        const collectEntries = () => {
          const entries = {};
          let totalChars = 0;
          const parts = [];
          const len = window.localStorage.length;
          for (let i = 0; i < len && i < 250; i++) {
            const key = window.localStorage.key(i);
            if (!key) continue;
            const val = window.localStorage.getItem(key);
            if (typeof val !== 'string') continue;
            if (totalChars + key.length + val.length > 786432) break;
            totalChars += key.length + val.length;
            entries[key] = val;
            parts.push(key + '=' + val.length + ':' + val.slice(0, 24) + val.slice(-16));
          }
          parts.sort();
          return { entries, digest: parts.join('|') };
        };
        try {
          lastDigest = collectEntries().digest;
        } catch (_) {}
        const postSnapshot = (force) => {
          timer = null;
          try {
            const bridge = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.\(LocalStorageSyncScriptHandler.handlerName);
            if (!bridge || typeof bridge.postMessage !== 'function') return;
            const { entries, digest } = collectEntries();
            if (!force && digest === lastDigest) return;
            lastDigest = digest;
            bridge.postMessage({
              uuid: PROFILE_UUID,
              origin,
              entries,
              explicitClear: explicitlyRemovedOrCleared
            });
          } catch (_) {}
        };
        const scheduleSync = () => {
          if (timer) return;
          timer = setTimeout(() => postSnapshot(true), 220);
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
          if (this === window.localStorage) {
            explicitlyRemovedOrCleared = true;
            scheduleSync();
          }
          return r;
        };
        Storage.prototype.clear = function() {
          const r = origClear.apply(this, arguments);
          if (this === window.localStorage) {
            explicitlyRemovedOrCleared = true;
            scheduleSync();
          }
          return r;
        };
        window.addEventListener('pagehide', () => postSnapshot(false));
        document.addEventListener('visibilitychange', () => {
          if (document.visibilityState === 'hidden') postSnapshot(false);
        });
        setInterval(() => postSnapshot(false), 2500);
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
    let explicitClear = (dict["explicitClear"] as? Bool) ?? false
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
      if cleanEntries.isEmpty && !explicitClear, let prev = perOrigin[origin], !prev.isEmpty {
        return
      }
      if perOrigin[origin] == cleanEntries {
        return
      }
      perOrigin[origin] = cleanEntries
      self.localStorageCache[norm] = perOrigin
      IosGroupWebViewPool.shared.refreshUserScriptsForUuid(norm)
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
      guard self.nonPersistentStores[uuid] != nil, self.hydratedUuids.contains(uuid) else { return }
      self.pendingPersistWorkItems[uuid]?.cancel()
      let item = DispatchWorkItem { [weak self, weak store] in
        guard let self = self, let store = store else { return }
        self.pendingPersistWorkItems.removeValue(forKey: uuid)
        self.flushCookiesNow(uuid: uuid, store: store, allowEmptyOverwrite: false)
      }
      self.pendingPersistWorkItems[uuid] = item
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: item)
    }
  }

  func flushCookiesForUuid(_ uuid: String) {
    if #available(iOS 17.0, *) {
      return
    }
    let norm = uuid.lowercased()
    DispatchQueue.main.async {
      if let store = self.nonPersistentStores[norm], self.hydratedUuids.contains(norm) {
        self.lastThrottledFlushAt[norm] = Date().timeIntervalSince1970
        self.flushCookiesNow(uuid: norm, store: store.httpCookieStore, allowEmptyOverwrite: false)
      }
    }
  }

  func flushCookiesThrottled(uuid: String, minInterval: TimeInterval = 4.0) {
    if #available(iOS 17.0, *) {
      return
    }
    let norm = uuid.lowercased()
    DispatchQueue.main.async {
      guard let store = self.nonPersistentStores[norm], self.hydratedUuids.contains(norm) else {
        return
      }
      let now = Date().timeIntervalSince1970
      if let last = self.lastThrottledFlushAt[norm], now - last < minInterval {
        return
      }
      self.lastThrottledFlushAt[norm] = now
      self.flushCookiesNow(uuid: norm, store: store.httpCookieStore, allowEmptyOverwrite: false)
    }
  }

  private func flushCookiesNow(
    uuid: String,
    store: WKHTTPCookieStore,
    allowEmptyOverwrite: Bool,
    completion: (() -> Void)? = nil
  ) {
    guard nonPersistentStores[uuid] != nil, hydratedUuids.contains(uuid) else {
      completion?()
      return
    }
    store.getAllCookies { [weak self] cookies in
      guard let self = self else {
        completion?()
        return
      }
      guard self.nonPersistentStores[uuid] != nil, self.hydratedUuids.contains(uuid) else {
        completion?()
        return
      }
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
            version: c.version,
            isHostOnly: !c.domain.hasPrefix(".")
          )
        )
      }
      let dir = self.profileDirUrl(for: uuid)
      self.ioQueue.async {
        self.ensureProfileMarkerSync(uuid: uuid)
        let cookiesUrl = dir.appendingPathComponent("cookies.json")
        if records.isEmpty && !allowEmptyOverwrite {
          if let existingData = try? Data(contentsOf: cookiesUrl),
             let existingRecords = try? JSONDecoder().decode([PersistedCookieRecord].self, from: existingData) {
            let nowTs = Date().timeIntervalSince1970
            let hasValidSaved = existingRecords.contains { rec in
              if let exp = rec.expiresAt {
                return exp > nowTs
              }
              return true
            }
            if hasValidSaved {
              DispatchQueue.main.async {
                self.rehydrateCookiesIntoMemoryStore(uuid: uuid) {
                  completion?()
                }
              }
              return
            }
          }
        }
        if let data = try? JSONEncoder().encode(records) {
          try? data.write(to: cookiesUrl, options: .atomic)
        }
        if let completion = completion {
          DispatchQueue.main.async {
            completion()
          }
        }
      }
    }
  }

  private static func makeHttpCookie(from rec: PersistedCookieRecord) -> HTTPCookie? {
    let rawDomain = rec.domain.trimmingCharacters(in: .whitespacesAndNewlines)
    let cleanHost = rawDomain.trimmingCharacters(in: CharacterSet(charactersIn: "."))
    guard !cleanHost.isEmpty else { return nil }
    let cleanPath = rec.path.isEmpty ? "/" : rec.path
    let isHostPrefix = rec.name.hasPrefix("__Host-")
    let hostOnly = isHostPrefix || (rec.isHostOnly == true && !rawDomain.hasPrefix("."))

    var props: [HTTPCookiePropertyKey: Any] = [
      .name: rec.name,
      .value: rec.value,
      .path: isHostPrefix ? "/" : cleanPath,
      .version: String(rec.version),
    ]
    if let originUrl = URL(string: "https://\(cleanHost)\(isHostPrefix ? "/" : cleanPath)") {
      props[.originURL] = originUrl
    }
    if !isHostPrefix {
      props[.domain] = hostOnly ? cleanHost : rawDomain
    } else {
      props[.domain] = cleanHost
    }
    if rec.isSecure || isHostPrefix || rec.name.hasPrefix("__Secure-") {
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
    if let cookie = HTTPCookie(properties: props) {
      return cookie
    }
    props[.domain] = cleanHost
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
