import Foundation
import XCTest
@testable import Paperview

final class BoardMergeTests: XCTestCase {
    func item(_ id: String, _ x: Double = 0, version: Int = 1) -> BoardElement {
        var e = BoardElement(kind: .rectangle, id: id); e.x = x; e.version = version; return e
    }
    func doc(_ elements: [BoardElement]) -> BoardDocument { BoardDocument(elements: elements) }
    func testIndependentEditsAndOrdering() {
        let base = doc([item("a"), item("b")])
        let merged = mergeBoards(base, doc([item("a", 1), item("b")]), doc([item("b", 2), item("a")]))
        XCTAssertEqual(merged, doc([item("a", 1), item("b", 2)]))
        XCTAssertTrue(sameBoard(base, doc(Array(base.elements.reversed()))))
    }
    func testDeleteEditAndVersionBoundChoice() {
        let base = doc([item("a")]), local = doc([]), remote = doc([item("a", 2)])
        let conflict = boardConflicts(base, local, remote).first!
        let choice = BoardResolution(conflict: conflict, choice: .local)
        XCTAssertEqual(mergeBoards(base, local, remote, resolutions: [choice]), .empty)
        XCTAssertNil(mergeBoards(base, local, doc([item("a", 2, version: 2)]), resolutions: [choice]))
    }
    func testAtomicGroupMembershipCannotBeWaived() {
        var a = item("a"), b = item("b"); a.groupId = "g"; b.groupId = "g"
        let base = doc([a, b]); var ungrouped = a; ungrouped.groupId = nil
        var moved = b; moved.x = 10
        let local = doc([ungrouped, b]), remote = doc([a, moved])
        let conflicts = boardConflicts(base, local, remote)
        XCTAssertTrue(conflicts.contains { $0.id == "group-membership" })
        XCTAssertNil(mergeBoards(base, local, remote, resolutions: conflicts.filter { $0.kind == .element }.map { .init(conflict: $0, choice: .local) }))
    }
    func testRelatedTargetChangeInvalidatesArrowReview() {
        let target = item("target")
        var arrow = BoardElement(kind: .arrow, id: "arrow"); arrow.startAnchor = .init(elementId: "target", x: 0, y: 0)
        let base = doc([target]), local = doc([target, arrow]), remote = doc([])
        let conflicts = boardConflicts(base, local, remote)
        let review = conflicts.first { $0.id == "arrow" }!
        XCTAssertEqual(review.related.map(\.id), ["target"])
        let resolution = BoardResolution(conflict: review, choice: .remote)
        XCTAssertNotNil(mergeBoards(base, local, remote, resolutions: [resolution]))
        let changedRemote = doc([item("target", 4)])
        XCTAssertNil(mergeBoards(base, local, changedRemote, resolutions: [resolution]))
    }
    func testImmutableAssetsUnionAndConflict() {
        let a = BoardAsset(mimeType: "image/png", dataURL: "data:a")
        let b = BoardAsset(mimeType: "image/png", dataURL: "data:b")
        let base = BoardDocument(assets: ["a": a])
        XCTAssertEqual(mergeBoards(base, .empty, .empty)?.assets, ["a": a])
        XCTAssertTrue(boardConflicts(base, BoardDocument(assets: ["a": b]), base).contains { $0.kind == .asset })
    }
    func testAggregateLimitsAndMissingAssets() {
        var e = item("image"); e.assetId = "absent"
        XCTAssertTrue(boardIssues(doc([e])).contains { $0.id == "missing-asset:image" })
        let assets = Dictionary(uniqueKeysWithValues: (0...1000).map { (String($0), BoardAsset(mimeType: "image/png", dataURL: "")) })
        XCTAssertTrue(boardIssues(BoardDocument(assets: assets)).contains { $0.id == "asset-limit" })
        let many = doc((0...50000).map { var e = item(String($0)); e.deleted = true; return e })
        XCTAssertTrue(boardIssues(many).contains { $0.id == "element-limit" })
    }
    func testUTF8AndEscapedEnvelopeLimits() {
        let asset = BoardAsset(mimeType: "image/png", dataURL: String(repeating: "é", count: 13 * 1024 * 1024))
        let issues = boardIssues(BoardDocument(assets: ["a": asset]))
        XCTAssertTrue(issues.contains { $0.id == "asset-bytes" })
        XCTAssertTrue(issues.contains { $0.id == "body-limit" })
        var e = item("text"); e.text = String(repeating: "\\", count: 13 * 1024 * 1024)
        XCTAssertTrue(boardIssues(doc([e])).contains { $0.id == "body-limit" })
    }
    func testDeletedArrowStillCannotSelfReference() {
        var arrow = BoardElement(kind: .arrow, id: "a"); arrow.deleted = true
        arrow.startAnchor = .init(elementId: "a", x: 0, y: 0)
        XCTAssertFalse(boardIssues(doc([arrow])).isEmpty)
    }
    func testOnlyContractTextDefaultsAreCanonicalAliases() {
        var text = BoardElement(kind: .text, id: "text"); text.text = "Synthetic"
        let legacy = doc([text]); var canonical = text; canonical.fontSize = 18; canonical.fontFamily = "sans-serif"
        XCTAssertTrue(sameBoard(legacy, doc([canonical])))
        var edited = text; edited.x = 8
        let merged = mergeBoards(legacy, doc([edited]), doc([canonical]))
        XCTAssertEqual(merged?.element("text")?.x, 8)
        XCTAssertEqual(merged?.element("text")?.fontSize, 18)
        XCTAssertEqual(merged?.element("text")?.fontFamily, "sans-serif")
        canonical.bold = false
        XCTAssertFalse(sameBoard(legacy, doc([canonical])))
        canonical = text; canonical.fontSize = 19
        XCTAssertFalse(sameBoard(legacy, doc([canonical])))
        var shape = item("shape"), explicit = shape; explicit.fontFamily = "sans-serif"
        XCTAssertFalse(sameBoard(doc([shape]), doc([explicit])))
        shape.version += 1
        XCTAssertFalse(sameBoard(doc([shape]), doc([item("shape")])))
    }
    func testOneULPGeometryDifferenceRemainsARealConflict() {
        let original = item("a", 435.21739130434787)
        var local = original; local.fill = "#ff0000"
        var remote = original; remote.x = original.x.nextDown
        XCTAssertFalse(sameBoard(doc([original]), doc([remote])))
        let conflicts = boardConflicts(doc([original]), doc([local]), doc([remote]))
        XCTAssertEqual(conflicts.map(\.id), ["a"])
        let choice = BoardResolution(conflict: conflicts[0], choice: .local)
        remote.x = remote.x.nextDown
        XCTAssertNil(mergeBoards(doc([original]), doc([local]), doc([remote]), resolutions: [choice]))
    }
    func testDefaultCanonicalizationDoesNotUnbindVersionReviewedChoices() {
        var base = BoardElement(kind: .text, id: "a"); base.text = "Base"
        var local = base; local.text = "Local"
        var remote = canonicalBoardElement(base); remote.text = "Remote"
        let conflict = boardConflicts(doc([base]), doc([local]), doc([remote]))[0]
        let choice = BoardResolution(conflict: conflict, choice: .local)
        XCTAssertEqual(mergeBoards(doc([base]), doc([local]), doc([remote]), resolutions: [choice])?.element("a")?.text, "Local")
        remote.version += 1
        XCTAssertNil(mergeBoards(doc([base]), doc([local]), doc([remote]), resolutions: [choice]))
    }

}
