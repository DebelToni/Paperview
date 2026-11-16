import UIKit
import XCTest
@testable import Paperview

@MainActor final class BoardEditorTests: XCTestCase {
    private func textView(_ editor: BoardSourceController) throws -> UITextView {
        editor.loadViewIfNeeded()
        return try XCTUnwrap(editor.view.subviews.compactMap { $0 as? UITextView }.first)
    }
    private func save(_ editor: BoardSourceController) {
        _ = editor.perform(NSSelectorFromString("save"))
    }
    private func settle() async { for _ in 0..<20 { await Task.yield() } }

    func testCapturedCoverTitleBaselineRetainsConcurrentTitleAsConflict() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = CoverTitleService()
        let session = BoardSession(api: service, spaceID: "synthetic", storageDirectory: directory, validate: { _ in })
        try await session.open()
        let original = session.board
        var target = try XCTUnwrap(original.element("cover"))
        service.remote.board.elements[0].paperTitle = "Remote title"
        await session.refresh()
        target.paperTitle = "Local title"
        let candidate = try BoardEngine(board: original)
        let document = try candidate.apply(.put([target]))
        try session.edit(document, from: original)
        XCTAssertTrue(session.hasPendingIntent)
        XCTAssertEqual(session.board.element("cover")?.paperTitle, "Remote title")
        XCTAssertEqual(session.conflicts.first?.local?.paperTitle, "Local title")
        let recovered = BoardSession(api: service, spaceID: "synthetic", storageDirectory: directory, validate: { _ in })
        try await recovered.open()
        XCTAssertTrue(recovered.hasPendingIntent)
        XCTAssertEqual(recovered.conflicts, session.conflicts)
    }

    func testFailedSaveRetainsSourceAndAllowsRetry() async throws {
        var attempts = 0
        let editor = BoardSourceController(title: "SVG", source: "synthetic draft") { value in
            XCTAssertEqual(value, "edited draft")
            attempts += 1
            throw BoardError.invalidDocument("Synthetic validation failure")
        }
        let text = try textView(editor); text.text = "edited draft"
        XCTAssertEqual(text.smartQuotesType,.no); XCTAssertEqual(text.smartDashesType,.no); XCTAssertEqual(text.smartInsertDeleteType,.no)
        save(editor); await settle()
        XCTAssertEqual(text.text, "edited draft")
        XCTAssertTrue(text.isEditable)
        XCTAssertEqual(editor.navigationItem.rightBarButtonItem?.isEnabled, true)
        XCTAssertTrue(editor.view.subviews.compactMap { $0 as? UILabel }.contains { $0.text?.contains("Synthetic validation failure") == true })
        save(editor); await settle(); XCTAssertEqual(attempts, 2)
    }

    func testAwaitedAcceptanceKeepsEditorPresentedAndBlocksDuplicateSave() async throws {
        var resume: CheckedContinuation<Bool, Never>?
        var attempts = 0
        let editor = BoardSourceController(title: "HTML", source: "draft") { _ in
            attempts += 1
            return await withCheckedContinuation { resume = $0 }
        }
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 600, height: 800))
        let host = UIViewController(); window.rootViewController = host; window.makeKeyAndVisible()
        let navigation = UINavigationController(rootViewController: editor)
        host.present(navigation, animated: false)
        defer { window.isHidden = true }
        let text = try textView(editor)
        save(editor); await settle()
        XCTAssertNotNil(resume)
        XCTAssertTrue(host.presentedViewController === navigation)
        XCTAssertFalse(text.isEditable)
        XCTAssertEqual(editor.navigationItem.leftBarButtonItem?.isEnabled, false)
        save(editor); XCTAssertEqual(attempts, 1)
        _ = editor.perform(NSSelectorFromString("cancel"))
        XCTAssertTrue(host.presentedViewController === navigation)
        resume?.resume(returning: true); await settle()
        XCTAssertTrue(navigation.isBeingDismissed || host.presentedViewController == nil)
    }

    func testFalseAcceptanceAndOversizedSourceRemainRecoverable() async throws {
        var attempts = 0
        let editor = BoardSourceController(title: "Mermaid", source: "graph TD") { _ in attempts += 1; return false }
        let text = try textView(editor)
        save(editor); await settle()
        XCTAssertEqual(text.text, "graph TD"); XCTAssertTrue(text.isEditable)
        XCTAssertNotNil(editor.view.subviews.compactMap { $0 as? UILabel }.first?.text)
        text.text = String(repeating: "x", count: 100001)
        save(editor); await settle()
        XCTAssertEqual(attempts, 1); XCTAssertEqual(text.text.utf8.count, 100001)
        XCTAssertTrue(editor.view.subviews.compactMap { $0 as? UILabel }.contains { $0.text == "Source exceeds 100,000 bytes." })
    }
}

@MainActor private final class CoverTitleService: BoardService {
    let storageIdentity = "https://synthetic.invalid\naccount:editor"
    var remote: SpaceSnapshot
    init() {
        var cover = BoardElement(kind: .paper, id: "cover")
        cover.paperId = "synthetic-paper"; cover.paperTitle = "Original title"; cover.text = "Synthetic paper"
        remote = SpaceSnapshot(space: SpaceSummary(id: "synthetic", title: "Synthetic", visibility: "private", creatorId: "editor", revision: 1, member: true, shared: false, createdAt: 0), board: BoardDocument(elements: [cover]), creators: [:], papers: [])
    }
    func space(id: String) async throws -> SpaceSnapshot { remote }
    func saveBoard(id: String, revision: Int, board: BoardDocument) async throws -> Int {
        remote.board = board; remote.space.revision += 1; return remote.space.revision
    }
}
