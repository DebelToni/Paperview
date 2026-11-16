import XCTest
@testable import Paperview

private final class BoardMockProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, data) = try Self.handler!(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
@MainActor final class BoardAPITests: XCTestCase {
    private func api(cookies: [HTTPCookie] = []) -> SpaceAPI { SpaceAPI(origin: URL(string: "https://fixture.invalid")!, cookies: cookies, protocolClasses: [BoardMockProtocol.self]) }
    private let me = Data(#"{"user":{"id":"canonical","email":"test@example.invalid","nickname":"Test","is_admin":false,"approved":true}}"#.utf8)
    private let snapshot = Data(#"{"space":{"id":"s","title":"Fixture","visibility":"private","creator_id":"canonical","revision":1,"member":true,"shared":false,"created_at":0},"board":{"version":1,"elements":[],"assets":{}},"creators":{},"papers":[]}"#.utf8)
    override func tearDown() { BoardMockProtocol.handler = nil; super.tearDown() }
    func testInvalidIdentifiersNeverReachNetwork() async throws {
        BoardMockProtocol.handler = { _ in XCTFail("Unexpected network"); throw PaperError.invalidResponse }
        let service = api()
        for id in ["", "../a", "a/b", "a?x", "a#x", "%2f", "é", "a\n"] {
            do { _ = try await service.space(id: id); XCTFail(id) } catch PaperError.invalidURL {} catch { XCTFail("\(error)") }
            do { _ = try await service.history(id: id); XCTFail(id) } catch PaperError.invalidURL {} catch { XCTFail("\(error)") }
        }
    }
    func testCanonicalIdentityBoundAndRevalidated() async throws {
        var paths: [String] = []; let me = me; let snapshot = snapshot
        BoardMockProtocol.handler = { request in paths.append(request.url!.path); return (200, request.url!.path == "/api/me" ? me : snapshot) }
        let service = api(); _ = try await service.space(id: "s"); _ = try await service.space(id: "s")
        XCTAssertEqual(paths, ["/api/me", "/api/spaces/s", "/api/me", "/api/spaces/s"])
        XCTAssertEqual(service.storageIdentity, "https://fixture.invalid\naccount:canonical")
        BoardMockProtocol.handler = { _ in (200, Data(#"{"user":{"id":"other","email":"other@example.invalid","nickname":"Other","is_admin":false,"approved":true}}"#.utf8)) }
        do { _ = try await service.space(id: "s"); XCTFail("Changed owner accepted") } catch PaperError.unauthorized {}
    }
    func testGuestCannotBootstrapBoard() async throws {
        var count = 0
        BoardMockProtocol.handler = { request in count += 1; XCTAssertEqual(request.url!.path, "/api/me"); return (403, Data(#"{"detail":"guest denied"}"#.utf8)) }
        do { _ = try await api().space(id: "s"); XCTFail("Guest accepted") } catch PaperError.http(403, _) {}
        XCTAssertEqual(count, 1)
    }
    func testBoardIdentityMismatchRejected() async throws {
        let me = me; let bad = Data(String(decoding: snapshot, as: UTF8.self).replacingOccurrences(of: #""id":"s""#, with: #""id":"other""#).utf8)
        BoardMockProtocol.handler = { request in (200, request.url!.path == "/api/me" ? me : bad) }
        do { _ = try await api().space(id: "s"); XCTFail("Wrong space accepted") } catch PaperError.invalidResponse {}
    }
    func testMutationOriginAndCookieScope() async throws {
        let allowed = HTTPCookie(properties: [.domain: "fixture.invalid", .path: "/api/spaces", .name: "space", .value: "local"])!
        let foreign = HTTPCookie(properties: [.domain: "else.invalid", .path: "/", .name: "foreign", .value: "secret"])!
        let wrongPath = HTTPCookie(properties: [.domain: "fixture.invalid", .path: "/api/papers", .name: "paper", .value: "secret"])!
        BoardMockProtocol.handler = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://fixture.invalid/api/spaces/s/join")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Origin"), "https://fixture.invalid")
            let cookie = request.value(forHTTPHeaderField: "Cookie") ?? ""
            XCTAssertTrue(cookie.contains("space=local")); XCTAssertFalse(cookie.contains("secret"))
            return (200, Data("{}".utf8))
        }
        try await api(cookies: [allowed, foreign, wrongPath]).requestJoin(id: "s")
    }
    func testSummaryCodingKeys() throws {
        let value = try JSONDecoder().decode(SpaceSnapshot.self, from: snapshot)
        XCTAssertEqual(value.space.creatorId, "canonical"); XCTAssertEqual(value.space.createdAt, 0)
        let wire = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(value.space)) as? [String: Any])
        XCTAssertEqual(wire["creator_id"] as? String, "canonical"); XCTAssertNil(wire["creatorId"])
    }
    func testKnownRevisionRefreshesMetadataWithoutReplacingCachedBoard() async throws {
        let me = me, snapshot = snapshot
        var reads = 0
        BoardMockProtocol.handler = { request in
            if request.url!.path == "/api/me" { return (200,me) }
            reads += 1
            if reads == 1 { XCTAssertNil(request.url?.query); return (200,snapshot) }
            XCTAssertEqual(URLComponents(url:request.url!,resolvingAgainstBaseURL:false)?.queryItems?.first?.value,"1")
            var payload = try XCTUnwrap(JSONSerialization.jsonObject(with:snapshot) as? [String:Any])
            payload["board"] = NSNull()
            payload["papers"] = [["id":"p","title":"Synthetic PDF","space_id":"s","is_read":true]]
            return (200,try JSONSerialization.data(withJSONObject:payload))
        }
        let service = api(); let first = try await service.space(id:"s"), second = try await service.space(id:"s")
        XCTAssertEqual(first.board,second.board); XCTAssertEqual(second.papers.first?.isRead,true)
    }
    func testNullBoardWithoutMatchingRevisionCacheFailsLoudly() async throws {
        let me = me, snapshot = snapshot
        var payload = try XCTUnwrap(JSONSerialization.jsonObject(with:snapshot) as? [String:Any]); payload["board"] = NSNull()
        let missing = try JSONSerialization.data(withJSONObject:payload)
        BoardMockProtocol.handler = { request in (200,request.url!.path == "/api/me" ? me : missing) }
        do { _ = try await api().space(id:"s"); XCTFail("Null board accepted without a cache") } catch PaperError.invalidResponse {}
        let service = api()
        BoardMockProtocol.handler = { request in (200,request.url!.path == "/api/me" ? me : snapshot) }
        _ = try await service.space(id:"s")
        var summary = try XCTUnwrap(payload["space"] as? [String:Any]); summary["revision"] = 2; payload["space"] = summary
        let mismatch = try JSONSerialization.data(withJSONObject:payload)
        BoardMockProtocol.handler = { request in (200,request.url!.path == "/api/me" ? me : mismatch) }
        do { _ = try await service.space(id:"s"); XCTFail("Null board accepted for a different revision") } catch PaperError.invalidResponse {}
    }
    func testCacheNeverBypassesFreshAuthorization() async throws {
        let me = me, snapshot = snapshot
        BoardMockProtocol.handler = { request in (200,request.url!.path == "/api/me" ? me : snapshot) }
        let service = api(); _ = try await service.space(id:"s")
        BoardMockProtocol.handler = { request in
            XCTAssertEqual(request.url?.path,"/api/me")
            return (403,Data(#"{"detail":"revoked"}"#.utf8))
        }
        do { _ = try await service.space(id:"s"); XCTFail("Cached content bypassed authorization") } catch PaperError.http(403,_) {}
    }
    func testAnonymousPublicBoardAndBoundAccountCannotSwitchToAnonymous() async throws {
        let me = me, snapshot = snapshot
        var payload = try XCTUnwrap(JSONSerialization.jsonObject(with:snapshot) as? [String:Any])
        var summary = try XCTUnwrap(payload["space"] as? [String:Any]); summary["member"] = false; summary["visibility"] = "public"; payload["space"] = summary
        let publicData = try JSONSerialization.data(withJSONObject:payload), anonymous = Data(#"{"user":null}"#.utf8)
        BoardMockProtocol.handler = { request in (200,request.url!.path == "/api/me" ? anonymous : publicData) }
        let reader = api(); let data = try await reader.space(id:"s")
        XCTAssertFalse(data.space.member); XCTAssertEqual(reader.storageIdentity,"https://fixture.invalid\nanonymous")
        BoardMockProtocol.handler = { request in (200,request.url!.path == "/api/me" ? me : snapshot) }
        let member = api(); _ = try await member.space(id:"s")
        BoardMockProtocol.handler = { _ in (200,anonymous) }
        do { _ = try await member.space(id:"s"); XCTFail("Account cache switched to anonymous") } catch PaperError.unauthorized {}
    }
}
