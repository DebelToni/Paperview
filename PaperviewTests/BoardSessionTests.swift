import Foundation
import XCTest
@testable import Paperview

@MainActor private final class BoardServiceFixture: BoardService {
    var storageIdentity = "https://synthetic.invalid\naccount:one"
    var remote: SpaceSnapshot
    var failure: Error?
    var saves: [BoardDocument] = []
    var saveRevisions: [Int] = []
    var acknowledgementFailure: Error?
    var saving: (() async throws -> Void)?
    var fetching: (() async throws -> Void)?
    init() {
        remote = SpaceSnapshot(space: SpaceSummary(id: "s", title: "Synthetic", visibility: "private", creatorId: "one", revision: 1, member: true, shared: false, createdAt: 0), board: .empty, creators: [:], papers: [])
    }
    func space(id: String) async throws -> SpaceSnapshot { try await fetching?(); if let failure { throw failure }; return remote }
    func saveBoard(id: String, revision: Int, board: BoardDocument) async throws -> Int {
        saves.append(board); saveRevisions.append(revision); try await saving?()
        if let failure { throw failure }
        guard revision == remote.space.revision else { throw PaperError.http(409, "Synthetic revision conflict") }
        remote.board = board; remote.space.revision += 1
        if let acknowledgementFailure { throw acknowledgementFailure }
        return remote.space.revision
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
    func testExplicitLegacyV1JournalRetainsPendingInkAndAccountIsolation() async throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let api = BoardServiceFixture(), initial = session(api, dir)
        try await initial.open()
        let files = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)!
        let file = try XCTUnwrap(files.allObjects.compactMap { $0 as? URL }.first { $0.lastPathComponent == "draft.json" })
        let local = draft(4), archive = Data([1, 2, 3, 4])
        func object<T: Encodable>(_ value: T) throws -> Any { try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) }
        // Explicit build-14 journal shape, not the current journal encoder.
        let legacy: [String: Any] = ["version": 1, "identity": api.storageIdentity, "spaceID": "s",
            "base": try object(BoardDocument.empty), "local": try object(local),
            "archives": ["a": ["element": try object(local.elements[0]), "data": archive.base64EncodedString()]]]
        try JSONSerialization.data(withJSONObject: legacy).write(to: file)
        let recovered = session(api, dir); try await recovered.open()
        XCTAssertEqual(recovered.board, local); XCTAssertTrue(recovered.dirty)
        XCTAssertFalse(recovered.hasPendingSubmission)
        XCTAssertEqual(recovered.nativeStroke(for: local.elements[0]), archive)
        api.storageIdentity = "https://synthetic.invalid\naccount:other"
        let other = session(api, dir); try await other.open()
        XCTAssertEqual(other.board, .empty); XCTAssertNil(other.nativeStroke(for: local.elements[0]))
    }
    func testAcknowledgedBorrowedRemoteConflictSurvivesRelaunchAndRejectsStaleChoice() async throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let api = BoardServiceFixture()
        var a = draft(0).elements[0], b = a; b.id = "b"
        api.remote.board = BoardDocument(elements: [a, b])
        let s = session(api, dir); try await s.open()
        a.x = 1; a.version = 2; try s.edit(BoardDocument(elements: [a, b]))
        b.x = 1; b.version = 2; api.remote.board.elements[1] = b; api.remote.space.revision = 2
        api.saving = {
            var edited = s.board; edited.elements[1].x = 2; edited.elements[1].version = 3
            try s.edit(edited)
        }
        await s.refresh(); api.saving = nil
        XCTAssertTrue(s.hasPendingSubmission); XCTAssertEqual(api.saves.count, 1)
        let reopened = session(api, dir); try await reopened.open()
        XCTAssertTrue(reopened.hasPendingSubmission)
        let conflict = try XCTUnwrap(reopened.conflicts.first { $0.id == "b" })
        let stale = BoardResolution(conflict: conflict, choice: .local)
        api.remote.board.elements[1].x = 3; api.remote.board.elements[1].version = 4; api.remote.space.revision = 4
        await reopened.resolve([stale])
        XCTAssertEqual(api.saves.count, 1); XCTAssertTrue(reopened.hasPendingSubmission)
        XCTAssertEqual(reopened.conflicts.first { $0.id == "b" }?.remote?.x, 3)
        let fresh = try XCTUnwrap(reopened.conflicts.first { $0.id == "b" })
        await reopened.resolve([BoardResolution(conflict: fresh, choice: .local)])
        XCTAssertFalse(reopened.dirty); XCTAssertEqual(api.remote.board.element("b")?.x, 2)
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
    func testExactServerTextDefaultsDoNotProducePollConflicts() async throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let api = BoardServiceFixture()
        var text = BoardElement(kind: .text, id: "text"); text.text = "Synthetic text"
        let original = BoardDocument(elements: [text]); api.remote.board = original
        let s = session(api, dir); try await s.open()
        XCTAssertEqual(s.board.element("text")?.fontSize, 18)
        XCTAssertEqual(s.board.element("text")?.fontFamily, "sans-serif")
        text.x = 14
        try s.edit(BoardDocument(elements: [text]), from: original)
        api.remote.board = canonicalBoard(api.remote.board); api.remote.space.revision += 1
        await s.refresh(); await s.refresh(); await s.refresh()
        XCTAssertTrue(s.conflicts.isEmpty); XCTAssertFalse(s.dirty); XCTAssertEqual(api.saves.count, 1)
        XCTAssertEqual(api.remote.board.element("text")?.x, 14)
        XCTAssertEqual(api.remote.board.element("text")?.fontSize, 18)
    }
    func testVersionOnlyRemoteEditIsNotAnUnchangedPoll() async throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let api = BoardServiceFixture(); api.remote.board = draft(0)
        let s = session(api, dir); try await s.open(); try s.edit(draft(1))
        api.remote.board.elements[0].version += 1; api.remote.space.revision += 1
        await s.refresh()
        XCTAssertEqual(s.conflicts.map(\.id), ["a"]); XCTAssertTrue(api.saves.isEmpty)
        XCTAssertEqual(s.base, draft(0)); XCTAssertEqual(s.board, draft(1))
    }
    func testDefiniteRejectionDoesNotImportBorrowedRemoteEditsIntoDraft() async throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let api = BoardServiceFixture()
        let b = BoardElement(kind: .rectangle, id: "b")
        var original = draft(0); original.elements.append(b); api.remote.board = original
        let s = session(api, dir); try await s.open()
        var local = original; local.elements[0].x = 1; try s.edit(local)
        api.remote.board.elements[1].x = 10; api.remote.space.revision += 1
        api.saving = {
            XCTAssertEqual(s.board, local); XCTAssertEqual(s.base, original)
            api.remote.board.elements[1].x = 20; api.remote.space.revision += 1
            api.saving = nil
            throw PaperError.http(409, "Synthetic independent edit during PUT")
        }
        await s.refresh()
        XCTAssertTrue(s.conflicts.isEmpty); XCTAssertFalse(s.dirty)
        XCTAssertEqual(api.saves.count, 2); XCTAssertEqual(api.remote.board.element("a")?.x, 1)
        XCTAssertEqual(api.remote.board.element("b")?.x, 20)
    }
    func testUnknownSavePreservesOriginalBranchesAndDoesNotRetryAutomatically() async throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let api = BoardServiceFixture()
        let b = BoardElement(kind: .rectangle, id: "b")
        var original = draft(0); original.elements.append(b); api.remote.board = original
        let s = session(api, dir); try await s.open()
        var local = original; local.elements[0].x = 1; try s.edit(local)
        api.remote.board.elements[1].x = 10; api.remote.space.revision += 1
        api.saving = { throw URLError(.networkConnectionLost) }
        await s.refresh()
        XCTAssertEqual(s.base, original); XCTAssertEqual(s.board, local)
        let recovery = try XCTUnwrap(JSONSerialization.jsonObject(with: s.recoveryData()) as? [String: Any])
        XCTAssertNotNil(recovery["submission"])
        api.saving = nil; api.remote.board.elements[1].x = 20; api.remote.space.revision += 1
        await s.refresh(); await s.refresh()
        XCTAssertEqual(api.saves.count, 1)
        XCTAssertEqual(s.conflicts.filter { $0.kind == .element }.map(\.id), ["a"])
        await s.resolve(s.conflicts.map { BoardResolution(conflict: $0, choice: .local) })
        XCTAssertFalse(s.dirty); XCTAssertTrue(s.conflicts.isEmpty)
        XCTAssertEqual(api.remote.board.element("a")?.x, 1); XCTAssertEqual(api.remote.board.element("b")?.x, 20)
    }
    func testLostAcknowledgementRetainsInFlightRevertAcrossRelaunch() async throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let api = BoardServiceFixture(), s = session(api, dir)
        try await s.open(); try s.edit(draft(4))
        api.saving = { try s.edit(.empty) }; api.acknowledgementFailure = URLError(.networkConnectionLost)
        await s.refresh()
        XCTAssertEqual(api.remote.board, draft(4)); XCTAssertEqual(s.board, .empty); XCTAssertTrue(s.dirty)
        api.saving = nil; api.acknowledgementFailure = nil
        let recovered = session(api, dir); try await recovered.open()
        XCTAssertEqual(recovered.board, .empty); XCTAssertEqual(recovered.base, draft(4)); XCTAssertTrue(recovered.dirty)
        XCTAssertTrue(recovered.conflicts.isEmpty)
        await recovered.refresh()
        XCTAssertEqual(api.remote.board, .empty); XCTAssertFalse(recovered.dirty); XCTAssertEqual(api.saves.count, 2)
    }
    func testUnconfirmedRevertRequiresExplicitFencedRetryEvenWhenLocalEqualsServer() async throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let api = BoardServiceFixture(), s = session(api, dir)
        try await s.open(); try s.edit(draft(4))
        api.saving = { try s.edit(.empty); throw URLError(.timedOut) }
        await s.refresh(); api.saving = nil
        let recovered = session(api, dir); try await recovered.open(); await recovered.refresh()
        XCTAssertEqual(recovered.board, .empty); XCTAssertEqual(recovered.base, .empty)
        XCTAssertTrue(recovered.dirty); XCTAssertEqual(recovered.conflicts.map(\.id), ["a"])
        XCTAssertEqual(api.saves.count, 1)
        let choice = BoardResolution(conflict: try XCTUnwrap(recovered.conflicts.first), choice: .local)
        await recovered.resolve([choice])
        XCTAssertFalse(recovered.dirty); XCTAssertTrue(recovered.conflicts.isEmpty)
        XCTAssertEqual(api.saves.count, 2); XCTAssertEqual(api.remote.space.revision, 2)
        XCTAssertEqual(api.remote.board, .empty)
    }
    func testUnknownOutcomeChoiceCannotWaiveNewServerVersion() async throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let api = BoardServiceFixture(); api.remote.board = draft(0)
        let s = session(api, dir); try await s.open(); try s.edit(draft(1))
        api.saving = { throw URLError(.networkConnectionLost) }
        await s.refresh(); api.saving = nil; await s.refresh()
        let stale = s.conflicts.map { BoardResolution(conflict: $0, choice: .local) }
        api.remote.board = draft(2); api.remote.board.elements[0].version = 2; api.remote.space.revision += 1
        await s.resolve(stale)
        XCTAssertEqual(api.saves.count, 1); XCTAssertFalse(s.conflicts.isEmpty)
        XCTAssertEqual(s.conflicts.first?.remote?.version, 2)
        await s.resolve(s.conflicts.map { BoardResolution(conflict: $0, choice: .local) })
        XCTAssertEqual(api.remote.board, draft(1)); XCTAssertFalse(s.dirty)
    }
    func testNoOpPollDoesNotValidateRewriteJournalOrNotify() async throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let api = BoardServiceFixture(); var validations = 0, notifications = 0
        let s = BoardSession(api: api, spaceID: "s", storageDirectory: dir, validate: { _ in validations += 1 })
        try await s.open(); s.onChange = { notifications += 1 }
        let files = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)!
        let file = try XCTUnwrap(files.allObjects.compactMap { $0 as? URL }.first { $0.lastPathComponent == "draft.json" })
        let inode = try FileManager.default.attributesOfItem(atPath: file.path)[.systemFileNumber] as? NSNumber
        let bytes = try Data(contentsOf: file), validated = validations, generation = s.boardGeneration
        await s.refresh(); await s.refresh(); await s.refresh()
        XCTAssertEqual(validations, validated); XCTAssertEqual(notifications, 0); XCTAssertEqual(s.boardGeneration, generation)
        XCTAssertEqual(try Data(contentsOf: file), bytes)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: file.path)[.systemFileNumber] as? NSNumber, inode)
        api.remote.space.title = "Updated metadata"; api.remote.space.revision += 1
        api.remote.papers = [PaperInfo(id: "p", title: "Synthetic", spaceID: "s", isRead: true)]
        await s.refresh()
        XCTAssertEqual(s.snapshot?.space.title, "Updated metadata"); XCTAssertEqual(s.snapshot?.papers.first?.isRead, true)
        XCTAssertEqual(validations, validated); XCTAssertEqual(notifications, 1); XCTAssertEqual(s.boardGeneration, generation)
        XCTAssertEqual(try Data(contentsOf: file), bytes)
    }
    func testNewRecoveryInkDuringUseServerIsNotDiscarded() async throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let api = BoardServiceFixture(), s = session(api, dir)
        try await s.open(); try s.edit(draft(1))
        api.fetching = { try s.retainUnconvertedInk(Data([1, 3, 5]), id: "late") }
        do { try await s.useServer(); XCTFail("New recovery ink must require another review") } catch {}
        XCTAssertTrue(s.hasUnconvertedInk); XCTAssertEqual(s.board, draft(1))
    }
    func testReadOnlyTransitionChangesVisibleBoardGeneration() async throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let api = BoardServiceFixture(), s = session(api, dir)
        try await s.open(); try s.edit(draft(1)); let generation = s.boardGeneration
        api.remote.space.member = false; await s.refresh()
        XCTAssertEqual(s.board, .empty); XCTAssertGreaterThan(s.boardGeneration, generation)
        XCTAssertTrue(s.dirty); XCTAssertTrue(api.saves.isEmpty)
    }

    func testContactChoiceFetchesLatestRemoteEvenWithoutAnInterveningPoll() async throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let api = BoardServiceFixture(); api.remote.board = draft(0)
        let s = session(api, dir); try await s.open(); let original = s.board
        api.remote.board = draft(2); api.remote.space.revision += 1; await s.refresh()
        try s.edit(draft(1), from: original)
        let stale = s.conflicts.map { BoardResolution(conflict: $0, choice: .local) }
        api.remote.board = draft(3); api.remote.space.revision += 1
        await s.resolve(stale)
        XCTAssertTrue(s.hasPendingIntent); XCTAssertEqual(s.board, draft(3)); XCTAssertTrue(api.saves.isEmpty)
        XCTAssertEqual(s.conflicts.first?.remote?.x, 3)
    }
    func testSubmittedAndAcknowledgedBoardRetainsServerTombstones() async throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let api = BoardServiceFixture()
        var tombstone = BoardElement(kind: .image, id: "old"); tombstone.deleted = true; tombstone.assetId = "asset"
        let asset = BoardAsset(mimeType: "image/png", dataURL: "data:image/png;base64,AAAA")
        api.remote.board = BoardDocument(elements: [tombstone], assets: ["asset": asset])
        let s = session(api, dir); try await s.open()
        try s.edit(BoardDocument(elements: [BoardElement(kind: .rectangle, id: "new")], assets: ["asset": asset]))
        await s.refresh(); await s.refresh()
        XCTAssertEqual(api.saves.count, 1); XCTAssertFalse(s.dirty); XCTAssertTrue(s.conflicts.isEmpty)
        XCTAssertEqual(s.board.element("old"), tombstone); XCTAssertEqual(s.base.element("old"), tombstone)
        XCTAssertEqual(s.board.assets["asset"], asset)
    }
    func testUnconvertedInkPollDoesNotRevalidateOrRewritePortableBoard() async throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let api = BoardServiceFixture(); var validations = 0, notifications = 0
        let s = BoardSession(api: api, spaceID: "s", storageDirectory: dir, validate: { _ in validations += 1 })
        try await s.open(); try s.retainUnconvertedInk(Data([4, 2]), id: "raw")
        s.onChange = { notifications += 1 }
        let files = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)!
        let file = try XCTUnwrap(files.allObjects.compactMap { $0 as? URL }.first { $0.lastPathComponent == "draft.json" })
        let inode = try FileManager.default.attributesOfItem(atPath: file.path)[.systemFileNumber] as? NSNumber
        let validated = validations
        await s.refresh(); await s.refresh()
        XCTAssertTrue(s.dirty); XCTAssertTrue(s.hasUnconvertedInk); XCTAssertTrue(api.saves.isEmpty)
        XCTAssertEqual(validations, validated); XCTAssertEqual(notifications, 0)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: file.path)[.systemFileNumber] as? NSNumber, inode)
    }

}
