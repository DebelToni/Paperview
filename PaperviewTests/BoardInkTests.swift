import XCTest
import UIKit
import PencilKit
@testable import Paperview

@MainActor final class BoardInkTests: XCTestCase {
    private func drawing() -> PKDrawing {
        let points = [CGPoint(x: 20, y: 30), CGPoint(x: 60, y: 50)].enumerated().map { i, point in
            PKStrokePoint(location: point, timeOffset: Double(i) / 60,
                          size: CGSize(width: 4, height: 4), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        }
        return PKDrawing(strokes: [PKStroke(ink: PKInk(.monoline, color: .black),
            path: PKStrokePath(controlPoints: points, creationDate: Date(timeIntervalSince1970: 1)))])
    }

    func testArchiveIsStableWorldSpaceAcrossViewport() throws {
        let original = drawing()
        let viewport = BoardViewport(x: 140, y: -70, zoom: 2.5)
        let screen = original.transformed(using: CGAffineTransform(a: viewport.zoom, b: 0, c: 0, d: viewport.zoom, tx: viewport.x, ty: viewport.y))
        let restored = BoardInk.worldDrawing(screen, viewport: viewport)
        let decoded = try PKDrawing(data: restored.dataRepresentation())
        XCTAssertEqual(decoded.strokes.count, 1)
        let p = decoded.strokes[0].path[0].location.applying(decoded.strokes[0].transform)
        XCTAssertEqual(p.x, 20, accuracy: 0.001)
        XCTAssertEqual(p.y, 30, accuracy: 0.001)
        XCTAssertEqual(decoded.bounds.minX, original.bounds.minX, accuracy: 0.01)
        XCTAssertEqual(decoded.bounds.width, original.bounds.width, accuracy: 0.01)
    }

    func testPortableInkUsesLocalPointsAndConstantWidth() throws {
        let e = try XCTUnwrap(BoardInk.element(from: drawing().strokes[0], color: "#123456", width: 2, z: 9))
        XCTAssertEqual(e.kind, .pen); XCTAssertEqual(e.strokeWidth, 2)
        XCTAssertEqual(e.stroke, "#123456"); XCTAssertEqual(e.z, 9)
        XCTAssertEqual(e.x, 20, accuracy: 0.01); XCTAssertEqual(e.y, 30, accuracy: 0.01)
        XCTAssertEqual(e.points?.first, [0, 0]); XCTAssertGreaterThan(e.points?.count ?? 0, 2)
        XCTAssertNil(e.assetId)
    }

    func testEmptyContactDoesNotCreateElement() {
        XCTAssertTrue(BoardInk.worldDrawing(PKDrawing(), viewport: BoardViewport()).strokes.isEmpty)
    }
    func testBoundedReductionPreservesEndpoints() {
        let input = (0..<100001).map { CGPoint(x: $0, y: $0 % 7) }
        let reduced = BoardInk.boundedPoints(input)
        XCTAssertEqual(reduced.count, 20000)
        XCTAssertEqual(reduced.first, input.first); XCTAssertEqual(reduced.last, input.last)
    }
    func testVeryLongLowZoomContactIsPortableAndKeepsArchive() throws {
        let original = drawing().transformed(using: CGAffineTransform(scaleX: 10000, y: 10000))
        let e = try XCTUnwrap(BoardInk.element(from: original.strokes[0], color: "#000000", width: 2, z: 0))
        XCTAssertLessThanOrEqual(e.points?.count ?? 0, 20000)
        let decoded = try PKDrawing(data: original.dataRepresentation())
        XCTAssertEqual(decoded.strokes.count, 1)
        XCTAssertEqual(e.x + (e.points?.last?[0] ?? 0), 600000, accuracy: 0.01)
    }

    func testRejectedCompletedContactSurvivesReadOnlyAndRetriesExactIDs() throws {
        let engine: BoardEngine
        do { engine = try BoardEngine(board: .empty) }
        catch BoardError.unavailable { throw XCTSkip("Native engine archive is not linked") }
        let surface = BoardSurface(engine: engine); surface.tool = .pen
        let canvas = try XCTUnwrap(surface.subviews.compactMap { $0 as? BoardContactCanvas }.first)
        var ids: [[String]] = []; var accepted = false
        surface.onCommand = { command, _ in
            if case let .put(elements, _) = command { ids.append(elements.map { $0.id }) }
            return accepted
        }
        canvas.contactBegan?(); canvas.drawing = drawing()
        surface.canvasViewDidEndUsingTool(canvas)
        XCTAssertTrue(surface.hasRetainedInk); XCTAssertFalse(surface.isUsingTool)
        let archive = try XCTUnwrap(surface.retainedInkData())
        surface.editable = false; surface.cancelGesture(); surface.reload()
        XCTAssertEqual(surface.retainedInkData(), archive)
        XCTAssertFalse(canvas.drawing.strokes.isEmpty)
        accepted = true; surface.retryRetainedInk()
        XCTAssertEqual(ids.count, 2); XCTAssertEqual(ids[0], ids[1])
        XCTAssertFalse(surface.hasRetainedInk); XCTAssertTrue(canvas.drawing.strokes.isEmpty)
    }

    func testSinglePointDotRemainsSinglePortablePoint() throws {
        let p = PKStrokePoint(location: CGPoint(x: 30, y: 40), timeOffset: 0,
            size: CGSize(width: 4, height: 4), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        let stroke = PKStroke(ink: PKInk(.monoline, color: .black), path: PKStrokePath(controlPoints: [p], creationDate: Date()))
        let element = try XCTUnwrap(BoardInk.element(from: stroke, color: "#000000", width: 4, z: 0))
        XCTAssertEqual(element.points?.count, 1)
    }

    func testDelegateCapturesInkStyleAndViewportForEachContact() throws {
        let engine: BoardEngine
        do { engine = try BoardEngine(board: .empty) }
        catch BoardError.unavailable { throw XCTSkip("Native engine archive is not linked") }
        let surface = BoardSurface(engine: engine)
        surface.frame = CGRect(x: 0, y: 0, width: 800, height: 600)
        surface.layoutIfNeeded()
        surface.setViewport(BoardViewport(x: 10, y: 20, zoom: 2))
        surface.tool = .pen; surface.strokeColor = "#123456"; surface.strokeWidth = 3
        let canvas = try XCTUnwrap(surface.subviews.compactMap { $0 as? PKCanvasView }.first)
        var elements: [BoardElement] = []; var archives: [[String: Data]] = []
        surface.onCommand = { command, native in
            XCTAssertTrue(surface.isUsingTool)
            if case let .put(items, _) = command { elements.append(contentsOf: items) }
            archives.append(native); return true
        }
        surface.canvasViewDidBeginUsingTool(canvas)
        XCTAssertTrue(surface.isUsingTool)
        surface.strokeColor = "#FF0000"; surface.strokeWidth = 7
        surface.setViewport(BoardViewport(x: 100, y: 100, zoom: 1))
        let activeTool = try XCTUnwrap(canvas.tool as? PKInkingTool)
        XCTAssertEqual(activeTool.width, 6, accuracy: 0.001)
        XCTAssertEqual(activeTool.color, BoardRenderer.color("#123456"))
        canvas.drawing = drawing()
        XCTAssertTrue(elements.isEmpty); XCTAssertTrue(archives.isEmpty)
        surface.canvasViewDidEndUsingTool(canvas)
        XCTAssertFalse(surface.isUsingTool)
        XCTAssertEqual(elements.count, 1)
        XCTAssertEqual(elements[0].stroke, "#123456"); XCTAssertEqual(elements[0].strokeWidth, 3)
        XCTAssertEqual(elements[0].x, 5, accuracy: 0.01); XCTAssertEqual(elements[0].y, 5, accuracy: 0.01)
        XCTAssertFalse(try XCTUnwrap(archives.first?[elements[0].id]).isEmpty)
        surface.canvasViewDidBeginUsingTool(canvas)
        let nextTool = try XCTUnwrap(canvas.tool as? PKInkingTool)
        XCTAssertEqual(nextTool.width, 14, accuracy: 0.001)
        XCTAssertEqual(nextTool.color, BoardRenderer.color("#FF0000"))
        canvas.drawing = drawing()
        XCTAssertEqual(elements.count, 1)
        surface.canvasViewDidEndUsingTool(canvas)
        XCTAssertEqual(elements.count, 2)
        XCTAssertEqual(elements[1].stroke, "#FF0000"); XCTAssertEqual(elements[1].strokeWidth, 7)
        XCTAssertFalse(try XCTUnwrap(archives.last?[elements[1].id]).isEmpty)
    }

    func testRetainedInkOverlayFollowsNavigationWithoutChangingRecoveryArchive() throws {
        let engine: BoardEngine
        do { engine = try BoardEngine(board: .empty) }
        catch BoardError.unavailable { throw XCTSkip("Native engine archive is not linked") }
        let surface = BoardSurface(engine: engine); surface.frame = CGRect(x: 0, y: 0, width: 800, height: 600)
        surface.layoutIfNeeded(); surface.tool = .pen
        let canvas = try XCTUnwrap(surface.subviews.compactMap { $0 as? PKCanvasView }.first)
        surface.onCommand = { _, _ in false }
        surface.canvasViewDidBeginUsingTool(canvas); canvas.drawing = drawing(); surface.canvasViewDidEndUsingTool(canvas)
        let archive = try XCTUnwrap(surface.retainedInkData())
        surface.setViewport(BoardViewport(x: 120, y: -15, zoom: 2)); surface.prepareFrame()
        let restored = BoardInk.worldDrawing(canvas.drawing, viewport: surface.viewport)
        XCTAssertEqual(restored.bounds.minX, drawing().bounds.minX, accuracy: 0.01)
        XCTAssertEqual(restored.bounds.minY, drawing().bounds.minY, accuracy: 0.01)
        XCTAssertEqual(surface.retainedInkData(), archive)
    }

    func testUnrepresentableContactRetainsAllStrokesAndStableRawRecoveryID() throws {
        let engine: BoardEngine
        do { engine = try BoardEngine(board: .empty) }
        catch BoardError.unavailable { throw XCTSkip("Native engine archive is not linked") }
        let surface = BoardSurface(engine: engine); surface.tool = .pen
        let canvas = try XCTUnwrap(surface.subviews.compactMap { $0 as? PKCanvasView }.first)
        let original = drawing(), outside = original.transformed(using: CGAffineTransform(translationX: 1e7, y: 0))
        let mixed = PKDrawing(strokes: original.strokes + outside.strokes)
        var commands = 0, ids: [String] = [], saved: [Data] = []
        surface.onCommand = { _, _ in commands += 1; return true }
        surface.onUnconvertedInk = { data, id in saved.append(data); ids.append(id); return true }
        surface.canvasViewDidBeginUsingTool(canvas); canvas.drawing = mixed; surface.canvasViewDidEndUsingTool(canvas)
        XCTAssertEqual(commands, 0, "A valid first stroke must not cause a partial contact save")
        XCTAssertTrue(surface.hasRetainedInk)
        XCTAssertEqual(try PKDrawing(data: XCTUnwrap(surface.retainedInkData())).strokes.count, 2)
        surface.retryRetainedInk()
        XCTAssertEqual(ids.count, 2); XCTAssertEqual(ids.first, ids.last); XCTAssertEqual(saved.first, saved.last)
        XCTAssertEqual(commands, 0); XCTAssertEqual(canvas.drawing.strokes.count, 2)
    }

    func testDecodedNativeInkAndTilesSurviveFramesAndFractionalZoom() throws {
        let archiveDrawing = drawing().transformed(using: CGAffineTransform(scaleX: 1000, y: 1000))
        let archive = archiveDrawing.dataRepresentation()
        let element = try XCTUnwrap(BoardInk.element(from: archiveDrawing.strokes[0], color: "#ff0000", width: 1, z: 0))
        let item = BoardRenderItem(element: element, points: element.points?.map { [$0[0] + element.x, $0[1] + element.y] })
        let renderer = BoardRenderer(); var resolutions = 0
        renderer.nativeStroke = { _ in resolutions += 1; return archive }
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        func frame(_ zoom: Double) -> UIImage {
            UIGraphicsImageRenderer(size: CGSize(width: 80, height: 80), format: format).image { output in
                UIColor.white.setFill(); output.fill(CGRect(x: 0, y: 0, width: 80, height: 80))
                output.cgContext.scaleBy(x: zoom, y: zoom)
                renderer.draw([item], board: .empty, in: output.cgContext, zoom: zoom)
            }
        }
        let image = frame(0.001), rasterCount = renderer.nativeRasterCount
        XCTAssertGreaterThan(rasterCount, 0)
        for i in 0..<40 { _ = frame(0.001 + Double(i) * 0.000001) }
        XCTAssertEqual(renderer.nativeDecodeCount, 1); XCTAssertEqual(resolutions, 1)
        XCTAssertEqual(renderer.nativeRasterCount, rasterCount); XCTAssertEqual(renderer.pathBuildCount, 0)
        let cg = try XCTUnwrap(image.cgImage)
        var bytes = [UInt8](repeating: 0, count: 80 * 80 * 4)
        let c = try XCTUnwrap(CGContext(data: &bytes, width: 80, height: 80, bitsPerComponent: 8, bytesPerRow: 80 * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        c.draw(cg, in: CGRect(x: 0, y: 0, width: 80, height: 80))
        let middle = (40 * 80 + 40) * 4
        XCTAssertLessThan(bytes[middle], 64); XCTAssertLessThan(bytes[middle + 1], 64)
        renderer.invalidateNativeInk(); _ = frame(0.001)
        XCTAssertEqual(renderer.nativeDecodeCount, 1); XCTAssertEqual(renderer.nativeRasterCount, rasterCount)
    }

}
