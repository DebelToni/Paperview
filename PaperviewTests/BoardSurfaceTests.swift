import XCTest
import UIKit
import PencilKit
@testable import Paperview

@MainActor final class BoardSurfaceTests: XCTestCase {
    private func engine(_ elements: [BoardElement] = []) throws -> BoardEngine {
        do { return try BoardEngine(board: BoardDocument(elements: elements)) }
        catch BoardError.unavailable { throw XCTSkip("Native engine archive is not linked") }
    }
    func testViewportRoundTripAndAnchoredZoom() throws {
        let viewport = BoardViewport(x: -234, y: 56, zoom: 3.5), point = BoardPoint(x: -912, y: 789)
        let roundTrip = viewport.world(viewport.screen(point))
        XCTAssertEqual(roundTrip.x, point.x, accuracy: 1e-9); XCTAssertEqual(roundTrip.y, point.y, accuracy: 1e-9)
        let surface = BoardSurface(engine: try engine()); surface.frame = CGRect(x: 0, y: 0, width: 800, height: 600)
        surface.setViewport(viewport)
        let center = CGPoint(x: 400, y: 300), before = surface.viewport.world(center)
        surface.zoom(by: 2)
        XCTAssertEqual(surface.viewport.world(center).x, before.x, accuracy: 1e-9)
        XCTAssertEqual(surface.viewport.world(center).y, before.y, accuracy: 1e-9)
        surface.setViewport(BoardViewport(x: .nan, y: 0, zoom: 1))
        XCTAssertTrue(surface.viewport.x.isFinite)
    }

    func testRectangleEmitsCompletedCommandWithoutApplyingEngine() throws {
        let engine = try engine(), surface = BoardSurface(engine: engine)
        surface.tool = .rectangle
        var received: [BoardElement] = []; var ended = 0
        surface.onCommand = { command, native in
            if case let .put(elements, _) = command { received = elements }
            XCTAssertTrue(surface.isUsingTool); XCTAssertTrue(native.isEmpty)
            return true
        }
        surface.onToolContactEnded = { ended += 1 }
        surface.begin(at: CGPoint(x: 40, y: 50))
        XCTAssertTrue(received.isEmpty)
        surface.finish(at: CGPoint(x: 10, y: 20))
        XCTAssertEqual(received.first?.x, 10); XCTAssertEqual(received.first?.width, 30)
        XCTAssertEqual(received.first?.kind, .rectangle)
        XCTAssertTrue(engine.board.elements.isEmpty); XCTAssertEqual(ended, 1)
    }

    func testCancelledContactNeverCommitsAndReadOnlyRejectsInput() throws {
        let surface = BoardSurface(engine: try engine()); surface.tool = .rectangle
        var commands = 0; surface.onCommand = { _, _ in commands += 1; return true }
        surface.begin(at: .zero); surface.cancelGesture(); surface.finish(at: CGPoint(x: 50, y: 50))
        XCTAssertEqual(commands, 0); XCTAssertFalse(surface.isUsingTool)
        surface.editable = false; surface.begin(at: .zero)
        XCTAssertFalse(surface.isUsingTool)
    }

    func testSelectionExpandsGroupsAndMoveUsesEngineCommand() throws {
        var a = BoardElement(kind: .rectangle, id: "a"); a.width = 100; a.height = 100; a.groupId = "g"
        var b = a; b.id = "b"; b.x = 150
        let engine = try engine([a, b]), surface = BoardSurface(engine: engine)
        surface.select(["a"]); XCTAssertEqual(Set(surface.selection), ["a", "b"])
        var moved: [String] = []
        surface.onCommand = { command, _ in
            if case let .move(ids, dx, dy) = command { moved = ids; XCTAssertEqual(dx, 10); XCTAssertEqual(dy, 20) }
            return true
        }
        surface.begin(at: CGPoint(x: 20, y: 20)); surface.finish(at: CGPoint(x: 30, y: 40))
        XCTAssertEqual(Set(moved), ["a", "b"]); XCTAssertEqual(engine.board.element("a")?.x, 0)
    }

