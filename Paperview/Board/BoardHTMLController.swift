import UIKit
import WebKit

/// The only WebKit surface on the native board. No account cookies enter this view.
@MainActor final class BoardHTMLController: UIViewController, WKScriptMessageHandler, WKNavigationDelegate {
    private let api: SpaceAPI
    private let session: BoardSession
    private let element: BoardElement
    private let identity: String
    private let channel = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    private var web: WKWebView!
    private var resources: BoardHTMLResources!
    private var tasks: [Int: Task<Void, Never>] = [:]
    private var monitor: Task<Void, Never>?
    private var deadlines: [Int: Date] = [:]
    private var lastID = 0
    private var authority: Task<Void, Never>?
    private var closed = false
    private var childLoaded = false
    private let world = WKContentWorld.world(name: "PaperviewHTMLHost")

    init(api: SpaceAPI, session: BoardSession, element: BoardElement, cookies: WKHTTPCookieStore) {
        self.api = api; self.session = session; self.element = element; identity = api.storageIdentity
        super.init(nibName: nil, bundle: nil)
        // Deliberately do not copy cookies. Only native SpaceAPI performs authorized requests.
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    private var valid: Bool {
        guard !closed, session.authorized, identity == api.storageIdentity,
              let current = session.board.element(element.id), !current.deleted else { return false }
        return current.diagramType == "html" && current.text == element.text
    }
    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Interactive HTML"
        view.backgroundColor = .white
        navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .close, primaryAction: UIAction { [weak self] _ in self?.close() })
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        resources = BoardHTMLResources()
        config.setURLSchemeHandler(resources, forURLScheme: "space-html")
        config.userContentController.add(self, contentWorld: world, name: "asset")
        config.userContentController.addUserScript(WKUserScript(source: Self.bridge(channel: channel), injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: world))
        web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = self
        web.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(web)
        NSLayoutConstraint.activate([web.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor), web.bottomAnchor.constraint(equalTo: view.bottomAnchor), web.leadingAnchor.constraint(equalTo: view.leadingAnchor), web.trailingAnchor.constraint(equalTo: view.trailingAnchor)])
        monitor = Task { [weak self] in
            guard let self else { return }
            do {
                guard valid else { close(); return }
                let payload = try await api.htmlFrame(id: session.spaceID, elementID: element.id, channel: channel)
                guard valid else { close(); return }
                guard let document = String(data: payload.data, encoding: .utf8), document.hasSuffix(element.text ?? "") else { close(); return }
                try resources.install(payload, channel: channel)
                web.load(URLRequest(url: BoardHTMLResources.hostURL))
                authority = Task { [weak self] in
                    guard let self else { return }
                    do {
                        while !Task.isCancelled {
                            try await Task.sleep(for: .seconds(2))
                            let remote = try await api.space(id: session.spaceID)
                            guard valid, let current = remote.board.element(element.id), !current.deleted,
                                  current.diagramType == "html", current.text == element.text else { close(); return }
                        }
                    } catch { if !Task.isCancelled { close() } }
                }
                while !Task.isCancelled {
                    try await Task.sleep(for: .milliseconds(100))
                    if !valid { close(); return }
                    for (id, deadline) in deadlines where deadline <= Date() {
                        tasks.removeValue(forKey: id)?.cancel(); deadlines.removeValue(forKey: id)
                    }
                }
            } catch { close() }
        }
    }
    override func viewDidDisappear(_ animated: Bool) { super.viewDidDisappear(animated); dispose() }
    override var keyCommands: [UIKeyCommand]? { [UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(escape))] }
    @objc private func escape() { close() }
    private func close() { dispose(); dismiss(animated: true) }
    private func dispose() {
        guard !closed else { return }; closed = true
        monitor?.cancel(); monitor = nil
        authority?.cancel(); authority = nil
        tasks.values.forEach { $0.cancel() }; tasks.removeAll()
        web?.evaluateJavaScript("window.disposeHTML?.()", in: nil, in: world, completionHandler: nil)
        web?.stopLoading()
        web?.configuration.userContentController.removeScriptMessageHandler(forName: "asset", contentWorld: world)
        resources?.clear()
    }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard valid, message.frameInfo.isMainFrame, message.frameInfo.request.url == BoardHTMLResources.hostURL,
              let body = message.body as? [String: Any], body["channel"] as? String == channel,
              let kind = body["type"] as? String else { return }
        if kind == "close" { close(); return }
        guard kind == "read", let id = body["id"] as? Int, id > 0, id <= 9_007_199_254_740_991,
              id > lastID, tasks[id] == nil, tasks.count < 16, let path = body["path"] as? String, Self.validPath(path) else { return }
        lastID = id; deadlines[id] = Date().addingTimeInterval(20)
        tasks[id] = Task { [weak self] in
            guard let self else { return }
            defer { tasks.removeValue(forKey: id); deadlines.removeValue(forKey: id) }
            do {
                let result = try await api.htmlPrivateAsset(id: session.spaceID, elementID: element.id, path: path)
                guard valid, !Task.isCancelled, result.data.count <= 8 * 1024 * 1024 else { return }
                web.callAsyncJavaScript("window.finishHTML(id, bytes, mime, null)", arguments: ["id": id, "bytes": result.data.base64EncodedString(), "mime": result.mimeType], in: nil, in: world, completionHandler: nil)
            } catch {
                guard valid, !Task.isCancelled else { return }
                if (error as? PaperError)?.deniesAccess == true { close(); return }
                web.callAsyncJavaScript("window.finishHTML(id, null, null, 'Private CDN access denied')", arguments: ["id": id], in: nil, in: world, completionHandler: nil)
            }
        }
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let url = navigationAction.request.url
        if navigationAction.targetFrame?.isMainFrame == true {
            decisionHandler(!closed && url == BoardHTMLResources.hostURL ? .allow : .cancel)
        } else {
            let allow = !closed && !childLoaded && url == BoardHTMLResources.frameURL
            if allow { childLoaded = true }
            decisionHandler(allow ? .allow : .cancel)
        }
    }
    static func validPath(_ path: String) -> Bool {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        return path.utf8.count <= 2048 && parts.count >= 2 && ["public", "private"].contains(String(parts[0])) && parts.dropFirst().allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." } && !path.contains(where: { "\\%?#:".contains($0) }) && !path.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }
    static func bridge(channel: String) -> String {
        """
        (()=>{const channel='\(channel)',frame=document.querySelector('iframe'),pending=new Map();let closed=false,lastID=0;
        const finish=(id,bytes,mime,error)=>{const entry=pending.get(id);if(!entry)return;pending.delete(id);clearTimeout(entry.timer);try{if(error)entry.port.postMessage({error});else {const raw=atob(bytes);if(raw.length>8388608)throw Error();const data=Uint8Array.from(raw,c=>c.charCodeAt(0));entry.port.postMessage({id,channel,bytes:data.buffer,mime},[data.buffer]);}}catch{entry.port.postMessage({error:'Invalid asset'});}finally{entry.port.close();}};
        window.finishHTML=finish;
        window.disposeHTML=()=>{if(closed)return;closed=true;frame.contentWindow.postMessage({type:'space-html-dispose',channel},'*');for(const id of [...pending.keys()])finish(id,null,null,'HTML frame closed');frame.remove();};
        addEventListener('message',e=>{if(closed||e.source!==frame.contentWindow||e.data?.channel!==channel)return;
        if(e.data.type==='space-html-close'){webkit.messageHandlers.asset.postMessage({type:'close',channel});return;}
        const {id,path}=e.data,port=e.ports[0];if(e.data.type!=='space-cdn-read'||!port)return;
        if(!Number.isSafeInteger(id)||id<=lastID||pending.has(id)||pending.size>=16||typeof path!=='string'||path.length>2048||! /^(public|private)\\//.test(path)||/[\\\\%?#:\\x00-\\x1f\\x7f]/.test(path)||path.split('/').some(p=>!p||p==='.'||p==='..')){port.postMessage({error:'Invalid request'});port.close();return;}
        lastID=id;pending.set(id,{port,timer:setTimeout(()=>finish(id,null,null,'CDN request timed out'),20000)});
        webkit.messageHandlers.asset.postMessage({type:'read',channel,id,path});});
        addEventListener('keydown',e=>{if(e.key==='Escape')webkit.messageHandlers.asset.postMessage({type:'close',channel});});
        let loads=0;frame.addEventListener('load',()=>{if(++loads>1)webkit.messageHandlers.asset.postMessage({type:'close',channel});});
        })();
        """
    }
}

