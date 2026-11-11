import UIKit
import PDFKit
import PencilKit

/// Portable coordinates are top-left, unrotated, effective CropBox coordinates.
struct ReaderGeometry {
    let box: CGRect
    let rotation: Int
    let userUnit: CGFloat
    let overlayTransform: CGAffineTransform?
    init(page: PDFPage, overlayTransform: CGAffineTransform? = nil) {
        self.overlayTransform = overlayTransform
        let media = page.pageRef?.getBoxRect(.mediaBox) ?? page.bounds(for: .mediaBox)
        let crop = page.pageRef?.getBoxRect(.cropBox) ?? page.bounds(for: .cropBox)
        let intersection = crop.intersection(media)
        box = intersection.isNull || intersection.isEmpty ? media : intersection
        rotation = ((page.rotation % 360) + 360) % 360
        var unit: CGPDFReal = 1
        if let dictionary = page.pageRef?.dictionary { CGPDFDictionaryGetNumber(dictionary, "UserUnit", &unit) }
        userUnit = unit > 0 ? CGFloat(unit) : 1
    }
    @MainActor init(page: PDFPage, pdfView: PDFView, overlay: UIView) {
        let base = ReaderGeometry(page: page)
        guard overlay.superview != nil else { self = base; return }
        func point(_ p: CGPoint) -> CGPoint { overlay.convert(pdfView.convert(base.pdf(p), from: page), from: pdfView) }
        let origin = point(.zero), right = point(CGPoint(x: 1, y: 0)), bottom = point(CGPoint(x: 0, y: 1))
        let transform = CGAffineTransform(a: right.x - origin.x, b: right.y - origin.y, c: bottom.x - origin.x, d: bottom.y - origin.y, tx: origin.x, ty: origin.y)
        guard abs(transform.a * transform.d - transform.b * transform.c) > 0.001 else { self = base; return }
        self = ReaderGeometry(page: page, overlayTransform: transform)
    }
    var displaySize: CGSize {
        rotation == 90 || rotation == 270 ? CGSize(width: box.height, height: box.width) : box.size
    }
    func canvas(_ normalized: CGPoint, size: CGSize) -> CGPoint {
        if let overlayTransform { return normalized.applying(overlayTransform) }
        let p: CGPoint
        switch rotation {
        case 90: p = CGPoint(x: 1 - normalized.y, y: normalized.x)
        case 180: p = CGPoint(x: 1 - normalized.x, y: 1 - normalized.y)
        case 270: p = CGPoint(x: normalized.y, y: 1 - normalized.x)
        default: p = normalized
        }
        return CGPoint(x: p.x * size.width, y: p.y * size.height)
    }
    func normalized(_ point: CGPoint, size: CGSize) -> CGPoint {
        if let overlayTransform { return point.applying(overlayTransform.inverted()) }
        let p = CGPoint(x: point.x / size.width, y: point.y / size.height)
        switch rotation {
        case 90: return CGPoint(x: p.y, y: 1 - p.x)
        case 180: return CGPoint(x: 1 - p.x, y: 1 - p.y)
        case 270: return CGPoint(x: 1 - p.y, y: p.x)
        default: return p
        }
    }
    func pdf(_ normalized: CGPoint) -> CGPoint {
        CGPoint(x: box.minX + normalized.x * box.width, y: box.maxY - normalized.y * box.height)
    }
    func scale(size: CGSize) -> CGFloat {
        if let transform = overlayTransform { return hypot(transform.a, transform.b) / box.width }
        return size.width / displaySize.width
    }
}

enum ReaderTool: String, CaseIterable {
    case pen, question, highlight, select, text, erase
    var symbol: String {
        switch self {
        case .pen: return "pencil.tip"
        case .question: return "questionmark"
        case .highlight: return "highlighter"
        case .select: return "lasso"
        case .text: return "textformat"
        case .erase: return "eraser"
        }
    }
    var kind: AnnotationKind { self == .question ? .question : self == .highlight ? .highlight : .pen }
}

