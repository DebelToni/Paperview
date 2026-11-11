import UIKit
import PDFKit
import PencilKit

/// Flatten Space ink, retaining the uploaded PDF's vector content and original annotations.
@MainActor enum ReaderExport {
    nonisolated static let maximumNativePixels = 12_000_000
    private enum ExportError: Error, LocalizedError {
        case invalidPage, invalidNative(String)
        nonisolated var errorDescription: String? {
            switch self {
            case .invalidPage: return "The original PDF page could not be exported."
            case .invalidNative(let id): return "Native ink \(id) could not be restored. Export was cancelled rather than losing its appearance."
            }
        }
    }
    static func pageSize(_ geometry: ReaderGeometry) -> CGSize {
        CGSize(width: geometry.displaySize.width * geometry.userUnit, height: geometry.displaySize.height * geometry.userUnit)
    }
    nonisolated static func nativeScale(for size: CGSize) -> CGFloat {
        var scale = min(3, min(8191 / max(1, size.width), min(8191 / max(1, size.height), sqrt(CGFloat(maximumNativePixels) / max(1, size.width * size.height)))))
        // UIImage rounds each dimension up to a pixel.
        while ceil(size.width * scale) * ceil(size.height * scale) > CGFloat(maximumNativePixels) { scale *= 0.999 }
        return scale
    }
    static func export(document: PDFDocument, annotations: [PaperAnnotation], native: @escaping (PaperAnnotation) -> Data?) throws -> Data {
        guard document.pageCount > 0, let first = document.page(at: 0) else { throw ExportError.invalidPage }
        let firstSize = pageSize(ReaderGeometry(page: first))
        guard firstSize.width.isFinite, firstSize.height.isFinite, firstSize.width > 0, firstSize.height > 0,
              annotations.allSatisfy({ (1...document.pageCount).contains($0.page) }) else { throw ExportError.invalidPage }
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: firstSize))
        var failure: Error?
        let data = renderer.pdfData { output in
            for index in 0..<document.pageCount {
                do {
                    try autoreleasepool {
                        guard let page = document.page(at: index), let original = page.pageRef else { throw ExportError.invalidPage }
                        let geometry = ReaderGeometry(page: page), size = pageSize(geometry)
                        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else { throw ExportError.invalidPage }
                        let bounds = CGRect(origin: .zero, size: size)
                        output.beginPage(withBounds: bounds, pageInfo: [:])
                        let context = output.cgContext
                        context.saveGState(); defer { context.restoreGState() }
                        context.clip(to: bounds)
                        context.setFillColor(UIColor.white.cgColor); context.fill(bounds)
                        context.saveGState()
                        // CGPDFPage draws raw PDF coordinates. Do not use getDrawingTransform
                        // here: its UserUnit scaling differs from drawPDFPage's raw coordinates.
                        let pdfToReference = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: -geometry.box.minX, ty: geometry.box.maxY)
                        context.concatenate(pdfToReference.concatenating(ReaderInk.referenceTransform(geometry: geometry, size: size)))
                        context.drawPDFPage(original)
                        context.restoreGState()
                        // PDFAnnotation.draw already applies its owning page's CropBox origin
                        // and rotation. Its context is displayed-page, bottom-left coordinates,
                        // unlike CGPDFPage's raw PDF coordinates. Only physical UserUnit remains.
                        context.saveGState()
                        context.translateBy(x: 0, y: size.height)
                        context.scaleBy(x: geometry.userUnit, y: -geometry.userUnit)
                        for annotation in page.annotations where annotation.shouldDisplay {
                            context.saveGState(); annotation.draw(with: .cropBox, in: context); context.restoreGState()
                        }
                        context.restoreGState()

                        let values = annotations.filter { $0.page == index + 1 }
                        // Preserve the supplied stroke order, also when native and desktop ink interleave.
                        var run: [PKStroke] = []
                        func flushNative() {
                            guard !run.isEmpty else { return }
                            autoreleasepool {
                                let drawing = PKDrawing(strokes: run)
                                let rect = drawing.bounds.insetBy(dx: -2, dy: -2).intersection(bounds)
                                guard !rect.isNull, !rect.isEmpty else { return }
                                // One transparent native run at a time. No original-page bitmap,
                                // and at most 12M pixels / 8192 pixels per side in flight.
                                let image = drawing.image(from: rect, scale: nativeScale(for: rect.size))
                                image.draw(in: rect)
                            }
                            run.removeAll(keepingCapacity: true)
                        }
                        for value in values where value.type != .text {
                            if let archive = native(value) {
                                guard let stroke = ReaderInk.stroke(value, geometry: geometry, size: size, native: archive) else { throw ExportError.invalidNative(value.id) }
                                run.append(stroke)
                            } else {
                                flushNative()
                                drawPortable(value, geometry: geometry, size: size, context: context)
                            }
                        }
                        flushNative()
                        // Text is above ink in the reader, including explicit newlines.
                        for value in values where value.type == .text { drawText(value, geometry: geometry, size: size, context: context) }
                    }
                } catch { failure = error; return }
            }
        }
        if let failure { throw failure }
        return data
    }
    private static func drawPortable(_ value: PaperAnnotation, geometry: ReaderGeometry, size: CGSize, context: CGContext) {
        let points = (value.points ?? []).compactMap { pair -> CGPoint? in
            guard pair.count == 2 else { return nil }
            return geometry.canvas(CGPoint(x: pair[0], y: pair[1]), size: size)
        }
        guard let first = points.first else { return }
        let color = ReaderInk.color(value.color)
        context.saveGState(); defer { context.restoreGState() }
        context.setStrokeColor(color.cgColor); context.setFillColor(color.cgColor)
        context.setAlpha(value.type == .highlight ? 0.28 : 1)
        let width = CGFloat(value.size ?? 2) * geometry.scale(size: size)
        if points.count == 1 || points.allSatisfy({ $0 == first }) {
            context.fillEllipse(in: CGRect(x: first.x - width / 2, y: first.y - width / 2, width: width, height: width))
        } else {
            context.setLineWidth(width); context.setLineCap(.round); context.setLineJoin(.round)
            context.beginPath(); context.move(to: first)
            points.dropFirst().forEach { context.addLine(to: $0) }
            context.strokePath()
        }
    }
    private static func drawText(_ value: PaperAnnotation, geometry: ReaderGeometry, size: CGSize, context: CGContext) {
        let text = (value.text ?? "") as NSString
        let attributes: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: CGFloat(value.size ?? 16)), .foregroundColor: ReaderInk.color(value.color)]
        let options: NSStringDrawingOptions = [.usesLineFragmentOrigin, .usesFontLeading]
        let measured = text.boundingRect(with: CGSize(width: 1_000_000, height: 1_000_000), options: options, attributes: attributes, context: nil)
        context.saveGState(); defer { context.restoreGState() }
        context.concatenate(ReaderInk.referenceTransform(geometry: geometry, size: size))
        let rect = CGRect(x: CGFloat(value.x ?? 0) * geometry.box.width, y: CGFloat(value.y ?? 0) * geometry.box.height,
                          width: max(1, ceil(measured.width) + 2), height: max(1, ceil(measured.height) + 2))
        text.draw(with: rect, options: options, attributes: attributes, context: nil)
    }
}
