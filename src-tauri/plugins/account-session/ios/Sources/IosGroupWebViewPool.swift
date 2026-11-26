import CoreFoundation
import Foundation
import UIKit
import WebKit

struct IosPoolError: Error, LocalizedError {
  let message: String

  init(_ message: String) {
    self.message = message
  }

  var errorDescription: String? {
    message
  }
}

struct EnsureGroupWebviewSpec {
  let providerId: String
  let uuid: String
  let entryUrl: String
  let allowedHosts: [String]
  let proxyUrl: String?
  let timezone: String?
  let timezoneInitScript: String?
  let autoApprove: Bool
  let backgroundRafJs: String
  let netHookJs: String
  let requestedViewInstanceId: UInt64
}

struct GroupWebviewEnsureOutcome {
  let viewInstanceId: UInt64
  let url: String
  let loggedOut: Bool
}

struct GroupWebviewEvalOutcome {
  let exists: Bool
  let valueJson: String?
  let url: String?
  let error: String?
}

struct GroupWebviewStateOutcome {
  let exists: Bool
  let viewInstanceId: UInt64
  let url: String?
}

final class PooledAccountWebView: NSObject, WKNavigationDelegate, WKUIDelegate {
  let providerId: String
  let uuid: String
  var allowedHosts: [String]
  let proxyUrl: String?
  let timezone: String?
  let viewInstanceId: UInt64
  let webView: WKWebView

  var paintReady: Bool = false
  var processTerminated: Bool = false
  var lastLoadError: String?
  var lastUsedMs: UInt64
  var isBorrowedByForeground: Bool = false
  weak var foregroundOwner: AccountWebViewController?

  init(
    providerId: String,
    uuid: String,
    allowedHosts: [String],
    proxyUrl: String?,
    timezone: String?,
    viewInstanceId: UInt64,
    webView: WKWebView
  ) {
    self.providerId = providerId
    self.uuid = uuid.lowercased()
    self.allowedHosts = allowedHosts
    self.proxyUrl = proxyUrl
    self.timezone = timezone
    self.viewInstanceId = viewInstanceId
    self.webView = webView
    self.lastUsedMs = Self.nowMs()
    super.init()
    self.webView.navigationDelegate = self
    self.webView.uiDelegate = self
  }

  static func nowMs() -> UInt64 {
    UInt64(Date().timeIntervalSince1970 * 1000.0)
  }

  func touch() {
    lastUsedMs = Self.nowMs()
  }

  func webView(
    _ webView: WKWebView,
    decidePolicyFor navigationAction: WKNavigationAction,
    decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
  ) {
    if isBorrowedByForeground, let owner = foregroundOwner {
      owner.handleDecidePolicy(webView, navigationAction: navigationAction, decisionHandler: decisionHandler)
      return
    }

    guard let url = navigationAction.request.url else {
      decisionHandler(.allow)
      return
    }
    let abs = url.absoluteString
    if abs == "about:blank"
      || abs.hasPrefix("about:srcdoc")
      || abs.hasPrefix("blob:null/")
      || abs.hasPrefix("blob:https://")
    {
      decisionHandler(.allow)
      return
    }
    let isMainFrame = navigationAction.targetFrame?.isMainFrame ?? true
    if !isMainFrame {
      let scheme = url.scheme?.lowercased() ?? ""
      let ok = scheme == "https" || scheme == "http" || scheme == "about" || scheme == "blob" || scheme == "data"
      decisionHandler(ok ? .allow : .cancel)
      return
    }
    let scheme = url.scheme?.lowercased() ?? ""
    if scheme != "https" {
      decisionHandler(.cancel)
      return
    }
    if AccountSessionCoordinator.shared.isGoogleOAuthHost(url) {
      decisionHandler(.cancel)
      return
    }
    if AccountSessionCoordinator.shared.hostMatchesAllowed(url, allowedHosts: allowedHosts) {
      decisionHandler(.allow)
      return
    }
    decisionHandler(.cancel)
  }