enum ReaderInk {
    /// A transformed stroke must retain its complete path identity. Count equality is never identity.
    static func matchingIndices(before: [Data], after: [Data]) -> [Int?] {
        var used = Set<Int>()
        var result = after.map { data -> Int? in
            let match = before.indices.first { !used.contains($0) && before[$0] == data }
            if let match { used.insert(match) }; return match
        }
        for i in result.indices where result[i] == nil {
            guard let new = try? PKDrawing(data: after[i]).strokes.first else { continue }
            let candidates = before.indices.filter { oldIndex in
                guard !used.contains(oldIndex), let old = try? PKDrawing(data: before[oldIndex]).strokes.first else { return false }
                return samePath(old, new)
            }
            // Ambiguous duplicates become explicit delete/add operations, never a guessed ID transfer.
            if candidates.count == 1 { result[i] = candidates[0]; used.insert(candidates[0]) }
        }
        return result
    }
    private static func samePath(_ a: PKStroke, _ b: PKStroke) -> Bool {
        guard a.path.creationDate == b.path.creationDate, a.path.count == b.path.count,
              a.randomSeed == b.randomSeed, a.ink.inkType == b.ink.inkType, a.ink.color.isEqual(b.ink.color),
              a.mask?.cgPath == b.mask?.cgPath else { return false }
        return a.path.indices.allSatisfy { i in
            let x = a.path[i], y = b.path[i]
            return x.location == y.location && x.size == y.size && x.timeOffset == y.timeOffset && x.force == y.force && x.opacity == y.opacity && x.azimuth == y.azimuth && x.altitude == y.altitude
        }
    }
    private struct NativeArchive: Codable { var version = 1; var drawing: Data }
    static func referenceTransform(geometry: ReaderGeometry, size: CGSize) -> CGAffineTransform {
        let origin = geometry.canvas(.zero, size: size)
        let right = geometry.canvas(CGPoint(x: 1, y: 0), size: size)
        let bottom = geometry.canvas(CGPoint(x: 0, y: 1), size: size)
        return CGAffineTransform(a: (right.x - origin.x) / geometry.box.width, b: (right.y - origin.y) / geometry.box.width,
                                 c: (bottom.x - origin.x) / geometry.box.height, d: (bottom.y - origin.y) / geometry.box.height,
                                 tx: origin.x, ty: origin.y)
    }
    /// Keep path, mask, pressure, timing and ink untouched; only compose its complete affine transform.
    static func nativeArchive(_ stroke: PKStroke, geometry: ReaderGeometry, size: CGSize) -> Data {
        // PencilKit composes each stroke.transform and retains native masks/rendering state.
        let stable = PKDrawing(strokes: [stroke]).transformed(using: referenceTransform(geometry: geometry, size: size).inverted())
        return try! JSONEncoder().encode(NativeArchive(drawing: stable.dataRepresentation()))
    }
    static func color(_ hex: String) -> UIColor {
        let digits = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        let expanded = digits.count == 3 || digits.count == 4 ? digits.map { String(repeating: String($0), count: 2) }.joined() : digits
        let rgba = expanded.count == 6 ? expanded + "ff" : expanded
        let value = UInt32(rgba, radix: 16) ?? 0x007affff
        return UIColor(red: CGFloat((value >> 24) & 255) / 255, green: CGFloat((value >> 16) & 255) / 255, blue: CGFloat((value >> 8) & 255) / 255, alpha: CGFloat(value & 255) / 255)
    }

