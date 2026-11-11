import XCTest
import WebKit
@testable import Paperview

@MainActor private final class TrackpadTestHandler: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    var input: BoardTrackpad?
    var loaded: XCTestExpectation?
    var changed: XCTestExpectation?
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if let value = message.body as? Bool { input?.setBoardActive(value); changed?.fulfill(); changed = nil }
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { loaded?.fulfill(); loaded = nil }
}

@MainActor final class BoardTrackpadTests: XCTestCase {
    func testNativeRecognizersExcludeTouchscreenAndLockBoardWithoutHover() {
        let web = WKWebView(), input = BoardTrackpad(webView: web)
        XCTAssertEqual(input.pan.allowedScrollTypesMask, .all)
        XCTAssertEqual(input.pan.allowedTouchTypes, [])
        XCTAssertEqual(input.pinch.allowedTouchTypes, [])
        XCTAssertFalse(input.gestureRecognizerShouldBegin(input.pan))
        input.setBoardActive(true)
        XCTAssertTrue(input.gestureRecognizerShouldBegin(input.pan))
        XCTAssertTrue(input.gestureRecognizerShouldBegin(input.pinch))
        XCTAssertFalse(web.scrollView.isScrollEnabled)
        XCTAssertFalse(web.scrollView.bounces)
        XCTAssertFalse(web.scrollView.bouncesZoom)
        XCTAssertEqual(web.scrollView.minimumZoomScale, 1)
        XCTAssertEqual(web.scrollView.maximumZoomScale, 1)
        XCTAssertTrue(input.gestureRecognizer(input.pinch, shouldRecognizeSimultaneouslyWith: input.pan))
        // WKWebView may not create a page pinch recognizer before loading a document.
        input.setBoardActive(false)
        XCTAssertTrue(web.scrollView.isScrollEnabled)
    }

    func testPinchUsesIncrementalScaleAndDoesNotAmplifyRepeatedUpdates() {
        let web = WKWebView(), input = BoardTrackpad(webView: web)
        var delta = input.pinchWheelDelta(scale: 1.01, began: true)
        for _ in 0..<100 { delta += input.pinchWheelDelta(scale: 1.01, began: false) }
        XCTAssertEqual(exp(-delta * 0.01), pow(1.01, 0.6), accuracy: 0.000001)
        var smooth: CGFloat = 0
        for i in 0...100 { smooth += input.pinchWheelDelta(scale: 1 + CGFloat(i) / 1000, began: i == 0) }
        let single = input.pinchWheelDelta(scale: 1.1, began: true)
        XCTAssertEqual(smooth, single, accuracy: 0.000001)
        let reverse = input.pinchWheelDelta(scale: 1, began: false)
        XCTAssertEqual(single + reverse, 0, accuracy: 0.000001)
        XCTAssertLessThanOrEqual(abs(input.pinchWheelDelta(scale: 100, began: true)), 8)
        XCTAssertLessThanOrEqual(abs(input.pinchWheelDelta(scale: 0.001, began: true)), 8)
    }

    func testNativePanAndPinchReachRealWKCanvasWithoutMovingWebpage() async throws {
        let handler = TrackpadTestHandler(), configuration = WKWebViewConfiguration()
        configuration.userContentController.add(handler, name: "boardTrackpad")
        configuration.userContentController.addUserScript(WKUserScript(source: BoardTrackpad.script, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        let input = BoardTrackpad(webView: web); handler.input = input; web.navigationDelegate = handler
        defer { configuration.userContentController.removeScriptMessageHandler(forName: "boardTrackpad") }
        let loaded = expectation(description: "WK canvas loaded"); handler.loaded = loaded
        let entered = expectation(description: "Canvas present without hover"); handler.changed = entered
        web.loadHTMLString(#"""
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <style>body{margin:0;height:2000px}canvas{width:600px;height:400px}</style>
        <canvas aria-label="Drawing canvas"></canvas>
        <script>
        window.inputState = {x:0,y:0,zoom:1,count:0};
        document.querySelector('canvas').addEventListener('wheel', e => {
          e.preventDefault(); inputState.count++;
          if (e.ctrlKey) inputState.zoom *= Math.exp(-e.deltaY * .01);
          else {inputState.x -= e.deltaX; inputState.y -= e.deltaY;}
        }, {passive:false});
        </script>
        """#, baseURL: URL(string: "https://space.toni.foo"))
        await fulfillment(of: [loaded, entered], timeout: 15)
        XCTAssertTrue(input.boardActive)
        XCTAssertFalse(web.scrollView.isScrollEnabled)
        let overscroll = try await web.evaluateJavaScript("getComputedStyle(document.documentElement).overscrollBehavior") as? String
        XCTAssertEqual(overscroll, "none")
        let viewport = try await web.evaluateJavaScript("document.querySelector('meta[name=viewport]').content") as? String
        XCTAssertTrue(viewport?.contains("user-scalable=no") == true)
        web.scrollView.setContentOffset(CGPoint(x: 100, y: 100), animated: false)
        XCTAssertEqual(web.scrollView.contentOffset, .zero)
        // No mouse movement is needed. Touchscreen pointer events remain available.
        _ = try await web.evaluateJavaScript("document.querySelector('canvas').dispatchEvent(new PointerEvent('pointermove',{bubbles:true,pointerType:'touch',clientX:100,clientY:100}))")
        input.forward(dx: 30, dy: -20, zoom: false)
        input.forward(dx: 0, dy: -log(1.5) * 100, zoom: true)
        // The read is queued after native-to-JavaScript input on the same WKWebView.
        let snapshot = try await web.evaluateJavaScript("JSON.stringify({ ...inputState, scrollY, pageZoom:visualViewport.scale })")
        let value = try XCTUnwrap(snapshot as? String)
        let data = try XCTUnwrap(value.data(using: .utf8))
        let state = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Double])
        XCTAssertEqual(state["count"], 2)
        XCTAssertEqual(state["x"], -30)
        XCTAssertEqual(state["y"], 20)
        XCTAssertEqual(try XCTUnwrap(state["zoom"]), 1.5, accuracy: 0.0001)
        XCTAssertEqual(state["scrollY"], 0)
        XCTAssertEqual(state["pageZoom"], 1)
        let left = expectation(description: "Board removed"); handler.changed = left
        _ = try await web.evaluateJavaScript("document.querySelector('canvas').remove()")
        await fulfillment(of: [left], timeout: 5)
        // WebKit applies restored overflow/viewport constraints asynchronously.
        let restored = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in web.scrollView.isScrollEnabled }, object: nil)
        await fulfillment(of: [restored], timeout: 5)
        XCTAssertTrue(web.scrollView.isScrollEnabled)
        input.forward(dx: 50, dy: 50, zoom: false)
        let count = try await web.evaluateJavaScript("inputState.count") as? Int
        XCTAssertEqual(count, 2)
    }
}