/// Two immutable resources, never a general URL proxy. Response policy is not rewritten.
@MainActor final class BoardHTMLResources: NSObject, WKURLSchemeHandler {
    static let hostURL = URL(string: "space-html://isolated/host")!
    static let frameURL = URL(string: "space-html://isolated/frame")!
    private var frame: SpaceAPI.NativePayload?
    func install(_ payload: SpaceAPI.NativePayload, channel: String) throws {
        guard payload.mimeType == "text/html", let csp = payload.headers.first(where: { $0.key.lowercased() == "content-security-policy" })?.value,
              csp.contains("sandbox allow-scripts;"), csp.contains("frame-ancestors 'self'"),
              !csp.contains("allow-same-origin") else { throw PaperError.invalidResponse }
        frame = payload
    }
    func clear() { frame = nil }
    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        guard urlSchemeTask.request.httpMethod == "GET", let frame, let url = urlSchemeTask.request.url else { urlSchemeTask.didFailWithError(PaperError.invalidURL); return }
        let data: Data, headers: [String: String]
        if url == Self.hostURL {
            data = Data("<!doctype html><meta name='referrer' content='no-referrer'><style>html,body,iframe{margin:0;width:100%;height:100%;border:0;background:white}</style><iframe sandbox='allow-scripts' referrerpolicy='no-referrer' src='space-html://isolated/frame'></iframe>".utf8)
            headers = ["Content-Type": "text/html; charset=utf-8", "Content-Security-Policy": "default-src 'none'; style-src 'unsafe-inline'; frame-src space-html://isolated; base-uri 'none'; form-action 'none'; object-src 'none'", "Cache-Control": "no-store"]
        } else if url == Self.frameURL { data = frame.data; headers = frame.headers }
        else { urlSchemeTask.didFailWithError(PaperError.invalidURL); return }
        guard let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers) else { urlSchemeTask.didFailWithError(PaperError.invalidResponse); return }
        urlSchemeTask.didReceive(response); urlSchemeTask.didReceive(data); urlSchemeTask.didFinish()
    }
    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {}
}
