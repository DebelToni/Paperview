import UIKit
import WebKit

/// Only recognized exact-origin routes may enter native screens.
enum NativeSpaceRoute: Equatable {
    case home
    case space(String)
    case paper(PaperRoute)
    case invitation(String)

    static func parse(_ url: URL, bridge: WebBridge) -> NativeSpaceRoute? {
        guard bridge.trusts(url), let parts = URLComponents(url: url, resolvingAgainstBaseURL: false), parts.fragment == nil else { return nil }
        if let paper = bridge.paper(url) { return .paper(paper) }
        guard parts.query == nil else { return nil }
        if parts.percentEncodedPath == "/" || parts.percentEncodedPath.isEmpty { return .home }
        let fields = parts.percentEncodedPath.split(separator: "/", omittingEmptySubsequences: false)
        guard fields.count == 3 || fields.count == 4 && fields[3].isEmpty, fields[0].isEmpty, WebBridge.validID(String(fields[2])) else { return nil }
        if fields[1] == "space" { return .space(String(fields[2])) }
        if fields[1] == "join" { return .invitation(String(fields[2])) }
        return nil
    }
}

/// WebKit holds authentication cookies. All Space documents and dashboard UI are native.
@MainActor final class SpaceAppController: UINavigationController {
    private let bridge = WebBridge(origin: WebBridge.launchOrigin(arguments: ProcessInfo.processInfo.arguments), accountOrigin: WebBridge.launchAccountOrigin(arguments: ProcessInfo.processInfo.arguments))
    private var api: SpaceAPI?
    private var login: BrowserController?
    private var pendingURL: URL?
    private var preparing = false
    private var openingPaper = false
    private let store = WKWebsiteDataStore.default().httpCookieStore
    private var applicationStorage: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .white; overrideUserInterfaceStyle = .light
        navigationBar.prefersLargeTitles = false
        #if DEBUG
        if let raw = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--space-test-route=") })?.split(separator: "=", maxSplits: 1).last,
           let url = URL(string: String(raw), relativeTo: bridge.origin)?.absoluteURL, bridge.trusts(url) { pendingURL = url }
        if ProcessInfo.processInfo.arguments.contains("--space-test-clear-web-data"), bridge.origin.scheme == "http", ["127.0.0.1","localhost"].contains(bridge.origin.host ?? "") {
            WKWebsiteDataStore.default().removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) { [weak self] in Task { @MainActor in self?.prepareHome() } }
            return
        }
        #endif
        prepareHome()
    }
    private func freshAPI(_ completion: @escaping (SpaceAPI) -> Void) {
        store.getAllCookies { [weak self] cookies in
            Task { @MainActor in guard let self else { return }; completion(SpaceAPI(origin: self.bridge.origin, cookies: cookies)) }
        }
    }
    private func prepareHome() {
        guard !preparing else { return }; preparing = true
        freshAPI { [weak self] api in
            guard let self else { return }; self.preparing = false; self.api = api
            let home = SpaceHomeController(api: api)
            home.onOpenSpace = { [weak self] in self?.openSpace($0) }
            home.onOpenPaper = { [weak self] in self?.openPaper(PaperRoute(paperID: $0, followID: nil)) }
            home.onSignIn = { [weak self] in self?.signIn() }
            home.onAccount = { [weak self] in self?.account() }
            self.setViewControllers([home], animated: false)
            if let url = self.pendingURL { self.pendingURL = nil; self.open(url) }
        }
    }
    func open(_ url: URL) {
        guard bridge.trusts(url) else { return }
        guard isViewLoaded, api != nil else { pendingURL = url; return }
        switch NativeSpaceRoute.parse(url, bridge: bridge) {
        case .home: popToRootViewController(animated: true)
        case let .space(id): openSpace(id)
        case let .paper(route): openPaper(route)
        case let .invitation(token): invitation(token)
        case nil:
            let path = url.path
            if path == "/login" || path == "/signup" || path.hasPrefix("/api/accounts/") || Self.isGuestClaim(url) { showBrowser(url) }
            else if path == "/settings/cdn", let api, let current = topViewController { SpacePanels.presentAccount(from: current, api: api) { [weak self] in self?.signedOut() } }
            else { failure(PaperError.invalidURL) }
        }
    }
    private static func isGuestClaim(_ url: URL) -> Bool {
        let fields = url.path.split(separator: "/")
        return fields.count == 2 && fields[0] == "guest" && WebBridge.validID(String(fields[1])) && url.query == nil && url.fragment == nil
    }
    private func openSpace(_ id: String) {
        guard let api, WebBridge.validID(id) else { return }
        if let current = topViewController as? BoardViewController, current.session.spaceID == id { return }
        let controller = BoardViewController(api: api, spaceID: id, storageDirectory: applicationStorage.appendingPathComponent("BoardSessions", isDirectory: true))
        controller.onOpenPaper = { [weak self] in self?.openPaper(PaperRoute(paperID: $0, followID: nil)) }
        controller.onInteractHTML = { [weak self, weak controller] element in
            guard let self, let controller else { return }
            let html = BoardHTMLController(api: api, session: controller.session, element: element, cookies: self.store)
            controller.present(UINavigationController(rootViewController: html), animated: true)
        }
        pushViewController(controller, animated: true)
    }
    private func openPaper(_ route: PaperRoute) {
        guard !openingPaper else { return }; openingPaper = true
        freshAPI { [weak self] api in
            guard let self else { return }; self.openingPaper = false
            let reader = PaperReaderController(api: api, paperID: route.paperID, followID: route.followID, storageDirectory: self.applicationStorage.appendingPathComponent("ReaderSessions", isDirectory: true))
            self.pushViewController(reader, animated: true)
        }
    }
    private func signIn(returnPath: String? = nil) {
        var components = URLComponents(url: bridge.origin.appendingPathComponent("api/accounts/start"), resolvingAgainstBaseURL: false)!
        if let returnPath { components.queryItems = [URLQueryItem(name: "return_path", value: returnPath)] }
        if let url = components.url { showBrowser(url) }
    }
    private func showBrowser(_ url: URL) {
        guard bridge.trusts(url), login == nil else { return }
        let browser = BrowserController(); login = browser
        browser.initialURL = url; browser.authenticationOnly = true
        browser.onNativeNavigation = { [weak self, weak browser] destination in
            guard let self, self.bridge.trusts(destination) else { return }
            self.invalidateSessions()
            self.pendingURL = destination
            browser?.dismiss(animated: false) { [weak self] in self?.login = nil; self?.prepareHome() }
        }
        let navigation = UINavigationController(rootViewController: browser)
        navigation.modalPresentationStyle = .fullScreen
        browser.navigationItem.leftBarButtonItem = UIBarButtonItem(barButtonSystemItem: .cancel, target: self, action: #selector(cancelSignIn))
        present(navigation, animated: false)
    }
    @objc private func cancelSignIn() {
        login?.dismiss(animated: true) { [weak self] in self?.login = nil; self?.invalidateSessions(); self?.prepareHome() }
    }
    private func invalidateSessions() {
        for case let board as BoardViewController in viewControllers { board.session.invalidateAccess() }
    }
    private func account() {
        guard let api, let current = topViewController else { return }
        let menu = UIAlertController(title: nil, message: nil, preferredStyle: .actionSheet)
        menu.addAction(UIAlertAction(title: "Account and service access", style: .default) { _ in self.showBrowser(self.bridge.origin.appendingPathComponent("api/accounts/settings")) })
        menu.addAction(UIAlertAction(title: "CDN, suggestions and sign out", style: .default) { _ in
            SpacePanels.presentAccount(from: current, api: api) { [weak self] in self?.signedOut() }
        })
        menu.addAction(UIAlertAction(title: "Cancel", style: .cancel)); menu.popoverPresentationController?.sourceView = current.view
        menu.popoverPresentationController?.sourceRect = CGRect(x: current.view.bounds.maxX - 24,y:current.view.safeAreaInsets.top,width:1,height:1)
        current.present(menu, animated: true)
    }
    private func signedOut() {
        invalidateSessions()
        // Native logout revokes before this callback. Mirror only Space's human-session
        // deletion into WebKit, without clearing authority or other services' cookies.
        store.getAllCookies { [weak self] cookies in
            guard let self else { return }
            let group = DispatchGroup()
            for cookie in cookies where cookie.name == "space_session" && cookie.domain.trimmingCharacters(in: CharacterSet(charactersIn: ".")) == self.bridge.origin.host {
                group.enter(); self.store.delete(cookie) { group.leave() }
            }
            group.notify(queue: .main) { [weak self] in self?.prepareHome() }
        }
    }
    private func invitation(_ token: String) {
        guard let api else { return }
        Task {
            do {
                guard let identity = try await api.identity() else { signIn(returnPath: "/join/" + token); return }
                guard let current = topViewController, current.presentedViewController == nil else { return }
                let alert = UIAlertController(title: "Join this space?", message: nil, preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: "Join as \(identity.nickname)", style: .default) { _ in
                    Task { do { self.openSpace(try await api.acceptInvitation(token: token)) } catch { self.failure(error) } }
                })
                alert.addAction(UIAlertAction(title: "Cancel", style: .cancel)); current.present(alert, animated: true)
            } catch { failure(error) }
        }
    }
    private func failure(_ error: Error) {
        let alert = UIAlertController(title: "Space", message: error.localizedDescription, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default)); topViewController?.present(alert, animated: true)
    }
}