  func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
    processTerminated = false
    if isBorrowedByForeground, let owner = foregroundOwner {
      owner.handleDidCommit(webView)
    }
  }

  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    processTerminated = false
    lastLoadError = nil
    if let url = webView.url, url.absoluteString != "about:blank" {
      paintReady = true
    }
    IosProfileStoreManager.shared.flushCookiesForUuid(uuid)
    if isBorrowedByForeground, let owner = foregroundOwner {
      owner.handleDidFinish(webView)
    }
  }

  func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
    recordError(error)
    if isBorrowedByForeground, let owner = foregroundOwner {
      owner.handleDidFail(webView, error: error)
    }
  }

  func webView(
    _ webView: WKWebView,
    didFailProvisionalNavigation navigation: WKNavigation!,
    withError error: Error
  ) {
    recordError(error)
    if isBorrowedByForeground, let owner = foregroundOwner {
      owner.handleDidFail(webView, error: error)
    }
  }

  func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
    processTerminated = true
    paintReady = false
    if isBorrowedByForeground, let owner = foregroundOwner {
      owner.handleProcessDidTerminate(webView)
    }
  }

  func webView(
    _ webView: WKWebView,
    createWebViewWith configuration: WKWebViewConfiguration,
    for navigationAction: WKNavigationAction,
    windowFeatures: WKWindowFeatures
  ) -> WKWebView? {
    if isBorrowedByForeground, let owner = foregroundOwner {
      return owner.handleCreatePopupWebView(
        webView,
        configuration: configuration,
        navigationAction: navigationAction
      )
    }
    return nil
  }

  func webViewDidClose(_ webView: WKWebView) {
    if isBorrowedByForeground, let owner = foregroundOwner {
      owner.handleDidClose(webView)
    }
  }

  private func recordError(_ error: Error) {
    let nsErr = error as NSError
    if nsErr.domain == NSURLErrorDomain && nsErr.code == NSURLErrorCancelled {
      return
    }
    if nsErr.domain == "WebKitErrorDomain" && nsErr.code == 102 {
      return
    }
    lastLoadError = nsErr.localizedDescription
  }
}

final class IosGroupWebViewPool {
  static let shared = IosGroupWebViewPool()

  private let maxIdleWarmViews = 3
  private let backgroundViewport = CGRect(x: 0, y: 0, width: 414, height: 896)

  private var entries: [String: PooledAccountWebView] = [:]
  private var inFlightCounts: [String: Int] = [:]
  private var autoApproveEnabled: Bool = false
  private var cachedRafJs: String = ""
  private var cachedNetHookJs: String = ""
  private weak var backgroundHostView: UIView?

