import XCTest
import UIKit
import PDFKit
import PencilKit
import WebKit
@testable import Paperview

private final class PaperMockProtocol: URLProtocol {
    // Tests configure the handler before starting their isolated session.
    static var handler: ((URLRequest) throws -> (Int, [String: String], Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, headers, data) = try Self.handler!(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

private final class AuthorityMessageProbe: NSObject, WKScriptMessageHandler {
    weak var browser: BrowserController?
    var received: XCTestExpectation?
    var hosts: [String] = []
    var mainFrames: [Bool] = []
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        hosts.append(message.frameInfo.securityOrigin.host)
        mainFrames.append(message.frameInfo.isMainFrame)
        browser?.userContentController(controller, didReceive: message)
        received?.fulfill()
    }
}

@MainActor final class IntegrationTests: XCTestCase {
    func testActualAuthorityFrameCannotOpenNativeReader() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let raw = env["PAPERVIEW_TEST_ACCOUNT_ORIGIN"], let account = URL(string: raw + "/"),
              account.scheme == "http", account.host == "localhost" else {
            throw XCTSkip("Missing isolated independent authority")
        }
        let browser = BrowserController()
        let navigation = UINavigationController(rootViewController: browser)
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = navigation
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        browser.loadViewIfNeeded()
        let spaceView = try XCTUnwrap(browser.view as? WKWebView)
        for _ in 0..<200 {
            if spaceView.url?.host == "127.0.0.1" && !spaceView.isLoading { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertEqual(spaceView.url?.host, "127.0.0.1")
        XCTAssertFalse(spaceView.isLoading)
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let probe = AuthorityMessageProbe()
        probe.browser = browser
        let messages = expectation(description: "Actual account-frame bridge messages")
        messages.expectedFulfillmentCount = 2
        probe.received = messages
        configuration.userContentController.add(probe, name: "paper")
        configuration.userContentController.add(probe, name: "boardTrackpad")
        let accountView = WKWebView(frame: CGRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        accountView.load(URLRequest(url: account))
        for _ in 0..<200 {
            if accountView.url == account && !accountView.isLoading { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertEqual(accountView.url, account)
        XCTAssertFalse(accountView.isLoading)
        let title = try await accountView.evaluateJavaScript("document.title") as? String
        XCTAssertEqual(title, "Account", "Must execute the actual authority public page")
        let target = try XCTUnwrap(env["PAPERVIEW_TEST_ORIGIN"]) + "/paper/" + (try XCTUnwrap(env["PAPERVIEW_TEST_PAPER"]))
        let encoded = String(data: try JSONSerialization.data(withJSONObject: [target]), encoding: .utf8)!
        _ = try await accountView.evaluateJavaScript("""
            window.webkit.messageHandlers.paper.postMessage(\(encoded)[0]);
            window.webkit.messageHandlers.boardTrackpad.postMessage(true);
            true;
            """
        )
        await fulfillment(of: [messages], timeout: 5)
        XCTAssertEqual(probe.hosts, ["localhost", "localhost"])
        XCTAssertEqual(probe.mainFrames, [true, true])
        let forbidden = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            navigation.viewControllers.count > 1
        }, object: nil)
        forbidden.isInverted = true
        await fulfillment(of: [forbidden], timeout: 1)
        XCTAssertEqual(navigation.viewControllers.count, 1, "Account-frame messages must not open a native PDF")
        XCTAssertTrue(navigation.topViewController === browser)
        accountView.stopLoading()
        configuration.userContentController.removeAllScriptMessageHandlers()
    }

    func testRejectsExternalAndPathIDsWithoutNetwork() async throws {
        let api = SpaceAPI(origin: URL(string: "https://example.invalid")!, cookies: [])
        for id in ["https://evil.invalid/a", "../private", "a/b", "a?x=1", "a#x", "%2f", ""] {
            do { _ = try await api.metadata(paperID: id); XCTFail("Unsafe ID accepted: \(id)") }
            catch PaperError.invalidURL {} catch { XCTFail("Unexpected: \(error)") }
        }
        let badOrigin = SpaceAPI(origin: URL(string: "https://example.invalid/not-api")!, cookies: [])
        do { _ = try await badOrigin.pdf(paperID: "p"); XCTFail("Unsafe origin accepted") }
        catch PaperError.invalidURL {} catch { XCTFail("Unexpected: \(error)") }
    }
    func testCookiePrincipalIdentityDoesNotDependOnOrder() {
        func cookie(_ name: String, _ value: String) -> HTTPCookie {
            HTTPCookie(properties: [.domain: "example.invalid", .path: "/", .name: name, .value: value])!
        }
        let origin = URL(string: "https://example.invalid")!
        let a = cookie("session", "a"), b = cookie("guest", "b")
        XCTAssertEqual(SpaceAPI(origin: origin, cookies: [a,b]).storageIdentity, SpaceAPI(origin: origin, cookies: [b,a]).storageIdentity)
        XCTAssertNotEqual(SpaceAPI(origin: origin, cookies: [a]).storageIdentity, SpaceAPI(origin: origin, cookies: [cookie("session", "other")]).storageIdentity)
    }
    // Opt-in isolated server only. Fixture JSON: {paperID, otherPaperID,
    // cookies:[{name,value,domain,path}], guestCookies:[{name,value,domain,path}]}.
    // Guest must already have explicitly claimed its fixture paper. No production defaults.
    func testIsolatedServerMemberGuestAndAnonymousBoundaries() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let raw = env["PAPERVIEW_TEST_ORIGIN"], let origin = URL(string: raw),
              let path = env["PAPERVIEW_TEST_CREDENTIALS"] else { throw XCTSkip("Isolated server fixture not configured") }
        guard ["localhost", "127.0.0.1", "::1"].contains(origin.host ?? "") else { throw XCTSkip("Only isolated loopback fixtures permitted") }
        struct Cookie: Decodable { var name: String; var value: String; var domain: String; var path: String }
        struct Fixture: Decodable { var paperID: String; var otherPaperID: String; var cookies: [Cookie]; var guestCookies: [Cookie] }
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        func cookies(_ values: [Cookie]) -> [HTTPCookie] { values.compactMap { HTTPCookie(properties: [.name: $0.name, .value: $0.value, .domain: $0.domain, .path: $0.path]) } }
        let member = SpaceAPI(origin: origin, cookies: cookies(fixture.cookies))
        let metadata = try await member.metadata(paperID: fixture.paperID)
        XCTAssertTrue(metadata.canEdit)
        let pdf = try await member.pdf(paperID: fixture.paperID)
        XCTAssertFalse(pdf.isEmpty)
        guard metadata.revision > 1 else { throw XCTSkip("Fixture must have revision > 1 for a valid stale token") }
        do { _ = try await member.save(paperID: fixture.paperID, revision: metadata.revision - 1, annotations: metadata.annotations); XCTFail("Stale revision accepted") }
        catch PaperError.http(409, _) {}
        let guest = SpaceAPI(origin: origin, cookies: cookies(fixture.guestCookies))
        let guestMetadata = try await guest.metadata(paperID: fixture.paperID)
        XCTAssertTrue(guestMetadata.guest)
        for api in [guest, SpaceAPI(origin: origin, cookies: [])] {
            do { _ = try await api.metadata(paperID: fixture.otherPaperID); XCTFail("Private paper disclosed") }
            catch PaperError.http(let status, _) { XCTAssertTrue([401,403,404].contains(status)) }
        }
        do { try await guest.markRead(paperID: fixture.paperID, read: true); XCTFail("Guest read mutation accepted") }
        catch PaperError.http(let status, _) { XCTAssertTrue([401,403].contains(status)) }
    }
    func testMockTransportRejectsRedirectAndDeclaredOversize() async throws {
        let api = SpaceAPI(origin: URL(string: "https://fixture.invalid")!, cookies: [], protocolClasses: [PaperMockProtocol.self])
        PaperMockProtocol.handler = { _ in (302, ["Location": "https://external.invalid/secret"], Data()) }
        defer { PaperMockProtocol.handler = nil }
        do { _ = try await api.pdf(paperID: "p"); XCTFail("Redirect accepted") }
        catch PaperError.http(302, _) {}
        PaperMockProtocol.handler = { _ in (200, ["Content-Length": "41944065"], Data()) }
        do { _ = try await api.pdf(paperID: "p"); XCTFail("Oversize accepted") }
        catch PaperError.oversized {}
        PaperMockProtocol.handler = { _ in (200, ["Content-Length": "26214401"], Data()) }
        do { _ = try await api.metadata(paperID: "p"); XCTFail("Oversize JSON accepted") }
        catch PaperError.oversized {}
    }
    func testMockCookieFilteringExactOriginAndModestPDF() async throws {
        let origin = URL(string: "https://fixture.invalid")!
        let own = HTTPCookie(properties: [.domain: "fixture.invalid", .path: "/api", .name: "session", .value: "secret"])!
        let external = HTTPCookie(properties: [.domain: "elsewhere.invalid", .path: "/", .name: "external", .value: "no"])!
        let wrongPath = HTTPCookie(properties: [.domain: "fixture.invalid", .path: "/private", .name: "private", .value: "no"])!
        let api = SpaceAPI(origin: origin, cookies: [own, external, wrongPath], protocolClasses: [PaperMockProtocol.self])
        defer { PaperMockProtocol.handler = nil }
        PaperMockProtocol.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Origin"), "https://fixture.invalid")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "session=secret")
            XCTAssertFalse(request.httpShouldHandleCookies)
            return (200, [:], Data("{\"is_read\":true}".utf8))
        }
        try await api.markRead(paperID: "p", read: true)
        let payload = Data(repeating: 42, count: 512 * 1024)
        PaperMockProtocol.handler = { _ in (200, ["Content-Type": "application/pdf", "Content-Length": String(payload.count)], payload) }
        let start = Date()
        let received = try await api.pdf(paperID: "p")
        XCTAssertEqual(received, payload)
        XCTAssertLessThan(Date().timeIntervalSince(start), 15, "Modest PDF byte iteration is unexpectedly slow")
    }

    func testAuthorizedAccountIdentitySurvivesCookieRotation() async throws {
        let origin = URL(string: "https://fixture.invalid")!
        func api(_ token: String) -> SpaceAPI {
            let cookie = HTTPCookie(properties: [.domain: "fixture.invalid", .path: "/", .name: "session", .value: token])!
            return SpaceAPI(origin: origin, cookies: [cookie], protocolClasses: [PaperMockProtocol.self])
        }
        var owner = "account-a"
        var selfID = "old-session"
        var meRequests = 0
        let metadata = PaperMetadata(paper: PaperInfo(id: "p", title: "t", spaceID: "s"), annotations: [], revision: 1, canEdit: true, guest: false, presenters: [])
        PaperMockProtocol.handler = { request in
            if request.url?.path == "/api/me" {
                meRequests += 1
                return (200, [:], try JSONSerialization.data(withJSONObject: ["user": ["id": owner]]))
            }
            if request.url?.path.hasSuffix("/file") == true { return (200, [:], Data("%PDF-test".utf8)) }
            var value = metadata; value.selfID = selfID
            return (200, [:], try JSONEncoder().encode(value))
        }
        defer { PaperMockProtocol.handler = nil }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = api("old-token")
        let session = PaperSession(api: first, paperID: "p", storageDirectory: dir)
        _ = try await session.open()
        let note = PaperAnnotation(id: "pending", page: 1, type: .pen, color: "#007aff", points: [[0.1, 0.2]])
        try session.edit(note, id: note.id)
        selfID = "new-session"
        let fresh = api("new-token")
        let restored = PaperSession(api: fresh, paperID: "p", storageDirectory: dir)
        _ = try await restored.open()
        XCTAssertEqual(first.storageIdentity, fresh.storageIdentity)
        XCTAssertEqual(restored.annotations, [note]); XCTAssertEqual(meRequests, 2)
        owner = "account-b"; selfID = "other-session"
        let other = PaperSession(api: api("other-token"), paperID: "p", storageDirectory: dir)
        _ = try await other.open(); XCTAssertTrue(other.annotations.isEmpty)
        await restored.refresh(); XCTAssertNil(restored.metadata)
        XCTAssertTrue(restored.annotations.isEmpty)
    }
    func testNativeInkThroughIsolatedServerMergeAndConflict() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let raw = env["PAPERVIEW_TEST_ORIGIN"], let origin = URL(string: raw),
              let path = env["PAPERVIEW_TEST_CREDENTIALS"] else { throw XCTSkip("Isolated server fixture not configured") }
        guard ["localhost", "127.0.0.1", "::1"].contains(origin.host ?? "") else { throw XCTSkip("Only isolated loopback fixtures permitted") }
        struct Cookie: Decodable { var name: String; var value: String; var domain: String; var path: String }
        struct Fixture: Decodable { var paperID: String; var cookies: [Cookie] }
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let cookies = fixture.cookies.compactMap { HTTPCookie(properties: [.name: $0.name, .value: $0.value, .domain: $0.domain, .path: $0.path]) }
        let api = SpaceAPI(origin: origin, cookies: cookies)
        let remote = SpaceAPI(origin: origin, cookies: cookies)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let session = PaperSession(api: api, paperID: fixture.paperID, storageDirectory: dir)
        let pdf = try await session.open()
        let document = try XCTUnwrap(PDFDocument(data: pdf))
        let geometry = ReaderGeometry(page: try XCTUnwrap(document.page(at: 0)))
        let points = [CGPoint(x: geometry.displaySize.width * 0.2, y: geometry.displaySize.height * 0.2), CGPoint(x: geometry.displaySize.width * 0.4, y: geometry.displaySize.height * 0.4)].enumerated().map { index, location in
            PKStrokePoint(location: location, timeOffset: Double(index) / 60, size: CGSize(width: 2, height: 2), opacity: 1, force: 0.7, azimuth: 0, altitude: 1)
        }
        let stroke = PKStroke(ink: PKInk(.monoline, color: .blue), path: PKStrokePath(controlPoints: points, creationDate: Date()))
        var note = ReaderInk.annotation(stroke, previous: nil, page: 1, tool: .question, color: "#007aff", geometry: geometry, size: geometry.displaySize)
        note.id = "native-test-" + UUID().uuidString
        var independent = note; independent.id += "-independent"
        let ids = Set([note.id, independent.id])
        let archive = ReaderInk.nativeArchive(stroke, geometry: geometry, size: geometry.displaySize)
        func cleanup() async throws {
            for attempt in 0..<3 {
                let current = try await remote.metadata(paperID: fixture.paperID)
                do {
                    _ = try await remote.save(paperID: fixture.paperID, revision: current.revision, annotations: current.annotations.filter { !ids.contains($0.id) })
                    return
                } catch PaperError.http(409, _) { if attempt == 2 { throw PaperError.http(409, "Fixture cleanup revision conflict") } }
            }
        }
        do {
            try session.edit([AnnotationEdit(id: note.id, original: nil, value: note, native: archive)])
            XCTAssertEqual(session.nativeStroke(for: note), archive)
            let restored = try XCTUnwrap(ReaderInk.stroke(note, geometry: geometry, size: geometry.displaySize, native: session.nativeStroke(for: note)))
            XCTAssertEqual(restored.path.count, stroke.path.count)
            await session.refresh()
            let shared = try await remote.metadata(paperID: fixture.paperID)
            XCTAssertEqual(shared.annotations.first { $0.id == note.id }, note)
            var local = note; local.color = "#ff2d55"
            try session.edit([AnnotationEdit(id: note.id, original: note, value: local, native: archive)])
            _ = try await remote.save(paperID: fixture.paperID, revision: shared.revision, annotations: shared.annotations + [independent])
            await session.refresh()
            let merged = try await remote.metadata(paperID: fixture.paperID)
            XCTAssertEqual(merged.annotations.first { $0.id == note.id }, local)
            XCTAssertEqual(merged.annotations.first { $0.id == independent.id }, independent)
            var draft = local; draft.color = "#000000"
            try session.edit([AnnotationEdit(id: note.id, original: local, value: draft, native: archive)])
            var competing = local; competing.color = "#ffcc00"
            _ = try await remote.save(paperID: fixture.paperID, revision: merged.revision, annotations: merged.annotations.map { $0.id == note.id ? competing : $0 })
            await session.refresh()
            XCTAssertEqual(session.conflicts.map(\.id), [note.id])
            XCTAssertEqual(session.conflicts.first?.local, draft)
            let afterConflict = try await remote.metadata(paperID: fixture.paperID)
            XCTAssertEqual(afterConflict.annotations.first { $0.id == note.id }, competing)
            try await cleanup()
        } catch {
            do { try await cleanup() } catch { XCTFail("Fixture cleanup failed: \(error)") }
            throw error
        }
    }

    func testIdentityLookupFailureCannotOpenJournalAndGuestUsesGrant() async throws {
        let origin = URL(string: "https://fixture.invalid")!
        let api = SpaceAPI(origin: origin, cookies: [], protocolClasses: [PaperMockProtocol.self])
        let snapshot = api.storageIdentity
        var metadata = PaperMetadata(paper: PaperInfo(id: "p", title: "t", spaceID: "s"), annotations: [], revision: 1, canEdit: true, guest: false, presenters: [], selfID: "session")
        var meRequests = 0
        PaperMockProtocol.handler = { request in
            if request.url?.path == "/api/me" {
                meRequests += 1
                return (401, [:], Data("{\"detail\":\"expired\"}".utf8))
            }
            return (200, [:], try JSONEncoder().encode(metadata))
        }
        defer { PaperMockProtocol.handler = nil }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let session = PaperSession(api: api, paperID: "p", storageDirectory: dir)
        do { _ = try await session.open(); XCTFail("Identity lookup failure accepted") }
        catch PaperError.http(401, _) {}
        XCTAssertEqual(api.storageIdentity, snapshot)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path))
        metadata.guest = true; metadata.selfID = "g_fixture-grant"
        let guest = SpaceAPI(origin: origin, cookies: [], protocolClasses: [PaperMockProtocol.self])
        _ = try await guest.metadata(paperID: "p")
        XCTAssertEqual(meRequests, 1, "Guest identity must use its authorized grant, not /api/me")
        XCTAssertEqual(guest.storageIdentity, "https://fixture.invalid\nguest:g_fixture-grant")
        metadata.selfID = "g_other-grant"
        do { _ = try await guest.metadata(paperID: "p"); XCTFail("Live API changed guest grants") }
        catch PaperError.unauthorized {}
    }

}
