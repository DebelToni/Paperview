import Foundation
import XCTest
@testable import Paperview

@MainActor final class BoardIntegrationTests: XCTestCase {
    private struct Cookie: Decodable { let name: String; let value: String; let domain: String; let path: String }
    private struct Fixture: Decodable { let spaceID: String; let cookies: [Cookie] }

    private func fixture() throws -> (URL, Fixture, [HTTPCookie]) {
        let env = ProcessInfo.processInfo.environment
        guard let raw = env["PAPERVIEW_TEST_ORIGIN"], let path = env["PAPERVIEW_TEST_CREDENTIALS"] else {
            throw XCTSkip("Isolated server fixture not configured")
        }
        guard let origin = URL(string: raw), origin.scheme == "http",
              ["localhost", "127.0.0.1", "::1", "[::1]"].contains(origin.host ?? ""),
              origin.user == nil, origin.password == nil, origin.query == nil, origin.fragment == nil,
              origin.path.isEmpty || origin.path == "/" else {
            throw XCTSkip("Only HTTP loopback fixtures permitted")
        }
        let value = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let cookies = try value.cookies.map { cookie in
            try XCTUnwrap(HTTPCookie(properties: [.name: cookie.name, .value: cookie.value, .domain: cookie.domain, .path: cookie.path]))
        }
        return (origin, value, cookies)
    }

    // Delete only our elements on a freshly fetched revision, retaining unrelated concurrent edits.
    private func cleanup(_ api: SpaceAPI, spaceID: String, ids: [String]) async throws {
        guard !ids.isEmpty else { return }
        for attempt in 0..<3 {
            let current = try await api.space(id: spaceID)
            let live = ids.filter { current.board.element($0).map { !$0.deleted } ?? false }
            guard !live.isEmpty else { return }
            let engine = try BoardEngine(board: current.board)
            let board = try engine.apply(.delete(live))
            do { _ = try await api.saveBoard(id: spaceID, revision: current.space.revision, board: board); return }
            catch PaperError.http(409, _) { if attempt == 2 { throw PaperError.http(409, "Cleanup revision conflict") } }
        }
    }

    func testRealSessionsMergeAndConflict() async throws {
        let (origin, fixture, cookies) = try fixture()
        let apiA = SpaceAPI(origin: origin, cookies: cookies), apiB = SpaceAPI(origin: origin, cookies: cookies)
        let remote = SpaceAPI(origin: origin, cookies: cookies)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let a = BoardSession(api: apiA, spaceID: fixture.spaceID, storageDirectory: root.appendingPathComponent("a"))
        let b = BoardSession(api: apiB, spaceID: fixture.spaceID, storageDirectory: root.appendingPathComponent("b"))
        let ids = [UUID().uuidString, UUID().uuidString]
        do {
            try await a.open(); try await b.open()
            var first = BoardElement(kind: .rectangle, id: ids[0]); first.width = 120; first.height = 80
            var second = BoardElement(kind: .rectangle, id: ids[1]); second.width = 90; second.height = 60; second.x = 150
            let engineA = try BoardEngine(board: a.board), engineB = try BoardEngine(board: b.board)
            try a.edit(engineA.apply(.put([first]))); try b.edit(engineB.apply(.put([second])))
            await a.refresh(); await b.refresh()
            let merged = try await remote.space(id: fixture.spaceID)
            XCTAssertEqual(merged.board.element(ids[0])?.deleted, false)
            XCTAssertEqual(merged.board.element(ids[1])?.deleted, false)
            XCTAssertFalse(a.dirty); XCTAssertFalse(b.dirty)
            await a.refresh(); await b.refresh()
            var changeA = try XCTUnwrap(a.board.element(ids[0])), changeB = try XCTUnwrap(b.board.element(ids[0]))
            changeA.stroke = "#ff0000"; changeB.stroke = "#0000ff"
            let nextA = try BoardEngine(board: a.board), nextB = try BoardEngine(board: b.board)
            try a.edit(nextA.apply(.put([changeA]))); try b.edit(nextB.apply(.put([changeB])))
            await a.refresh(); await b.refresh()
            XCTAssertTrue(b.conflicts.contains { $0.id == ids[0] })
            let after = try await remote.space(id: fixture.spaceID)
            XCTAssertEqual(after.board.element(ids[0])?.stroke, changeA.stroke)
            try await cleanup(remote, spaceID: fixture.spaceID, ids: ids)
        } catch {
            do { try await cleanup(remote, spaceID: fixture.spaceID, ids: ids) }
            catch { XCTFail("Fixture cleanup failed") }
            throw error
        }
    }

    func testRealSVGDiagram() async throws {
        let (origin, fixture, cookies) = try fixture()
        let api = SpaceAPI(origin: origin, cookies: cookies)
        var created: [String] = []
        do {
            let before = try await api.space(id: fixture.spaceID)
            let result = try await api.diagram(id: fixture.spaceID, revision: before.space.revision, format: "svg",
                source: "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"120\" height=\"80\"><rect x=\"5\" y=\"5\" width=\"110\" height=\"70\" fill=\"red\"/></svg>", x: 0, y: 0)
            // Never delete an element that existed before this call.
            if before.board.element(result.elementId) == nil { created = [result.elementId] }
            XCTAssertNil(before.board.element(result.elementId))
            XCTAssertNil(before.board.assets[result.assetId])
            let after = try await api.space(id: fixture.spaceID)
            try BoardEngine.validate(after.board)
            let element = try XCTUnwrap(after.board.element(result.elementId))
            XCTAssertEqual(element.kind, .image); XCTAssertFalse(element.deleted)
            XCTAssertEqual(element.assetId, result.assetId)
            XCTAssertNotNil(after.board.assets[result.assetId])
            XCTAssertEqual(after.space.revision, result.revision)
            try await cleanup(api, spaceID: fixture.spaceID, ids: created)
        } catch {
            do { try await cleanup(api, spaceID: fixture.spaceID, ids: created) }
            catch { XCTFail("Fixture cleanup failed") }
            throw error
        }
    }
}
