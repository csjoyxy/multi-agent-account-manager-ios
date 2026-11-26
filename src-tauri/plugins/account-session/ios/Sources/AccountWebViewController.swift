// Modified by csjoyxy in 2026 from https://github.com/ldjx7/multi-agent-account-manager (Apache-2.0) for iOS 16.0+ & iOS Group Chat support.
import Foundation
import Network
import Tauri
import UIKit
import WebKit

struct MobileAccountSessionSpec {
  let providerId: String
  let providerName: String
  let uuid: String
  let alias: String
  let autoAlias: Bool
  let entryUrl: String
  let allowedHosts: [String]
  let proxyUrl: String?
  let timezone: String?
  let timezoneInitScript: String?
  let switchSeq: UInt64
  let viewInstanceId: UInt64
  let isColdStart: Bool
}

final class AccountSessionCoordinator {
  static let shared = AccountSessionCoordinator()

  private let lock = NSLock()
  private var eventChannel: Channel?
  private var latestSwitchSeq: UInt64 = 0
  private var activeSpec: MobileAccountSessionSpec?
  private weak var controllerRef: AccountWebViewController?

  private init() {}

  func setEventChannel(_ channel: Channel) {
    lock.lock()
    eventChannel = channel
    lock.unlock()
  }

  func attachController(_ vc: AccountWebViewController) {
    lock.lock()
    controllerRef = vc
    lock.unlock()
  }

  func detachController(_ vc: AccountWebViewController) {
    lock.lock()
    if controllerRef === vc {
      controllerRef = nil
    }
    lock.unlock()
  }

  func beginSession(_ spec: MobileAccountSessionSpec) -> AccountWebViewController? {
    lock.lock()
    defer { lock.unlock() }
    if spec.switchSeq < latestSwitchSeq {
      return nil
    }
    latestSwitchSeq = spec.switchSeq
    activeSpec = spec
    return controllerRef
  }

  func isCurrent(_ switchSeq: UInt64, _ viewInstanceId: UInt64) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard let cur = activeSpec else { return false }
    return latestSwitchSeq == switchSeq
      && cur.switchSeq == switchSeq
      && cur.viewInstanceId == viewInstanceId
  }

  private static let embeddedWidgetHosts: [String] = [
    "challenges.cloudflare.com",
    "turnstile.cloudflare.com",
    "hcaptcha.com",
    "recaptcha.net",
    "gstatic.com",
    "arkoselabs.com",
    "funcaptcha.com",
    "friendlycaptcha.com",
    "geetest.com",
    "captcha-delivery.com",
    "firebaseapp.com",
    "stripe.com",
    "stripecdn.com",
  ]

  func isUuidActive(_ uuid: String) -> Bool {
    lock.lock()
    let fgActive = activeSpec?.uuid.lowercased() == uuid.lowercased()
    lock.unlock()
    return fgActive || IosGroupWebViewPool.shared.hasActiveWebView(forUuid: uuid)
  }

  func markCommittedAndReveal(_ switchSeq: UInt64, title: String) {
    lock.lock()
    let cur = activeSpec
    let vc = controllerRef
    let valid = cur != nil && latestSwitchSeq == switchSeq && cur?.switchSeq == switchSeq
    lock.unlock()
    guard valid, let spec = cur else { return }
    vc?.revealCommittedSession(switchSeq: spec.switchSeq, viewInstanceId: spec.viewInstanceId, title: title)
  }

  func invalidateAndClose(_ nextSeq: UInt64) -> AccountWebViewController? {
    lock.lock()
    defer { lock.unlock() }
    if nextSeq < latestSwitchSeq {
      return nil
    }
    latestSwitchSeq = nextSeq
    activeSpec = nil
    return controllerRef
  }

  func hostMatchesAllowed(_ url: URL?, allowedHosts: [String]) -> Bool {
    guard let url = url,
          let scheme = url.scheme?.lowercased(),
          scheme == "https",
          let host = url.host?.lowercased(),
          !host.isEmpty else {
      return false
    }
    if allowedHosts.contains("*") {
      return true
    }
    if allowedHosts.contains(where: { allowed in
      let clean = allowed.lowercased()
      return host == clean || host.hasSuffix(".\(clean)")
    }) {
      return true
    }
    if Self.embeddedWidgetHosts.contains(where: { widget in
      host == widget || host.hasSuffix(".\(widget)")
    }) {
      return true
    }
    if (host == "www.google.com" || host == "google.com") && url.path.hasPrefix("/recaptcha") {
      return true
    }
    return false
  }

  func isGoogleOAuthHost(_ url: URL?) -> Bool {
    guard let host = url?.host?.lowercased() else { return false }
    return host == "accounts.google.com" || host.hasSuffix(".accounts.google.com")
  }

  private func sendEvent(switchSeq: UInt64, viewInstanceId: UInt64, _ payload: JsonObject) {
    lock.lock()
    let valid = activeSpec != nil
      && latestSwitchSeq == switchSeq
      && activeSpec?.switchSeq == switchSeq
      && activeSpec?.viewInstanceId == viewInstanceId
    let ch = valid ? eventChannel : nil
    lock.unlock()
    ch?.send(.dictionary(payload))
  }

  func emitPageCommitVisible(spec: MobileAccountSessionSpec, url: String) {
    sendEvent(switchSeq: spec.switchSeq, viewInstanceId: spec.viewInstanceId, [
      "kind": "pageCommitVisible",
      "providerId": spec.providerId,
      "uuid": spec.uuid,
      "switchSeq": spec.switchSeq,
      "viewInstanceId": spec.viewInstanceId,
      "url": url,
    ])
  }

  func emitIdentityDetected(
    spec: MobileAccountSessionSpec,
    identity: String,
    avatarUrl: String?,
    quotaText: String?,
    quotaPercent: Int?,
    quotaDetailJson: String?
  ) {
    var payload: JsonObject = [
      "kind": "identityDetected",
      "providerId": spec.providerId,
      "uuid": spec.uuid,
      "switchSeq": spec.switchSeq,
      "viewInstanceId": spec.viewInstanceId,
      "identity": identity,
    ]
    if let avatarUrl = avatarUrl, !avatarUrl.isEmpty { payload["avatarUrl"] = avatarUrl }
    if let quotaText = quotaText, !quotaText.isEmpty { payload["quotaText"] = quotaText }
    if let quotaPercent = quotaPercent { payload["quotaPercent"] = quotaPercent }
    if let quotaDetailJson = quotaDetailJson, !quotaDetailJson.isEmpty {
      payload["quotaDetailJson"] = quotaDetailJson
    }
    sendEvent(switchSeq: spec.switchSeq, viewInstanceId: spec.viewInstanceId, payload)
  }

  func emitSessionLoggedOut(spec: MobileAccountSessionSpec) {
    sendEvent(switchSeq: spec.switchSeq, viewInstanceId: spec.viewInstanceId, [
      "kind": "sessionLoggedOut",
      "providerId": spec.providerId,
      "uuid": spec.uuid,
      "switchSeq": spec.switchSeq,
      "viewInstanceId": spec.viewInstanceId,
    ])
  }

  func emitSessionFailed(spec: MobileAccountSessionSpec, reason: String) {
    sendEvent(switchSeq: spec.switchSeq, viewInstanceId: spec.viewInstanceId, [
      "kind": "sessionFailed",
      "switchSeq": spec.switchSeq,
      "viewInstanceId": spec.viewInstanceId,
      "reason": reason,
    ])
  }

  func emitExternalAuthUnavailable(spec: MobileAccountSessionSpec, reason: String) {
    sendEvent(switchSeq: spec.switchSeq, viewInstanceId: spec.viewInstanceId, [
      "kind": "externalAuthUnavailable",
      "switchSeq": spec.switchSeq,
      "viewInstanceId": spec.viewInstanceId,
      "reason": reason,
    ])
  }

  func emitActivityClosed(spec: MobileAccountSessionSpec) {
    lock.lock()
    if latestSwitchSeq == spec.switchSeq && activeSpec?.viewInstanceId == spec.viewInstanceId {
      activeSpec = nil
    }
    let ch = eventChannel
    lock.unlock()
    ch?.send(.dictionary([
      "kind": "activityClosed",
      "switchSeq": spec.switchSeq,
      "viewInstanceId": spec.viewInstanceId,
    ]))
  }
}

