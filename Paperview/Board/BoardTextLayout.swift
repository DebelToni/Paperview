import UIKit
import JavaScriptCore
import SwiftMath

/// Immutable measured output. Construct only after an edit, never on Pencil contact updates.
@MainActor
final class BoardTextLayout {
    struct Link { let url: URL; let rect: CGRect }
    struct Signature: Equatable {
        let source: String, color: String
        let fontSize: Double
        let fontFamily: String
        let bold: Bool, italic: Bool
        init(_ element: BoardElement) {
            source = element.text ?? ""; color = element.stroke; fontSize = element.fontSize ?? 18
            fontFamily = element.fontFamily ?? "sans-serif"; bold = element.bold ?? false; italic = element.italic ?? false
        }
    }
    let estimatedCost: Int
    static let attachmentByteLimit = 8_000_000
    let attachmentBytes: Int
    let sourceMathFallbackCount: Int
    enum Failure: Error { case invalidInput, missingParser, parser(String) }
    let source: String
    let size: CGSize
    let links: [Link]
    private struct Chunk {
        let storage: NSTextStorage
        let manager: NSLayoutManager
        let container: NSTextContainer
        let origin: CGPoint
        let bounds: CGRect
        let glyphs: NSRange
    }
    private let chunks: [Chunk]
    private let rules: [CGRect]
    private let color: UIColor

