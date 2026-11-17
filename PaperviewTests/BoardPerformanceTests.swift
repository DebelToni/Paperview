import UIKit
import XCTest
@testable import Paperview

/// Synthetic main-thread work, not a claim about physical Pencil latency or display FPS.
@MainActor final class BoardPerformanceTests: XCTestCase {
    func testSyntheticDenseBoardPanWork() throws {
        var elements: [BoardElement] = []
        for index in 0..<2_000 {
            var stroke = BoardElement(kind: .pen, id: "benchmark-ink-\(index)")
            stroke.x = Double(index % 40) * 80; stroke.y = Double(index / 40) * 50
            stroke.width = 60; stroke.height = 30; stroke.strokeWidth = 2
            stroke.z = Double(index)
            stroke.points = (0..<32).map { point -> [Double] in
                let x = Double(point) * 60.0 / 31.0
                let y = 15.0 + sin(Double(point) * 0.4) * 14.0
                return [x, y]
            }
            elements.append(stroke)
        }
        for index in 0..<20 {
            var text = BoardElement(kind: .text, id: "benchmark-text-\(index)")
            text.x = Double(index % 5) * 200; text.y = Double(index / 5) * 220
            text.width = 180; text.height = 45; text.fontSize = 18; text.fontFamily = "sans-serif"
            text.text = "Synthetic board \(index)"; text.z = 2_000 + Double(index)
            elements.append(text)
        }
        let original = BoardDocument(elements: elements)
        let engine = try BoardEngine(board: original)
        let surface = BoardSurface(engine: engine)
        surface.frame = CGRect(x: 0, y: 0, width: 1024, height: 768)
        surface.layoutIfNeeded()
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        let raster = UIGraphicsImageRenderer(size: surface.bounds.size, format: format)
        var samples: [Double] = []
        for frame in 0..<65 {
            let elapsed: Double = autoreleasepool {
                let start = CACurrentMediaTime()
                surface.setViewport(BoardViewport(x: -Double(frame) * 3, y: -Double(frame), zoom: 1))
                surface.reload()
                _ = raster.image { context in
                    UIColor.white.setFill(); context.fill(surface.bounds)
                    surface.draw(surface.bounds)
                }
                return (CACurrentMediaTime() - start) * 1_000
            }
            if frame >= 5 { samples.append(elapsed) }
        }
        samples.sort()
        let p50 = samples[samples.count / 2], p95 = samples[Int(Double(samples.count - 1) * 0.95)]
        let result = "Synthetic pan/render: 2000 strokes × 32 points, 20 text objects, 1024×768 @1x, 60 measured frames; p50=\(p50)ms p95=\(p95)ms max=\(samples.last!)ms"
        print(result)
        let attachment = XCTAttachment(string: result); attachment.lifetime = .keepAlways; add(attachment)
        XCTAssertEqual(engine.board, original, "Navigating must not mutate any coordinate or document field")
        XCTAssertFalse(engine.canUndo)
    }
}
