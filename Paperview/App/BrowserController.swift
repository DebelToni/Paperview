import UIKit
import WebKit

private final class WeakPaperHandler: NSObject, WKScriptMessageHandler {
    weak var owner: BrowserController?
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        owner?.userContentController(controller, didReceive: message)
    }
}

final class BrowserController: UIViewController, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
    private let bridge = WebBridge(origin: WebBridge.launchOrigin(arguments: ProcessInfo.processInfo.arguments), accountOrigin: WebBridge.launchAccountOrigin(arguments: ProcessInfo.processInfo.arguments))
    private var webView: WKWebView!
    private var trackpad: BoardTrackpad!
    private let errorPanel = UIStackView()
    private let errorLabel = UILabel()
    private var pendingPaper: PaperRoute?
    private var opening = false
    private var readerActive = false
    private var retryURL: URL?

    override func loadView() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.ignoresViewportScaleLimits = false
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = .audio
        let handler = WeakPaperHandler()
        handler.owner = self
        configuration.userContentController.add(handler, name: "paper")
        configuration.userContentController.add(handler, name: "boardTrackpad")
        configuration.userContentController.addUserScript(WKUserScript(source: WebBridge.script, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        configuration.userContentController.addUserScript(WKUserScript(source: BoardTrackpad.script, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        trackpad = BoardTrackpad(webView: webView)
        webView.accessibilityIdentifier = "space.browser"
        view = webView
        errorPanel.axis = .vertical
        errorPanel.spacing = 16
        errorPanel.alignment = .center
        errorLabel.numberOfLines = 0
        errorLabel.textAlignment = .center
        let retry = UIButton(type: .system)
        retry.setTitle("Retry", for: .normal)
        retry.addTarget(self, action: #selector(retryLoad), for: .touchUpInside)
        errorPanel.addArrangedSubview(errorLabel)
        errorPanel.addArrangedSubview(retry)
        errorPanel.backgroundColor = .systemBackground
        errorPanel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(errorPanel)
        NSLayoutConstraint.activate([
            errorPanel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            errorPanel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            errorPanel.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, constant: -48)
        ])
        errorPanel.isHidden = true
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        var start = bridge.origin
        #if DEBUG
        if let route = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--space-test-route=") })?.split(separator: "=", maxSplits: 1).last,
           let candidate = URL(string: String(route), relativeTo: bridge.origin)?.absoluteURL, bridge.trusts(candidate) { start = candidate }
        #endif
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--space-test-clear-web-data"),
           bridge.origin.scheme == "http", ["127.0.0.1", "localhost"].contains(bridge.origin.host ?? "") {
            let destination = start
            webView.configuration.websiteDataStore.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) { [weak self] in
                self?.load(destination)
            }
            return
        }
        #endif
        if let paper = bridge.paper(start) {
            load(bridge.origin)
            openPaper(paper)
        } else { load(start) }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(true, animated: animated)
        if readerActive && navigationController?.topViewController === self {
            readerActive = false
            webView.evaluateJavaScript("window.__paperviewResume?.()", completionHandler: nil)
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if let route = pendingPaper {
            pendingPaper = nil
            openPaper(route)
        }
    }

    func open(_ url: URL) {
        loadViewIfNeeded()
        guard bridge.trusts(url) else { return }
        if let route = bridge.paper(url) { openPaper(route) }
        else { load(url) }
    }

    private func load(_ url: URL) {
        trackpad.setBoardActive(false)
        retryURL = url
        errorPanel.isHidden = true
        webView.load(URLRequest(url: url))
    }
    @objc private func retryLoad() { if let url = retryURL { load(url) } }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard ["paper", "boardTrackpad"].contains(message.name), message.frameInfo.isMainFrame,
              let frameURL = message.frameInfo.request.url, bridge.trusts(frameURL),
              let current = webView.url, bridge.trusts(current) else { return }
        let security = message.frameInfo.securityOrigin
        guard security.protocol == bridge.origin.scheme, security.host == bridge.origin.host,
              (security.port == 0 ? (security.protocol == "https" ? 443 : 80) : security.port) == (bridge.origin.port ?? (bridge.origin.scheme == "https" ? 443 : 80)) else { return }
        if message.name == "boardTrackpad" {
            if let active = message.body as? Bool { trackpad.setBoardActive(active) }
            return
        }
        guard let raw = message.body as? String, let url = URL(string: raw), let route = bridge.paper(url) else { return }
        openPaper(route)
    }

    private func openPaper(_ route: PaperRoute) {
        guard viewIfLoaded?.window != nil, navigationController?.topViewController === self else {
            if !readerActive { pendingPaper = route }
            return
        }
        guard !opening, !readerActive else { return }
        opening = true
        // Prevent duplicate opens before taking the fresh HttpOnly cookie snapshot.
        // Board autosaves continue; native networking uses no shared cookie jar.
        webView.evaluateJavaScript("window.__paperviewPause?.()") { [weak self] _, _ in
            guard let self else { return }
            self.webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.opening = false
                    let api = SpaceAPI(origin: self.bridge.origin, cookies: cookies)
                    let storage = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                        .appendingPathComponent("ReaderSessions", isDirectory: true)
                    let reader = PaperReaderController(api: api, paperID: route.paperID, followID: route.followID, storageDirectory: storage)
                    self.readerActive = true
                    self.navigationController?.pushViewController(reader, animated: true)
                }
            }
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url else { decisionHandler(.cancel); return }
        guard !readerActive && !opening else { decisionHandler(.cancel); return }
        if bridge.permitsNavigation(url) {
            if action.targetFrame?.isMainFrame != false, let paper = bridge.paper(url) {
                decisionHandler(.cancel); openPaper(paper); return
            }
            if action.targetFrame == nil { decisionHandler(.cancel); load(url); return }
            decisionHandler(.allow)
        } else {
            decisionHandler(.cancel)
            if action.targetFrame?.isMainFrame != false, ["https", "http"].contains(url.scheme ?? "") { UIApplication.shared.open(url) }
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        guard let url = response.response.url, bridge.permitsNavigation(url) else { decisionHandler(.cancel); return }
        if response.isForMainFrame, let http = response.response as? HTTPURLResponse, http.statusCode >= 400 {
            errorLabel.text = "Space returned HTTP \(http.statusCode)."
            errorPanel.isHidden = false
            decisionHandler(.cancel)
        } else { decisionHandler(.allow) }
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { show(error) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { show(error) }
    private func show(_ error: Error) {
        guard (error as NSError).code != NSURLErrorCancelled else { return }
        errorLabel.text = (error as NSError).code == NSURLErrorNotConnectedToInternet ? "You’re offline." : "Couldn’t load Space. \(error.localizedDescription)"
        errorPanel.isHidden = false
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        errorLabel.text = "Space stopped responding."
        errorPanel.isHidden = false
    }
}