    func testInputSeparatesPencilAndPanAndTrackpad() throws {
        let surface = BoardSurface(engine: try engine()); surface.tool = .pen
        let canvas = try XCTUnwrap(surface.subviews.compactMap { $0 as? PKCanvasView }.first)
        XCTAssertEqual(canvas.drawingPolicy, .pencilOnly); XCTAssertFalse(canvas.isScrollEnabled)
        let pans = (surface.gestureRecognizers ?? []).compactMap { $0 as? UIPanGestureRecognizer }
        XCTAssertTrue(pans.contains { $0.allowedTouchTypes.isEmpty && $0.allowedScrollTypesMask == .all })
        XCTAssertTrue(pans.contains { $0.allowedTouchTypes == [NSNumber(value: UITouch.TouchType.direct.rawValue)] })
    }

    func testRendererUsesResolvedWorldPointsAndTrueStackOrder() {
        var pen = BoardElement(kind: .pen); pen.stroke = "#FF0000"; pen.strokeWidth = 16
        pen.x = 1000; pen.y = 1000; pen.angle = 1 // Deliberately inconsistent local geometry.
        var object = BoardElement(kind: .ellipse); object.x = 20; object.y = 20; object.width = 40; object.height = 40
        object.fill = "#0000FF"; object.stroke = "transparent"
        let items = [BoardRenderItem(element: pen, points: [[5, 40], [75, 40]]), BoardRenderItem(element: object, points: nil)]
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        let image = UIGraphicsImageRenderer(size: CGSize(width: 80, height: 80), format: format).image { context in
            UIColor.white.setFill(); context.fill(CGRect(x: 0, y: 0, width: 80, height: 80))
            BoardRenderer().draw(items, board: .empty, in: context.cgContext, zoom: 1)
        }
        guard let cg = image.cgImage else { return XCTFail("Missing image") }
        var rgba = [UInt8](repeating: 0, count: 80 * 80 * 4)
        let context = CGContext(data: &rgba, width: 80, height: 80, bitsPerComponent: 8, bytesPerRow: 80 * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(cg, in: CGRect(x: 0, y: 0, width: 80, height: 80))
        let middle = (40 * 80 + 40) * 4, left = (40 * 80 + 10) * 4
        XCTAssertGreaterThan(rgba[middle + 2], 240); XCTAssertLessThan(rgba[middle], 10)
        XCTAssertGreaterThan(rgba[left], 240); XCTAssertLessThan(rgba[left + 2], 10)
    }
    func testRotatedResizeNoMotionAndOriginalGeometry() throws {
        var e = BoardElement(kind: .rectangle); e.width = 100; e.height = 50; e.angle = .pi / 2
        let engine = try engine([e]), surface = BoardSurface(engine: engine)
        surface.select([e.id]); let box = try XCTUnwrap(engine.bounds([e.id]))
        let handle = CGPoint(x: box.x + box.width, y: box.y + box.height)
        var commands: [BoardCommand] = []
        surface.onCommand = { command, _ in commands.append(command); return true }
        surface.begin(at: handle); surface.finish(at: handle)
        XCTAssertTrue(commands.isEmpty)
        surface.begin(at: handle); surface.finish(at: CGPoint(x: handle.x + 10, y: handle.y + 20))
        guard case let .resize(_, rect) = try XCTUnwrap(commands.first) else { return XCTFail("Expected resize") }
        XCTAssertEqual(rect.x, 0); XCTAssertEqual(rect.y, 0)
        XCTAssertEqual(rect.width, 110); XCTAssertEqual(rect.height, 70)
    }

    func testTextResizeRejectsMissingRichLayoutWithoutCommit() throws {
        var e = BoardElement(kind: .text); e.width = 100; e.height = 50; e.text = "Long **rich** source"
        let surface = BoardSurface(engine: try engine([e])); surface.select([e.id])
        var commands = 0, errors = 0
        surface.onCommand = { _, _ in commands += 1; return true }
        surface.onError = { _ in errors += 1 }
        surface.begin(at: CGPoint(x: 100, y: 50)); surface.finish(at: CGPoint(x: 80, y: 50))
        XCTAssertEqual(commands, 0); XCTAssertEqual(errors, 1)
    }

    func testFontHonorsFamilyBoldAndItalic() {
        var e = BoardElement(kind: .text); e.fontFamily = "serif"; e.bold = true; e.italic = true
        let font = BoardRenderer.font(e)
        XCTAssertTrue(font.fontDescriptor.symbolicTraits.contains(.traitBold))
        XCTAssertTrue(font.fontDescriptor.symbolicTraits.contains(.traitItalic))
        XCTAssertTrue(font.familyName.contains("Times"))
    }

    func testResizePreservesWorldCenterAndDefersDuringInkContact() throws {
        let surface = BoardSurface(engine: try engine())
        surface.frame = CGRect(x: 0, y: 0, width: 800, height: 600)
        surface.layoutIfNeeded(); surface.reload()
        surface.setViewport(BoardViewport(x: -123, y: 77, zoom: 2.5))
        let center = surface.viewport.world(CGPoint(x: 400, y: 300))
        surface.frame.size = CGSize(width: 600, height: 800)
        surface.setNeedsLayout(); surface.layoutIfNeeded(); surface.reload()
        XCTAssertEqual(surface.viewport.world(CGPoint(x: 300, y: 400)).x, center.x, accuracy: 1e-9)
        XCTAssertEqual(surface.viewport.world(CGPoint(x: 300, y: 400)).y, center.y, accuracy: 1e-9)
        surface.frame.size = CGSize(width: 800, height: 600)
        surface.setNeedsLayout(); surface.layoutIfNeeded(); surface.reload()
        surface.tool = .pen
        let canvas = try XCTUnwrap(surface.subviews.compactMap { $0 as? PKCanvasView }.first)
        surface.canvasViewDidBeginUsingTool(canvas)
        let before = surface.viewport
        surface.frame.size = CGSize(width: 600, height: 800)
        surface.setNeedsLayout(); surface.layoutIfNeeded(); surface.reload()
        XCTAssertEqual(surface.viewport, before)
        surface.canvasViewDidEndUsingTool(canvas)
        XCTAssertEqual(surface.viewport.world(CGPoint(x: 300, y: 400)).x, center.x, accuracy: 1e-9)
        XCTAssertEqual(surface.viewport.world(CGPoint(x: 300, y: 400)).y, center.y, accuracy: 1e-9)
    }

    func testUnknownFontFallsBackToSystem() {
        var e = BoardElement(kind: .text); e.fontFamily = "Arial"
        let font = BoardRenderer.font(e)
        XCTAssertEqual(font.familyName, UIFont.systemFont(ofSize: font.pointSize).familyName)
    }

    private final class EditorTap: UITapGestureRecognizer {
        override func location(in view: UIView?) -> CGPoint { CGPoint(x: 20, y: 20) }
    }

    func testExistingBlankEditorsAreNoOpAndClearingShapeLabelPutsShape() throws {
        for kind in [BoardKind.text, .rectangle] {
            var element = BoardElement(kind: kind); element.width = 100; element.height = 80; element.text = ""
            let surface = BoardSurface(engine: try engine([element]))
            surface.frame = CGRect(x: 0, y: 0, width: 800, height: 600); surface.layoutIfNeeded(); surface.reload()
            var commands: [BoardCommand] = []
            surface.onCommand = { command, _ in commands.append(command); return true }
            let tap = EditorTap()
            _ = surface.perform(NSSelectorFromString("opened:"), with: tap)
            let editor = try XCTUnwrap(surface.subviews.compactMap { $0 as? UITextView }.first)
            editor.text = ""; surface.textViewDidEndEditing(editor)
            XCTAssertTrue(commands.isEmpty); XCTAssertFalse(surface.isEditingText)
        }
        var shape = BoardElement(kind: .rectangle); shape.width = 100; shape.height = 80; shape.text = "label"
        let surface = BoardSurface(engine: try engine([shape]))
        surface.frame = CGRect(x: 0, y: 0, width: 800, height: 600); surface.layoutIfNeeded(); surface.reload()
        var commands: [BoardCommand] = []
        surface.onCommand = { command, _ in commands.append(command); return true }
        let tap = EditorTap()
        _ = surface.perform(NSSelectorFromString("opened:"), with: tap)
        let editor = try XCTUnwrap(surface.subviews.compactMap { $0 as? UITextView }.first)
        editor.text = ""; surface.textViewDidEndEditing(editor)
        XCTAssertEqual(commands.count, 1)
        guard case let .put(items, _) = try XCTUnwrap(commands.first), let edited = items.first else { return XCTFail("Expected put") }
        XCTAssertEqual(edited.id, shape.id); XCTAssertEqual(edited.kind, .rectangle)
        XCTAssertEqual(edited.width, shape.width); XCTAssertEqual(edited.height, shape.height); XCTAssertEqual(edited.text, "")
    }

}