final class AccountWebViewController: UIViewController, WKNavigationDelegate, WKUIDelegate {
  private var currentSpec: MobileAccountSessionSpec
  private var committedSent = false
  private var consecutiveLoggedOutCount = 0
  private var capturedTypedIdentity: String = ""
  private var probeTimer: Timer?
  private var staleResetDone = false

  private let headerView = UIView()
  private let backButton = UIButton(type: .system)
  private let titleLabel = UILabel()
  private let reloadButton = UIButton(type: .system)
  private let spinner = UIActivityIndicatorView(style: .medium)
  private let contentContainer = UIView()

  private let popupContainer = UIView()
  private let popupHeader = UIView()
  private let popupDomainLabel = UILabel()
  private let popupCloseButton = UIButton(type: .system)
  private let popupWebSlot = UIView()

  private var borrowedEntry: PooledAccountWebView?
  private var mainWebView: WKWebView?
  private var popupWebView: WKWebView?

  static let safariUserAgent =
    "Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1"

  init(initialSpec: MobileAccountSessionSpec) {
    self.currentSpec = initialSpec
    super.init(nibName: nil, bundle: nil)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    setupUI()
    bindSessionSpec(currentSpec)
  }

  deinit {
    probeTimer?.invalidate()
    if let entry = borrowedEntry {
      borrowedEntry = nil
      IosGroupWebViewPool.shared.returnFromForeground(entry, owner: self)
    }
    AccountSessionCoordinator.shared.detachController(self)
  }

