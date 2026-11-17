import UIKit
import PencilKit
import ImageIO

extension BoardPoint { var cgPoint: CGPoint { CGPoint(x: x, y: y) } }
extension BoardRect { var cgRect: CGRect { CGRect(x: x, y: y, width: width, height: height) } }

/// Only local/authorized decoded assets enter this interface. Rendering never fetches URLs.
@MainActor protocol BoardVisualProvider: AnyObject {
    func preview(for element: BoardElement, asset: BoardAsset?, targetSize: CGSize) -> UIImage?
    func paperInfo(for element: BoardElement) -> PaperInfo?
    func attributedText(for element: BoardElement) -> NSAttributedString?
    func drawText(for element: BoardElement, in context: CGContext, rect: CGRect) -> Bool
    func measureText(for element: BoardElement, constrainedTo width: Double) -> CGSize?
    func measureText(for element: BoardElement, width: CGFloat) -> CGSize?
}

extension BoardVisualProvider {
    func paperInfo(for element: BoardElement) -> PaperInfo? { nil }
    func attributedText(for element: BoardElement) -> NSAttributedString? { nil }
    func drawText(for element: BoardElement, in context: CGContext, rect: CGRect) -> Bool { false }
    func measureText(for element: BoardElement, constrainedTo width: Double) -> CGSize? { nil }
    func measureText(for element: BoardElement, width: CGFloat) -> CGSize? { measureText(for: element, constrainedTo: Double(width)) }
}

