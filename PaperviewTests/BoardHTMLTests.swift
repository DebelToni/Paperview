import XCTest
import WebKit
import UIKit
@testable import Paperview

@MainActor final class BoardHTMLTests: XCTestCase {
    func testStrictPaths() {
        for path in ["public/model.bin", "private/folder/image.png"] { XCTAssertTrue(BoardHTMLController.validPath(path), path) }
        for path in ["", "public/", "private/../x", "public/./x", "public//x", "https://host/x", "//host/x", "public/%2e/x", "private/a\\b", "public/a?x", "public/a#x", "public/a\nx", "other/x"] { XCTAssertFalse(BoardHTMLController.validPath(path), path) }
    }
    func testMissingCSPFailsClosed() {
        let resources = BoardHTMLResources()
        XCTAssertThrowsError(try resources.install(.init(data: Data(), mimeType: "text/html"), channel: String(repeating: "a", count: 32)))
    }

    private final class Receiver: NSObject, WKScriptMessageHandler {
        var receive: ((Any) -> Void)?
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) { receive?(message.body) }
    }

    /// A failure to execute the child is a compatibility failure, not grounds to remove
    /// frame-ancestors or switch to srcdoc. Run on the supported iOS simulator before release.
    func testActualWebKitSandboxAndResponseCSP() async throws {
        let ready = expectation(description: "Sandbox child executed under unchanged HTTP response CSP")
        let receiver = Receiver()
        receiver.receive = { value in
            guard let result = value as? [String: Bool] else { XCTFail("Invalid synthetic report"); return }
            XCTAssertEqual(result["parentBlocked"], true)
            XCTAssertEqual(result["storageBlocked"], true)
            XCTAssertEqual(result["networkBlocked"], true)
            XCTAssertEqual(result["opaqueOrigin"], true)
            ready.fulfill()
        }
        let csp = "default-src 'none'; sandbox allow-scripts; script-src 'unsafe-inline'; connect-src 'none'; frame-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'; frame-ancestors 'self'"
        let source = """
        <!doctype html><script>
        (async()=>{let parentBlocked=false,storageBlocked=false,networkBlocked=false;
        try{void parent.document.body;}catch{parentBlocked=true;}
        try{localStorage.setItem('synthetic','1');}catch{storageBlocked=true;}
        try{await fetch('space-html://isolated/host');}catch{networkBlocked=true;}
        parent.postMessage({parentBlocked,storageBlocked,networkBlocked,opaqueOrigin:self.origin==='null'},'*');})();
        </script>
        """
        let resources = BoardHTMLResources()
        try resources.install(.init(data: Data(source.utf8), mimeType: "text/html", headers: ["Content-Type": "text/html", "Content-Security-Policy": csp]), channel: String(repeating: "a", count: 32))
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.setURLSchemeHandler(resources, forURLScheme: "space-html")
        let world = WKContentWorld.world(name: "SyntheticHost")
        config.userContentController.add(receiver, contentWorld: world, name: "report")
        config.userContentController.addUserScript(WKUserScript(source: "addEventListener('message',e=>{if(e.source===document.querySelector('iframe').contentWindow)webkit.messageHandlers.report.postMessage(e.data);});", injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: world))
        let web = WKWebView(frame: .init(x: 0, y: 0, width: 320, height: 240), configuration: config)
        let window = UIWindow(frame: web.frame)
        let controller = UIViewController(); controller.view = web
        window.rootViewController = controller; window.makeKeyAndVisible()
        defer { web.stopLoading(); config.userContentController.removeScriptMessageHandler(forName: "report", contentWorld: world); resources.clear(); window.isHidden = true }
        web.load(URLRequest(url: BoardHTMLResources.hostURL))
        await fulfillment(of: [ready], timeout: 10)
    }
}
