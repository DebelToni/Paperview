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
    var nativeStroke: ((BoardElement) -> Data?)?
    private let images = NSCache<NSString, UIImage>()
    private var failedImages = Set<String>()

    init() { images.totalCostLimit = 48 * 1024 * 1024; images.countLimit = 128 }

    func invalidateAssets() { images.removeAllObjects(); failedImages.removeAll() }

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

    func draw(_ items: [BoardRenderItem], board: BoardDocument, in context: CGContext, zoom: Double) {
        // Engine query order includes the rectangle background tier. Never re-sort by kind/z here.
        for item in items {
            context.saveGState()
            draw(item, board: board, in: context, zoom: zoom)
            context.restoreGState()
        }
    }

    private func draw(_ item: BoardRenderItem, board: BoardDocument, in c: CGContext, zoom: Double) {
        let e = item.element
        c.setAlpha(e.opacity); c.setStrokeColor(Self.color(e.stroke).cgColor)
        c.setFillColor(Self.color(e.fill).cgColor); c.setLineWidth(e.strokeWidth)
        c.setLineCap(.round); c.setLineJoin(.round)
        if ["line", "arrow", "pen"].contains(e.kind.rawValue) {
            // These points are already resolved WORLD coordinates, including bindings/rotation.
            guard let points = item.points, let first = points.first, first.count >= 2 else { return }
            if e.kind == .pen, let data = nativeStroke?(e), let drawing = try? PKDrawing(data: data), !drawing.strokes.isEmpty {
                let rect = drawing.bounds
                let scale = min(3, max(0.25, zoom))
                if !rect.isNull, rect.width > 0, rect.height > 0, rect.width * rect.height * scale * scale <= 4_000_000 {
                    let key = "ink:\(e.id):\(e.version):\(scale)" as NSString
                    let image: UIImage
                    if let cached = images.object(forKey: key) { image = cached }
                    else {
                        image = drawing.image(from: rect, scale: scale)
                        images.totalCostLimit = 48 * 1024 * 1024
                        images.setObject(image, forKey: key, cost: Int(rect.width * rect.height * scale * scale * 4))
                    }
                    // Archive alpha is already captured by PencilKit.
                    UIGraphicsPushContext(c); image.draw(in: rect); UIGraphicsPopContext()
                    return
                }
            }
            let path = CGMutablePath(); path.move(to: CGPoint(x: first[0], y: first[1]))
            for p in points.dropFirst() where p.count >= 2 { path.addLine(to: CGPoint(x: p[0], y: p[1])) }
            if e.strokeStyle == "dotted" { c.setLineDash(phase: 0, lengths: [0.01, e.strokeWidth * 3]) }
            if !points.contains(where: { $0.count >= 2 && ($0[0] != first[0] || $0[1] != first[1]) }) {
                c.setFillColor(Self.color(e.stroke).cgColor)
                c.fillEllipse(in: CGRect(x: first[0] - e.strokeWidth / 2, y: first[1] - e.strokeWidth / 2, width: e.strokeWidth, height: e.strokeWidth))
            }
            c.addPath(path); c.strokePath(); c.setLineDash(phase: 0, lengths: [])
            if e.kind.rawValue == "arrow", points.count > 1,
               let end = points.last, end.count >= 2,
               let before = points.dropLast().reversed().first(where: { $0.count >= 2 && ($0[0] != end[0] || $0[1] != end[1]) }) {
                let angle = atan2(end[1] - before[1], end[0] - before[0])
                let size = max(10, e.strokeWidth * 4)
                c.move(to: CGPoint(x: end[0] - size * cos(angle - 0.45), y: end[1] - size * sin(angle - 0.45)))
                c.addLine(to: CGPoint(x: end[0], y: end[1]))
                c.addLine(to: CGPoint(x: end[0] - size * cos(angle + 0.45), y: end[1] - size * sin(angle + 0.45)))
                c.strokePath()
            }
            return
        }
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
            let image = visuals?.preview(for: e, asset: e.assetId.flatMap { board.assets[$0] }, targetSize: CGSize(width: e.width * zoom, height: e.height * zoom))
                ?? embeddedImage(e, board: board)
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
        let titleLimit = max(0,min(4,Int(floor((content.height - (!abstract.isEmpty && content.height >= 54 ? 30 : 0))/24))))
        let titleStyle = NSMutableParagraphStyle(); titleStyle.minimumLineHeight = 24; titleStyle.maximumLineHeight = 24; titleStyle.lineBreakMode = .byWordWrapping
        let titleWidth = max(1,content.width - (paper?.isRead == true ? 18 : 0))
        let titleText = NSAttributedString(string:title,attributes:[.font:UIFont.boldSystemFont(ofSize:18),.foregroundColor:UIColor(red:32/255,green:33/255,blue:36/255,alpha:1),.paragraphStyle:titleStyle])
        let natural = title.isEmpty ? 0 : titleText.boundingRect(with:CGSize(width:titleWidth,height:1e7),options:[.usesLineFragmentOrigin,.usesFontLeading],context:nil).height
        let titleHeight = min(CGFloat(titleLimit)*24,ceil(natural/24)*24)
        if titleHeight > 0 { titleText.draw(with:CGRect(x:content.minX,y:content.minY,width:titleWidth,height:titleHeight),options:[.usesLineFragmentOrigin,.usesFontLeading],context:nil) }
        let y = content.minY + titleHeight + 10
        let remaining = max(0,floor((content.maxY-y)/20)*20)
        if remaining > 0, !abstract.isEmpty {
            let style = NSMutableParagraphStyle(); style.minimumLineHeight = 20; style.maximumLineHeight = 20; style.lineBreakMode = .byWordWrapping
            NSAttributedString(string:abstract,attributes:[.font:UIFont.systemFont(ofSize:14),.foregroundColor:UIColor.darkGray,.paragraphStyle:style]).draw(with:CGRect(x:content.minX,y:y,width:content.width,height:remaining),options:[.usesLineFragmentOrigin,.usesFontLeading],context:nil)
        }
    }
    private func drawReadMarker(_ element: BoardElement, rect: CGRect, context: CGContext) {
        guard visuals?.paperInfo(for:element)?.isRead == true else { return }
        let x = rect.maxX-15, y = rect.minY+15
        context.saveGState(); defer { context.restoreGState() }
        context.setFillColor(UIColor.white.cgColor); context.setStrokeColor(Self.color("#137333").cgColor); context.setLineWidth(1.5)
        context.fillEllipse(in:CGRect(x:x-9,y:y-9,width:18,height:18)); context.strokeEllipse(in:CGRect(x:x-9,y:y-9,width:18,height:18))
        context.setLineWidth(2); context.move(to:CGPoint(x:x-4,y:y)); context.addLine(to:CGPoint(x:x-1,y:y+3)); context.addLine(to:CGPoint(x:x+4,y:y-3)); context.strokePath()
    }

    private func embeddedImage(_ e: BoardElement, board: BoardDocument) -> UIImage? {
        guard let id = e.assetId, let asset = board.assets[id], asset.mimeType.hasPrefix("image/") else { return nil }
        if let cached = images.object(forKey: ("asset:"+id) as NSString) { return cached }
        guard !failedImages.contains(id) else { return nil }
        guard let comma = asset.dataURL.firstIndex(of: ","),
              let data = Data(base64Encoded: String(asset.dataURL[asset.dataURL.index(after: comma)...])),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let metadata = CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [CFString:Any],
              let width = metadata[kCGImagePropertyPixelWidth] as? NSNumber, let height = metadata[kCGImagePropertyPixelHeight] as? NSNumber,
              width.doubleValue > 0, height.doubleValue > 0, width.doubleValue <= 8192, height.doubleValue <= 8192,
              width.doubleValue * height.doubleValue <= 24_000_000,
              let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 2048, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) else { failedImages.insert(id); return nil }
        let image = UIImage(cgImage: cg)
        images.totalCostLimit = 48 * 1024 * 1024
        images.setObject(image, forKey: ("asset:"+id) as NSString, cost: Int(image.size.width * image.size.height * image.scale * image.scale * 4))
        return image
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
        if e.kind == .text, visuals?.drawText(for: e, in: context, rect: rect) == true { return }
        let rendered: NSAttributedString
        if let rich = visuals?.attributedText(for: e) { rendered = rich }
        else {
            var font = Self.font(e)
            var traits: UIFontDescriptor.SymbolicTraits = []
            if e.bold == true { traits.insert(.traitBold) }; if e.italic == true { traits.insert(.traitItalic) }
            if let descriptor = font.fontDescriptor.withSymbolicTraits(traits) { font = UIFont(descriptor: descriptor, size: font.pointSize) }
            rendered = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: Self.color(e.stroke)])
        }
        context.saveGState(); context.clip(to: rect)
        UIGraphicsPushContext(context)
        rendered.draw(with: rect, options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
        UIGraphicsPopContext(); context.restoreGState()
    }
}
