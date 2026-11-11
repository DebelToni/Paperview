import XCTest
@testable import Paperview

@MainActor private final class FakePaperService: PaperService {
    var storageIdentity = "account-a"
    var value = PaperMetadata(paper: PaperInfo(id: "p", title: "Paper", spaceID: "s"), annotations: [], revision: 1, canEdit: true, guest: false, presenters: [])
    var failure: Error?
    var collisions = 0
    var saves = 0
    var reads = 0
    var onSave: (() -> Void)?
    var loseSaveAcknowledgement = false
    func metadata(paperID: String) async throws -> PaperMetadata { reads += 1; if let failure { throw failure }; return value }
    func pdf(paperID: String) async throws -> Data { Data("%PDF-fixture".utf8) }
    func save(paperID: String, revision: Int, annotations: [PaperAnnotation]) async throws -> Int {
        saves += 1
        if collisions > 0 { collisions -= 1; value.revision += 1; throw PaperError.http(409, "revision") }
        onSave?(); onSave = nil
        guard revision == value.revision else { throw PaperError.http(409, "revision") }
        value.annotations = annotations; value.revision += 1
        if loseSaveAcknowledgement { throw CancellationError() }
        return value.revision
    }
}
@MainActor final class CoreTests: XCTestCase {
    private func note(_ id: String = "a", _ text: String = "mine") -> PaperAnnotation {
        PaperAnnotation(id: id, page: 1, type: .question, color: "#ff2d55", points: [[0.1, 0.2]], text: text, size: 2)
    }
    private func directory() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }
    func testAnnotationCodable() throws {
        let value = note()
        XCTAssertEqual(try JSONDecoder().decode(PaperAnnotation.self, from: JSONEncoder().encode(value)), value)
        let encoded = try JSONEncoder().encode(PaperInfo(id: "p", title: "t", spaceID: "s", isRead: true))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(json["space_id"] as? String, "s"); XCTAssertEqual(json["is_read"] as? Bool, true)
    }
    func testDurableRelaunchAddEditRemove() async throws {
        let service = FakePaperService(), dir = directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = PaperSession(api: service, paperID: "p", storageDirectory: dir)
        _ = try await first.open(); try first.edit(note(), id: "a")
        let second = PaperSession(api: service, paperID: "p", storageDirectory: dir)
        _ = try await second.open(); XCTAssertEqual(second.annotations, [note()])
        await second.flush(); XCTAssertEqual(service.value.annotations, [note()])
        try second.edit(note("a", "changed"), id: "a"); await second.flush()
        XCTAssertEqual(service.value.annotations.first?.text, "changed")
        try second.edit(nil, id: "a"); await second.flush(); XCTAssertTrue(service.value.annotations.isEmpty)
    }
    func testSharedStackingAndLocalCreationOrderSurviveRelaunchAndSave() async throws {
        let service = FakePaperService(), dir = directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        service.value.annotations = [note("z"), note("b"), note("m")]
        let first = PaperSession(api: service, paperID: "p", storageDirectory: dir)
        _ = try await first.open()
        XCTAssertEqual(first.annotations.map(\.id), ["z", "b", "m"])
        try first.edit(note("b", "edited"), id: "b")
        try first.edit(note("y"), id: "y")
        try first.edit(note("a"), id: "a")
        let restored = PaperSession(api: service, paperID: "p", storageDirectory: dir)
        _ = try await restored.open()
        XCTAssertEqual(restored.annotations.map(\.id), ["z", "b", "m", "y", "a"])
        await restored.flush()
        XCTAssertEqual(service.value.annotations.map(\.id), ["z", "b", "m", "y", "a"])
        service.value.annotations.append(note("remote")); service.value.revision += 1
        try restored.edit(note("c"), id: "c")
        await restored.refresh()
        XCTAssertEqual(service.value.annotations.map(\.id), ["z", "b", "m", "y", "a", "remote", "c"])
    }
    func testIndependentRemoteAndConflict() async throws {
        let service = FakePaperService(), dir = directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        service.value.annotations = [note("a", "original")]
        let session = PaperSession(api: service, paperID: "p", storageDirectory: dir)
        _ = try await session.open(); try session.edit(note(), id: "a"); try session.edit(note("b"), id: "b")
        service.value.annotations = [note("a", "remote"), note("c")]; service.value.revision += 1
        await session.refresh()
        XCTAssertEqual(session.conflicts.map(\.id), ["a"])
        XCTAssertEqual(Set(service.value.annotations.map(\.id)), Set(["a", "b", "c"]))
        XCTAssertEqual(service.value.annotations.first { $0.id == "a" }?.text, "remote")
        try session.resolve(id: "a", keepMine: true); await session.flush()
        XCTAssertEqual(service.value.annotations.first { $0.id == "a" }?.text, "mine")
    }
    func testGlobalRevisionRetriesAndInflightEdit() async throws {
        let service = FakePaperService(), dir = directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let session = PaperSession(api: service, paperID: "p", storageDirectory: dir)
        _ = try await session.open(); try session.edit(note(), id: "a")
        service.collisions = 2
        service.onSave = { try! session.edit(self.note("a", "newer"), id: "a") }
        await session.flush(); XCTAssertEqual(service.saves, 3)
        XCTAssertEqual(session.annotations.first?.text, "newer")
        await session.flush(); XCTAssertEqual(service.value.annotations.first?.text, "newer")
    }
    func testInflightRevertIsNotLost() async throws {
        let service = FakePaperService(), dir = directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let session = PaperSession(api: service, paperID: "p", storageDirectory: dir)
        _ = try await session.open(); try session.edit(note(), id: "a")
        service.onSave = { try! session.edit(nil, id: "a") }
        await session.flush(); XCTAssertTrue(session.annotations.isEmpty)
        await session.flush(); XCTAssertTrue(service.value.annotations.isEmpty)
    }
    func testAuthorizationLossStopsPollingAndIsolatesPrincipal() async throws {
        let service = FakePaperService(), dir = directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let session = PaperSession(api: service, paperID: "p", storageDirectory: dir)
        _ = try await session.open(); try session.edit(note(), id: "a")
        service.failure = PaperError.http(403, "denied"); await session.refresh()
        let reads = service.reads; await session.refresh(); XCTAssertEqual(reads, service.reads)
        XCTAssertTrue(session.annotations.isEmpty); XCTAssertThrowsError(try session.edit(note(), id: "a"))
        service.failure = nil; service.storageIdentity = "account-b"
        let other = PaperSession(api: service, paperID: "p", storageDirectory: dir)
        _ = try await other.open(); XCTAssertTrue(other.annotations.isEmpty)
        service.storageIdentity = "account-a"
        let restored = PaperSession(api: service, paperID: "p", storageDirectory: dir)
        _ = try await restored.open(); XCTAssertEqual(restored.annotations, [note()])
    }
    func testCorruptJournalPreservedAndArchiveMismatch() async throws {
        let service = FakePaperService(), dir = directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let session = PaperSession(api: service, paperID: "p", storageDirectory: dir)
        _ = try await session.open(); try session.edit(note(), id: "a")
        try session.saveNativeStroke(Data([1,2]), annotation: note())
        XCTAssertEqual(session.nativeStroke(for: note()), Data([1,2]))
        try session.edit(note("a", "changed"), id: "a"); XCTAssertNil(session.nativeStroke(for: note()))
        let file = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil).first)
        try Data("broken".utf8).write(to: file)
        let restored = PaperSession(api: service, paperID: "p", storageDirectory: dir)
        do { _ = try await restored.open(); XCTFail("Expected corrupt journal") } catch PaperError.corruptJournal {} catch { XCTFail("\(error)") }
        XCTAssertEqual(try Data(contentsOf: file), Data("broken".utf8))
    }
    func testTransportFailureRetainsPending() async throws {
        let service = FakePaperService(), dir = directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let session = PaperSession(api: service, paperID: "p", storageDirectory: dir)
        _ = try await session.open(); try session.edit(note(), id: "a")
        service.failure = URLError(.notConnectedToInternet); await session.flush()
        XCTAssertEqual(session.annotations, [note()]); service.failure = nil
        await session.flush(); XCTAssertEqual(service.value.annotations, [note()])
    }
    func testRetriesAreBoundedAndRemoteDeleteConflicts() async throws {
        let service = FakePaperService(), dir = directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        service.value.annotations = [note("a", "base")]
        let session = PaperSession(api: service, paperID: "p", storageDirectory: dir)
        _ = try await session.open(); try session.edit(note(), id: "a")
        service.collisions = 10; await session.flush()
        XCTAssertEqual(service.saves, 3); XCTAssertEqual(session.annotations, [note()])
        service.collisions = 0; service.value.annotations = []; service.value.revision += 1
        await session.refresh(); XCTAssertEqual(session.conflicts.map(\.id), ["a"])
        try session.resolve(id: "a", keepMine: false)
        XCTAssertTrue(session.annotations.isEmpty); XCTAssertTrue(session.conflicts.isEmpty)
    }

    func testAtomicBatchFailureAndNativeTransaction() async throws {
        let service = FakePaperService(), dir = directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let session = PaperSession(api: service, paperID: "p", storageDirectory: dir)
        _ = try await session.open()
        var changes = 0; session.onChange = { changes += 1 }
        let batch = [AnnotationEdit(id: "a", original: nil, value: note(), native: Data([3])), AnnotationEdit(id: "b", original: nil, value: note("b"))]
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        let file = try XCTUnwrap(files.first)
        let before = try Data(contentsOf: file)
        // An unwritable destination fails after the complete batch is prepared.
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        XCTAssertThrowsError(try session.edit(batch))
        XCTAssertTrue(session.annotations.isEmpty); XCTAssertEqual(changes, 0)
        try FileManager.default.removeItem(at: file); try before.write(to: file)
        try session.edit(batch); XCTAssertEqual(changes, 1)
        let relaunched = PaperSession(api: service, paperID: "p", storageDirectory: dir)
        _ = try await relaunched.open()
        XCTAssertEqual(relaunched.annotations.count, 2)
        XCTAssertEqual(relaunched.nativeStroke(for: note()), Data([3]))
        XCTAssertEqual(relaunched.status, "Pending edits")
    }
    func testCapturedOriginalConflictSurvivesRelaunchAndPrincipalChange() async throws {
        let service = FakePaperService(), dir = directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        service.value.selfID = "session-a"; service.value.annotations = [note("a", "base")]
        let session = PaperSession(api: service, paperID: "p", storageDirectory: dir)
        _ = try await session.open()
        let baseline = note("a", "base")
        service.value.annotations = [note("a", "remote")]; service.value.revision += 1
        await session.refresh()
        try session.edit([AnnotationEdit(id: "a", original: baseline, value: note(), native: Data([9]))])
        XCTAssertEqual(session.conflicts.count, 1)
        let reopened = PaperSession(api: service, paperID: "p", storageDirectory: dir)
        _ = try await reopened.open(); XCTAssertEqual(reopened.conflicts.first?.original, baseline)
        XCTAssertEqual(reopened.status, "Conflicting annotations need a choice")
        service.value.selfID = "session-b"
        await reopened.refresh(); XCTAssertTrue(reopened.annotations.isEmpty)
        let changed = PaperSession(api: service, paperID: "p", storageDirectory: dir)
        _ = try await changed.open(); XCTAssertEqual(changed.annotations, [note()])
        service.value.selfID = "session-a"
        let original = PaperSession(api: service, paperID: "p", storageDirectory: dir)
        _ = try await original.open(); XCTAssertEqual(original.annotations, [note()])
    }
    func testAccessInvalidationDuringSaveDoesNotRepopulateState() async throws {
        let service = FakePaperService(), dir = directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let session = PaperSession(api: service, paperID: "p", storageDirectory: dir)
        _ = try await session.open(); try session.edit(note(), id: "a")
        service.onSave = { session.invalidateAccess() }
        await session.flush(); XCTAssertNil(session.metadata); XCTAssertTrue(session.annotations.isEmpty)
    }

    func testCancelledSaveKeepsInflightUndoDurable() async throws {
        let service = FakePaperService(), dir = directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let session = PaperSession(api: service, paperID: "p", storageDirectory: dir)
        _ = try await session.open(); try session.edit(note(), id: "a")
        service.onSave = { try! session.edit(nil, id: "a") }
        service.loseSaveAcknowledgement = true
        await session.flush(); XCTAssertTrue(session.annotations.isEmpty)
        let reopened = PaperSession(api: service, paperID: "p", storageDirectory: dir)
        _ = try await reopened.open()
        XCTAssertTrue(reopened.annotations.isEmpty)
        XCTAssertEqual(reopened.conflicts.map(\.id), ["a"])
        XCTAssertNil(reopened.conflicts.first?.local)
    }
    func testInvalidBatchHasNoPartialNotesOrArchives() async throws {
        let service = FakePaperService(), dir = directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let session = PaperSession(api: service, paperID: "p", storageDirectory: dir)
        _ = try await session.open()
        var invalid = note("b"); invalid.points = [[1.1, 0]]
        XCTAssertThrowsError(try session.edit([
            AnnotationEdit(id: "a", original: nil, value: note(), native: Data([1])),
            AnnotationEdit(id: "b", original: nil, value: invalid)
        ]))
        XCTAssertTrue(session.annotations.isEmpty); XCTAssertNil(session.nativeStroke(for: note()))
        let reopened = PaperSession(api: service, paperID: "p", storageDirectory: dir)
        _ = try await reopened.open(); XCTAssertTrue(reopened.annotations.isEmpty)
    }

    func testSameAccountReauthenticationRestoresPendingButOtherAccountCannotSee() async throws {
        let dir = directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = FakePaperService(); first.value.selfID = "old-session"
        let session = PaperSession(api: first, paperID: "p", storageDirectory: dir)
        _ = try await session.open(); try session.edit(note(), id: "a")
        let reauthenticated = FakePaperService(); reauthenticated.value.selfID = "new-session"
        let restored = PaperSession(api: reauthenticated, paperID: "p", storageDirectory: dir)
        _ = try await restored.open(); XCTAssertEqual(restored.annotations, [note()])
        let other = FakePaperService(); other.storageIdentity = "account-b"; other.value.selfID = "other-session"
        let isolated = PaperSession(api: other, paperID: "p", storageDirectory: dir)
        _ = try await isolated.open(); XCTAssertTrue(isolated.annotations.isEmpty)
        reauthenticated.value.selfID = "unexpected-session"
        await restored.refresh(); XCTAssertNil(restored.metadata)
        XCTAssertThrowsError(try restored.edit(note(), id: "a"))
    }

}
