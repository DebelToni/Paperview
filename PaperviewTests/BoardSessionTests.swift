import Foundation
import XCTest
@testable import Paperview

@MainActor private final class BoardServiceFixture: BoardService {
    var storageIdentity = "https://synthetic.invalid\naccount:one"
    var remote: SpaceSnapshot
    var failure: Error?
    var saves: [BoardDocument] = []
    var saving: (() async throws -> Void)?
    var fetching: (() async throws -> Void)?
    init() {
        remote = SpaceSnapshot(space: SpaceSummary(id: "s", title: "Synthetic", visibility: "private", creatorId: "one", revision: 1, member: true, shared: false, createdAt: 0), board: .empty, creators: [:], papers: [])
    }
    func space(id: String) async throws -> SpaceSnapshot { try await fetching?(); if let failure { throw failure }; return remote }
    func saveBoard(id: String, revision: Int, board: BoardDocument) async throws -> Int {
        saves.append(board); try await saving?()
        if let failure { throw failure }
        remote.board = board; remote.space.revision += 1; return remote.space.revision
    }
}
@MainActor final class BoardSessionTests: XCTestCase {
    private func directory() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }
    private func draft(_ x: Double) -> BoardDocument { var e = BoardElement(kind: .pen, id: "a"); e.x = x; return BoardDocument(elements: [e]) }
    private func session(_ api: BoardServiceFixture, _ dir: URL) -> BoardSession { BoardSession(api: api, spaceID: "s", storageDirectory: dir, validate: { _ in }) }
    func testFirstAuthorizedFetchMayBindCanonicalAccountIdentity() async throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let api = BoardServiceFixture(); api.storageIdentity = "https://synthetic.invalid\ncookie:unbound"
        api.fetching = { api.storageIdentity = "https://synthetic.invalid\naccount:canonical" }
        let s = session(api, dir); try await s.open(); try s.edit(draft(5))
        XCTAssertTrue(s.authorized); XCTAssertEqual(s.board, draft(5))
        api.fetching = { api.storageIdentity = "https://synthetic.invalid\naccount:other" }
        do { try await s.open(); XCTFail("An established session cannot adopt another account") } catch {}
        XCTAssertFalse(s.authorized); XCTAssertEqual(s.board, .empty)
    }
    func testDurableRecoveryAndAccountIsolation() async throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let api = BoardServiceFixture(), s = session(BoardServiceFixture(), dir)
        try await s.open(); try s.edit(draft(3))
        let recovered = session(api, dir); try await recovered.open(); XCTAssertEqual(recovered.board, draft(3)); XCTAssertTrue(recovered.dirty)
        api.storageIdentity = "https://synthetic.invalid\naccount:two"
        let other = session(api, dir); try await other.open(); XCTAssertEqual(other.board, .empty)
    }
    func testFailedSaveDoesNotAdvanceBase() async throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let api = BoardServiceFixture(), s = session(api, dir)
        try await s.open(); try s.edit(draft(1))
        api.saving = { throw PaperError.http(500, "synthetic") }
        await s.refresh(); XCTAssertEqual(s.base, .empty); XCTAssertEqual(s.board, draft(1)); XCTAssertTrue(s.dirty)
        let recovered = session(api, dir); try await recovered.open(); XCTAssertTrue(recovered.dirty)
    }
    func testEditDuringSaveAndRevertArePreserved() async throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let api = BoardServiceFixture(), s = session(api, dir)
        try await s.open(); try s.edit(draft(1))
        api.saving = { try s.edit(.empty) }
        await s.refresh(); XCTAssertEqual(s.base, draft(1)); XCTAssertEqual(s.board, .empty); XCTAssertTrue(s.dirty)
        api.saving = nil; await s.refresh(); XCTAssertEqual(api.remote.board, .empty); XCTAssertFalse(s.dirty)
    }
    func testDenialHidesContentAndReauthenticationRecovers() async throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let api = BoardServiceFixture(), s = session(api, dir)
        try await s.open(); try s.edit(draft(2))
        api.failure = PaperError.http(403, "denied"); await s.refresh()
        XCTAssertFalse(s.authorized); XCTAssertEqual(s.board, .empty); XCTAssertNil(s.snapshot)
        api.failure = nil; try await s.open(); XCTAssertEqual(s.board, draft(2)); XCTAssertTrue(s.dirty)
    }
    func testCorruptJournalIsNotOverwritten() async throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let api = BoardServiceFixture(), s = session(api, dir)
        try await s.open(); try s.edit(draft(2))
        let files = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)!
        var journalFile: URL?
        for case let url as URL in files where url.lastPathComponent == "draft.json" { journalFile = url }
        let file = try XCTUnwrap(journalFile), corrupt = Data("invalid-journal".utf8)
        try corrupt.write(to: file)
        let reopened = session(api, dir)
        do { try await reopened.open(); XCTFail("Corruption must fail visibly") } catch {}
        XCTAssertEqual(try Data(contentsOf: file), corrupt)
    }
    func testNativeArchiveRequiresCanonicalSemanticMatch() async throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let api = BoardServiceFixture(), s = session(api, dir)
        try await s.open(); let board = draft(1), bytes = Data([1, 2, 3]); try s.edit(board, native: ["a": bytes])
        var element = board.elements[0]; element.version += 1
        XCTAssertEqual(s.nativeStroke(for: element), bytes)
        element.x += 1; XCTAssertNil(s.nativeStroke(for: element))
        try s.edit(draft(4)); XCTAssertNil(s.nativeStroke(for: board.elements[0]))
    }
    func testAccountSwitchImmediatelyHidesBoardAndMetadata() async throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let api = BoardServiceFixture(), s = session(api, dir)
        try await s.open(); try s.edit(draft(2)); api.storageIdentity = "https://other.invalid\naccount:one"
        XCTAssertEqual(s.board, .empty); XCTAssertEqual(s.base, .empty); XCTAssertNil(s.snapshot)
        XCTAssertThrowsError(try s.edit(draft(3)))
    }
    func testUseServerRejectsEditsMadeDuringFetch() async throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let api = BoardServiceFixture(), s = session(api, dir)
        try await s.open(); try s.edit(draft(2))
        api.fetching = { try s.edit(self.draft(3)) }
        do { try await s.useServer(); XCTFail("Changed draft must require review") } catch {}
        XCTAssertEqual(s.board, draft(3)); XCTAssertEqual(s.base, .empty)
    }
    func testLateSaveAfterAccessInvalidationCannotExposeOrAdvanceDraft() async throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let api = BoardServiceFixture(), s = session(api, dir)
        try await s.open(); try s.edit(draft(2)); api.saving = { s.invalidateAccess() }
        await s.refresh(); XCTAssertEqual(s.board, .empty); XCTAssertFalse(s.authorized)
        api.saving = nil; try await s.open()
        XCTAssertEqual(s.board, draft(2)); XCTAssertFalse(s.dirty)
    }
    func testConcurrentGroupChangeBlocksUploadAndRetainsOriginalBase() async throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let api = BoardServiceFixture(); var a = draft(0).elements[0]; a.groupId = "g"
        var b = a; b.id = "b"; api.remote.board = BoardDocument(elements: [a, b])
        let s = session(api, dir); try await s.open()
        var ungrouped = a; ungrouped.groupId = nil
        try s.edit(BoardDocument(elements: [ungrouped, b]))
        var moved = b; moved.x = 12; api.remote.board = BoardDocument(elements: [a, moved])
        await s.refresh(); XCTAssertTrue(api.saves.isEmpty)
        XCTAssertTrue(s.conflicts.contains { $0.id == "group-membership" })
        XCTAssertEqual(s.base, BoardDocument(elements: [a, b]))
    }
    func testInvalidationPreservesJournalAndBlocksPersistence() async throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let api = BoardServiceFixture(), s = session(api, dir)
        try await s.open(); try s.edit(draft(2)); s.invalidateAccess()
        XCTAssertThrowsError(try s.persist())
        try await s.open(); XCTAssertEqual(s.board, draft(2))
    }
    func testReadOnlyTransitionDoesNotUploadOrDiscardDraft() async throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let api = BoardServiceFixture(), s = session(api, dir)
        try await s.open(); try s.edit(draft(2)); api.remote.space.member = false
        await s.refresh(); XCTAssertEqual(s.board, .empty); XCTAssertTrue(api.saves.isEmpty)
        XCTAssertThrowsError(try s.edit(draft(4)))
        api.remote.space.member = true; await s.refresh(); XCTAssertEqual(api.remote.board, draft(2))
    }
    func testStaleContactComposesIndependentRemoteElement() async throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let api = BoardServiceFixture(); api.remote.board = draft(0)
        let s = session(api, dir); try await s.open(); let original = s.board
        var b = BoardElement(kind: .rectangle, id: "b"); b.x = 20
        api.remote.board.elements.append(b); await s.refresh()
        try s.edit(draft(3), from: original)
        XCTAssertEqual(s.board.element("a")?.x, 3); XCTAssertEqual(s.board.element("b"), b)
        XCTAssertEqual(s.base, api.remote.board); XCTAssertFalse(s.hasPendingIntent)
    }
    func testAuxiliaryContactRecoversAndRejectsStaleChoice() async throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let api = BoardServiceFixture(); api.remote.board = draft(0)
        let s = session(api, dir); try await s.open(); let original = s.board
        api.remote.board = draft(2); await s.refresh()
        let bytes = Data([4, 5]); try s.edit(draft(1), from: original, native: ["a": bytes])
        XCTAssertEqual(s.board, draft(2)); XCTAssertEqual(s.base, draft(2)); XCTAssertTrue(s.hasPendingIntent)
        XCTAssertThrowsError(try s.edit(draft(9)))
        let stale = s.conflicts.map { BoardResolution(conflict: $0, choice: .local) }
        let recovered = session(api, dir); try await recovered.open()
        XCTAssertTrue(recovered.hasPendingIntent); XCTAssertEqual(recovered.conflicts, s.conflicts)
        api.remote.board = draft(3); await recovered.refresh()
        await recovered.resolve(stale)
        XCTAssertTrue(recovered.hasPendingIntent); XCTAssertEqual(recovered.board, draft(3)); XCTAssertTrue(api.saves.isEmpty)
        let choices = recovered.conflicts.map { BoardResolution(conflict: $0, choice: .local) }
        await recovered.resolve(choices)
        XCTAssertFalse(recovered.hasPendingIntent); XCTAssertEqual(api.remote.board, draft(1))
        XCTAssertEqual(recovered.nativeStroke(for: draft(1).elements[0]), bytes)
    }
    func testPendingUploadAndConflictingContactBothSurvive() async throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let api = BoardServiceFixture(); api.remote.board = draft(0)
        let s = session(api, dir); try await s.open(); let original = s.board
        var pending = draft(2); let b = BoardElement(kind: .rectangle, id: "b"); pending.elements.append(b)
        try s.edit(pending)
        api.saving = { try s.edit(self.draft(1), from: original) }
        await s.refresh()
        XCTAssertTrue(s.hasPendingIntent); XCTAssertFalse(s.conflicts.isEmpty)
        XCTAssertEqual(s.board, pending); XCTAssertEqual(s.base, pending)
        api.saving = nil
        let recovered = session(api, dir); try await recovered.open(); await recovered.refresh()
        XCTAssertTrue(recovered.hasPendingIntent); XCTAssertEqual(recovered.board.element("b"), b)
        XCTAssertEqual(api.saves.count, 1)
        recovered.invalidateAccess(); try await recovered.open(); XCTAssertTrue(recovered.hasPendingIntent)
        try await recovered.useServer(); XCTAssertFalse(recovered.hasPendingIntent)
    }
    func testUnconvertedInkIsDurableAndNotAFalseSavedState() async throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let api = BoardServiceFixture(), s = session(api, dir)
        try await s.open()
        let archive = Data([8, 4, 2, 1])
        try s.retainUnconvertedInk(archive, id: "stroke")
        XCTAssertTrue(s.hasUnconvertedInk); XCTAssertTrue(s.dirty)
        let raw = try XCTUnwrap(JSONSerialization.jsonObject(with: s.recoveryData()) as? [String: Any])
        XCTAssertEqual((raw["recoveryInk"] as? [String: String])?["stroke"], archive.base64EncodedString())
        let recovered = session(api, dir); try await recovered.open(); await recovered.refresh()
        XCTAssertTrue(recovered.hasUnconvertedInk); XCTAssertTrue(recovered.dirty); XCTAssertEqual(recovered.board, .empty)
        try recovered.discardUnconvertedInk(); XCTAssertFalse(recovered.hasUnconvertedInk); XCTAssertFalse(recovered.dirty)
    }
    func testSuccessfulRetriedContactAcknowledgesOnlyMatchingRecoveryInk() async throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let api = BoardServiceFixture(), s = session(api, dir)
        try await s.open(); try s.retainUnconvertedInk(Data([1]), id: "a"); try s.retainUnconvertedInk(Data([2]), id: "other")
        try s.edit(draft(3), native: ["a": Data([1])])
        let raw = try XCTUnwrap(JSONSerialization.jsonObject(with: s.recoveryData()) as? [String: Any])
        XCTAssertNil((raw["recoveryInk"] as? [String: String])?["a"])
        XCTAssertNotNil((raw["recoveryInk"] as? [String: String])?["other"])
        XCTAssertTrue(s.hasUnconvertedInk)
    }
    func testRecoveryCannotBeExportedOrAdoptedAfterAccountChange() async throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let api = BoardServiceFixture(), s = session(api, dir)
        try await s.open(); try s.retainUnconvertedInk(Data([1]), id: "a")
        api.storageIdentity = "https://synthetic.invalid\naccount:other"
        XCTAssertThrowsError(try s.recoveryData()); XCTAssertThrowsError(try s.discardUnconvertedInk())
        let other = session(api, dir); try await other.open(); XCTAssertFalse(other.hasUnconvertedInk)
    }
}