  private func setupUI() {
    view.backgroundColor = .systemBackground

    headerView.backgroundColor = .secondarySystemBackground
    headerView.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(headerView)

    let separator = UIView()
    separator.backgroundColor = .separator
    separator.translatesAutoresizingMaskIntoConstraints = false
    headerView.addSubview(separator)

    backButton.setTitle("← 返回", for: .normal)
    backButton.titleLabel?.font = .systemFont(ofSize: 15, weight: .medium)
    backButton.addTarget(self, action: #selector(handleBackTapped), for: .touchUpInside)
    backButton.translatesAutoresizingMaskIntoConstraints = false
    headerView.addSubview(backButton)

    titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
    titleLabel.textColor = .label
    titleLabel.textAlignment = .center
    titleLabel.lineBreakMode = .byTruncatingMiddle
    titleLabel.translatesAutoresizingMaskIntoConstraints = false
    headerView.addSubview(titleLabel)

    spinner.hidesWhenStopped = true
    spinner.translatesAutoresizingMaskIntoConstraints = false
    headerView.addSubview(spinner)

    reloadButton.setTitle("刷新", for: .normal)
    reloadButton.titleLabel?.font = .systemFont(ofSize: 14, weight: .medium)
    reloadButton.addTarget(self, action: #selector(handleReloadTapped), for: .touchUpInside)
    reloadButton.translatesAutoresizingMaskIntoConstraints = false
    headerView.addSubview(reloadButton)

    contentContainer.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(contentContainer)

    popupContainer.isHidden = true
    popupContainer.backgroundColor = .systemBackground
    popupContainer.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(popupContainer)

    popupHeader.backgroundColor = .tertiarySystemBackground
    popupHeader.translatesAutoresizingMaskIntoConstraints = false
    popupContainer.addSubview(popupHeader)

    popupDomainLabel.font = .systemFont(ofSize: 13, weight: .medium)
    popupDomainLabel.textColor = .secondaryLabel
    popupDomainLabel.lineBreakMode = .byTruncatingMiddle
    popupDomainLabel.translatesAutoresizingMaskIntoConstraints = false
    popupHeader.addSubview(popupDomainLabel)

    popupCloseButton.setTitle("关闭弹窗", for: .normal)
    popupCloseButton.titleLabel?.font = .systemFont(ofSize: 14, weight: .medium)
    popupCloseButton.addTarget(self, action: #selector(handleClosePopupTapped), for: .touchUpInside)
    popupCloseButton.translatesAutoresizingMaskIntoConstraints = false
    popupHeader.addSubview(popupCloseButton)

    popupWebSlot.translatesAutoresizingMaskIntoConstraints = false
    popupContainer.addSubview(popupWebSlot)

    NSLayoutConstraint.activate([
      headerView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
      headerView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      headerView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      headerView.heightAnchor.constraint(equalToConstant: 46),

      separator.leadingAnchor.constraint(equalTo: headerView.leadingAnchor),
      separator.trailingAnchor.constraint(equalTo: headerView.trailingAnchor),
      separator.bottomAnchor.constraint(equalTo: headerView.bottomAnchor),
      separator.heightAnchor.constraint(equalToConstant: 0.5),

      backButton.leadingAnchor.constraint(equalTo: headerView.leadingAnchor, constant: 12),
      backButton.centerYAnchor.constraint(equalTo: headerView.centerYAnchor),

      reloadButton.trailingAnchor.constraint(equalTo: headerView.trailingAnchor, constant: -12),
      reloadButton.centerYAnchor.constraint(equalTo: headerView.centerYAnchor),

      spinner.trailingAnchor.constraint(equalTo: reloadButton.leadingAnchor, constant: -8),
      spinner.centerYAnchor.constraint(equalTo: headerView.centerYAnchor),

      titleLabel.leadingAnchor.constraint(greaterThanOrEqualTo: backButton.trailingAnchor, constant: 8),
      titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: spinner.leadingAnchor, constant: -8),
      titleLabel.centerXAnchor.constraint(equalTo: headerView.centerXAnchor),
      titleLabel.centerYAnchor.constraint(equalTo: headerView.centerYAnchor),

      contentContainer.topAnchor.constraint(equalTo: headerView.bottomAnchor),
      contentContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      contentContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      contentContainer.bottomAnchor.constraint(equalTo: view.bottomAnchor),

      popupContainer.topAnchor.constraint(equalTo: headerView.bottomAnchor),
      popupContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      popupContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      popupContainer.bottomAnchor.constraint(equalTo: view.bottomAnchor),

      popupHeader.topAnchor.constraint(equalTo: popupContainer.topAnchor),
      popupHeader.leadingAnchor.constraint(equalTo: popupContainer.leadingAnchor),
      popupHeader.trailingAnchor.constraint(equalTo: popupContainer.trailingAnchor),
      popupHeader.heightAnchor.constraint(equalToConstant: 40),

      popupDomainLabel.leadingAnchor.constraint(equalTo: popupHeader.leadingAnchor, constant: 12),
      popupDomainLabel.centerYAnchor.constraint(equalTo: popupHeader.centerYAnchor),
      popupDomainLabel.trailingAnchor.constraint(lessThanOrEqualTo: popupCloseButton.leadingAnchor, constant: -8),

      popupCloseButton.trailingAnchor.constraint(equalTo: popupHeader.trailingAnchor, constant: -12),
      popupCloseButton.centerYAnchor.constraint(equalTo: popupHeader.centerYAnchor),

      popupWebSlot.topAnchor.constraint(equalTo: popupHeader.bottomAnchor),
      popupWebSlot.leadingAnchor.constraint(equalTo: popupContainer.leadingAnchor),
      popupWebSlot.trailingAnchor.constraint(equalTo: popupContainer.trailingAnchor),
      popupWebSlot.bottomAnchor.constraint(equalTo: popupContainer.bottomAnchor),
    ])
  }

  private func releaseBorrowedWebView() {
    if let entry = borrowedEntry {
      borrowedEntry = nil
      mainWebView = nil
      IosGroupWebViewPool.shared.returnFromForeground(entry, owner: self)
    } else {
      mainWebView?.removeFromSuperview()
      mainWebView = nil
    }
  }

  func bindSessionSpec(_ spec: MobileAccountSessionSpec) {
    currentSpec = spec
    committedSent = false
    consecutiveLoggedOutCount = 0
    capturedTypedIdentity = ""
    staleResetDone = false
    titleLabel.text = "\(spec.providerName) · \(spec.alias)"

    closePopupWebView()
    probeTimer?.invalidate()
    probeTimer = nil
    releaseBorrowedWebView()

    guard UUID(uuidString: spec.uuid) != nil else {
      AccountSessionCoordinator.shared.emitSessionFailed(spec: spec, reason: "账号资料 UUID 无效")
      dismiss(animated: true)
      return
    }

    spinner.startAnimating()
    IosGroupWebViewPool.shared.borrowOrCreateForForeground(spec: spec, owner: self) { [weak self] result in
      guard let self = self else { return }
      guard AccountSessionCoordinator.shared.isCurrent(spec.switchSeq, spec.viewInstanceId) else {
        if case .success(let (entry, _)) = result {
          IosGroupWebViewPool.shared.returnFromForeground(entry, owner: self)
        }
        return
      }

      switch result {
      case .failure(let err):
        self.spinner.stopAnimating()
        AccountSessionCoordinator.shared.emitSessionFailed(spec: spec, reason: err.message)
        self.dismiss(animated: true)
      case .success(let (entry, hasLiveAllowedPage)):
        self.borrowedEntry = entry
        let wv = entry.webView
        wv.removeFromSuperview()
        wv.translatesAutoresizingMaskIntoConstraints = false
        self.contentContainer.addSubview(wv)
        NSLayoutConstraint.activate([
          wv.topAnchor.constraint(equalTo: self.contentContainer.topAnchor),
          wv.leadingAnchor.constraint(equalTo: self.contentContainer.leadingAnchor),
          wv.trailingAnchor.constraint(equalTo: self.contentContainer.trailingAnchor),
          wv.bottomAnchor.constraint(equalTo: self.contentContainer.bottomAnchor),
        ])
        self.mainWebView = wv

        if hasLiveAllowedPage, let curUrl = wv.url {
          self.spinner.stopAnimating()
          self.committedSent = true
          AccountSessionCoordinator.shared.emitPageCommitVisible(spec: spec, url: curUrl.absoluteString)
          self.runProbeTick()
        } else if let entryUrl = URL(string: spec.entryUrl) {
          self.spinner.startAnimating()
          wv.load(URLRequest(url: entryUrl))
        } else {
          self.spinner.stopAnimating()
        }

        self.probeTimer = Timer.scheduledTimer(withTimeInterval: 1.1, repeats: true) { [weak self] _ in
          self?.runProbeTick()
        }
      }
    }
  }

  func revealCommittedSession(switchSeq: UInt64, viewInstanceId: UInt64, title: String) {
    guard currentSpec.switchSeq == switchSeq, currentSpec.viewInstanceId == viewInstanceId else {
      return
    }
    titleLabel.text = title
  }

  func closeFromManager() {
    probeTimer?.invalidate()
    probeTimer = nil
    closePopupWebView()
    releaseBorrowedWebView()
    if presentingViewController != nil {
      dismiss(animated: true)
    }
  }

  @objc private func handleBackTapped() {
    if !popupContainer.isHidden {
      closePopupWebView()
      return
    }
    probeTimer?.invalidate()
    probeTimer = nil
    let spec = currentSpec
    releaseBorrowedWebView()
    AccountSessionCoordinator.shared.emitActivityClosed(spec: spec)
    dismiss(animated: true)
  }

  @objc private func handleReloadTapped() {
    if let popup = popupWebView, !popupContainer.isHidden {
      popup.reload()
    } else {
      mainWebView?.reload()
    }
  }

  @objc private func handleClosePopupTapped() {
    closePopupWebView()
  }

  private func closePopupWebView() {
    popupWebView?.stopLoading()
    popupWebView?.configuration.userContentController.removeScriptMessageHandler(
      forName: LocalStorageSyncScriptHandler.handlerName
    )
    popupWebView?.removeFromSuperview()
    popupWebView = nil
    popupContainer.isHidden = true
  }

  func handleDecidePolicy(
    _ webView: WKWebView,
    navigationAction: WKNavigationAction,
    decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
  ) {
    guard let url = navigationAction.request.url else {
      decisionHandler(.allow)
      return
    }
    let abs = url.absoluteString
    if abs == "about:blank" || abs.hasPrefix("about:srcdoc") || abs.hasPrefix("blob:null/") || abs.hasPrefix("blob:https://") {
      decisionHandler(.allow)
      return
    }
    let isMainFrame = navigationAction.targetFrame?.isMainFrame ?? true
    if !isMainFrame {
      let scheme = url.scheme?.lowercased() ?? ""
      decisionHandler((scheme == "https" || scheme == "http" || scheme == "about" || scheme == "blob" || scheme == "data") ? .allow : .cancel)
      return
    }
    let scheme = url.scheme?.lowercased() ?? ""
    if scheme != "https" {
      decisionHandler(.cancel)
      return
    }
    if AccountSessionCoordinator.shared.isGoogleOAuthHost(url) {
      AccountSessionCoordinator.shared.emitExternalAuthUnavailable(
        spec: currentSpec,
        reason: "iOS 内置窗口暂不支持 Google OAuth，请使用 Chrome 登录后导入 Cookie"
      )
      decisionHandler(.cancel)
      return
    }
    if AccountSessionCoordinator.shared.hostMatchesAllowed(url, allowedHosts: currentSpec.allowedHosts) {
      if webView === popupWebView, let host = url.host {
        popupDomainLabel.text = "🔒 \(host)"
      }
      decisionHandler(.allow)
      return
    }
    decisionHandler(.cancel)
  }

  func handleDidCommit(_ webView: WKWebView) {
    guard webView === mainWebView else { return }
    guard let url = webView.url, url.absoluteString != "about:blank" else { return }
    if !committedSent && AccountSessionCoordinator.shared.hostMatchesAllowed(url, allowedHosts: currentSpec.allowedHosts) {
      committedSent = true
      AccountSessionCoordinator.shared.emitPageCommitVisible(spec: currentSpec, url: url.absoluteString)
    }
  }

  func handleDidFinish(_ webView: WKWebView) {
    if webView === mainWebView {
      spinner.stopAnimating()
      runProbeTick()
    } else if webView === popupWebView {
      IosProfileStoreManager.shared.flushCookiesForUuid(currentSpec.uuid)
    }
  }

  func handleDidFail(_ webView: WKWebView, error: Error) {
    handleLoadError(webView, error: error)
  }

  func handleProcessDidTerminate(_ webView: WKWebView) {
    if webView === mainWebView {
      webView.reload()
    } else if webView === popupWebView {
      closePopupWebView()
    }
  }

  func handleCreatePopupWebView(
    _ webView: WKWebView,
    configuration: WKWebViewConfiguration,
    navigationAction: WKNavigationAction
  ) -> WKWebView? {
    if let target = navigationAction.request.url,
       AccountSessionCoordinator.shared.isGoogleOAuthHost(target) {
      AccountSessionCoordinator.shared.emitExternalAuthUnavailable(
        spec: currentSpec,
        reason: "iOS 内置窗口暂不支持 Google OAuth，请使用 Chrome 登录后导入 Cookie"
      )
      return nil
    }
    closePopupWebView()
    let ucc = WKUserContentController()
    configuration.userContentController = ucc
    if let lsScript = IosProfileStoreManager.shared.localStorageInitScript(for: currentSpec.uuid) {
      ucc.add(LocalStorageSyncScriptHandler(), name: LocalStorageSyncScriptHandler.handlerName)
      ucc.addUserScript(
        WKUserScript(source: lsScript, injectionTime: .atDocumentStart, forMainFrameOnly: false)
      )
    }
    let autoFlag = IosGroupWebViewPool.shared.currentAutoApprove() ? "true" : "false"
    ucc.addUserScript(
      WKUserScript(source: "window.__maamAutoApprove = \(autoFlag);", injectionTime: .atDocumentStart, forMainFrameOnly: true)
    )
    ucc.addUserScript(
      WKUserScript(source: Self.hookInitScript, injectionTime: .atDocumentStart, forMainFrameOnly: true)
    )
    if let tzScript = currentSpec.timezoneInitScript, !tzScript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      ucc.addUserScript(
        WKUserScript(source: tzScript, injectionTime: .atDocumentStart, forMainFrameOnly: false)
      )
    }
    let popup = WKWebView(frame: .zero, configuration: configuration)
    popup.navigationDelegate = self
    popup.uiDelegate = self
    popup.customUserAgent = Self.safariUserAgent
    popup.translatesAutoresizingMaskIntoConstraints = false
    popupWebSlot.addSubview(popup)
    NSLayoutConstraint.activate([
      popup.topAnchor.constraint(equalTo: popupWebSlot.topAnchor),
      popup.leadingAnchor.constraint(equalTo: popupWebSlot.leadingAnchor),
      popup.trailingAnchor.constraint(equalTo: popupWebSlot.trailingAnchor),
      popup.bottomAnchor.constraint(equalTo: popupWebSlot.bottomAnchor),
    ])
    popupWebView = popup
    popupDomainLabel.text = navigationAction.request.url?.host.map { "🔒 \($0)" } ?? "登录窗口"
    popupContainer.isHidden = false
    return popup
  }

  func handleDidClose(_ webView: WKWebView) {
    if webView === popupWebView {
      closePopupWebView()
    }
  }

  func webView(
    _ webView: WKWebView,
    decidePolicyFor navigationAction: WKNavigationAction,
    decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
  ) {
    handleDecidePolicy(webView, navigationAction: navigationAction, decisionHandler: decisionHandler)
  }

  func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
    handleDidCommit(webView)
  }

  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    handleDidFinish(webView)
  }

  func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
    handleDidFail(webView, error: error)
  }

  func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
    handleDidFail(webView, error: error)
  }

  func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
    handleProcessDidTerminate(webView)
  }

  private func handleLoadError(_ webView: WKWebView, error: Error) {
    guard webView === mainWebView else { return }
    spinner.stopAnimating()
    let nsErr = error as NSError
    if nsErr.domain == NSURLErrorDomain && nsErr.code == NSURLErrorCancelled {
      return
    }
    if nsErr.domain == "WebKitErrorDomain" && nsErr.code == 102 {
      return
    }
    if !committedSent {
      AccountSessionCoordinator.shared.emitSessionFailed(
        spec: currentSpec,
        reason: "页面加载失败: \(nsErr.localizedDescription)"
      )
    }
  }

  func webView(
    _ webView: WKWebView,
    createWebViewWith configuration: WKWebViewConfiguration,
    for navigationAction: WKNavigationAction,
    windowFeatures: WKWindowFeatures
  ) -> WKWebView? {
    handleCreatePopupWebView(webView, configuration: configuration, navigationAction: navigationAction)
  }

  func webViewDidClose(_ webView: WKWebView) {
    handleDidClose(webView)
  }

  private func runProbeTick() {
    let spec = currentSpec
    guard AccountSessionCoordinator.shared.isCurrent(spec.switchSeq, spec.viewInstanceId) else {
      return
    }
    if let popup = popupWebView, !popupContainer.isHidden {
      popup.evaluateJavaScript(Self.identityProbeJs) { [weak self] result, _ in
        guard let self = self,
              let jsonStr = result as? String,
              let data = jsonStr.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
          return
        }
        let email = (dict["email"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let typed = (dict["typed"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !email.isEmpty {
          self.capturedTypedIdentity = email
        } else if !typed.isEmpty {
          self.capturedTypedIdentity = typed
        }
      }
    }

    mainWebView?.evaluateJavaScript(Self.identityProbeJs) { [weak self] result, _ in
      guard let self = self else { return }
      guard AccountSessionCoordinator.shared.isCurrent(spec.switchSeq, spec.viewInstanceId),
            let jsonStr = result as? String,
            let data = jsonStr.data(using: .utf8),
            let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        return
      }
      let typed = (dict["typed"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
      if !typed.isEmpty {
        self.capturedTypedIdentity = typed
      }
      let isAuth = (dict["auth"] as? Bool) ?? false
      let loggedOut = (dict["loggedOut"] as? Bool) ?? false
      let stale = (dict["staleSession"] as? Bool) ?? false

      if isAuth {
        self.consecutiveLoggedOutCount = 0
        self.staleResetDone = false
        let email = (dict["email"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedId = !email.isEmpty ? email : self.capturedTypedIdentity
        let avatar = dict["avatar"] as? String
        let quotaText = dict["quotaText"] as? String
        let quotaPct = (dict["quotaPct"] as? NSNumber)?.intValue
        var detailJson: String? = nil
        if let detailObj = dict["quotaDetail"], !(detailObj is NSNull),
           let detailData = try? JSONSerialization.data(withJSONObject: detailObj),
           let str = String(data: detailData, encoding: .utf8) {
          detailJson = str
        }
        AccountSessionCoordinator.shared.emitIdentityDetected(
          spec: spec,
          identity: resolvedId,
          avatarUrl: avatar,
          quotaText: quotaText,
          quotaPercent: quotaPct,
          quotaDetailJson: detailJson
        )
      } else if loggedOut {
        self.consecutiveLoggedOutCount += 1
        if self.consecutiveLoggedOutCount >= 2 {
          AccountSessionCoordinator.shared.emitSessionLoggedOut(spec: spec)
          if stale && !self.staleResetDone {
            self.staleResetDone = true
            if spec.providerId == "muse", let logoutUrl = URL(string: "https://muse.ai/api/logout") {
              self.mainWebView?.load(URLRequest(url: logoutUrl))
            } else if spec.providerId == "hark", let loginUrl = URL(string: "https://app.hark.com/login") {
              self.mainWebView?.load(URLRequest(url: loginUrl))
            }
          }
        }
      }
    }
  }

  static let hookInitScript = #"""
(() => {
  try {
    if (location.protocol !== 'https:') return;
    if (window !== window.top) return;
    if (window.__maamNetHooked) return;
    window.__maamNetHooked = true;
    const initHost = (location.hostname || '').toLowerCase();
    const isPrimaryHost = initHost === 'muse.ai' || initHost.endsWith('.muse.ai') || initHost === 'app.hark.com' || initHost.endsWith('.hark.com');
    const authCheck = window.__maamAuthCheck || { status: 'unknown', checkedAt: 0, inflight: false };
    window.__maamAuthCheck = authCheck;
    const markAuthInvalid = () => {
      authCheck.status = 'invalid';
      authCheck.checkedAt = Date.now();
      window.__maamQuota = null;
      window.__maamQuotaDetail = null;
      try {
        localStorage.removeItem('__maam_cached_quota__');
        localStorage.removeItem('__maam_cached_quota_detail_v2__');
      } catch (_) {}
    };
    const markAuthOk = () => {
      authCheck.status = 'ok';
      authCheck.checkedAt = Date.now();
    };
    const setQuota = (text, pct) => {
      if (!text) return;
      const cleanPct = typeof pct === 'number' && Number.isFinite(pct) ? Math.max(0, Math.min(100, Math.round(pct))) : null;
      const obj = { text: String(text).slice(0, 48), pct: cleanPct };
      window.__maamQuota = obj;
      try { localStorage.setItem('__maam_cached_quota__', JSON.stringify(obj)); } catch (_) {}
    };
    const saveDetail = (detail) => {
      if (!detail || !detail.planLabel) return;
      window.__maamQuotaDetail = detail;
      try { localStorage.setItem('__maam_cached_quota_detail_v2__', JSON.stringify(detail)); } catch (_) {}
      const rem = typeof detail.planUsedPercent === 'number' ? Math.max(0, Math.min(100, 100 - detail.planUsedPercent)) : null;
      setQuota(detail.planValue || detail.planLabel, rem);
    };
    const formatHarkReset = (iso) => {
      if (!iso || typeof iso !== 'string') return null;
      const d = new Date(iso);
      if (Number.isNaN(d.getTime())) return null;
      const pad = (n) => String(n).padStart(2, '0');
      const hhmm = pad(d.getHours()) + ':' + pad(d.getMinutes());
      const now = new Date();
      const diffDays = Math.round((new Date(d.getFullYear(), d.getMonth(), d.getDate()).getTime() - new Date(now.getFullYear(), now.getMonth(), now.getDate()).getTime()) / 86400000);
      if (diffDays === 0) return '今天 ' + hhmm + ' 重置';
      if (diffDays === 1) return '明天 ' + hhmm + ' 重置';
      return (d.getMonth() + 1) + '月' + d.getDate() + '日 ' + hhmm + ' 重置';
    };
    const mapHarkSub = (node) => {
      if (!(location.hostname || '').toLowerCase().endsWith('hark.com')) return null;
      if (!node || typeof node !== 'object') return null;
      const meters = (node.meters && typeof node.meters === 'object' ? (node.meters.harkTokens || node.meters) : null)
        || (node.harkTokens && typeof node.harkTokens === 'object' ? node.harkTokens : null)
        || (('dailyLimit' in node || 'poolLimit' in node) ? node : null);
      if (meters && typeof meters === 'object' && (typeof meters.dailyLimit === 'number' || typeof meters.poolLimit === 'number')) {
        const rawPlan = (node.plan && node.plan.name) || node.planName || (typeof node.plan === 'string' ? node.plan : '') || '';
        const shortPlan = String(rawPlan).replace(/^hark\s+/i, '').trim();
        const hasDaily = typeof meters.dailyLimit === 'number' && meters.dailyLimit > 0 && typeof meters.dailyUsed === 'number';
        const hasMonthly = typeof meters.poolLimit === 'number' && meters.poolLimit > 0 && typeof meters.poolUsed === 'number';
        if (hasDaily || hasMonthly) {
          const dailyPct = hasDaily ? Math.max(0, Math.min(100, Math.round((meters.dailyUsed / meters.dailyLimit) * 100))) : null;
          const monthlyPct = hasMonthly ? Math.max(0, Math.min(100, Math.round((meters.poolUsed / meters.poolLimit) * 100))) : null;
          if (hasDaily) {
            return {
              planLabel: shortPlan ? (shortPlan + ' · 每日') : '每日上限',
              planValue: '已使用 ' + dailyPct + '%',
              planSubtext: formatHarkReset(meters.dailyResetsAt),
              planUsedPercent: dailyPct,
              extraLabel: hasMonthly ? '每月上限' : null,
              extraValue: hasMonthly ? ('已使用 ' + monthlyPct + '%') : null,
              extraSubtext: hasMonthly ? formatHarkReset(meters.poolResetsAt) : null,
              extraUsedPercent: monthlyPct
            };
          }
          return {
            planLabel: shortPlan ? (shortPlan + ' · 每月') : '每月上限',
            planValue: '已使用 ' + monthlyPct + '%',
            planSubtext: formatHarkReset(meters.poolResetsAt),
            planUsedPercent: monthlyPct,
            extraLabel: null, extraValue: null, extraSubtext: null, extraUsedPercent: null
          };
        }
      }
      return null;
    };
    const mapSub = (node) => {
      if (!node || typeof node !== 'object') return null;
      const harkRes = mapHarkSub(node);
      if (harkRes) return harkRes;
      const s = (node.subscription && typeof node.subscription === 'object' && node.subscription.usage) ? node.subscription : node;
      const u = s.usage;
      if (!u || typeof u !== 'object') return null;
      if (!('state' in u) && !('percentUsed' in u) && !('percent_used' in u) && !('quotaStatus' in u) && !('quota_status' in u)) return null;
      const subType = s.subscriptionType || s.subscription_type || '';
      const tierName = (s.tier && typeof s.tier.name === 'string' && s.tier.name.trim()) || '';
      const planLabel = (typeof s.usageRowLabel === 'string' && s.usageRowLabel.trim()) || (typeof s.usage_row_label === 'string' && s.usage_row_label.trim()) || tierName || (subType === 'PAID' ? '订阅版' : subType === 'FREE' ? '免费版' : '基础额度');
      const rawPct = typeof u.percentUsed === 'number' ? u.percentUsed : u.percent_used;
      const qStatus = u.quotaStatus || u.quota_status || '';
      let planUsedPercent = null;
      if (u.state !== 'UNLIMITED' && typeof rawPct === 'number' && Number.isFinite(rawPct)) {
        planUsedPercent = Math.max(0, Math.min(100, Math.round(rawPct)));
      } else if (qStatus === 'DEPLETED') {
        planUsedPercent = 100;
      }
      const rawVal = (typeof s.usageRowValueLabel === 'string' && s.usageRowValueLabel.trim()) || (typeof s.usage_row_value_label === 'string' && s.usage_row_value_label.trim()) || '';
      const planValue = rawVal || (u.state === 'UNLIMITED' ? '无限额度' : planUsedPercent !== null ? ('已使用 ' + planUsedPercent + '%') : qStatus === 'DEPLETED' ? '已用尽' : '额度充足');
      let planSubtext = (typeof s.statusSubtitle === 'string' && s.statusSubtitle.trim()) || (typeof s.status_subtitle === 'string' && s.status_subtitle.trim()) || null;
      const topupVal = (typeof s.topupRowValueLabel === 'string' && s.topupRowValueLabel.trim()) || (typeof s.topup_row_value_label === 'string' && s.topup_row_value_label.trim()) || '';
      const topupBal = typeof s.topupBalance === 'number' ? s.topupBalance : s.topup_balance;
      const topupTot = typeof s.topupTotal === 'number' ? s.topupTotal : s.topup_total;
      let extraLabel = null, extraValue = null, extraSubtext = null, extraUsedPercent = null;
      if (topupVal || (typeof topupTot === 'number' && topupTot > 0)) {
        extraLabel = (typeof s.topupRowLabel === 'string' && s.topupRowLabel.trim()) || '额外的使用额度';
        if (typeof topupTot === 'number' && topupTot > 0 && typeof topupBal === 'number') {
          extraUsedPercent = Math.max(0, Math.min(100, Math.round(((topupTot - topupBal) / topupTot) * 100)));
        }
        extraValue = topupVal || (extraUsedPercent !== null ? ('已使用 ' + extraUsedPercent + '%') : null);
        extraSubtext = '从不过期';
      }
      return { planLabel, planValue, planSubtext, planUsedPercent, extraLabel, extraValue, extraSubtext, extraUsedPercent };
    };
    const BAD_EMAIL_RE = /^(?:support|privacy|help|legal|press|noreply|no-reply|info|security|contact|abuse|feedback|sales|terms|hello|team|admin)@/i;
    const EMAIL_STRICT_RE = /^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$/;
    const recordEmail = (raw) => {
      if (typeof raw !== 'string') return;
      const clean = raw.trim().toLowerCase();
      if (EMAIL_STRICT_RE.test(clean) && !BAD_EMAIL_RE.test(clean) && !clean.endsWith('@example.com')) {
        window.__maamApiEmail = clean;
      }
    };
    const inspectNode = (node, depth, skipSub) => {
      if (!node || typeof node !== 'object' || depth > 8) return;
      if (Array.isArray(node)) {
        for (let i = 0; i < node.length && i < 20; i++) inspectNode(node[i], depth + 1, skipSub);
        return;
      }
      for (const ek of ['email', 'user_email', 'userEmail', 'contact_email', 'primary_email']) {
        if (typeof node[ek] === 'string' && node[ek].includes('@')) recordEmail(node[ek]);
      }
      let nextSkip = Boolean(skipSub);
      if (!nextSkip) {
        const mapped = mapSub(node);
        if (mapped) { saveDetail(mapped); nextSkip = true; }
      }
      const keys = Object.keys(node);
      for (let i = 0; i < keys.length && i < 32; i++) {
        const v = node[keys[i]];
        if (v && typeof v === 'object') inspectNode(v, depth + 1, nextSkip);
      }
    };
    const inspectText = (txt) => {
      if (typeof txt !== 'string' || txt.length < 2 || txt.length > 400000) return;
      if (!/percent_used|percentUsed|quota_status|quotaStatus|usage_row_value_label|usageRowValueLabel|email|credits|billing|subscription|harkTokens|dailyLimit|poolLimit|meters/i.test(txt)) return;
      try { inspectNode(JSON.parse(txt), 0, false); return; } catch (_) {}
      const lines = txt.split('\n');
      for (let i = 0; i < lines.length && i < 200; i++) {
        const idx = lines[i].indexOf(':');
        if (idx > 0 && idx < 12) {
          const rest = lines[i].slice(idx + 1).trim();
          if (rest.startsWith('{') || rest.startsWith('[')) {
            try { inspectNode(JSON.parse(rest), 0, false); } catch (_) {}
          }
        }
      }
    };
    const origFetch = window.fetch;
    if (isPrimaryHost && typeof origFetch === 'function') {
      window.fetch = function(...args) {
        const reqUrl = typeof args[0] === 'string' ? args[0] : (args[0] && args[0].url) || '';
        const p = origFetch.apply(this, args);
        p.then((res) => {
          try {
            const parsedUrl = new URL(reqUrl || '', location.origin);
            const path = parsedUrl.origin === location.origin ? parsedUrl.pathname : '';
            if (res.status === 401 && path.startsWith('/api/')) markAuthInvalid();
            else if (res.ok && (path === '/api/client-version' || path === '/api/auth/check' || path === '/api/profile' || path === '/api/billing/summary' || path.startsWith('/api/chat'))) markAuthOk();
            const ct = (res.headers && res.headers.get('content-type')) || '';
            if (!ct.includes('event-stream') && (ct.includes('json') || ct.includes('text'))) {
              res.clone().text().then(inspectText).catch(() => {});
            }
          } catch (_) {}
        }).catch(() => {});
        return p;
      };
    }
    window.__maamVerifySession = async () => {
      if (authCheck.inflight || typeof origFetch !== 'function') return;
      const now = Date.now();
      if (authCheck.checkedAt && now - authCheck.checkedAt < 12000) return;
      authCheck.inflight = true;
      try {
        if (initHost.endsWith('muse.ai')) {
          const r1 = await origFetch.call(window, '/api/client-version', { credentials: 'same-origin', cache: 'no-store' });
          if (r1 && r1.status === 401) { markAuthInvalid(); return; }
          if (r1 && r1.ok) {
            const r2 = await origFetch.call(window, '/api/auth/check', { method: 'POST', credentials: 'include', cache: 'no-store' });
            if (r2 && (r2.status === 401 || r2.status === 403)) { markAuthInvalid(); return; }
            if (r2 && r2.ok) { markAuthOk(); return; }
          }
        } else if (initHost.endsWith('hark.com')) {
          const r = await origFetch.call(window, '/api/profile', { credentials: 'include', cache: 'no-store' });
          if (r && r.status === 401) { markAuthInvalid(); return; }
          if (r && r.ok) { r.clone().text().then(inspectText).catch(() => {}); markAuthOk(); return; }
        }
        authCheck.checkedAt = Date.now();
      } catch (_) { authCheck.checkedAt = Date.now(); } finally { authCheck.inflight = false; }
    };
    if (isPrimaryHost && !window.__maamAutoApproveWatcher) {
      window.__maamAutoApproveWatcher = true;
      const DANGER_RE = /删除|移除|注销|清空|退出登录|退出账户|确认退出|支付|付款|购买|订阅|充值|转账|密码|更改邮箱|停用|封禁|delete|remove|logout|log out|sign out|payment|purchase|billing|checkout|subscribe|charge|transfer|password|deactivate|reset account/i;
      const PROMPT_RE = /授权|审批|权限|批准|请求允许|请求执行|需要你的允许|需要您的允许|需要确认|是否(?:允许|批准|授权|同意)|要允许|你的助手想要|助手想要|想(?:要|使用|访问|运行|执行|打开|上传|下载|读取|写入|查看|获取|调用|连接|发送)|允许.{0,24}(?:此操作|此次|使用|运行|执行|访问|操作|工具|命令|浏览|上传|下载|读取|写入|修改|打开|连接|发送|调用|查看|获取)|approve|approval|authorize|permission|wants to|would like to|asks? to|needs approval|allow\s+.{0,32}\bto\b|allow\s+.{0,24}(?:this|use|run|execute|access|tool|command|browser|upload|download|read|write|open|connect|send)/i;
      const SINGLE_APPROVE_BTN_RE = /^(?:允许(?!.*(?:始终|总是))[^，。！？]{0,10}|本次允许|仅允许一次|批准(?!.*(?:始终|总是))[^，。！？]{0,10}|同意(?:并继续)?|确认授权|确认允许|继续执行|allow(?!\s+always)(?:\s+(?:once|this\s+time|this\s+\w+|access|upload|download|run|execute|use))?|approve(?:\s+(?:once|this\s+\w+))?|authorize|grant)$/i;
      const APPROVE_BTN_RE = /^(?:(?:允许|本次允许|仅允许一次|始终允许|总是允许|批准|始终批准)[^，。！？]{0,18}|同意(?:并继续)?|确认授权|确认允许|继续执行|(?:allow|always\s+allow|approve|always\s+approve|authorize|grant)(?:\s+[\w\s'-]{1,28})?)$/i;
      const REJECT_BTN_RE = /^(?:(?:拒绝|不允许|不批准)[^，。！？]{0,12}|取消|暂不|以后再说|(?:deny|decline|reject|don't allow|do not allow)(?:\s+[\w\s'-]{1,20})?|cancel|block|never|not now)$/i;
      const MODAL_BOX_SEL = '[role="dialog"], [role="alertdialog"], [aria-modal="true"], dialog, [class*="permission" i], [class*="approval" i], [class*="approve" i], [class*="authorize" i], [class*="consent" i], [data-testid*="approv" i], [data-testid*="permiss" i]';
      const clickedAt = new WeakMap();
      const getBtnLabel = (b) => ((b.innerText || b.textContent || b.getAttribute('aria-label') || '') + '').replace(/\s+/g, ' ').trim();
      const isElVisible = (el) => {
        if (!el || !el.isConnected) return false;
        const r = el.getBoundingClientRect();
        if (r.width < 16 || r.height < 14) return false;
        let cur = el;
        for (let d = 0; cur && cur.nodeType === 1 && d < 8; d++) {
          try {
            const st = getComputedStyle(cur);
            if (st.display === 'none' || st.visibility === 'hidden') return false;
            const op = parseFloat(st.opacity);
            if (!Number.isNaN(op) && op < 0.05) return false;
          } catch (_) {}
          cur = cur.parentElement;
        }
        return true;
      };
      const isActionableBtn = (b) => {
        if (!isElVisible(b) || b.disabled || b.getAttribute('aria-disabled') === 'true') return false;
        if (b.closest && b.closest('nav, aside')) return false;
        return true;
      };
      const findApprovalTarget = () => {
        try {
          const allBtns = document.querySelectorAll('button, [role="button"]');
          for (const b of allBtns) {
            if (!isActionableBtn(b)) continue;
            const lbl = getBtnLabel(b);
            if (!APPROVE_BTN_RE.test(lbl) || REJECT_BTN_RE.test(lbl) || DANGER_RE.test(lbl)) continue;
            let cur = b.parentElement;
            for (let step = 0; step < 7 && cur && cur !== document.body && cur !== document.documentElement; step++) {
              if (cur.tagName === 'NAV' || cur.tagName === 'ASIDE') break;
              let isModal = false;
              try { isModal = typeof cur.matches === 'function' && cur.matches(MODAL_BOX_SEL); } catch (_) {}
              if (!isModal && cur.querySelector && cur.querySelector('textarea, [contenteditable="true"]')) break;
              const txt = (cur.innerText || cur.textContent || '').trim();
              if (txt.length > 2200) break;
              if (txt.length >= 6) {
                if (DANGER_RE.test(txt)) break;
                if (PROMPT_RE.test(txt)) {
                  const boxBtns = Array.from(cur.querySelectorAll('button, [role="button"]')).filter(isActionableBtn);
                  const hasReject = boxBtns.some((x) => REJECT_BTN_RE.test(getBtnLabel(x)));
                  if (hasReject || isModal) {
                    const approveBtns = boxBtns.filter((x) => {
                      const xLbl = getBtnLabel(x);
                      return APPROVE_BTN_RE.test(xLbl) && !REJECT_BTN_RE.test(xLbl) && !DANGER_RE.test(xLbl);
                    });
                    if (approveBtns.length > 0) {
                      const picked = approveBtns.find((x) => SINGLE_APPROVE_BTN_RE.test(getBtnLabel(x))) || approveBtns[0];
                      return { box: cur, button: picked, text: txt };
                    }
                  }
                }
              }
              cur = cur.parentElement;
            }
          }
        } catch (_) {}
        return null;
      };
      window.__maamFindAuthPrompt = () => {
        const target = findApprovalTarget();
        return target ? target.text.slice(0, 140) : '';
      };
      window.__maamScanAutoApprove = () => {
        if (window.__maamAutoApprove !== true) return false;
        const target = findApprovalTarget();
        if (!target) return false;
        const now = Date.now();
        const last = clickedAt.get(target.button) || 0;
        if (now - last < 4000) return false;
        clickedAt.set(target.button, now);
        target.button.click();
        return true;
      };
      let approveTimer = null;
      const scheduleAutoApproveScan = () => {
        if (window.__maamAutoApprove !== true || approveTimer) return;
        approveTimer = setTimeout(() => {
          approveTimer = null;
          window.__maamScanAutoApprove();
        }, 250);
      };
      const startObserver = () => {
        try {
          if (!document.documentElement) return;
          const obs = new MutationObserver(() => scheduleAutoApproveScan());
          obs.observe(document.documentElement, { childList: true, subtree: true });
        } catch (_) {}
      };
      if (document.documentElement) {
        startObserver();
      } else {
        document.addEventListener('DOMContentLoaded', startObserver, { once: true });
      }
      setInterval(() => {
        if (window.__maamAutoApprove === true) {
          window.__maamScanAutoApprove();
        }
      }, 1200);
    }
    const capture = (el) => {
      if (!el || typeof el.value !== 'string') return;
      const v = el.value.trim();
      if (/^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$/.test(v)) {
        window.__maamTypedIdentity = v.toLowerCase();
        try { sessionStorage.setItem('__maam_typed_identity__', window.__maamTypedIdentity); } catch (_) {}
      }
    };
    document.addEventListener('input', (e) => capture(e.target), true);
    document.addEventListener('change', (e) => capture(e.target), true);
    document.addEventListener('submit', () => document.querySelectorAll('input').forEach(capture), true);
  } catch (_) {}
})();
"""#

  private static let identityProbeJs = #"""
(() => {
  try {
    document.querySelectorAll('input').forEach((el) => {
      const v = (el.value || '').trim();
      if (/^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$/.test(v)) {
        window.__maamTypedIdentity = v.toLowerCase();
      }
    });
    let typed = window.__maamTypedIdentity || '';
    try { typed = typed || sessionStorage.getItem('__maam_typed_identity__') || ''; } catch (_) {}
    const host = (location.hostname || '').toLowerCase();
    const path = (location.pathname || '').toLowerCase();
    const isMetaCenter = host === 'accountscenter.meta.com';
    const isPrimary = host === 'muse.ai' || host.endsWith('.muse.ai') || host === 'app.hark.com' || host.endsWith('.hark.com');
    const isExtLogin = host === 'meta.com' || host.endsWith('.meta.com') || host === 'facebook.com' || host.endsWith('.facebook.com') || host === 'appleid.apple.com';
    const loginInputs = document.querySelectorAll('input[type="email"], input[type="password"], input[autocomplete="one-time-code"], input[placeholder*="邮箱"], input[placeholder*="email" i]');
    const hasLoginInput = Array.from(loginInputs).some((i) => !i.disabled && !i.readOnly && i.getBoundingClientRect().width > 20);
    const hasComposer = Array.from(document.querySelectorAll('textarea, [contenteditable="true"]')).some((el) => !el.disabled && !el.readOnly && el.getBoundingClientRect().width > 100);
    const bodyText = (document.body && document.body.innerText) || '';
    const bad = /^(support|privacy|help|legal|press|noreply|no-reply|info|security|contact|abuse|feedback|sales|terms|hello|team|admin)@/i;
    const providerMail = /@(?:[a-z0-9-]+\.)?(?:muse\.ai|hark\.com|meta\.com|facebook\.com)$/i;
    const re = /[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}/g;
    if (isExtLogin) {
      if (isMetaCenter && document.readyState !== 'loading') {
        const cands = (bodyText.match(re) || []).map((s) => s.toLowerCase()).filter((s) => !bad.test(s) && !s.endsWith('@example.com'));
        const metaEmail = cands.find((e) => !providerMail.test(e)) || cands[0] || '';
        return JSON.stringify({ auth: false, loggedOut: false, staleSession: false, typed, email: metaEmail, avatar: '', quotaText: '', quotaPct: null, quotaDetail: null });
      }
      return JSON.stringify({ auth: false, loggedOut: /^\/(login|signin|signup|auth)\b/.test(path) || hasLoginInput, staleSession: false, typed, email: '', avatar: '', quotaText: '', quotaPct: null, quotaDetail: null });
    }
    if (!isPrimary || document.readyState !== 'complete') {
      return JSON.stringify({ auth: false, loggedOut: false, staleSession: false, typed, email: '', avatar: '', quotaText: '', quotaPct: null, quotaDetail: null });
    }
    if (/^\/(login|signin|signup|auth)\b/.test(path) || (!hasComposer && hasLoginInput) || (!hasComposer && /登录或创建账户|Log in or sign up|Sign in to|登录以继续/i.test(bodyText))) {
      return JSON.stringify({ auth: false, loggedOut: true, staleSession: false, typed, email: '', avatar: '', quotaText: '', quotaPct: null, quotaDetail: null });
    }
    if (!hasComposer && window.__maamAuthCheck && window.__maamAuthCheck.status === 'invalid') {
      return JSON.stringify({ auth: false, loggedOut: true, staleSession: true, typed, email: '', avatar: '', quotaText: '', quotaPct: null, quotaDetail: null });
    }
    if (!hasComposer && typeof window.__maamVerifySession === 'function') {
      window.__maamVerifySession();
    }
    let detail = window.__maamQuotaDetail || null;
    if (!detail) {
      try { detail = JSON.parse(localStorage.getItem('__maam_cached_quota_detail_v2__') || 'null'); } catch (_) {}
    }
    let quotaText = (detail && (detail.planValue || detail.planLabel)) || (window.__maamQuota && window.__maamQuota.text) || '';
    let quotaPct = detail && typeof detail.planUsedPercent === 'number' ? Math.max(0, 100 - detail.planUsedPercent) : (window.__maamQuota ? window.__maamQuota.pct : null);
    const cands = [];
    if (window.__maamApiEmail) cands.push(window.__maamApiEmail);
    const bm = bodyText.match(re);
    if (bm) cands.push(...bm);
    const clean = cands.map((x) => String(x).toLowerCase()).filter((x) => !bad.test(x) && !x.endsWith('@example.com'));
    const foundEmail = clean.find((e) => !providerMail.test(e)) || clean[0] || '';
    return JSON.stringify({ auth: true, loggedOut: false, staleSession: false, typed, email: foundEmail, avatar: '', quotaText, quotaPct, quotaDetail: detail });
  } catch (_) {
    return JSON.stringify({ auth: false, loggedOut: false, staleSession: false, typed: '', email: '', avatar: '', quotaText: '', quotaPct: null, quotaDetail: null });
  }
})();
"""#
}