  private init() {
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handleMemoryWarning),
      name: UIApplication.didReceiveMemoryWarningNotification,
      object: nil
    )
  }

  private static func poolKey(providerId: String, uuid: String) -> String {
    "\(providerId):\(uuid.lowercased())"
  }

  private static func normalizeOptional(_ raw: String?) -> String? {
    guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
      return nil
    }
    return trimmed
  }

  @objc private func handleMemoryWarning() {
    DispatchQueue.main.async {
      self.evictIdleEntries(maxKeep: 0)
    }
  }

  func setAutoApprove(_ enabled: Bool) {
    autoApproveEnabled = enabled
    let flagLiteral = enabled ? "true" : "false"
    let script = """
    window.__maamAutoApprove = \(flagLiteral);
    if (window.__maamAutoApprove && typeof window.__maamScanAutoApprove === 'function') {
      window.__maamScanAutoApprove();
    }
    """
    for entry in entries.values where !entry.processTerminated {
      entry.webView.evaluateJavaScript(script, completionHandler: nil)
    }
  }

  func currentAutoApprove() -> Bool {
    autoApproveEnabled
  }

  func hasActiveWebView(forUuid uuid: String) -> Bool {
    let norm = uuid.lowercased()
    return entries.values.contains { $0.uuid == norm && $0.isBorrowedByForeground }
  }

  func destroyAllEntriesForUuid(_ uuid: String) {
    let norm = uuid.lowercased()
    let keysToRemove = entries.compactMap { key, val in
      (val.uuid == norm && !val.isBorrowedByForeground) ? key : nil
    }
    for key in keysToRemove {
      if let entry = entries.removeValue(forKey: key) {
        teardownEntry(entry)
      }
    }
  }

  func discardEntry(providerId: String, uuid: String) {
    let key = Self.poolKey(providerId: providerId, uuid: uuid)
    guard let entry = entries[key], !entry.isBorrowedByForeground else {
      return
    }
    entries.removeValue(forKey: key)
    teardownEntry(entry)
  }

  private func teardownEntry(_ entry: PooledAccountWebView) {
    entry.foregroundOwner = nil
    entry.isBorrowedByForeground = false
    entry.webView.stopLoading()
    entry.webView.navigationDelegate = nil
    entry.webView.uiDelegate = nil
    entry.webView.configuration.userContentController.removeScriptMessageHandler(
      forName: LocalStorageSyncScriptHandler.handlerName
    )
    entry.webView.removeFromSuperview()
  }

  private func ensureBackgroundHost() -> UIView? {
    if let host = backgroundHostView, host.window != nil {
      host.superview?.sendSubviewToBack(host)
      return host
    }
    let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    let window =
      scenes.flatMap { $0.windows }.first { $0.isKeyWindow }
      ?? scenes.flatMap { $0.windows }.first
    guard let targetWindow = window else {
      return nil
    }
    let host = UIView(frame: backgroundViewport)
    host.isUserInteractionEnabled = false
    host.clipsToBounds = true
    host.alpha = 0.01
    host.backgroundColor = .clear
    targetWindow.insertSubview(host, at: 0)
    backgroundHostView = host
    return host
  }

  private func parkInBackground(_ entry: PooledAccountWebView) {
    entry.isBorrowedByForeground = false
    entry.foregroundOwner = nil
    entry.touch()
    entry.webView.removeFromSuperview()
    entry.webView.translatesAutoresizingMaskIntoConstraints = true
    entry.webView.frame = backgroundViewport
    if let host = ensureBackgroundHost() {
      host.addSubview(entry.webView)
    }
  }

  private func evictIdleEntries(maxKeep: Int) {
    let candidates = entries.filter { key, entry in
      !entry.isBorrowedByForeground && (inFlightCounts[key] ?? 0) == 0
    }
    guard candidates.count > maxKeep else { return }
    let sorted = candidates.sorted { $0.value.lastUsedMs < $1.value.lastUsedMs }
    let toRemoveCount = candidates.count - maxKeep
    for i in 0..<toRemoveCount {
      let key = sorted[i].key
      if let removed = entries.removeValue(forKey: key) {
        teardownEntry(removed)
      }
    }
  }

  func borrowOrCreateForForeground(
    spec: MobileAccountSessionSpec,
    owner: AccountWebViewController,
    completion: @escaping (Result<(PooledAccountWebView, Bool), IosPoolError>) -> Void
  ) {
    let key = Self.poolKey(providerId: spec.providerId, uuid: spec.uuid)
    let normProxy = Self.normalizeOptional(spec.proxyUrl)
    let normTz = Self.normalizeOptional(spec.timezone)

    if let existing = entries[key] {
      if !existing.processTerminated
        && existing.proxyUrl == normProxy
        && existing.timezone == normTz
      {
        existing.allowedHosts = spec.allowedHosts
        existing.isBorrowedByForeground = true
        existing.foregroundOwner = owner
        existing.touch()
        let hasLiveAllowedPage: Bool = {
          guard let curUrl = existing.webView.url else { return false }
          return AccountSessionCoordinator.shared.hostMatchesAllowed(curUrl, allowedHosts: spec.allowedHosts)
        }()
        completion(.success((existing, hasLiveAllowedPage)))
        return
      } else {
        entries.removeValue(forKey: key)
        teardownEntry(existing)
      }
    }

    guard let parsedUuid = UUID(uuidString: spec.uuid) else {
      completion(.failure(IosPoolError("账号资料 UUID 无效")))
      return
    }

    evictIdleEntries(maxKeep: max(0, maxIdleWarmViews - 1))

    IosProfileStoreManager.shared.prepareDataStore(uuid: parsedUuid, proxyUrl: normProxy) { [weak self] store in
      guard let self = self else { return }
      let wv = self.buildConfiguredWebView(
        dataStore: store,
        uuid: spec.uuid,
        timezoneInitScript: spec.timezoneInitScript,
        backgroundRafJs: self.cachedRafJs,
        netHookJs: self.cachedNetHookJs
      )
      let entry = PooledAccountWebView(
        providerId: spec.providerId,
        uuid: spec.uuid,
        allowedHosts: spec.allowedHosts,
        proxyUrl: normProxy,
        timezone: normTz,
        viewInstanceId: spec.viewInstanceId,
        webView: wv
      )
      entry.isBorrowedByForeground = true
      entry.foregroundOwner = owner
      self.entries[key] = entry
      completion(.success((entry, false)))
    }
  }

  func returnFromForeground(_ entry: PooledAccountWebView, owner: AccountWebViewController) {
    guard entry.foregroundOwner === owner else { return }
    let key = Self.poolKey(providerId: entry.providerId, uuid: entry.uuid)
    IosProfileStoreManager.shared.flushCookiesForUuid(entry.uuid)
    if entry.processTerminated {
      if entries[key] === entry {
        entries.removeValue(forKey: key)
      }
      teardownEntry(entry)
      return
    }
    if entries[key] == nil {
      entries[key] = entry
    }
    parkInBackground(entry)
    evictIdleEntries(maxKeep: maxIdleWarmViews)
  }

  func ensureGroupWebView(
    spec: EnsureGroupWebviewSpec,
    completion: @escaping (Result<GroupWebviewEnsureOutcome, IosPoolError>) -> Void
  ) {
    autoApproveEnabled = spec.autoApprove
    if !spec.backgroundRafJs.isEmpty {
      cachedRafJs = spec.backgroundRafJs
    }
    if !spec.netHookJs.isEmpty {
      cachedNetHookJs = spec.netHookJs
    }

    let key = Self.poolKey(providerId: spec.providerId, uuid: spec.uuid)
    let normProxy = Self.normalizeOptional(spec.proxyUrl)
    let normTz = Self.normalizeOptional(spec.timezone)

    inFlightCounts[key, default: 0] += 1
    let finish: (Result<GroupWebviewEnsureOutcome, IosPoolError>) -> Void = { [weak self] res in
      if let self = self {
        let next = max(0, (self.inFlightCounts[key] ?? 1) - 1)
        if next == 0 {
          self.inFlightCounts.removeValue(forKey: key)
        } else {
          self.inFlightCounts[key] = next
        }
      }
      completion(res)
    }

    if let existing = entries[key] {
      if !existing.processTerminated
        && existing.proxyUrl == normProxy
        && existing.timezone == normTz
      {
        existing.allowedHosts = spec.allowedHosts
        existing.touch()
        if !existing.isBorrowedByForeground && existing.webView.superview == nil {
          parkInBackground(existing)
        }
        if existing.paintReady,
           let curUrl = existing.webView.url,
           curUrl.absoluteString != "about:blank"
        {
          waitUntilWebViewReady(entry: existing, maxAttempts: 40, completion: finish)
          return
        }
      } else if !existing.isBorrowedByForeground {
        entries.removeValue(forKey: key)
        teardownEntry(existing)
      }
    }

    if let borrowed = entries[key] {
      waitUntilWebViewReady(entry: borrowed, maxAttempts: 60, completion: finish)
      return
    }

    guard let parsedUuid = UUID(uuidString: spec.uuid) else {
      finish(.failure(IosPoolError("账号资料 UUID 无效")))
      return
    }
    guard let entryUrl = URL(string: spec.entryUrl) else {
      finish(.failure(IosPoolError("服务入口地址无效")))
      return
    }

    evictIdleEntries(maxKeep: max(0, maxIdleWarmViews - 1))

    IosProfileStoreManager.shared.prepareDataStore(uuid: parsedUuid, proxyUrl: normProxy) { [weak self] store in
      guard let self = self else {
        finish(.failure(IosPoolError("会话池已释放")))
        return
      }
      if let raced = self.entries[key], !raced.processTerminated {
        self.waitUntilWebViewReady(entry: raced, maxAttempts: 80, completion: finish)
        return
      }
      let wv = self.buildConfiguredWebView(
        dataStore: store,
        uuid: spec.uuid,
        timezoneInitScript: spec.timezoneInitScript,
        backgroundRafJs: self.cachedRafJs,
        netHookJs: self.cachedNetHookJs
      )
      let entry = PooledAccountWebView(
        providerId: spec.providerId,
        uuid: spec.uuid,
        allowedHosts: spec.allowedHosts,
        proxyUrl: normProxy,
        timezone: normTz,
        viewInstanceId: spec.requestedViewInstanceId,
        webView: wv
      )
      self.entries[key] = entry
      self.parkInBackground(entry)
      wv.load(URLRequest(url: entryUrl))
      self.waitUntilWebViewReady(entry: entry, maxAttempts: 100, completion: finish)
    }
  }

  private func waitUntilWebViewReady(
    entry: PooledAccountWebView,
    maxAttempts: Int,
    attempt: Int = 0,
    completion: @escaping (Result<GroupWebviewEnsureOutcome, IosPoolError>) -> Void
  ) {
    if entry.processTerminated {
      completion(.failure(IosPoolError("iOS 网页进程因系统内存压力已终止，请重试")))
      return
    }
    let checkJs = """
    (() => {
      try {
        const href = location.href || '';
        if (!href || href === 'about:blank') return JSON.stringify({ ready: false, loggedOut: false, href: '' });
        const ready = document.readyState === 'complete' || document.readyState === 'interactive';
        if (!ready) return JSON.stringify({ ready: false, loggedOut: false, href });
        const path = (location.pathname || '').toLowerCase();
        const hasComposer = Array.from(document.querySelectorAll('textarea, [contenteditable="true"], [role="textbox"]'))
          .some((el) => !el.disabled && !el.readOnly && el.getBoundingClientRect().width > 40);
        const loginInputs = document.querySelectorAll('input[type="email"], input[type="password"], input[autocomplete="one-time-code"]');
        const hasLogin = Array.from(loginInputs).some((i) => !i.disabled && i.getBoundingClientRect().width > 20);
        const bodyText = (document.body && document.body.innerText) || '';
        const loggedOut = (!hasComposer && (/^\\/(login|signin|signup|auth)\\b/.test(path) || hasLogin || /登录或创建账户|Log in or sign up|Sign in to|登录以继续/i.test(bodyText)))
          || (!hasComposer && window.__maamAuthCheck && window.__maamAuthCheck.status === 'invalid');
        return JSON.stringify({
          ready: document.readyState === 'complete' || hasComposer || loggedOut,
          loggedOut,
          href
        });
      } catch (_) {
        return JSON.stringify({ ready: false, loggedOut: false, href: '' });
      }
    })()
    """

    entry.webView.evaluateJavaScript(checkJs) { [weak self] res, _ in
      guard let self = self else { return }
      if let jsonStr = res as? String,
         let data = jsonStr.data(using: .utf8),
         let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
      {
        let isReady = (dict["ready"] as? Bool) ?? false
        let loggedOut = (dict["loggedOut"] as? Bool) ?? false
        let href = (dict["href"] as? String) ?? entry.webView.url?.absoluteString ?? ""
        if isReady && !href.isEmpty {
          entry.paintReady = true
          entry.touch()
          completion(
            .success(
              GroupWebviewEnsureOutcome(
                viewInstanceId: entry.viewInstanceId,
                url: href,
                loggedOut: loggedOut
              )
            )
          )
          return
        }
      }

      if let loadErr = entry.lastLoadError, !entry.paintReady && attempt >= 8 {
        completion(.failure(IosPoolError("成员页面加载失败: \(loadErr)")))
        return
      }

      if attempt + 1 >= maxAttempts {
        let curHref = entry.webView.url?.absoluteString ?? ""
        if !curHref.isEmpty && curHref != "about:blank" {
          entry.paintReady = true
          completion(
            .success(
              GroupWebviewEnsureOutcome(
                viewInstanceId: entry.viewInstanceId,
                url: curHref,
                loggedOut: false
              )
            )
          )
        } else {
          completion(.failure(IosPoolError("成员页面加载超时，请切换至该账号页检查网络或登录状态")))
        }
        return
      }

      DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
        self?.waitUntilWebViewReady(
          entry: entry,
          maxAttempts: maxAttempts,
          attempt: attempt + 1,
          completion: completion
        )
      }
    }
  }

  func evaluateJs(
    providerId: String,
    uuid: String,
    js: String,
    completion: @escaping (GroupWebviewEvalOutcome) -> Void
  ) {
    let key = Self.poolKey(providerId: providerId, uuid: uuid)
    guard let entry = entries[key], !entry.processTerminated else {
      completion(GroupWebviewEvalOutcome(exists: false, valueJson: nil, url: nil, error: "WebView 不存在或已回收"))
      return
    }
    entry.touch()
    if !entry.isBorrowedByForeground && entry.webView.superview == nil {
      parkInBackground(entry)
    }
    entry.webView.evaluateJavaScript(js) { result, error in
      let curUrl = entry.webView.url?.absoluteString
      if let error = error {
        completion(
          GroupWebviewEvalOutcome(
            exists: !entry.processTerminated,
            valueJson: nil,
            url: curUrl,
            error: error.localizedDescription
          )
        )
        return
      }
      let encoded = Self.encodeJsEvalResultToJson(result)
      completion(GroupWebviewEvalOutcome(exists: true, valueJson: encoded, url: curUrl, error: nil))
    }
  }

  func getState(providerId: String, uuid: String) -> GroupWebviewStateOutcome {
    let key = Self.poolKey(providerId: providerId, uuid: uuid)
    guard let entry = entries[key], !entry.processTerminated else {
      return GroupWebviewStateOutcome(exists: false, viewInstanceId: 0, url: nil)
    }
    return GroupWebviewStateOutcome(
      exists: true,
      viewInstanceId: entry.viewInstanceId,
      url: entry.webView.url?.absoluteString
    )
  }

  func navigate(providerId: String, uuid: String, targetUrl: URL) -> Bool {
    let key = Self.poolKey(providerId: providerId, uuid: uuid)
    guard let entry = entries[key], !entry.processTerminated else {
      return false
    }
    entry.touch()
    entry.webView.load(URLRequest(url: targetUrl))
    return true
  }

  func reload(providerId: String, uuid: String) -> Bool {
    let key = Self.poolKey(providerId: providerId, uuid: uuid)
    guard let entry = entries[key], !entry.processTerminated else {
      return false
    }
    entry.touch()
    entry.webView.reload()
    return true
  }

  private func buildConfiguredWebView(
    dataStore: WKWebsiteDataStore,
    uuid: String,
    timezoneInitScript: String?,
    backgroundRafJs: String,
    netHookJs: String
  ) -> WKWebView {
    let config = WKWebViewConfiguration()
    config.websiteDataStore = dataStore
    config.allowsInlineMediaPlayback = true
    config.preferences.javaScriptCanOpenWindowsAutomatically = true
    config.defaultWebpagePreferences.allowsContentJavaScript = true

    let ucc = config.userContentController
    if let lsScript = IosProfileStoreManager.shared.localStorageInitScript(for: uuid) {
      ucc.add(LocalStorageSyncScriptHandler(), name: LocalStorageSyncScriptHandler.handlerName)
      ucc.addUserScript(
        WKUserScript(source: lsScript, injectionTime: .atDocumentStart, forMainFrameOnly: false)
      )
    }

    let flagLiteral = autoApproveEnabled ? "true" : "false"
    ucc.addUserScript(
      WKUserScript(
        source: "window.__maamAutoApprove = \(flagLiteral);",
        injectionTime: .atDocumentStart,
        forMainFrameOnly: true
      )
    )
    ucc.addUserScript(
      WKUserScript(
        source: AccountWebViewController.hookInitScript,
        injectionTime: .atDocumentStart,
        forMainFrameOnly: true
      )
    )
    if !backgroundRafJs.isEmpty {
      ucc.addUserScript(
        WKUserScript(source: backgroundRafJs, injectionTime: .atDocumentStart, forMainFrameOnly: true)
      )
    }
    if !netHookJs.isEmpty {
      ucc.addUserScript(
        WKUserScript(source: netHookJs, injectionTime: .atDocumentStart, forMainFrameOnly: true)
      )
    }
    if let tzScript = timezoneInitScript?.trimmingCharacters(in: .whitespacesAndNewlines), !tzScript.isEmpty {
      ucc.addUserScript(
        WKUserScript(source: tzScript, injectionTime: .atDocumentStart, forMainFrameOnly: false)
      )
    }

    let wv = WKWebView(frame: backgroundViewport, configuration: config)
    wv.allowsBackForwardNavigationGestures = true
    wv.customUserAgent = AccountWebViewController.safariUserAgent
    return wv
  }

  private static func encodeJsEvalResultToJson(_ result: Any?) -> String {
    guard let val = result, !(val is NSNull) else {
      return "null"
    }
    if let str = val as? String {
      if let data = try? JSONEncoder().encode(str),
         let encoded = String(data: data, encoding: .utf8) {
        return encoded
      }
      return "null"
    }
    if CFGetTypeID(val as CFTypeRef) == CFBooleanGetTypeID() {
      return (val as? Bool == true) ? "true" : "false"
    }
    if let num = val as? NSNumber {
      return num.stringValue
    }
    if JSONSerialization.isValidJSONObject(val),
       let data = try? JSONSerialization.data(withJSONObject: val),
       let encoded = String(data: data, encoding: .utf8) {
      return encoded
    }
    return "null"
  }
}
