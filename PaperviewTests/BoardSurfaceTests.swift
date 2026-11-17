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

    func testViewportFramesReuseBoundedQueryAndRefreshNewlyExposedContent() throws {
        var distant = BoardElement(kind: .rectangle, id: "distant")
        distant.x = 1200; distant.y = 280; distant.width = 40; distant.height = 40
        distant.fill = "#ff0000"; distant.stroke = "transparent"
        let engine = try engine([distant]), surface = BoardSurface(engine: engine)
        surface.frame = CGRect(x: 0, y: 0, width: 800, height: 600); surface.layoutIfNeeded()
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        func frame() -> UIImage {
            UIGraphicsImageRenderer(size: surface.bounds.size, format: format).image { output in
                UIColor.white.setFill(); output.fill(surface.bounds); surface.draw(surface.bounds)
            }
        }
        _ = frame()
        let initial = surface.viewportQueryCount
        for x in 1...60 { surface.setViewport(BoardViewport(x: Double(x), y: 0, zoom: 1)); surface.reload(); _ = frame() }
        XCTAssertEqual(surface.viewportQueryCount, initial, "Small pans reuse world-space items, not JSON for every sample")
        XCTAssertEqual(surface.documentIndexCount, 1)
        XCTAssertEqual(surface.selectionBoundsCount, 0, "Empty selection must never issue document bounds")
        surface.setViewport(BoardViewport(x: -600, y: 0, zoom: 1))
        let image = frame()
        XCTAssertEqual(surface.viewportQueryCount, initial + 1)
        let cg = try XCTUnwrap(image.cgImage)
        var bytes = [UInt8](repeating: 0, count: 800 * 600 * 4)
        let c = try XCTUnwrap(CGContext(data: &bytes, width: 800, height: 600, bitsPerComponent: 8, bytesPerRow: 800 * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        c.draw(cg, in: surface.bounds)
        let pixel = (300 * 800 + 620) * 4
        XCTAssertGreaterThan(bytes[pixel], 240); XCTAssertLessThan(bytes[pixel + 1], 20)
        var added = distant; added.id = "new"; added.x = 900
        try engine.apply(.put([added])); surface.reload(); surface.prepareFrame()
        XCTAssertEqual(surface.documentIndexCount, 2)
        XCTAssertEqual(surface.viewportQueryCount, initial + 2, "A document change invalidates even a contained query")
    }

    func testPrefetchAtNegativeWorldLimitStillPaintsVisibleContent() throws {
        var element = BoardElement(kind: .rectangle, id: "world-edge")
        element.x = -10_000_000; element.y = -10_000_000; element.width = 100; element.height = 100
        element.fill = "#ff0000"; element.stroke = "transparent"
        let surface = BoardSurface(engine: try engine([element]))
        surface.frame = CGRect(x: 0, y: 0, width: 200, height: 200); surface.layoutIfNeeded()
        surface.onError = { XCTFail("Valid edge-of-world query failed: \($0)") }
        surface.setViewport(BoardViewport(x: 10_000_000, y: 10_000_000, zoom: 1))
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let image = UIGraphicsImageRenderer(size: surface.bounds.size, format: format).image { output in
            UIColor.white.setFill(); output.fill(surface.bounds); surface.draw(surface.bounds)
        }
        let cg = try XCTUnwrap(image.cgImage)
        var bytes = [UInt8](repeating: 0, count: 200 * 200 * 4)
        let context = try XCTUnwrap(CGContext(data: &bytes, width: 200, height: 200, bitsPerComponent: 8, bytesPerRow: 200 * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(cg, in: surface.bounds)
        XCTAssertTrue(stride(from: 0, to: bytes.count, by: 4).contains { bytes[$0] > 240 && bytes[$0 + 1] < 20 && bytes[$0 + 2] < 20 })
        XCTAssertEqual(surface.viewportQueryCount, 1)
    }
    func testSelectionBoundsAndDocumentIndexAreNotFrameWork() throws {
        let elements = (0..<3000).map { index -> BoardElement in
            var e = BoardElement(kind: .rectangle, id: "r-\(index)")
            e.x = Double(index % 100) * 100; e.y = Double(index / 100) * 100; e.width = 40; e.height = 40
            return e
        }
        let surface = BoardSurface(engine: try engine(elements))
        surface.frame = CGRect(x: 0, y: 0, width: 800, height: 600); surface.layoutIfNeeded(); surface.select([elements[0].id])
        let queries = surface.selectionBoundsCount
        for x in 1...120 { surface.setViewport(BoardViewport(x: Double(x), y: 0, zoom: 1)); surface.reload(); surface.prepareFrame() }
        XCTAssertEqual(surface.documentIndexCount, 1); XCTAssertEqual(surface.selectionBoundsCount, queries)
        XCTAssertLessThanOrEqual(surface.viewportQueryCount, 2)
    }

    func testPenModeFingerNavigationAndOpeningPoliciesExcludePencil() throws {
        let surface = BoardSurface(engine: try engine()); surface.tool = .pen
        let finger = try XCTUnwrap((surface.gestureRecognizers ?? []).compactMap { $0 as? UIPanGestureRecognizer }
            .first { $0.allowedTouchTypes == [NSNumber(value: UITouch.TouchType.direct.rawValue)] })
        XCTAssertEqual(finger.minimumNumberOfTouches, 1)
        let opening = try XCTUnwrap((surface.gestureRecognizers ?? []).compactMap { $0 as? UITapGestureRecognizer }.first)
        XCTAssertEqual(Set(opening.allowedTouchTypes), Set([UITouch.TouchType.direct, .indirectPointer].map { NSNumber(value: $0.rawValue) }))
        XCTAssertTrue(surface.gestureRecognizerShouldBegin(finger)); XCTAssertTrue(surface.gestureRecognizerShouldBegin(opening))
        surface.tool = .rectangle
        XCTAssertEqual(finger.minimumNumberOfTouches, 2)
        XCTAssertFalse(surface.gestureRecognizerShouldBegin(opening))
        surface.tool = .pen
        let canvas = try XCTUnwrap(surface.subviews.compactMap { $0 as? PKCanvasView }.first)
        surface.canvasViewDidBeginUsingTool(canvas)
        XCTAssertFalse(surface.gestureRecognizerShouldBegin(finger))
        XCTAssertFalse(surface.gestureRecognizerShouldBegin(opening))
        surface.canvasViewDidEndUsingTool(canvas)
    }

    func testSystemContextRecognizerIsNotBlockedByRawSelectionContact() throws {
        let surface = BoardSurface(engine: try engine())
        surface.begin(at: CGPoint(x: 20, y: 20))
        XCTAssertTrue(surface.isUsingTool)
        XCTAssertTrue(surface.gestureRecognizerShouldBegin(UILongPressGestureRecognizer()))
        XCTAssertTrue(surface.isUsingTool, "Configuration must not cancel an ordinary drag")
        surface.cancelGesture(); surface.tool = .rectangle
        XCTAssertFalse(surface.prepareContextMenu(), "Shape tools reserve their contacts for drawing")
    }
    private final class NavigationPan: UIPanGestureRecognizer {
        override func translation(in view: UIView?) -> CGPoint { CGPoint(x: 75, y: -30) }
        override func setTranslation(_ translation: CGPoint, in view: UIView?) {}
    }
    func testReadOnlySelectionAndPanRemainUsableWithoutMutations() throws {
        var e = BoardElement(kind: .rectangle); e.width = 100; e.height = 100; e.fill = "#ffffff"
        let surface = BoardSurface(engine: try engine([e])); surface.editable = false
        var commands = 0; surface.onCommand = { _, _ in commands += 1; return true }
        surface.begin(at: CGPoint(x: 30, y: 30)); surface.finish(at: CGPoint(x: 60, y: 60))
        XCTAssertEqual(surface.selection, [e.id]); XCTAssertEqual(commands, 0)
        let before = surface.viewport
        _ = surface.perform(NSSelectorFromString("panned:"), with: NavigationPan())
        XCTAssertEqual(surface.viewport.x, before.x + 75); XCTAssertEqual(surface.viewport.y, before.y - 30)
        XCTAssertNotNil(surface.accessibilityValue)
    }

    func testFinishEditingTextDoesNotDiscardRejectedEditAndUsesKeyboardGuide() throws {
        var e = BoardElement(kind: .rectangle); e.width = 100; e.height = 100; e.text = "source"
        let surface = BoardSurface(engine: try engine([e]))
        surface.frame = CGRect(x: 0, y: 0, width: 800, height: 600); surface.layoutIfNeeded()
        _ = surface.perform(NSSelectorFromString("opened:"), with: EditorTap())
        let editor = try XCTUnwrap(surface.subviews.compactMap { $0 as? UITextView }.first)
        editor.text = "kept edit"
        var accepted = false; surface.onCommand = { _, _ in accepted }
        XCTAssertTrue(surface.constraints.contains { $0.secondItem === surface.keyboardLayoutGuide && $0.firstItem === editor })
        XCTAssertFalse(surface.finishEditingText()); XCTAssertEqual(editor.text, "kept edit")
        accepted = true
        XCTAssertTrue(surface.finishEditingText()); XCTAssertFalse(surface.isEditingText)
    }

    func testThousandPortablePathsDoNotRebuildDuringFramesOrTransientMoves() {
        let items = (0..<1000).map { index -> BoardRenderItem in
            var e = BoardElement(kind: .pen, id: "pen-\(index)")
            e.x = Double(index % 40) * 20; e.y = Double(index / 40) * 20
            let points = (0..<32).map { [e.x + Double($0) / 2, e.y + Double($0 % 3)] }
            return BoardRenderItem(element: e, points: points)
        }
        let renderer = BoardRenderer(), format = UIGraphicsImageRendererFormat(); format.scale = 1
        func frame(moving: Set<String> = []) {
            _ = UIGraphicsImageRenderer(size: CGSize(width: 800, height: 600), format: format).image { output in
                renderer.draw(items, board: .empty, in: output.cgContext, zoom: 1, moving: moving, offset: CGPoint(x: 3, y: 5))
            }
        }
        frame(); XCTAssertEqual(renderer.pathBuildCount, 1000)
        for _ in 0..<10 { frame() }
        frame(moving: Set(items.prefix(500).map { $0.element.id }))
        XCTAssertEqual(renderer.pathBuildCount, 1000)
    }

    func testShapeLabelsAreCenteredLikeTheWebBoard() throws {
        var element = BoardElement(kind: .rectangle, id: "label")
        element.x = 20; element.y = 20; element.width = 160; element.height = 100
        element.text = "Label"; element.fontSize = 20; element.stroke = "#000000"; element.fill = "#ffffff"
        let renderer = BoardRenderer(), format = UIGraphicsImageRendererFormat(); format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 200, height: 140), format: format).image { output in
            UIColor.white.setFill(); output.fill(CGRect(x: 0, y: 0, width: 200, height: 140))
            renderer.draw([BoardRenderItem(element: element, points: nil)], board: .empty, in: output.cgContext, zoom: 1)
        }
        var bytes = [UInt8](repeating: 0, count: 200 * 140 * 4)
        let context = try XCTUnwrap(CGContext(data: &bytes, width: 200, height: 140, bitsPerComponent: 8, bytesPerRow: 200 * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(try XCTUnwrap(image.cgImage), in: CGRect(x: 0, y: 0, width: 200, height: 140))
        var xs: [Int] = [], ys: [Int] = []
        for y in 24..<116 { for x in 24..<176 where bytes[(y * 200 + x) * 4] < 100 { xs.append(x); ys.append(y) } }
        let minX = try XCTUnwrap(xs.min()), maxX = try XCTUnwrap(xs.max())
        let minY = try XCTUnwrap(ys.min()), maxY = try XCTUnwrap(ys.max())
        XCTAssertEqual(Double(minX + maxX) / 2, 100, accuracy: 4)
        XCTAssertEqual(Double(minY + maxY) / 2, 70, accuracy: 6)
    }
    private final class CardProvider: BoardVisualProvider {
        var paper = PaperInfo(id: "paper", title: "Synthetic paper title", spaceID: "s", abstract: "An actual synthetic abstract for layout regression.")
        func paperInfo(for element: BoardElement) -> PaperInfo? { paper }
        func preview(for element: BoardElement, asset: BoardAsset?, targetSize: CGSize) -> UIImage? { nil }
    }
    func testPaperCardTextLayoutIsReusedUntilItsProjectionChanges() {
        let provider = CardProvider(), renderer = BoardRenderer(); renderer.visuals = provider
        var e = BoardElement(kind: .paper); e.width = 360; e.height = 280; e.paperId = "paper"
        func frame() {
            _ = UIGraphicsImageRenderer(size: CGSize(width: 360, height: 280)).image { output in
                renderer.draw([BoardRenderItem(element: e, points: nil)], board: .empty, in: output.cgContext, zoom: 1)
            }
        }
        for _ in 0..<30 { frame() }
        XCTAssertEqual(renderer.paperCardLayoutCount, 1)
        provider.paper.isRead = true; frame()
        XCTAssertEqual(renderer.paperCardLayoutCount, 2)
        e.paperTitle = "User title override"; frame()
        XCTAssertEqual(renderer.paperCardLayoutCount, 3)
    }

}