    static func decodeEntities(_ text: String) -> String {
        let regex = try! NSRegularExpression(pattern: "&(#x[0-9a-f]+|#[0-9]+|amp|lt|gt|quot|apos|nbsp);", options: .caseInsensitive)
        let result = NSMutableString(string: text)
        let named = ["amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{00a0}"]
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            let entity = (text as NSString).substring(with: match.range(at: 1)).lowercased()
            let replacement: String
            if entity.hasPrefix("#") {
                let hex = entity.hasPrefix("#x")
                let number = UInt32(entity.dropFirst(hex ? 2 : 1), radix: hex ? 16 : 10) ?? 0
                replacement = number > 0 ? UnicodeScalar(number).map(String.init) ?? "�" : "�"
            } else { replacement = named[entity] ?? "" }
            result.replaceCharacters(in: match.range, with: replacement)
        }
        return result as String
    }
    private static let mathCache = NSCache<NSString, UIImage>()
    private static let parser: JSContext? = {
        guard let url = Bundle.main.url(forResource: "text-tools", withExtension: "js"),
              let script = try? String(contentsOf: url, encoding: .utf8), let context = JSContext() else { return nil }
        context.evaluateScript(script)
        return context.exception == nil ? context : nil
    }()

    static func parse(_ source: String) throws -> [String: Any] {
        guard source.utf16.count <= 100_000 else { throw Failure.invalidInput }
        guard let context = parser else { throw Failure.missingParser }
        context.exception = nil
        let value = context.objectForKeyedSubscript("BoardTextTools")?.objectForKeyedSubscript("parseMarkdown")?.call(withArguments: [source])
        if let exception = context.exception { throw Failure.parser(exception.toString()) }
        guard let json = value?.toString()?.data(using: .utf8),
              let result = try JSONSerialization.jsonObject(with: json) as? [String: Any] else { throw Failure.parser("Invalid parser response") }
        return result
    }

    static func mathFitsBudget(_ tex: String) -> Bool {
        guard tex.utf16.count <= 4096 else { return false }
        var depth = 0, commands = 0, escaped = false
        for scalar in tex.unicodeScalars {
            if escaped { escaped = false; continue }
            if scalar == "\\" { commands += 1; escaped = true; if commands > 256 { return false } }
            else if scalar == "{" { depth += 1; if depth > 64 { return false } }
            else if scalar == "}" { depth = max(0, depth - 1) }
        }
        return true
    }

    init(element: BoardElement, width: CGFloat) throws {
        source = element.text ?? ""
        let base = CGFloat(element.fontSize ?? 18)
        guard width.isFinite, width > 0, base.isFinite, (1...512).contains(base) else { throw Failure.invalidInput }
        let parsed = try Self.parse(source)
        var result = NSMutableAttributedString(string: "")
        var available = width
        var built: [Chunk] = []
        var decorations: [CGRect] = []
        var found: [Link] = []
        var y: CGFloat = 0
        var extent: CGFloat = 0
        // Also covers table measurement passes. Reuse locally even if NSCache evicts.
        var images: [NSString: UIImage] = [:]
        var bitmapBytes = 0
        var fallbackCount = 0
        let ink = BoardRenderer.color(element.stroke)
        func measure(_ text: NSAttributedString, width: CGFloat, at origin: CGPoint? = nil) -> CGSize {
            let storage = NSTextStorage(attributedString: text)
            let manager = NSLayoutManager()
            let container = NSTextContainer(size: CGSize(width: max(0.01, width), height: .greatestFiniteMagnitude))
            container.lineFragmentPadding = 0
            storage.addLayoutManager(manager); manager.addTextContainer(container); manager.ensureLayout(for: container)
            let used = manager.usedRect(for: container)
            if let origin {
                built.append(Chunk(storage: storage, manager: manager, container: container, origin: origin,
                                   bounds: used, glyphs: manager.glyphRange(for: container)))
                storage.enumerateAttribute(.link, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
                    guard let url = value as? URL else { return }
                    let glyphs = manager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
                    manager.enumerateEnclosingRects(forGlyphRange: glyphs, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0), in: container) { rect, _ in
                        found.append(Link(url: url, rect: rect.offsetBy(dx: origin.x, dy: origin.y)))
                    }
                }
            }
            return CGSize(width: min(width, ceil(used.maxX)), height: ceil(used.maxY))
        }
        func flush() {
            guard result.length > 0 else { return }
            let measured = measure(result, width: width, at: CGPoint(x: 0, y: y))
            y += measured.height; extent = max(extent, measured.width)
            result = NSMutableAttributedString(string: "")
        }
        let initial = BoardRenderer.font(element)
        let font = initial
        let traits = font.fontDescriptor.symbolicTraits
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: ink]
        func append(_ text: String, _ attrs: [NSAttributedString.Key: Any]) { result.append(NSAttributedString(string: text, attributes: attrs)) }
        func math(_ tex: String, display: Bool, attrs: [NSAttributedString.Key: Any]) {
            let font = attrs[.font] as? UIFont ?? initial
            guard Self.mathFitsBudget(tex) else { append("⟦TeX exceeds native rendering limits⟧", attrs.merging([.foregroundColor: UIColor.systemRed]) { _, new in new }); return }
            let key = "\(font.fontName):\(font.pointSize):\(display):\(available):\(element.stroke):4:\(tex)" as NSString
            func sourceFallback() {
                fallbackCount += 1
                append(display ? "$$\n\(tex)\n$$" : "$\(tex)$", attrs)
            }
            var image = images[key] ?? Self.mathCache.object(forKey: key)
            if images[key] == nil, let cached = image, let cg = cached.cgImage {
                let cost = cg.bytesPerRow * cg.height
                guard cost <= Self.attachmentByteLimit - bitmapBytes else { sourceFallback(); return }
                images[key] = cached; bitmapBytes += cost
            }
            if image == nil {
                let label = MTMathUILabel()
                label.fontSize = font.pointSize
                label.textColor = ink
                label.labelMode = display ? .display : .text
                label.latex = tex
                if label.error != nil { append("⟦TeX error: \(tex)⟧", attrs.merging([.foregroundColor: UIColor.systemRed]) { _, new in new }); return }
                let natural = label.intrinsicContentSize
                guard natural.width.isFinite, natural.height.isFinite, natural.width > 0, natural.height > 0,
                      natural.width <= 8192, natural.height <= 8192 else { append("⟦TeX: \(tex)⟧", attrs); return }
                let scale = min(1, available / natural.width, 1024 / max(natural.width, natural.height))
                let bounds = CGSize(width: natural.width * scale, height: natural.height * scale)
                // Fixed RGBA8 backing makes the pre-allocation check exact, including
                // row padding. No uncharged 4x attachment survives cache eviction.
                let pixelsWide = max(1, Int(ceil(bounds.width * 4)))
                let pixelsHigh = max(1, Int(ceil(bounds.height * 4)))
                let rowBytes = (pixelsWide * 4 + 63) / 64 * 64
                let cost = rowBytes * pixelsHigh
                guard cost <= Self.attachmentByteLimit - bitmapBytes else { sourceFallback(); return }
                guard let context = CGContext(data: nil, width: pixelsWide, height: pixelsHigh,
                                              bitsPerComponent: 8, bytesPerRow: rowBytes,
                                              space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                    sourceFallback(); return
                }
                label.frame = CGRect(origin: .zero, size: natural)
                label.layoutIfNeeded()
                context.scaleBy(x: 4 * scale, y: 4 * scale)
                label.layer.render(in: context)
                guard let cg = context.makeImage() else { sourceFallback(); return }
                let rendered = UIImage(cgImage: cg, scale: 4, orientation: .up)
                image = rendered
                images[key] = rendered; bitmapBytes += cost
                Self.mathCache.totalCostLimit = Self.attachmentByteLimit
                Self.mathCache.countLimit = 64
                Self.mathCache.setObject(rendered, forKey: key, cost: cost)
            }
            if let image {
                let attachment = NSTextAttachment(); attachment.image = image
                let scale = min(1, available / image.size.width)
                attachment.bounds = CGRect(x: 0, y: font.descender, width: image.size.width * scale, height: image.size.height * scale)
                result.append(NSAttributedString(attachment: attachment))
            }
        }
        func inline(_ tokens: [[String: Any]], _ attrs: [NSAttributedString.Key: Any]) {
            for token in tokens {
                let type = token["type"] as? String ?? ""
                var next = attrs
                let current = attrs[.font] as? UIFont ?? font
                switch type {
                case "strong", "em":
                    var symbolic = current.fontDescriptor.symbolicTraits
                    symbolic.insert(type == "strong" ? .traitBold : .traitItalic)
                    next[.font] = UIFont(descriptor: current.fontDescriptor.withSymbolicTraits(symbolic) ?? current.fontDescriptor, size: current.pointSize)
                case "del": next[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
                case "codespan": next[.font] = UIFont.monospacedSystemFont(ofSize: current.pointSize, weight: .regular); next[.backgroundColor] = UIColor(white: 0.95, alpha: 1)
                case "link":
                    if let href = token["href"] as? String, !href.unicodeScalars.contains(where: { $0.value <= 32 || $0.value == 127 }), let url = URL(string: Self.decodeEntities(href)), ["https", "http", "mailto"].contains(url.scheme?.lowercased() ?? "") { next[.link] = url; next[.underlineStyle] = 1 }
                case "math": math(token["text"] as? String ?? "", display: false, attrs: attrs); continue
                case "br": append("\n", attrs); continue
                default: break
                }
                if let children = token["tokens"] as? [[String: Any]], type != "html", type != "image" { inline(children, next) }
                else {
                    let text = token["text"] as? String ?? token["raw"] as? String ?? ""
                    append(type == "html" || type == "codespan" ? text : Self.decodeEntities(text).replacingOccurrences(of: "\n", with: " "), next)
                }
            }
        }
        func blocks(_ tokens: [[String: Any]], indent: CGFloat = 0) throws {
            for token in tokens {
                let type = token["type"] as? String ?? ""
                if type == "space" || type == "def" { continue }
                var attrs = attributes
                let paragraph = NSMutableParagraphStyle(); paragraph.firstLineHeadIndent = indent; paragraph.headIndent = indent; paragraph.paragraphSpacing = base * 0.45
                attrs[.paragraphStyle] = paragraph
                switch type {
                case "math": math(token["text"] as? String ?? "", display: true, attrs: attrs)
                case "heading":
                    let factors: [CGFloat] = [2, 1.65, 1.4, 1.2, 1.1, 1]
                    attrs[.font] = UIFont.boldSystemFont(ofSize: base * factors[max(0, min(5, (token["depth"] as? Int ?? 1) - 1))])
                    inline(token["tokens"] as? [[String: Any]] ?? [], attrs)
                case "blockquote":
                    flush(); let top = y
                    try blocks(token["tokens"] as? [[String: Any]] ?? [], indent: indent + min(base, width / 3))
                    flush()
                    decorations.append(CGRect(x: indent, y: top, width: min(base * 0.12, width / 6), height: y - top))
                    continue
                case "list":
                    var number = token["start"] as? Int ?? 1
                    for item in token["items"] as? [[String: Any]] ?? [] {
                        let marker = (token["ordered"] as? Bool == true) ? "\(number). " : (item["checked"] as? Bool).map { $0 ? "☑ " : "☐ " } ?? "• "
                        append(marker, attrs); try blocks(item["tokens"] as? [[String: Any]] ?? [], indent: indent + base * 1.5); number += 1
                    }; continue
                case "hr":
                    flush()
                    let ruleWidth = min(max(0, width - indent), base * 8)
                    decorations.append(CGRect(x: indent, y: y + base * 0.4, width: ruleWidth, height: max(1, base / 16)))
                    extent = max(extent, indent + ruleWidth); y += base * 1.25
                    continue
                case "code":
                    attrs[.font] = UIFont.monospacedSystemFont(ofSize: base, weight: .regular)
                    attrs[.backgroundColor] = UIColor(white: 0.95, alpha: 1)
                    let code = token["text"] as? String ?? ""
                    guard let context = Self.parser else { throw Failure.missingParser }
                    context.exception = nil
                    let value = context.objectForKeyedSubscript("BoardTextTools")?.objectForKeyedSubscript("analyzeCode")?.call(withArguments: [code, token["lang"] as? String ?? ""])
                    guard context.exception == nil, let data = value?.toString()?.data(using: .utf8), let analysis = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw Failure.parser("Code analysis failed") }
                    for span in analysis["spans"] as? [[String: Any]] ?? [] {
                        var styled = attrs
                        if let hex = span["color"] as? String, let value = UInt32(hex.dropFirst(), radix: 16) { styled[.foregroundColor] = UIColor(red: CGFloat((value >> 16) & 255)/255, green: CGFloat((value >> 8) & 255)/255, blue: CGFloat(value & 255)/255, alpha: 1) }
                        append(span["text"] as? String ?? "", styled)
                    }
                    for diagnostic in analysis["diagnostics"] as? [[String: Any]] ?? [] { append("\nLine \(diagnostic["line"] as? Int ?? 1): Python syntax error", attrs.merging([.foregroundColor: UIColor.systemRed]) { _, new in new }) }
                case "table":
                    flush()
                    let rows = [token["header"] as? [[String: Any]] ?? []] + (token["rows"] as? [[[String: Any]]] ?? [])
                    let count = rows.first?.count ?? 0
                    guard count > 0 else { continue }
                    let padding = base * 0.4
                    let alignment = token["align"] as? [Any] ?? []
                    func cellText(_ cell: [String: Any], header: Bool, cap: CGFloat, column: Int) -> NSAttributedString {
                        result = NSMutableAttributedString(string: ""); available = cap
                        var style = attrs
                        if header { style[.font] = UIFont(descriptor: font.fontDescriptor.withSymbolicTraits(traits.union(.traitBold)) ?? font.fontDescriptor, size: base) }
                        let paragraph = NSMutableParagraphStyle()
                        if cap < 1e7, column < alignment.count, let align = alignment[column] as? String {
                            paragraph.alignment = align == "right" ? .right : align == "center" ? .center : .left
                        }
                        style[.paragraphStyle] = paragraph
                        inline(cell["tokens"] as? [[String: Any]] ?? [["text": cell["text"] as? String ?? ""]], style)
                        return NSAttributedString(attributedString: result)
                    }
                    var widths = Array(repeating: base + padding * 2, count: count)
                    for (r, row) in rows.enumerated() {
                        for (c, cell) in row.prefix(count).enumerated() {
                            let text = cellText(cell, header: r == 0, cap: 1e7, column: c)
                            widths[c] = max(widths[c], measure(text, width: 1e7).width + padding * 2)
                        }
                    }
                    let scale = min(1, max(0.01, width - indent) / widths.reduce(0, +))
                    widths = widths.map { $0 * scale }
                    for (r, row) in rows.enumerated() {
                        var x = indent
                        var bottom = y
                        for c in 0..<count {
                            let pad = min(padding, widths[c] / 4)
                            let cap = max(0.01, widths[c] - pad * 2)
                            let text = cellText(c < row.count ? row[c] : [:], header: r == 0, cap: cap, column: c)
                            let measured = measure(text, width: cap, at: CGPoint(x: x + pad, y: y + pad))
                            bottom = max(bottom, y + measured.height + pad * 2)
                            x += widths[c]
                        }
                        y = bottom
                        decorations.append(CGRect(x: indent, y: y, width: x - indent, height: 1))
                        extent = max(extent, x)
                    }
                    result = NSMutableAttributedString(string: ""); available = width
                    y += base * 0.45
                    continue
                default: inline(token["tokens"] as? [[String: Any]] ?? [["text": token["text"] as? String ?? token["raw"] as? String ?? ""]], attrs)
                }
                append("\n", attrs)
            }
        }
        try blocks(parsed["tokens"] as? [[String: Any]] ?? [])
        flush()
        chunks = built; rules = decorations; color = ink; links = found
        size = CGSize(width: min(width, extent), height: max(base * 1.3, y))
        var retainedImages = Set<ObjectIdentifier>()
        var retainedBytes = 0
        for chunk in built {
            chunk.storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: chunk.storage.length)) { value, _, _ in
                guard let image = (value as? NSTextAttachment)?.image, let cg = image.cgImage,
                      retainedImages.insert(ObjectIdentifier(image)).inserted else { return }
                retainedBytes += cg.bytesPerRow * cg.height
            }
        }
        attachmentBytes = retainedBytes
        sourceMathFallbackCount = fallbackCount
        estimatedCost = retainedBytes + max(1024, source.utf16.count * 48 + built.count * 1024 + decorations.count * 64 + found.count * 256)
    }

    func draw(in context: CGContext, at point: CGPoint = .zero) {
        context.saveGState(); defer { context.restoreGState() }
        UIGraphicsPushContext(context); defer { UIGraphicsPopContext() }
        context.setFillColor(color.cgColor)
        let clip = context.boundingBoxOfClipPath
        for rect in rules {
            let placed = rect.offsetBy(dx: point.x, dy: point.y)
            if placed.intersects(clip) { context.fill(placed) }
        }
        for chunk in chunks {
            let origin = CGPoint(x: point.x + chunk.origin.x, y: point.y + chunk.origin.y)
            let localClip = clip.offsetBy(dx: -origin.x, dy: -origin.y)
            guard chunk.bounds.intersects(localClip) else { continue }
            // TextKit's immutable layout is reused; glyph work follows the visible
            // region of long text, rather than drawing its entire stored source.
            let range = NSIntersectionRange(chunk.glyphs, chunk.manager.glyphRange(forBoundingRect: localClip, in: chunk.container))
            guard range.length > 0 else { continue }
            chunk.manager.drawBackground(forGlyphRange: range, at: origin)
            chunk.manager.drawGlyphs(forGlyphRange: range, at: origin)
        }
    }
}
