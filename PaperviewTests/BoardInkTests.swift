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

}
