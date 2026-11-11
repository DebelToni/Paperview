import XCTest
import JavaScriptCore
@testable import Paperview

final class WebBridgeTests: XCTestCase {
    func testDebugAccountOriginIsExplicitValidatedLoopbackOnly() {
        let origin = URL(string: "http://127.0.0.1:18749")!
        let account = WebBridge.launchAccountOrigin(arguments: ["--accounts-test-origin=http://localhost:18749"])
        XCTAssertEqual(account?.absoluteString, "http://localhost:18749")
        let bridge = WebBridge(origin: origin, accountOrigin: account)
        XCTAssertTrue(bridge.permitsNavigation(URL(string: "http://localhost:18749/api/accounts/authorize")!))
        XCTAssertFalse(bridge.trusts(URL(string: "http://localhost:18749/paper/private")!))
        XCTAssertNil(bridge.paper(URL(string: "http://localhost:18749/paper/private")!))
        XCTAssertFalse(WebBridge(origin: origin).permitsNavigation(URL(string: "http://localhost:18749")!))
        XCTAssertNil(WebBridge.launchAccountOrigin(arguments: []))
        for raw in ["https://evil.test", "http://localhost.evil.test", "http://user@localhost:18749",
                    "http://localhost:18749/path", "http://localhost:18749?x=1", "http://localhost:18749#x"] {
            XCTAssertNil(WebBridge.launchAccountOrigin(arguments: ["--accounts-test-origin=" + raw]))
        }
    }

    func testAccountsNavigationDoesNotGrantBridgeAuthority() {
        let bridge = WebBridge(origin: URL(string: "https://space.toni.foo")!)
        let account = URL(string: "https://accounts.toni.foo/account")!
        XCTAssertTrue(bridge.permitsNavigation(account))
        XCTAssertFalse(bridge.trusts(account))
        XCTAssertNil(bridge.paper(URL(string: "https://accounts.toni.foo/paper/private")!))
        for raw in ["http://accounts.toni.foo/account", "https://accounts.toni.foo:444/account",
                    "https://accounts.toni.foo.evil/account", "https://user@accounts.toni.foo/account"] {
            XCTAssertFalse(bridge.permitsNavigation(URL(string: raw)!))
        }
    }

    let bridge = WebBridge(origin: URL(string: "https://space.toni.foo")!)

    func testPaperAndFollow() {
        XCTAssertEqual(bridge.paper(URL(string: "https://space.toni.foo/paper/p_123?follow=s-9")!), PaperRoute(paperID: "p_123", followID: "s-9"))
        XCTAssertNotNil(bridge.paper(URL(string: "https://space.toni.foo:443/paper/abc/")!))
    }
    func testRejectsSpoofsAndEndpoints() {
        for value in [
            "http://space.toni.foo/paper/a", "https://space.toni.foo:444/paper/a",
            "https://space.toni.foo.evil.test/paper/a", "https://evil.test/paper/a",
            "https://user@space.toni.foo/paper/a", "file:///paper/a", "javascript:alert(1)",
            "https://space.toni.foo/api/papers/a/file", "https://space.toni.foo/paper/a/b",
            "https://space.toni.foo/paper/%2f", "https://space.toni.foo/paper/a?follow=",
            "https://space.toni.foo/paper/a?follow=b&follow=c", "https://space.toni.foo/paper/a?origin=https://evil.test",
            "https://space.toni.foo/paper/a#code"
        ] { XCTAssertNil(bridge.paper(URL(string: value)!), value) }
    }
    func testProductionDefaultAndNonLoopbackOverride() {
        XCTAssertEqual(WebBridge.launchOrigin(arguments: []), bridge.origin)
        XCTAssertEqual(WebBridge.launchOrigin(arguments: ["--space-test-origin=http://evil.test"]), bridge.origin)
    }
    func testHistoryInterceptionPreservesBoardAndNetworkingWithoutExposingCredentials() throws {
        let context = try XCTUnwrap(JSContext())
        var exceptions: [String] = []
        context.exceptionHandler = { _, error in exceptions.append(error?.toString() ?? "JavaScript exception") }
        // JavaScriptCore has no browser URL implementation. Supply only the URL API used
        // by this script; the input remains an actual history.pushState invocation.
        context.evaluateScript(#"""
        var window = this, messages = [], listeners = {};
        var location = {href: 'https://space.toni.foo/space/board', origin: 'https://space.toni.foo'};
        class URL {
          constructor(value) {
            const match = String(value).match(/^(https:\/\/[^/]+)?([^?#]*)(?:\?([^#]*))?(#.*)?$/);
            this.origin = match[1] || location.origin; this.pathname = match[2]; this.hash = match[4] || '';
            this.href = this.origin + this.pathname + (match[3] ? '?' + match[3] : '') + this.hash;
            const pairs = (match[3] || '').split('&').filter(Boolean).map(p => p.split('='));
            this.searchParams = {keys: () => pairs.map(p => p[0]), getAll: k => pairs.filter(p => p[0] === k).map(p => p[1]), has: k => pairs.some(p => p[0] === k), get: k => pairs.find(p => p[0] === k)?.[1]};
          }
        }
        var history = {pushState(s,t,u) {location.href = new URL(u).href;}, replaceState(s,t,u) {location.href = new URL(u).href;}};
        var document = {cookie: 'fixture_secret=never-send', addEventListener() {}};
        function addEventListener(name, callback) {listeners[name] = callback;}
        var webkit = {messageHandlers: {paper: {postMessage(value) {messages.push(value);}}}};
        var fetch = function() {}, originalFetch = fetch;
        function XMLHttpRequest() {}
        XMLHttpRequest.prototype.send = function() {};
        var originalSend = XMLHttpRequest.prototype.send;
        var navigator = {sendBeacon() {return true;}}, originalBeacon = navigator.sendBeacon;
        """#)
        context.evaluateScript(WebBridge.script)
        context.evaluateScript("history.pushState({}, '', '/paper/p_123?follow=s-9'); history.pushState({}, '', '/paper/p_123');")
        XCTAssertEqual(context.evaluateScript("location.href")?.toString(), "https://space.toni.foo/space/board")
        XCTAssertEqual(context.evaluateScript("JSON.stringify(messages)")?.toString(), "[\"https://space.toni.foo/paper/p_123?follow=s-9\"]")
        XCTAssertEqual(context.evaluateScript("fetch === originalFetch && XMLHttpRequest.prototype.send === originalSend && navigator.sendBeacon === originalBeacon")?.toBool(), true)
        XCTAssertEqual(context.evaluateScript("JSON.stringify(messages).includes('never-send')")?.toBool(), false)
        XCTAssertTrue(exceptions.isEmpty, exceptions.joined(separator: "\n"))
    }

}
