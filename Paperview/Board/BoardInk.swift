import UIKit
import PencilKit

/// A contact archive is world-space, independent of the viewport at capture time.
enum BoardInk {
    static func boundedPoints(_ points: [CGPoint], limit: Int = 20000) -> [CGPoint] {
        guard points.count > limit else { return points }
        return (0..<limit).map { points[Int(Double($0) * Double(points.count - 1) / Double(limit - 1))] }
    }
    static func screenDrawing(_ drawing: PKDrawing, viewport: BoardViewport) -> PKDrawing {
        drawing.transformed(using: CGAffineTransform(a: viewport.zoom, b: 0, c: 0,
            d: viewport.zoom, tx: viewport.x, ty: viewport.y))
    }
    static func worldDrawing(_ drawing: PKDrawing, viewport: BoardViewport) -> PKDrawing {
        drawing.transformed(using: CGAffineTransform(a: 1 / viewport.zoom, b: 0, c: 0,
            d: 1 / viewport.zoom, tx: -viewport.x / viewport.zoom, ty: -viewport.y / viewport.zoom))
    }

    static func element(from stroke: PKStroke, color: String, width: Double, z: Double) -> BoardElement? {
        // Estimate transformed control-polygon length without allocating interpolated samples.
        let controls = stroke.path.map { $0.location.applying(stroke.transform) }
        guard !controls.isEmpty, width.isFinite, (0.1...200).contains(width),
              controls.allSatisfy({ $0.x.isFinite && $0.y.isFinite && abs($0.x) <= 1e7 && abs($0.y) <= 1e7 }) else { return nil }
        let length = zip(controls, controls.dropFirst()).reduce(0.0) { $0 + hypot($1.1.x - $1.0.x, $1.1.y - $1.0.y) }
        let scale = max(hypot(stroke.transform.a, stroke.transform.b), hypot(stroke.transform.c, stroke.transform.d), 0.000001)
        guard length.isFinite, scale.isFinite else { return nil }
        let spacing = max(0.5, width / 3, length / 19000) / scale
        let path = stroke.path.interpolatedPoints(by: .distance(spacing))
        var sampled = path.map { $0.location.applying(stroke.transform) }
        if let last = controls.last, sampled.last != last { sampled.append(last) }
        let positions = boundedPoints(sampled)
        guard let first = positions.first,
              positions.allSatisfy({ $0.x.isFinite && $0.y.isFinite && abs($0.x) <= 1e7 && abs($0.y) <= 1e7 }) else { return nil }
        let minX = positions.reduce(first.x) { min($0, $1.x) }
        let minY = positions.reduce(first.y) { min($0, $1.y) }
        let maxX = positions.reduce(first.x) { max($0, $1.x) }
        let maxY = positions.reduce(first.y) { max($0, $1.y) }
        guard maxX - minX <= 1e7, maxY - minY <= 1e7 else { return nil }
        var element = BoardElement(kind: .pen)
        element.x = minX; element.y = minY
        element.width = maxX - minX; element.height = maxY - minY
        element.points = positions.map { [Double($0.x - minX), Double($0.y - minY)] }
        element.stroke = color; element.strokeWidth = width; element.z = z
        return element
    }
}

/// PencilKit owns prediction and contact rendering only, never committed board state.
final class BoardContactCanvas: PKCanvasView {
    var contactBegan: (() -> Void)?
    var contactCancelled: (() -> Void)?
    private var activeTouch: UITouch?
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        if activeTouch == nil, let touch = touches.first(where: { $0.type == .pencil }) { activeTouch = touch; contactBegan?() }
        super.touchesBegan(touches, with: event)
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesEnded(touches, with: event)
        if let activeTouch, touches.contains(activeTouch) { self.activeTouch = nil }
    }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        if let activeTouch, touches.contains(activeTouch) { self.activeTouch = nil; contactCancelled?() }
        super.touchesCancelled(touches, with: event)
    }
}