@MainActor final class BoardRenderer {
    weak var visuals: (any BoardVisualProvider)?
    var nativeStroke: ((BoardElement) -> Data?)? { didSet { invalidateNativeInk(); nativeDrawings.removeAllObjects() } }
    var onChange: (() -> Void)?
    var onError: ((Error) -> Void)?
    private let images = NSCache<NSString, UIImage>()
    private var failedImages = Set<String>()
    private var assets: [String: BoardAsset] = [:]
    private var imageTargets: [String: Int] = [:]
    private var imageTasks: [String: Task<Void, Never>] = [:]
    private final class NativeInk {
        let data: Data, drawing: PKDrawing, bounds: CGRect
        let key = UUID().uuidString
        init(data: Data, drawing: PKDrawing) { self.data = data; self.drawing = drawing; bounds = drawing.bounds }
    }
    private let nativeDrawings = NSCache<NSString, NativeInk>()
    private var checkedInk: [String: Int] = [:]
    private var missingInk = Set<String>()
    private var geometryGeneration: UInt64 = 0
    private final class Path {
        let generation: UInt64, version: Int, path: CGPath, first: CGPoint, dot: Bool
        let arrow: CGPath?
        init(generation: UInt64, element: BoardElement, points: [[Double]]) {
            self.generation = generation; version = element.version
            let value = CGMutablePath(), head = CGMutablePath()
            let first = CGPoint(x: points[0][0], y: points[0][1]); self.first = first; value.move(to: first)
            var distinct = false
            for p in points.dropFirst() where p.count >= 2 {
                value.addLine(to: CGPoint(x: p[0], y: p[1])); distinct = distinct || p[0] != first.x || p[1] != first.y
            }
            path = value; dot = !distinct
            if element.kind == .arrow, let end = points.last, end.count >= 2,
               let before = points.dropLast().reversed().first(where: { $0.count >= 2 && ($0[0] != end[0] || $0[1] != end[1]) }) {
                let angle = atan2(end[1] - before[1], end[0] - before[0]), size = max(10, element.strokeWidth * 4)
                head.move(to: CGPoint(x: end[0] - size * cos(angle - 0.45), y: end[1] - size * sin(angle - 0.45)))
                head.addLine(to: CGPoint(x: end[0], y: end[1]))
                head.addLine(to: CGPoint(x: end[0] - size * cos(angle + 0.45), y: end[1] - size * sin(angle + 0.45)))
                arrow = head
            } else { arrow = nil }
        }
    }
    private let paths = NSCache<NSString, Path>()
    private struct CardSignature: Equatable {
        var title: String, abstract: String
        var size: CGSize
        var read: Bool
    }
    @MainActor private final class CardText {
        let storage: NSTextStorage, manager: NSLayoutManager, container: NSTextContainer
        let height: CGFloat
        init(_ string: String, font: UIFont, color: UIColor, lineHeight: CGFloat, width: CGFloat) {
            let style = NSMutableParagraphStyle(); style.minimumLineHeight = lineHeight; style.maximumLineHeight = lineHeight; style.lineBreakMode = .byWordWrapping
            let storage = NSTextStorage(string: string, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: style])
            let manager = NSLayoutManager(), container = NSTextContainer(size: CGSize(width: width, height: 1e7)); container.lineFragmentPadding = 0
            storage.addLayoutManager(manager); manager.addTextContainer(container); manager.ensureLayout(for: container)
            self.storage = storage; self.manager = manager; self.container = container
            height = string.isEmpty ? 0 : manager.usedRect(for: container).height
        }
        func draw(in context: CGContext, rect: CGRect) {
            guard !rect.isEmpty else { return }
            context.saveGState(); context.clip(to: rect); defer { context.restoreGState() }
            let glyphs = manager.glyphRange(forBoundingRect: CGRect(origin: .zero, size: rect.size), in: container)
            manager.drawGlyphs(forGlyphRange: glyphs, at: rect.origin)
        }
    }
    @MainActor private final class Card {
        let signature: CardSignature, title: CardText, abstract: CardText, titleHeight: CGFloat
        init(_ signature: CardSignature) {
            self.signature = signature
            let title = CardText(signature.title, font: .boldSystemFont(ofSize: 18), color: BoardRenderer.color("#202124"), lineHeight: 24,
                                 width: max(1, signature.size.width - (signature.read ? 18 : 0)))
            self.title = title
            let limit = max(0, min(4, floor((signature.size.height - (!signature.abstract.isEmpty && signature.size.height >= 54 ? 30 : 0)) / 24)))
            titleHeight = min(limit * 24, ceil(title.height / 24) * 24)
            abstract = CardText(signature.abstract, font: .systemFont(ofSize: 14), color: .darkGray, lineHeight: 20, width: signature.size.width)
        }
    }
    private let cards = NSCache<NSString, Card>()
    private(set) var paperCardLayoutCount = 0

    private(set) var nativeDecodeCount = 0
    private(set) var nativeRasterCount = 0
    private(set) var imageDecodeCount = 0
    private(set) var pathBuildCount = 0

    init() {
        images.totalCostLimit = 48 * 1024 * 1024; images.countLimit = 512
        nativeDrawings.totalCostLimit = 16 * 1024 * 1024; nativeDrawings.countLimit = 512
        paths.totalCostLimit = 32 * 1024 * 1024; paths.countLimit = 4096
        cards.totalCostLimit = 8 * 1024 * 1024; cards.countLimit = 512
    }
    func invalidateNativeInk() { checkedInk.removeAll(keepingCapacity: true); missingInk.removeAll(keepingCapacity: true); geometryGeneration &+= 1 }
    func updateAssets(_ values: [String: BoardAsset]) {
        // Immutable sources survive unrelated edits. Removed IDs may later be reused.
        for (id, old) in assets where values[id] != old {
            images.removeObject(forKey: ("asset:" + id) as NSString); imageTargets.removeValue(forKey: id)
            failedImages.remove(id); imageTasks.removeValue(forKey: id)?.cancel()
        }
        assets = values
    }
    func invalidateAssets() {
        imageTasks.values.forEach { $0.cancel() }; imageTasks.removeAll()
        images.removeAllObjects(); imageTargets.removeAll(); failedImages.removeAll(); assets.removeAll()
    }

    static func color(_ value: String) -> UIColor {
        if value == "transparent" { return .clear }
        var hex = value.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        if hex.count == 3 { hex = hex.map { "\($0)\($0)" }.joined() }
        guard (hex.count == 6 || hex.count == 8), let bits = UInt64(hex, radix: 16) else { return .label }
        let alpha = hex.count == 8 ? CGFloat(bits & 255) / 255 : 1
        let rgb = hex.count == 8 ? bits >> 8 : bits
        return UIColor(red: CGFloat((rgb >> 16) & 255) / 255,
                       green: CGFloat((rgb >> 8) & 255) / 255,
                       blue: CGFloat(rgb & 255) / 255, alpha: alpha)
    }

    func draw(_ items: [BoardRenderItem], board: BoardDocument, in context: CGContext, zoom: Double,
              displayScale: CGFloat = 1, moving: Set<String> = [], offset: CGPoint = .zero, hidden: Set<String> = []) {
        // Preserve Rust's presentation order and source identity during transient movement.
        for item in items where !hidden.contains(item.element.id) {
            context.saveGState()
            if moving.contains(item.element.id) { context.translateBy(x: offset.x, y: offset.y) }
            draw(item, board: board, in: context, zoom: zoom, displayScale: displayScale)
            context.restoreGState()
        }
    }

    private func draw(_ item: BoardRenderItem, board: BoardDocument, in c: CGContext, zoom: Double, displayScale: CGFloat) {
        let e = item.element
        c.setAlpha(e.opacity); c.setStrokeColor(Self.color(e.stroke).cgColor)
        c.setFillColor(Self.color(e.fill).cgColor); c.setLineWidth(e.strokeWidth)
        c.setLineCap(.round); c.setLineJoin(.round)
        if ["line", "arrow", "pen"].contains(e.kind.rawValue) {
            // These points are already resolved WORLD coordinates, including bindings/rotation.
            guard let points = item.points, let first = points.first, first.count >= 2 else { return }
            if e.kind == .pen, let ink = nativeInk(e) {
                drawNative(ink, in: c, zoom: zoom, displayScale: displayScale)
                return
            }
            let key = e.id as NSString
            let path: Path
            if let cached = paths.object(forKey: key), cached.generation == geometryGeneration, cached.version == e.version { path = cached }
            else {
                path = Path(generation: geometryGeneration, element: e, points: points); pathBuildCount += 1
                paths.setObject(path, forKey: key, cost: points.count * 32 + 256)
            }
            if e.strokeStyle == "dotted" { c.setLineDash(phase: 0, lengths: [0.01, e.strokeWidth * 3]) }
            if path.dot {
                c.setFillColor(Self.color(e.stroke).cgColor)
                c.fillEllipse(in: CGRect(x: path.first.x - e.strokeWidth / 2, y: path.first.y - e.strokeWidth / 2, width: e.strokeWidth, height: e.strokeWidth))
            }
            c.addPath(path.path); c.strokePath(); c.setLineDash(phase: 0, lengths: [])
            if let arrow = path.arrow { c.addPath(arrow); c.strokePath() }
            return
        }
        let width = abs(cos(e.angle)) * e.width + abs(sin(e.angle)) * e.height
        let height = abs(sin(e.angle)) * e.width + abs(cos(e.angle)) * e.height
        let paintedBounds = CGRect(x: e.x + e.width / 2 - width / 2, y: e.y + e.height / 2 - height / 2, width: width, height: height).insetBy(dx: -e.strokeWidth / 2, dy: -e.strokeWidth / 2)
        guard paintedBounds.intersects(c.boundingBoxOfClipPath) else { return }
        c.translateBy(x: e.x + e.width / 2, y: e.y + e.height / 2)
        c.rotate(by: e.angle)
        let rect = CGRect(x: -e.width / 2, y: -e.height / 2, width: e.width, height: e.height)
        let shape = CGMutablePath()
        switch e.kind.rawValue {
        case "ellipse": shape.addEllipse(in: rect)
        case "diamond":
            shape.move(to: CGPoint(x: rect.midX, y: rect.minY))
            shape.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
            shape.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
            shape.addLine(to: CGPoint(x: rect.minX, y: rect.midY)); shape.closeSubpath()
        case "paper" where e.paperView != "page":
            shape.addRoundedRect(in: rect, cornerWidth: min(8,e.width/2,e.height/2), cornerHeight: min(8,e.width/2,e.height/2))
        default: shape.addRect(rect)
        }
        if ![BoardKind.text,.image].contains(e.kind) { c.addPath(shape); c.drawPath(using: .fillStroke) }
        if e.kind == .paper, e.paperView != "page" {
            drawPaperCard(e, rect: rect, context: c)
            drawReadMarker(e, rect: rect, context: c)
            return
        }
        if ["image", "paper"].contains(e.kind.rawValue) {
            let image = visuals?.preview(for: e, asset: e.assetId.flatMap { board.assets[$0] }, targetSize: CGSize(width: e.width * zoom * displayScale, height: e.height * zoom * displayScale))
                ?? embeddedImage(e, board: board, target: max(e.width, e.height) * zoom * displayScale)
            if e.kind == .image, let url = e.url, BoardURLImports.isYouTube(url) {
                let titleHeight = min(rect.height, 48)
                let thumbnail = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height - titleHeight)
                if let image, thumbnail.width > 0, thumbnail.height > 0, image.size.width > 0, image.size.height > 0 {
                    let scale = max(thumbnail.width / image.size.width, thumbnail.height / image.size.height)
                    let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
                    c.saveGState(); c.clip(to: thumbnail)
                    UIGraphicsPushContext(c)
                    image.draw(in: CGRect(x: thumbnail.midX - size.width / 2, y: thumbnail.midY - size.height / 2, width: size.width, height: size.height))
                    UIGraphicsPopContext(); c.restoreGState()
                }
                let titleRect = CGRect(x: rect.minX, y: thumbnail.maxY, width: rect.width, height: titleHeight)
                c.setFillColor(UIColor.white.cgColor); c.fill(titleRect)
                c.saveGState(); c.clip(to: titleRect)
                let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byTruncatingTail
                paragraph.minimumLineHeight = 20; paragraph.maximumLineHeight = 20
                UIGraphicsPushContext(c)
                ((e.text?.isEmpty == false ? e.text : nil) ?? "YouTube").draw(
                    with: CGRect(x: titleRect.minX + 12, y: titleRect.minY + 4, width: max(0, titleRect.width - 24), height: min(40, max(0, titleHeight - 4))),
                    options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                    attributes: [.font: UIFont.boldSystemFont(ofSize: 16), .foregroundColor: Self.color("#202124"), .paragraphStyle: paragraph], context: nil)
                UIGraphicsPopContext(); c.restoreGState()
            } else if let image {
                c.saveGState(); c.addPath(shape); c.clip()
                UIGraphicsPushContext(c); image.draw(in: rect); UIGraphicsPopContext(); c.restoreGState()
            } else {
                drawText(e.kind == .image ? "Media preview unavailable" : (e.paperTitle ?? e.text ?? "PDF"), element: e, rect: rect.insetBy(dx: 8, dy: 8), context: c)
            }
        } else if let text = e.text, !text.isEmpty {
            drawText(text, element: e, rect: rect, context: c)
        }
        if e.kind == .paper { drawReadMarker(e, rect: rect, context: c) }
    }

    private func drawPaperCard(_ element: BoardElement, rect: CGRect, context: CGContext) {
        let paper = visuals?.paperInfo(for: element)
        let title = element.paperTitle ?? paper?.title ?? element.text ?? "Paper"
        let abstract = paper?.abstract ?? ""
        let content = rect.insetBy(dx: 16, dy: 16)
        guard content.width > 0, content.height > 0 else { return }
        context.saveGState(); context.clip(to: content); UIGraphicsPushContext(context)
        defer { UIGraphicsPopContext(); context.restoreGState() }
        let signature = CardSignature(title: title, abstract: abstract, size: content.size, read: paper?.isRead == true)
        let key = element.id as NSString, layout: Card
        if let cached = cards.object(forKey: key), cached.signature == signature { layout = cached }
        else {
            layout = Card(signature); paperCardLayoutCount += 1
            cards.setObject(layout, forKey: key, cost: (title.utf16.count + abstract.utf16.count) * 48 + 2048)
        }
        let titleWidth = max(1, content.width - (signature.read ? 18 : 0))
        layout.title.draw(in: context, rect: CGRect(x: content.minX, y: content.minY, width: titleWidth, height: layout.titleHeight))
        let y = content.minY + layout.titleHeight + 10
        let remaining = max(0, floor((content.maxY - y) / 20) * 20)
        layout.abstract.draw(in: context, rect: CGRect(x: content.minX, y: y, width: content.width, height: remaining))

    }
    private func drawReadMarker(_ element: BoardElement, rect: CGRect, context: CGContext) {
        guard visuals?.paperInfo(for:element)?.isRead == true else { return }
        let x = rect.maxX-15, y = rect.minY+15
        context.saveGState(); defer { context.restoreGState() }
        context.setFillColor(UIColor.white.cgColor); context.setStrokeColor(Self.color("#137333").cgColor); context.setLineWidth(1.5)
        context.fillEllipse(in:CGRect(x:x-9,y:y-9,width:18,height:18)); context.strokeEllipse(in:CGRect(x:x-9,y:y-9,width:18,height:18))
        context.setLineWidth(2); context.move(to:CGPoint(x:x-4,y:y)); context.addLine(to:CGPoint(x:x-1,y:y+3)); context.addLine(to:CGPoint(x:x+4,y:y-3)); context.strokePath()
    }

    private func nativeInk(_ element: BoardElement) -> NativeInk? {
        let key = element.id as NSString
        if checkedInk[element.id] == element.version {
            if missingInk.contains(element.id) { return nil }
            if let cached = nativeDrawings.object(forKey: key) { return cached }
        }
        checkedInk[element.id] = element.version
        guard let data = nativeStroke?(element) else { missingInk.insert(element.id); nativeDrawings.removeObject(forKey: key); return nil }
        if let cached = nativeDrawings.object(forKey: key), cached.data == data { return cached }
        do {
            let drawing = try PKDrawing(data: data); nativeDecodeCount += 1
            guard !drawing.strokes.isEmpty, !drawing.bounds.isNull, !drawing.bounds.isEmpty,
                  drawing.bounds.minX.isFinite, drawing.bounds.minY.isFinite, drawing.bounds.width.isFinite, drawing.bounds.height.isFinite else { throw BoardError.invalidDocument("Native Pencil ink has empty bounds.") }
            let value = NativeInk(data: data, drawing: drawing)
            nativeDrawings.setObject(value, forKey: key, cost: data.count * 2 + 256)
            return value
        } catch {
            missingInk.insert(element.id)
            onError?(BoardError.invalidDocument("Native Pencil ink could not be rendered; its archive is retained. " + error.localizedDescription))
            return nil
        }
    }

    static func inkRasterScale(zoom: Double, displayScale: CGFloat) -> CGFloat {
        // Half-octaves avoid a fresh bitmap at every fractional pinch sample.
        let target = max(1.0 / 64, min(8, zoom * displayScale))
        return pow(2, ceil(log2(target) * 2) / 2)
    }
    private func drawNative(_ ink: NativeInk, in context: CGContext, zoom: Double, displayScale: CGFloat) {
        let visible = ink.bounds.intersection(context.boundingBoxOfClipPath)
        guard !visible.isNull, !visible.isEmpty else { return }
        var scale = Self.inkRasterScale(zoom: zoom, displayScale: displayScale)
        while visible.width * visible.height * scale * scale > 12_000_000 { scale /= sqrt(2) }
        // Large world-space strokes are cropped, never replaced by sampled constant-width ink.
        let side = 512 / scale
        let minX = floor((visible.minX - ink.bounds.minX) / side), maxX = ceil((visible.maxX - ink.bounds.minX) / side)
        let minY = floor((visible.minY - ink.bounds.minY) / side), maxY = ceil((visible.maxY - ink.bounds.minY) / side)
        UIGraphicsPushContext(context); defer { UIGraphicsPopContext() }
        for row in Int(minY)..<Int(maxY) { for column in Int(minX)..<Int(maxX) {
            let rect = CGRect(x: ink.bounds.minX + CGFloat(column) * side, y: ink.bounds.minY + CGFloat(row) * side, width: side, height: side).intersection(ink.bounds)
            let key = "ink:\(ink.key):\(scale):\(column):\(row)" as NSString
            let image: UIImage
            if let cached = images.object(forKey: key) { image = cached }
            else {
                image = ink.drawing.image(from: rect, scale: scale); nativeRasterCount += 1
                images.setObject(image, forKey: key, cost: (image.cgImage?.bytesPerRow ?? 0) * (image.cgImage?.height ?? 0))
            }
            image.draw(in: rect)
        } }
    }

    private func embeddedImage(_ e: BoardElement, board: BoardDocument, target: CGFloat) -> UIImage? {
        guard let id = e.assetId, let asset = board.assets[id], asset.mimeType.hasPrefix("image/") else { return nil }
        let key = ("asset:" + id) as NSString, cached = images.object(forKey: key)
        let pixels = Int(min(2048, max(256, pow(2, ceil(log2(max(1, target)))))))
        if let cached, imageTargets[id, default: 0] >= pixels { return cached }
        guard !failedImages.contains(id), imageTasks[id] == nil, imageTasks.count < 2 else { return cached }
        if assets[id] == nil { assets[id] = asset }
        imageDecodeCount += 1
        imageTasks[id] = Task { [weak self] in
            let image = await Task.detached(priority: .userInitiated) { Self.decodeImage(asset, pixels: pixels) }.value
            guard let self, !Task.isCancelled, assets[id] == asset else { return }
            imageTasks.removeValue(forKey: id)
            if let image {
                images.setObject(image, forKey: key, cost: (image.cgImage?.bytesPerRow ?? 0) * (image.cgImage?.height ?? 0)); imageTargets[id] = pixels
            } else { failedImages.insert(id); onError?(BoardVisualStore.Failure.invalidMedia) }
            onChange?()
        }
        return cached
    }
    nonisolated private static func decodeImage(_ asset: BoardAsset, pixels: Int) -> UIImage? {
        guard let data = try? BoardVisualStore.embedded(asset, mime: asset.mimeType),
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let metadata = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = metadata[kCGImagePropertyPixelWidth] as? NSNumber, let height = metadata[kCGImagePropertyPixelHeight] as? NSNumber,
              width.doubleValue > 0, height.doubleValue > 0, width.doubleValue <= 8192, height.doubleValue <= 8192,
              width.doubleValue * height.doubleValue <= 24_000_000,
              let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceThumbnailMaxPixelSize: pixels, kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else { return nil }
        return UIImage(cgImage: cg)
    }

    static func font(_ e: BoardElement) -> UIFont {
        let size = e.fontSize ?? 18
        var font: UIFont
        switch e.fontFamily {
        case "monospace": font = UIFont.monospacedSystemFont(ofSize: size, weight: .regular)
        case "serif": font = UIFont(name: "TimesNewRomanPSMT", size: size) ?? UIFont.systemFont(ofSize: size)
        default: font = UIFont.systemFont(ofSize: size)
        }
        var traits = font.fontDescriptor.symbolicTraits
        if e.bold == true { traits.insert(.traitBold) }
        if e.italic == true { traits.insert(.traitItalic) }
        if let descriptor = font.fontDescriptor.withSymbolicTraits(traits) { font = UIFont(descriptor: descriptor, size: size) }
        return font
    }

    private func drawText(_ text: String, element e: BoardElement, rect: CGRect, context: CGContext) {
        context.saveGState(); context.clip(to: rect); defer { context.restoreGState() }
        if e.kind == .text, visuals?.drawText(for: e, in: context, rect: rect) == true { return }
        let rendered: NSAttributedString
        let centered = [.rectangle, .ellipse, .diamond].contains(e.kind)
        if let rich = visuals?.attributedText(for: e) { rendered = rich }
        else {
            var font = Self.font(e)
            var traits: UIFontDescriptor.SymbolicTraits = []
            if e.bold == true { traits.insert(.traitBold) }; if e.italic == true { traits.insert(.traitItalic) }
            if let descriptor = font.fontDescriptor.withSymbolicTraits(traits) { font = UIFont(descriptor: descriptor, size: font.pointSize) }
            let paragraph = NSMutableParagraphStyle(); paragraph.alignment = centered ? .center : .left
            rendered = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: Self.color(e.stroke), .paragraphStyle: paragraph])
        }
        var target = rect
        if centered {
            let height = rendered.boundingRect(with: CGSize(width: rect.width, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil).height
            target.origin.y += (rect.height - height) / 2
            target.size.height = max(rect.height, height)
        }
        UIGraphicsPushContext(context)
        rendered.draw(with: target, options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
        UIGraphicsPopContext()
    }
}