    static func archive(_ stroke: PKStroke) -> Data { PKDrawing(strokes: [stroke]).dataRepresentation() }
    static func stroke(_ annotation: PaperAnnotation, geometry: ReaderGeometry, size: CGSize, native: Data? = nil) -> PKStroke? {
        if let native {
            guard let stored = try? JSONDecoder().decode(NativeArchive.self, from: native), stored.version == 1,
                  let drawing = try? PKDrawing(data: stored.drawing), drawing.strokes.count == 1 else { return nil }
            return drawing.transformed(using: referenceTransform(geometry: geometry, size: size)).strokes[0]
        }
        guard annotation.type != .text, let points = annotation.points, !points.isEmpty else { return nil }
        let width = CGFloat(annotation.size ?? 2) * geometry.scale(size: size)
        // PKStrokePath smooths sparse vertices. Densify every straight segment, including
        // each original corner, to bound that interpolation to approximately one PDF point.
        let vertices = points.compactMap { pair -> CGPoint? in
            guard pair.count == 2 else { return nil }
            return geometry.canvas(CGPoint(x: pair[0], y: pair[1]), size: size)
        }
        guard !vertices.isEmpty, vertices.count <= 40000 else { return nil }
        var lengths: [CGFloat] = []
        for i in 1..<vertices.count { lengths.append(hypot(vertices[i].x - vertices[i - 1].x, vertices[i].y - vertices[i - 1].y)) }
        let total = lengths.reduce(0, +)
        let available = 40000 - vertices.count
        let spacing = max(geometry.scale(size: size), available > 0 ? total / CGFloat(available) : total + 1)
        var locations = [vertices[0]]
        for i in lengths.indices {
            // floor gives a strict global control budget even for many tiny segments.
            let proposed = available > 0 ? Int(floor(lengths[i] / max(0.00001, spacing))) : 0
            let extra = min(proposed, max(0, 40000 - locations.count - (vertices.count - i - 1)))
            let divisions = extra + 1
            for step in 1...divisions {
                let t = CGFloat(step) / CGFloat(divisions)
                let a = vertices[i], b = vertices[i + 1]
                locations.append(CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
            }
        }
        let controls = locations.enumerated().map { index, point in
            PKStrokePoint(location: point, timeOffset: Double(index) / 120, size: CGSize(width: width, height: width), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        }
        guard !controls.isEmpty else { return nil }
        let baseColor = color(annotation.color)
        let ink = PKInk(annotation.type == .highlight ? .marker : .monoline, color: baseColor.withAlphaComponent(baseColor.cgColor.alpha * (annotation.type == .highlight ? 0.28 : 1)))
        return PKStroke(ink: ink, path: PKStrokePath(controlPoints: controls, creationDate: Date(timeIntervalSince1970: 0)))
    }
    static func annotation(_ stroke: PKStroke, previous: PaperAnnotation?, page: Int, tool: ReaderTool, color: String, geometry: ReaderGeometry, size: CGSize) -> PaperAnnotation {
        // Sample the rendered curve rather than dropping intermediate native control data.
        var length: CGFloat = 0
        for i in 1..<max(1, stroke.path.count) {
            let a = stroke.path[i - 1].location, b = stroke.path[i].location
            length += hypot(b.x - a.x, b.y - a.y)
        }
        let interpolated = Array(stroke.path.interpolatedPoints(by: .distance(max(1, length / 19000))))
        let samples = interpolated.isEmpty ? Array(stroke.path) : interpolated
        let count = min(20000, samples.count)
        let points = (0..<count).map { index -> [Double] in
            let sampleIndex = count <= 1 ? 0 : Int((Double(index) * Double(samples.count - 1) / Double(count - 1)).rounded())
            let point = samples[sampleIndex]
            let p = geometry.normalized(point.location.applying(stroke.transform), size: size)
            return [Double(min(1, max(0, p.x))), Double(min(1, max(0, p.y)))]
        }
        let width = stroke.path.first.map { $0.size.width } ?? 2
        let transformScale = sqrt(abs(stroke.transform.a * stroke.transform.d - stroke.transform.b * stroke.transform.c))
        let measuredWidth = Double(width * transformScale / geometry.scale(size: size))
        let referenceWidth = abs(transformScale - 1) < 0.00001 ? (previous?.size ?? measuredWidth) : measuredWidth
        return PaperAnnotation(id: previous?.id ?? UUID().uuidString, page: page, type: previous?.type ?? tool.kind, color: previous?.color ?? color, points: points, size: referenceWidth)
    }
}
