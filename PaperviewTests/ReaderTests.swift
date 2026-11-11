import XCTest
import UIKit
import PDFKit
import PencilKit
import CryptoKit
@testable import Paperview

@MainActor final class ReaderTests: XCTestCase {
    /// A real PDF, with nonzero origins, intersecting boxes, all rotations and UserUnit.
    private func document(withContent: Bool = false) throws -> PDFDocument {
        var objects = [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Count 4 /Kids [3 0 R 4 0 R 5 0 R 6 0 R] >>"
        ] + [0, 90, 180, 270].enumerated().map { index, rotation in
            let resources = withContent ? "/Resources << /Font << /F1 7 0 R >> >> /Contents 8 0 R" : "/Resources << >>"
            return "<< /Type /Page /Parent 2 0 R /MediaBox [10 20 610 820] /CropBox [30 40 \(index == 1 ? 650 : 580) 780] /Rotate \(rotation) /UserUnit \(index == 2 ? 2 : 1) \(resources) >>"
        }
        if withContent {
            let content = "0 0 0 rg 85 700 8 8 re f BT /F1 14 Tf 80 500 Td (Original vector text) Tj ET"
            objects.append("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>")
            objects.append("<< /Length \(content.utf8.count) >>\nstream\n\(content)\nendstream")
        }
        var text = "%PDF-1.7\n"; var offsets = [0]
        for (index, object) in objects.enumerated() {
            offsets.append(text.utf8.count); text += "\(index + 1) 0 obj\n\(object)\nendobj\n"
        }
        let start = text.utf8.count
        text += "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"
        for offset in offsets.dropFirst() { text += String(format: "%010d 00000 n \n", offset) }
        text += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(start)\n%%EOF\n"
        return try XCTUnwrap(PDFDocument(data: Data(text.utf8)))
    }
    func testPDFKitDefaultURLCallbackIsSuppressed() throws {
        let reader = PaperReaderController(api: SpaceAPI(origin: URL(string: "https://example.invalid")!, cookies: []), paperID: "fixture", storageDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        var opened: [URL] = []
        reader.openOriginalLink = { opened.append($0) }
        reader.loadViewIfNeeded()
        defer { reader.invalidateAccess() }
        XCTAssertTrue(reader.pdfView.delegate === reader)
        let selector = NSSelectorFromString("PDFViewWillClickOnLink:withURL:")
        XCTAssertTrue(reader.responds(to: selector))
        for value in ["https://example.org", "javascript:alert(1)", "file:///etc/passwd"] {
            reader.perform(selector, with: reader.pdfView, with: try XCTUnwrap(URL(string: value)))
        }
        XCTAssertTrue(opened.isEmpty, "PDFKit callbacks must not open URLs, including safe ones")
    }
    func testOriginalLinkQuadsSurviveSerializationAndExcludeGaps() throws {
        let pdf = try document()
        let page = try XCTUnwrap(pdf.page(at: 0))
        let link = PDFAnnotation(bounds: CGRect(x: 80, y: 500, width: 160, height: 60), forType: .link, withProperties: nil)
        link.action = PDFActionURL(url: try XCTUnwrap(URL(string: "https://example.org")))
        // PDFKit quad points are relative to the annotation origin, in Z order.
        link.quadrilateralPoints = [
            CGPoint(x: 0, y: 60), CGPoint(x: 100, y: 60), CGPoint(x: 0, y: 40), CGPoint(x: 100, y: 40),
            CGPoint(x: 0, y: 20), CGPoint(x: 60, y: 20), CGPoint(x: 0, y: 0), CGPoint(x: 60, y: 0)
        ].map { NSValue(cgPoint: $0) }
        page.addAnnotation(link)
        let loaded = try XCTUnwrap(PDFDocument(data: try XCTUnwrap(pdf.dataRepresentation())))
        let loadedPage = try XCTUnwrap(loaded.page(at: 0))
        let loadedLink = try XCTUnwrap(loadedPage.annotations.first { $0.type == "Link" })
        XCTAssertEqual(loadedLink.quadrilateralPoints?.count, 8)
        XCTAssertNotNil(ReaderLinks.link(on: loadedPage, at: CGPoint(x: 100, y: 550)))
        XCTAssertNotNil(ReaderLinks.link(on: loadedPage, at: CGPoint(x: 100, y: 510)))
        XCTAssertNil(ReaderLinks.link(on: loadedPage, at: CGPoint(x: 100, y: 530)))
        XCTAssertNil(ReaderLinks.link(on: loadedPage, at: CGPoint(x: 200, y: 510)))
        loadedLink.shouldDisplay = false
        XCTAssertNil(ReaderLinks.link(on: loadedPage, at: CGPoint(x: 100, y: 550)))
        let view = PDFView(); view.document = loaded
        XCTAssertFalse(ReaderLinks.activate(loadedLink, in: view) { _ in XCTFail("Hidden link opened") })
    }
    func testOriginalLinksUsePDFKitCoordinatesAndDoNotMutatePDF() throws {
        let pdf = try document(withContent: true)
        for index in 0..<pdf.pageCount {
            let page = try XCTUnwrap(pdf.page(at: index))
            let link = PDFAnnotation(bounds: CGRect(x: 80, y: 500, width: 160, height: 30), forType: .link, withProperties: nil)
            link.action = PDFActionURL(url: try XCTUnwrap(URL(string: "https://example.org/paper?q=1")))
            page.addAnnotation(link)
        }
        // Reload a serialized PDF so these are original embedded annotations, not shared marks.
        let bytes = try XCTUnwrap(pdf.dataRepresentation())
        let sourceURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("pdf")
        defer { try? FileManager.default.removeItem(at: sourceURL) }
        try bytes.write(to: sourceURL)
        let original = try XCTUnwrap(PDFDocument(url: sourceURL))
        let before = try sourceSnapshots(original)
        func originalLinkURLs(_ document: PDFDocument) throws -> [URL] {
            try (0..<document.pageCount).map { index in
                let page = try XCTUnwrap(document.page(at: index))
                let link = try XCTUnwrap(page.annotations.first { $0.type == "Link" })
                let action = try XCTUnwrap(link.action as? PDFActionURL)
                return try XCTUnwrap(action.url)
            }
        }
        let urlsBefore = try originalLinkURLs(original)
        let view = PDFView(frame: CGRect(x: 0, y: 0, width: 800, height: 1000))
        view.document = original; view.isInMarkupMode = true; view.layoutDocumentView()
        var opened: [URL] = []
        for index in 0..<original.pageCount {
            let page = try XCTUnwrap(original.page(at: index))
            let point = CGPoint(x: 120, y: 515)
            let screen = view.convert(point, from: page)
            let roundTrip = view.convert(screen, to: page)
            XCTAssertEqual(roundTrip.x, point.x, accuracy: 0.01)
            XCTAssertEqual(roundTrip.y, point.y, accuracy: 0.01)
            let link = try XCTUnwrap(ReaderLinks.link(on: page, at: roundTrip))
            XCTAssertTrue(ReaderLinks.activate(link, in: view) { opened.append($0) })
            XCTAssertNil(ReaderLinks.link(on: page, at: CGPoint(x: 400, y: 400)))
        }
        XCTAssertEqual(opened.count, 4)
        XCTAssertEqual(opened, urlsBefore)
        XCTAssertEqual(try originalLinkURLs(original), urlsBefore)
        XCTAssertEqual(try sourceSnapshots(original), before)
        XCTAssertEqual(try Data(contentsOf: sourceURL), bytes, "Link activation must not rewrite original source bytes")
        let reopened = try XCTUnwrap(PDFDocument(url: sourceURL))
        XCTAssertEqual(try sourceSnapshots(reopened), before)
        XCTAssertEqual(try originalLinkURLs(reopened), urlsBefore)
        XCTAssertEqual(original.pageCount, 4)
    }
    func testOriginalLinkURLPolicyAndToolGating() throws {
        for value in ["javascript:alert(1)", "file:///etc/passwd", "data:text/html,hello", "ftp://example.org", "https://user:pass@example.org", "relative/path"] {
            XCTAssertNil(ReaderLinks.safeURL(try XCTUnwrap(URL(string: value))), value)
        }
        for value in ["https://example.org/paper", "http://example.org", "mailto:author@example.org"] {
            XCTAssertNotNil(ReaderLinks.safeURL(try XCTUnwrap(URL(string: value))))
        }
        for tool in [ReaderTool.pen, .question, .highlight, .erase, .text, .select] {
            XCTAssertFalse(ReaderLinks.allows(.pencil, tool: tool, editing: true))
            XCTAssertEqual(ReaderLinks.allows(.direct, tool: tool, editing: true), tool != .text && tool != .select)
            XCTAssertTrue(ReaderLinks.allows(.direct, tool: tool, editing: false))
            XCTAssertTrue(ReaderLinks.allows(.indirectPointer, tool: tool, editing: false))
        }
    }
    func testOriginalInternalAndUnsafeLinkActions() throws {
        let pdf = try document(), view = PDFView()
        view.document = pdf
        let page = try XCTUnwrap(pdf.page(at: 2))
        let link = PDFAnnotation(bounds: CGRect(x: 80, y: 500, width: 160, height: 30), forType: .link, withProperties: nil)
        link.action = PDFActionGoTo(destination: PDFDestination(page: page, at: CGPoint(x: 80, y: 500)))
        XCTAssertTrue(ReaderLinks.activate(link, in: view) { _ in XCTFail("Internal link opened browser") })
        link.action = PDFActionNamed(name: .firstPage)
        XCTAssertTrue(ReaderLinks.activate(link, in: view) { _ in XCTFail("Named page action opened browser") })
        link.action = PDFActionURL(url: try XCTUnwrap(URL(string: "javascript:alert(1)")))
        XCTAssertFalse(ReaderLinks.activate(link, in: view) { _ in XCTFail("Unsafe URL opened") })
        let mark = PDFAnnotation(bounds: link.bounds, forType: .freeText, withProperties: nil)
        mark.action = PDFActionURL(url: try XCTUnwrap(URL(string: "https://example.org")))
        XCTAssertFalse(ReaderLinks.activate(mark, in: view) { _ in XCTFail("Non-link annotation opened") })
    }
    func testMixedCropRotationAndUserUnitGeometry() throws {
        let pdf = try document()
        XCTAssertEqual(pdf.pageCount, 4)
        for index in 0..<4 {
            let geometry = ReaderGeometry(page: try XCTUnwrap(pdf.page(at: index)))
            XCTAssertEqual(geometry.rotation, index * 90)
            XCTAssertEqual(geometry.box.minX, 30, accuracy: 0.001)
            XCTAssertEqual(geometry.box.minY, 40, accuracy: 0.001)
            XCTAssertLessThanOrEqual(geometry.box.maxX, 610)
            for p in [CGPoint.zero, CGPoint(x: 1, y: 1), CGPoint(x: 0.24, y: 0.73)] {
                let size = CGSize(width: 833, height: 1171)
                let actual = geometry.normalized(geometry.canvas(p, size: size), size: size)
                XCTAssertEqual(actual.x, p.x, accuracy: 0.000001)
                XCTAssertEqual(actual.y, p.y, accuracy: 0.000001)
                let pdfPoint = geometry.pdf(p)
                XCTAssertEqual(pdfPoint.x, geometry.box.minX + p.x * geometry.box.width, accuracy: 0.000001)
                XCTAssertEqual(pdfPoint.y, geometry.box.maxY - p.y * geometry.box.height, accuracy: 0.000001)
            }
        }
        XCTAssertEqual(ReaderGeometry(page: try XCTUnwrap(pdf.page(at: 2))).userUnit, 2)
    }
    func testDesktopInkImportsEditsAndRetainsSemanticID() throws {
        let pdf = try document()
        for index in 0..<4 {
            let geometry = ReaderGeometry(page: try XCTUnwrap(pdf.page(at: index)))
            let original = PaperAnnotation(id: "desktop-question", page: index + 1, type: .question, color: "#000000", points: [[0.1, 0.2], [0.5, 0.6], [0.8, 0.7]], size: 3)
            let size = geometry.displaySize
            let stroke = try XCTUnwrap(ReaderInk.stroke(original, geometry: geometry, size: size))
            XCTAssertEqual(stroke.path.first!.size.width, 3, accuracy: 0.001)
            let imported = ReaderInk.annotation(stroke, previous: original, page: index + 1, tool: .pen, color: "#007aff", geometry: geometry, size: size)
            XCTAssertEqual(imported.id, original.id)
            XCTAssertEqual(imported.type, .question)
            XCTAssertEqual(imported.color, "#000000")
            XCTAssertEqual(imported.points!.first![0], 0.1, accuracy: 0.01)
            XCTAssertEqual(imported.points!.first![1], 0.2, accuracy: 0.01)
            let moved = PKStroke(ink: stroke.ink, path: stroke.path, transform: CGAffineTransform(translationX: 10, y: 12), mask: nil)
            let edited = ReaderInk.annotation(moved, previous: original, page: index + 1, tool: .highlight, color: "#ffcc00", geometry: geometry, size: size)
            XCTAssertEqual(edited.id, original.id); XCTAssertEqual(edited.type, .question)
            XCTAssertNotEqual(edited.points, original.points)
        }
    }
    func testVariableStrokeArchiveRestoresWithoutFlattening() throws {
        let geometry = ReaderGeometry(page: try XCTUnwrap(document().page(at: 0)))
        let points: [PKStrokePoint] = (0..<12).map { (index: Int) -> PKStrokePoint in
            let location = CGPoint(x: 30 + CGFloat(index) * 4, y: 40 + CGFloat(index) * 3)
            let size = CGSize(width: CGFloat(index + 1), height: CGFloat(index + 2))
            let pressure = CGFloat(index + 1) / 12
            return PKStrokePoint(location: location, timeOffset: Double(index) / 120,
                                 size: size, opacity: pressure, force: pressure, azimuth: 0.3, altitude: 1)
        }
        let stroke = PKStroke(ink: PKInk(.monoline, color: .blue), path: PKStrokePath(controlPoints: points, creationDate: Date(timeIntervalSince1970: 123)), transform: CGAffineTransform(translationX: 7, y: 9), mask: UIBezierPath(rect: CGRect(x: 20, y: 30, width: 200, height: 200)))
        let value = ReaderInk.annotation(stroke, previous: nil, page: 1, tool: .question, color: "#007aff", geometry: geometry, size: geometry.displaySize)
        let data = ReaderInk.nativeArchive(stroke, geometry: geometry, size: geometry.displaySize)
        XCTAssertNil(ReaderInk.stroke(value, geometry: geometry, size: geometry.displaySize, native: ReaderInk.archive(stroke)), "Raw screen-coordinate archives must never be restored as stable reference data")
        let restored = try XCTUnwrap(ReaderInk.stroke(value, geometry: geometry, size: geometry.displaySize, native: data))
        XCTAssertEqual(restored.path.count, stroke.path.count)
        XCTAssertEqual(restored.mask?.cgPath, stroke.mask?.cgPath)
        XCTAssertEqual(restored.transform.tx, stroke.transform.tx, accuracy: 0.00001)
        XCTAssertEqual(restored.transform.ty, stroke.transform.ty, accuracy: 0.00001)
        for i in 0..<stroke.path.count {
            XCTAssertEqual(restored.path[i].location, stroke.path[i].location)
            XCTAssertEqual(restored.path[i].size, stroke.path[i].size)
            XCTAssertEqual(restored.path[i].force, stroke.path[i].force, accuracy: 0.001)
            XCTAssertEqual(restored.path[i].opacity, stroke.path[i].opacity, accuracy: 0.001)
        }
    }
    func testNativeMatchingPreservesIDsForMoveAndErase() {
        let a = Data([1]), b = Data([2]), moved = Data([3])
        XCTAssertEqual(ReaderInk.matchingIndices(before: [a, b], after: [a, moved]), [0, nil])
        XCTAssertEqual(ReaderInk.matchingIndices(before: [a, b], after: [b]), [1])
        XCTAssertEqual(ReaderInk.matchingIndices(before: [a, b], after: []), [])
        XCTAssertEqual(ReaderInk.matchingIndices(before: [a], after: [a, b]), [0, nil])
        XCTAssertEqual(ReaderInk.matchingIndices(before: [a, b], after: [b, a]), [1, 0])
    }
    func testRGBAColorsAndActualOverlayTransform() throws {
        let color = ReaderInk.color("#f008")
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        XCTAssertTrue(color.getRed(&red, green: &green, blue: &blue, alpha: &alpha))
        XCTAssertEqual(red, 1); XCTAssertEqual(green, 0); XCTAssertEqual(blue, 0)
        XCTAssertEqual(alpha, 136.0 / 255.0, accuracy: 0.001)
        let page = try XCTUnwrap(document().page(at: 1))
        let transform = CGAffineTransform(a: 0, b: 580, c: -740, d: 0, tx: 740, ty: 0)
        let geometry = ReaderGeometry(page: page, overlayTransform: transform)
        let point = CGPoint(x: 0.2, y: 0.7)
        let canvas = geometry.canvas(point, size: CGSize(width: 740, height: 580))
        XCTAssertEqual(canvas.x, 222, accuracy: 0.001)
        XCTAssertEqual(canvas.y, 116, accuracy: 0.001)
        let restored = geometry.normalized(canvas, size: .zero)
        XCTAssertEqual(restored.x, point.x, accuracy: 0.000001)
        XCTAssertEqual(restored.y, point.y, accuracy: 0.000001)
    }
    func testPencilOnlyCanvasAndToolSymbols() {
        let overlay = ReaderPageView(frame: CGRect(x: 0, y: 0, width: 600, height: 800))
        overlay.layoutIfNeeded()
        XCTAssertEqual(overlay.canvas.drawingPolicy, .pencilOnly)
        XCTAssertFalse(overlay.canvas.isScrollEnabled)
        XCTAssertFalse(overlay.textLayer.isUserInteractionEnabled)
        XCTAssertEqual(overlay.canvas.frame, overlay.bounds)
        for tool in ReaderTool.allCases { XCTAssertNotNil(UIImage(systemName: tool.symbol), tool.rawValue) }
        XCTAssertFalse(overlay.acceptsTouch(.pencil), "Read-only ink passes through")
        overlay.editingEnabled = true
        for tool in [ReaderTool.pen, .question, .highlight, .erase] {
            overlay.readerTool = tool
            XCTAssertTrue(overlay.acceptsTouch(.pencil)); XCTAssertFalse(overlay.acceptsTouch(.direct))
            XCTAssertFalse(overlay.acceptsTouch(.indirectPointer))
        }
        for tool in [ReaderTool.select, .text] { overlay.readerTool = tool; XCTAssertTrue(overlay.acceptsTouch(.direct)) }
        overlay.editingEnabled = false
        XCTAssertNil(overlay.hitTest(CGPoint(x: 50, y: 50), with: nil))
    }
    func testNativeJournalReloadCanonicalMatchAndStableErase() async throws {
        let service = ReaderFixtureService()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = PaperSession(api: service, paperID: "p", storageDirectory: directory)
        _ = try await session.open()
        let geometry = ReaderGeometry(page: try XCTUnwrap(document().page(at: 0)))
        let value = PaperAnnotation(id: "desktop-id", page: 1, type: .question, color: "#000000", points: [[0.1, 0.2], [0.6, 0.7]], size: 4)
        let stroke = try XCTUnwrap(ReaderInk.stroke(value, geometry: geometry, size: geometry.displaySize))
        let archive = ReaderInk.nativeArchive(stroke, geometry: geometry, size: geometry.displaySize)
        try session.edit([AnnotationEdit(id: value.id, original: nil, value: value, native: archive)])
        let reopened = PaperSession(api: service, paperID: "p", storageDirectory: directory)
        _ = try await reopened.open()
        XCTAssertEqual(reopened.nativeStroke(for: value), archive)
        var moved = value; moved.points = [[0.2, 0.3], [0.7, 0.8]]
        try reopened.edit([AnnotationEdit(id: moved.id, original: nil, value: moved)])
        XCTAssertNil(reopened.nativeStroke(for: moved), "Never reuse a stale archive after a canonical change")
        try reopened.edit([AnnotationEdit(id: moved.id, original: nil, value: nil)])
        XCTAssertTrue(reopened.annotations.isEmpty)
        XCTAssertNil(reopened.nativeStroke(for: value))
        let erased = PaperSession(api: service, paperID: "p", storageDirectory: directory)
        _ = try await erased.open()
        XCTAssertTrue(erased.annotations.isEmpty)
    }
    func testStableNativeArchiveAcrossWindowRotationAndScale() throws {
        let page = try XCTUnwrap(document().page(at: 2)) // UserUnit 2 remains part of the real page.
        page.rotation = 90
        let source = ReaderGeometry(page: page)
        let sourceSize = CGSize(width: source.displaySize.width * 1.7, height: source.displaySize.height * 1.7)
        let original = PaperAnnotation(id: "stable", page: 3, type: .question, color: "#007aff80", points: [[0.15, 0.25], [0.5, 0.6], [0.8, 0.7]], size: 3)
        let imported = try XCTUnwrap(ReaderInk.stroke(original, geometry: source, size: sourceSize))
        let moved = PKDrawing(strokes: [imported]).transformed(using: CGAffineTransform(translationX: 12, y: 8)).strokes[0]
        let canonical = ReaderInk.annotation(moved, previous: original, page: 3, tool: .pen, color: "#000000", geometry: source, size: sourceSize)
        let archive = ReaderInk.nativeArchive(moved, geometry: source, size: sourceSize)
        page.rotation = 270
        let destination = ReaderGeometry(page: page)
        let size = CGSize(width: destination.displaySize.width * 0.6, height: destination.displaySize.height * 0.6)
        let restored = try XCTUnwrap(ReaderInk.stroke(canonical, geometry: destination, size: size, native: archive))
        XCTAssertEqual(restored.path.count, moved.path.count)
        var ar: CGFloat = 0, ag: CGFloat = 0, ab: CGFloat = 0, aa: CGFloat = 0
        var er: CGFloat = 0, eg: CGFloat = 0, eb: CGFloat = 0, ea: CGFloat = 0
        XCTAssertTrue(restored.ink.color.getRed(&ar, green: &ag, blue: &ab, alpha: &aa))
        XCTAssertTrue(moved.ink.color.getRed(&er, green: &eg, blue: &eb, alpha: &ea))
        // PencilKit's archive can change UIColor's color-space representation.
        for (a, b) in zip([ar, ag, ab, aa], [er, eg, eb, ea]) { XCTAssertEqual(a, b, accuracy: 1.0 / 255.0) }
        for i in moved.path.indices {
            let before = source.normalized(moved.path[i].location.applying(moved.transform), size: sourceSize)
            let after = destination.normalized(restored.path[i].location.applying(restored.transform), size: size)
            XCTAssertEqual(before.x, after.x, accuracy: 0.00001); XCTAssertEqual(before.y, after.y, accuracy: 0.00001)
            XCTAssertEqual(restored.path[i].size, moved.path[i].size)
        }
        // The PDFKit-derived overlay affine can differ from both prior rotation and window dimensions.
        let affine = CGAffineTransform(a: 0, b: 1100, c: -900, d: 0, tx: 940, ty: 30)
        let actual = ReaderGeometry(page: page, overlayTransform: affine)
        let remapped = try XCTUnwrap(ReaderInk.stroke(canonical, geometry: actual, size: size, native: archive))
        let p = actual.normalized(remapped.path[0].location.applying(remapped.transform), size: size)
        let expected = source.normalized(moved.path[0].location.applying(moved.transform), size: sourceSize)
        XCTAssertEqual(p.x, expected.x, accuracy: 0.00001); XCTAssertEqual(p.y, expected.y, accuracy: 0.00001)
    }
    func testTransformedIdentityDoesNotGuessErasedThenAddedStroke() throws {
        let geometry = ReaderGeometry(page: try XCTUnwrap(document().page(at: 0)))
        let value = PaperAnnotation(id: "a", page: 1, type: .pen, color: "#000000", points: [[0.1, 0.2], [0.5, 0.6]], size: 2)
        let a = try XCTUnwrap(ReaderInk.stroke(value, geometry: geometry, size: geometry.displaySize))
        let moved = PKDrawing(strokes: [a]).transformed(using: CGAffineTransform(translationX: 10, y: 12)).strokes[0]
        let b = PKStroke(ink: a.ink, path: PKStrokePath(controlPoints: Array(a.path), creationDate: Date(timeIntervalSince1970: 1234)))
        let c = PKStroke(ink: a.ink, path: PKStrokePath(controlPoints: Array(a.path), creationDate: Date(timeIntervalSince1970: 5678)))
        XCTAssertEqual(ReaderInk.matchingIndices(before: [ReaderInk.archive(a)], after: [ReaderInk.archive(moved)]), [0])
        let masked = PKStroke(ink: a.ink, path: a.path, transform: a.transform, mask: UIBezierPath(rect: CGRect(x: 20, y: 30, width: 200, height: 300)))
        let maskedMoved = PKDrawing(strokes: [masked]).transformed(using: CGAffineTransform(translationX: 10, y: 12)).strokes[0]
        XCTAssertEqual(ReaderInk.matchingIndices(before: [ReaderInk.archive(masked)], after: [ReaderInk.archive(maskedMoved)]), [0])
        XCTAssertEqual(ReaderInk.matchingIndices(before: [ReaderInk.archive(a), ReaderInk.archive(b)], after: [ReaderInk.archive(a), ReaderInk.archive(c)]), [0, nil])
    }
    func testHighlightOpacityMonolineAndLongPortablePathBudget() async throws {
        let geometry = ReaderGeometry(page: try XCTUnwrap(document().page(at: 0)))
        let note = PaperAnnotation(id: "h", page: 1, type: .highlight, color: "#ffcc0080", points: [[0.1, 0.2], [0.9, 0.2]], size: 8)
        let highlight = try XCTUnwrap(ReaderInk.stroke(note, geometry: geometry, size: geometry.displaySize))
        XCTAssertEqual(highlight.ink.color.cgColor.alpha, 128.0 / 255.0 * 0.28, accuracy: 0.001)
        var pen = note; pen.type = .pen
        XCTAssertEqual(try XCTUnwrap(ReaderInk.stroke(pen, geometry: geometry, size: geometry.displaySize)).ink.inkType, .monoline)
        let points = (0..<21001).map { index in
            PKStrokePoint(location: CGPoint(x: CGFloat(index % 2) * 500, y: CGFloat(index % 700)), timeOffset: Double(index) / 120,
                          size: CGSize(width: 2, height: 2), opacity: 1, force: 0.8, azimuth: 0, altitude: 1)
        }
        let long = PKStroke(ink: PKInk(.monoline, color: .blue), path: PKStrokePath(controlPoints: points, creationDate: Date()))
        let value = ReaderInk.annotation(long, previous: nil, page: 1, tool: .pen, color: "#007aff", geometry: geometry, size: geometry.displaySize)
        XCTAssertLessThanOrEqual(value.points!.count, 20000)
        let archive = ReaderInk.nativeArchive(long, geometry: geometry, size: geometry.displaySize)
        let service = ReaderFixtureService(), directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = PaperSession(api: service, paperID: "p", storageDirectory: directory)
        _ = try await session.open()
        try session.edit([AnnotationEdit(id: value.id, original: nil, value: value, native: archive)])
        let reopened = PaperSession(api: service, paperID: "p", storageDirectory: directory)
        _ = try await reopened.open()
        let stored = try XCTUnwrap(reopened.nativeStroke(for: value))
        let restored = try XCTUnwrap(ReaderInk.stroke(value, geometry: geometry, size: geometry.displaySize, native: stored))
        XCTAssertEqual(restored.path.count, points.count, "Portable reduction must never truncate the native journal")
    }
    func testExpectedOriginalConflictAndNativeArchiveAreOneDurableEdit() async throws {
        let service = ReaderFixtureService()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = PaperAnnotation(id: "same", page: 1, type: .question, color: "#000000", points: [[0.1, 0.2], [0.6, 0.7]], size: 3)
        service.annotations = [original]
        let session = PaperSession(api: service, paperID: "p", storageDirectory: directory)
        _ = try await session.open()
        var remote = original; remote.color = "#ffcc00"
        service.annotations = [remote]
        await session.refresh() // Models an already in-flight refresh completing during Pencil contact.
        var local = original; local.points = [[0.2, 0.3], [0.7, 0.8]]
        let geometry = ReaderGeometry(page: try XCTUnwrap(document().page(at: 0)))
        let stroke = try XCTUnwrap(ReaderInk.stroke(local, geometry: geometry, size: geometry.displaySize))
        let archive = ReaderInk.nativeArchive(stroke, geometry: geometry, size: geometry.displaySize)
        try session.edit([AnnotationEdit(id: local.id, original: original, value: local, native: archive)])
        XCTAssertEqual(session.conflicts.first?.id, original.id)
        let reopened = PaperSession(api: service, paperID: "p", storageDirectory: directory)
        _ = try await reopened.open()
        XCTAssertEqual(reopened.annotations, [local])
        XCTAssertEqual(reopened.conflicts.first?.remote, remote)
        XCTAssertEqual(reopened.nativeStroke(for: local), archive)
        try reopened.resolve(id: local.id, keepMine: false)
        XCTAssertEqual(reopened.annotations, [remote])
        XCTAssertNil(reopened.nativeStroke(for: remote))
    }
    func testPDFKitInstalledOverlayUsesActualPageTransform() async throws {
        let pdf = try document()
        // Use the very same document/page pair in PDFKit conversions.
        let target = try XCTUnwrap(pdf.page(at: 1))
        let shown = expectation(description: "PDFKit displays rotated overlay")
        let provider = ReaderOverlayFixture(target: target, shown: shown)
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else { throw XCTSkip("Requires a hosted UIKit scene") }
        let previousKey = scene.windows.first { $0.isKeyWindow }
        let host = UIViewController(), window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 600, height: 800)
        let view = PDFView(frame: window.bounds)
        window.rootViewController = host; window.makeKeyAndVisible()
        host.view.addSubview(view)
        view.displayMode = .singlePageContinuous; view.displayDirection = .vertical
        view.isInMarkupMode = true; view.pageOverlayViewProvider = provider; view.document = pdf
        view.autoScales = true; view.layoutDocumentView(); view.go(to: target)
        await fulfillment(of: [shown], timeout: 5)
        defer { view.pageOverlayViewProvider = nil; view.document = nil; window.isHidden = true; previousKey?.makeKeyAndVisible() }
        await Task.yield(); view.layoutIfNeeded()
        let overlay = try XCTUnwrap(provider.overlay)
        XCTAssertNotNil(overlay.superview)
        XCTAssertGreaterThan(overlay.bounds.width, 0)
        let geometry = ReaderGeometry(page: target, pdfView: view, overlay: overlay)
        XCTAssertNotNil(geometry.overlayTransform, "The installed overlay must use PDFKit's actual affine")
        for p in [CGPoint.zero, CGPoint(x: 1, y: 1), CGPoint(x: 0.2, y: 0.7)] {
            let actual = geometry.canvas(p, size: overlay.bounds.size)
            let screen = overlay.convert(actual, to: view)
            let expected = view.convert(geometry.pdf(p), from: target)
            XCTAssertEqual(screen.x, expected.x, accuracy: 0.01); XCTAssertEqual(screen.y, expected.y, accuracy: 0.01)
        }
    }
    func testQueuedSqueezePreservesCurrentStrokeAndReturnsToPen() {
        let api = SpaceAPI(origin: URL(string: "https://example.invalid")!, cookies: [])
        let reader = PaperReaderController(api: api, paperID: "fixture", storageDirectory: FileManager.default.temporaryDirectory)
        reader.requestQuickErase(duringContact: true)
        XCTAssertEqual(reader.tool, .pen)
        reader.finishToolContact(); XCTAssertEqual(reader.tool, .erase)
        reader.finishToolContact(); XCTAssertEqual(reader.tool, .pen)
        reader.requestQuickErase(duringContact: false); XCTAssertEqual(reader.tool, .erase)
        reader.requestQuickErase(duringContact: true)
        reader.finishToolContact(); XCTAssertEqual(reader.tool, .erase)
        reader.finishToolContact(); XCTAssertEqual(reader.tool, .pen)
        XCTAssertFalse(reader.isViewLoaded)
    }
    func testSqueezeRestoresEveryPreviousToolAndRepeatedRequestsKeepIt() {
        for previous in ReaderTool.allCases {
            let reader = PaperReaderController(api: SpaceAPI(origin: URL(string: "https://example.invalid")!, cookies: []), paperID: "p", storageDirectory: FileManager.default.temporaryDirectory)
            reader.setTool(previous)
            reader.requestQuickErase(duringContact: false)
            reader.requestQuickErase(duringContact: false)
            XCTAssertEqual(reader.tool, .erase)
            reader.requestQuickErase(duringContact: true)
            reader.requestQuickErase(duringContact: true)
            reader.finishToolContact(); XCTAssertEqual(reader.tool, .erase)
            reader.finishToolContact(); XCTAssertEqual(reader.tool, previous)
            reader.finishToolContact(); XCTAssertEqual(reader.tool, previous)
            reader.requestQuickErase(duringContact: true)
            reader.requestQuickErase(duringContact: true)
            XCTAssertEqual(reader.tool, previous)
            reader.finishToolContact(); XCTAssertEqual(reader.tool, .erase)
            reader.finishToolContact(); XCTAssertEqual(reader.tool, previous)
            XCTAssertFalse(reader.isViewLoaded)
        }
    }
    func testManualSelectionCancelsArmedAndQueuedSqueeze() {
        let reader = PaperReaderController(api: SpaceAPI(origin: URL(string: "https://example.invalid")!, cookies: []), paperID: "p", storageDirectory: FileManager.default.temporaryDirectory)
        for duringContact in [false, true] {
            reader.setTool(.highlight)
            reader.requestQuickErase(duringContact: duringContact)
            reader.setTool(.question)
            reader.finishToolContact(); reader.finishToolContact()
            XCTAssertEqual(reader.tool, .question)
        }
    }
    func testTextSweepUsesRotatedLabelBoundsAndNotBoundingBoxGaps() {
        let overlay = ReaderPageView(frame: CGRect(x: 0, y: 0, width: 600, height: 800))
        overlay.editingEnabled = true; overlay.readerTool = .erase
        let value = PaperAnnotation(id: "text", page: 1, type: .text, color: "#007aff", x: 0.2, y: 0.2, text: "Two\nlines", size: 16)
        overlay.textValues = [value.id: value]
        let label = UILabel(frame: CGRect(x: 0, y: 0, width: 120, height: 40))
        label.accessibilityIdentifier = value.id
        label.layer.anchorPoint = .zero
        label.transform = CGAffineTransform(rotationAngle: .pi / 4)
        label.layer.position = CGPoint(x: 250, y: 250)
        overlay.textLayer.addSubview(label)
        let miss = overlay.convert(CGPoint(x: -10, y: 10), from: label)
        XCTAssertTrue(overlay.beginErase(at: miss))
        XCTAssertTrue(overlay.erasedText.isEmpty)
        overlay.endErase()
        // Neither endpoint is inside; the swept segment crosses the transformed text.
        let start = overlay.convert(CGPoint(x: -30, y: 20), from: label)
        let end = overlay.convert(CGPoint(x: 150, y: 20), from: label)
        XCTAssertTrue(overlay.beginErase(at: start)); overlay.sweepErase(to: end)
        XCTAssertEqual(overlay.erasedText[value.id], value)
        XCTAssertTrue(label.isHidden)
        overlay.endErase()
        overlay.readerTool = .pen
        XCTAssertFalse(overlay.beginErase(at: start))
        overlay.readerTool = .erase; overlay.editingEnabled = false
        XCTAssertFalse(overlay.beginErase(at: start))
    }
    func testObjectEraseTextOnlyAndMixedBatchUndoRedoKeepRichInkAndSource() async throws {
        for mixed in [false, true] {
            let service = ReaderFixtureService()
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let pdf = try document(withContent: true)
            let source = try sourceSnapshots(pdf)
            let geometry = ReaderGeometry(page: try XCTUnwrap(pdf.page(at: 0)))
            let text = PaperAnnotation(id: "text", page: 1, type: .text, color: "#007aff", x: 0.2, y: 0.2, text: "First\nSecond", size: 16)
            let ink = [AnnotationKind.pen, .question, .highlight].enumerated().map { i, kind in
                PaperAnnotation(id: "ink-\(i)", page: 1, type: kind, color: "#007aff", points: [[0.1, 0.5 + Double(i) * 0.1], [0.9, 0.5 + Double(i) * 0.1]], size: 4)
            }
            service.annotations = ink + [text]
            let session = PaperSession(api: service, paperID: "p", storageDirectory: directory)
            _ = try await session.open()
            // A native mask and nonuniform controls must survive deletion and undo unchanged.
            var controls: [PKStrokePoint] = []
            for i in 0..<8 {
                let location = CGPoint(x: 40 + CGFloat(i) * 12, y: 100)
                let size = CGSize(width: CGFloat(i) + 2, height: CGFloat(i) + 3)
                let force = CGFloat(i + 1) / 8
                controls.append(PKStrokePoint(location: location, timeOffset: Double(i) / 120,
                                              size: size, opacity: 0.8, force: force, azimuth: 0.3, altitude: 1))
            }
            let rich = PKStroke(ink: PKInk(.monoline, color: .blue), path: PKStrokePath(controlPoints: controls, creationDate: Date(timeIntervalSince1970: 12)), mask: UIBezierPath(rect: CGRect(x: 30, y: 80, width: 80, height: 40)))
            let archive = ReaderInk.nativeArchive(rich, geometry: geometry, size: geometry.displaySize)
            try session.edit([AnnotationEdit(id: ink[0].id, original: ink[0], value: ink[0], native: archive)])
            let reader = PaperReaderController(api: SpaceAPI(origin: URL(string: "https://example.invalid")!, cookies: []), paperID: "p", storageDirectory: directory, session: session)
            reader.pdfView.document = pdf
            let overlay = try XCTUnwrap(reader.pdfView(reader.pdfView, overlayViewFor: try XCTUnwrap(pdf.page(at: 0))) as? ReaderPageView)
            reader.setTool(.highlight); reader.requestQuickErase(duringContact: false)
            XCTAssertEqual((overlay.canvas.tool as? PKEraserTool)?.eraserType, .vector)
            let label = try XCTUnwrap(overlay.textLayer.subviews.first)
            let hit = overlay.convert(CGPoint(x: label.bounds.midX, y: label.bounds.midY), from: label)
            XCTAssertTrue(overlay.beginErase(at: hit))
            reader.canvasViewDidBeginUsingTool(overlay.canvas)
            if mixed {
                // Use real PKDrawing strokes and the resulting vector-erasure drawing.
                // Synthetic tests cannot establish physical PencilKit hit delivery.
                overlay.canvas.drawing = PKDrawing(strokes: [])
                reader.canvasViewDrawingDidChange(overlay.canvas)
            }
            reader.canvasViewDidEndUsingTool(overlay.canvas)
            XCTAssertEqual(session.annotations.count, 4, "PencilKit end must not split the pending text/ink batch")
            reader.finishErase(overlay, page: 1)
            XCTAssertEqual(reader.tool, .highlight)
            XCTAssertEqual(Set(session.annotations.map { $0.id }), mixed ? Set<String>() : Set(ink.map { $0.id }))
            reader.undo()
            XCTAssertEqual(Set(session.annotations.map { $0.id }), Set((ink + [text]).map { $0.id }))
            XCTAssertEqual(session.nativeStroke(for: ink[0]), archive)
            reader.redo()
            XCTAssertEqual(Set(session.annotations.map { $0.id }), mixed ? Set<String>() : Set(ink.map { $0.id }))
            XCTAssertEqual(try sourceSnapshots(pdf), source)
            let reopened = PaperSession(api: service, paperID: "p", storageDirectory: directory)
            _ = try await reopened.open()
            XCTAssertEqual(Set(reopened.annotations.map { $0.id }), Set(session.annotations.map { $0.id }))
        }
    }
    func testManualSelectionDuringEraseContactDoesNotResurrectTemporaryTool() async throws {
        let service = ReaderFixtureService()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = PaperSession(api: service, paperID: "p", storageDirectory: directory)
        _ = try await session.open()
        let reader = PaperReaderController(api: SpaceAPI(origin: URL(string: "https://example.invalid")!, cookies: []), paperID: "p", storageDirectory: directory, session: session)
        let pdf = try document(); reader.pdfView.document = pdf
        let overlay = try XCTUnwrap(reader.pdfView(reader.pdfView, overlayViewFor: try XCTUnwrap(pdf.page(at: 0))) as? ReaderPageView)
        reader.setTool(.question); reader.requestQuickErase(duringContact: false)
        XCTAssertTrue(overlay.beginErase(at: .zero))
        reader.requestQuickErase(duringContact: true)
        reader.setTool(.text)
        XCTAssertEqual(reader.tool, .erase, "Do not interrupt the current contact")
        reader.finishErase(overlay, page: 1)
        XCTAssertEqual(reader.tool, .text)
        reader.finishToolContact(); XCTAssertEqual(reader.tool, .text)
    }
    func testEraseKeepsCapturedTextOriginalForConcurrentEditConflict() async throws {
        let service = ReaderFixtureService()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let text = PaperAnnotation(id: "text", page: 1, type: .text, color: "#007aff", x: 0.2, y: 0.2, text: "Before", size: 16)
        let neighbor = PaperAnnotation(id: "neighbor", page: 1, type: .text, color: "#007aff", x: 0.8, y: 0.8, text: "Neighbor", size: 16)
        service.annotations = [text, neighbor]
        let session = PaperSession(api: service, paperID: "p", storageDirectory: directory)
        _ = try await session.open()
        let reader = PaperReaderController(api: SpaceAPI(origin: URL(string: "https://example.invalid")!, cookies: []), paperID: "p", storageDirectory: directory, session: session)
        let pdf = try document(); reader.pdfView.document = pdf
        let overlay = try XCTUnwrap(reader.pdfView(reader.pdfView, overlayViewFor: try XCTUnwrap(pdf.page(at: 0))) as? ReaderPageView)
        reader.setTool(.erase)
        let label = try XCTUnwrap(overlay.textLayer.subviews.first { $0.accessibilityIdentifier == text.id })
        XCTAssertTrue(overlay.beginErase(at: overlay.convert(CGPoint(x: label.bounds.midX, y: label.bounds.midY), from: label)))
        var remote = text; remote.text = "Remote edit"
        var remoteNeighbor = neighbor; remoteNeighbor.text = "Unrelated remote edit"
        service.annotations = [remote, remoteNeighbor]
        await session.refresh()
        reader.finishErase(overlay, page: 1)
        XCTAssertEqual(session.conflicts.first?.original, text)
        XCTAssertEqual(session.conflicts.first?.remote, remote)
        XCTAssertNil(session.conflicts.first?.local)
        XCTAssertEqual(session.annotations.first { $0.id == neighbor.id }, remoteNeighbor)
    }
    func testTextEraseFailedJournalRetainsBatchAndReturnToolUntilRetry() async throws {
        let service = ReaderFixtureService()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let backup = directory.appendingPathExtension("saved")
        defer { try? FileManager.default.removeItem(at: directory); try? FileManager.default.removeItem(at: backup) }
        let text = PaperAnnotation(id: "text", page: 1, type: .text, color: "#007aff", x: 0.2, y: 0.2, text: "Keep until durable", size: 16)
        service.annotations = [text]
        let session = PaperSession(api: service, paperID: "p", storageDirectory: directory)
        _ = try await session.open()
        let reader = PaperReaderController(api: SpaceAPI(origin: URL(string: "https://example.invalid")!, cookies: []), paperID: "p", storageDirectory: directory, session: session)
        let pdf = try document(); reader.pdfView.document = pdf
        let overlay = try XCTUnwrap(reader.pdfView(reader.pdfView, overlayViewFor: try XCTUnwrap(pdf.page(at: 0))) as? ReaderPageView)
        reader.setTool(.question); reader.requestQuickErase(duringContact: false)
        let label = try XCTUnwrap(overlay.textLayer.subviews.first)
        XCTAssertTrue(overlay.beginErase(at: overlay.convert(CGPoint(x: label.bounds.midX, y: label.bounds.midY), from: label)))
        try FileManager.default.moveItem(at: directory, to: backup)
        try Data([0]).write(to: directory)
        reader.finishErase(overlay, page: 1)
        XCTAssertTrue(overlay.failedWrite)
        XCTAssertEqual(overlay.erasedText[text.id], text)
        XCTAssertEqual(session.annotations, [text])
        XCTAssertEqual(reader.tool, .question)
        try FileManager.default.removeItem(at: directory)
        try FileManager.default.moveItem(at: backup, to: directory)
        try XCTUnwrap(overlay.retryWrite)()
        XCTAssertFalse(overlay.failedWrite); XCTAssertTrue(overlay.erasedText.isEmpty)
        XCTAssertTrue(session.annotations.isEmpty)
        reader.undo(); XCTAssertEqual(session.annotations, [text])
    }
    func testDesktopSharpVImageFollowsStraightSegmentsAndControlBudget() throws {
        let geometry = ReaderGeometry(page: try XCTUnwrap(document().page(at: 0)))
        let size = geometry.displaySize
        let note = PaperAnnotation(id: "sharp", page: 1, type: .pen, color: "#007aff", points: [[0.15, 0.2], [0.5, 0.7], [0.85, 0.2]], size: 3)
        let stroke = try XCTUnwrap(ReaderInk.stroke(note, geometry: geometry, size: size))
        XCTAssertGreaterThan(stroke.path.count, 500)
        XCTAssertLessThanOrEqual(stroke.path.count, 40000)
        let pixels = try ReaderPixels(PKDrawing(strokes: [stroke]).image(from: CGRect(origin: .zero, size: size), scale: 2))
        let vertices = note.points!.map { geometry.canvas(CGPoint(x: $0[0], y: $0[1]), size: size) }
        func distance(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
            let dx = b.x - a.x, dy = b.y - a.y
            let t = min(1, max(0, ((p.x - a.x) * dx + (p.y - a.y) * dy) / (dx * dx + dy * dy)))
            return hypot(p.x - a.x - t * dx, p.y - a.y - t * dy)
        }
        var maximumDeviation: CGFloat = 0, colored = 0
        for y in stride(from: 0, to: pixels.height, by: 2) {
            for x in stride(from: 0, to: pixels.width, by: 2) {
                let rgba = pixels.pixel(x: x, y: y)
                guard rgba[0] < 0.5 && rgba[2] > 0.7 else { continue }
                let p = CGPoint(x: (CGFloat(x) + 0.5) / 2, y: (CGFloat(y) + 0.5) / 2)
                maximumDeviation = max(maximumDeviation, min(distance(p, vertices[0], vertices[1]), distance(p, vertices[1], vertices[2])))
                colored += 1
            }
        }
        XCTAssertGreaterThan(colored, 500)
        XCTAssertLessThan(maximumDeviation, 3.5, "Sparse PK controls bow far away from a sharp desktop polyline")
        XCTAssertGreaterThan(pixels.ink(near: vertices[1], radius: 3), 3, "The original sharp corner must remain visible")
        var many = note
        many.points = (0..<20000).map { [Double($0 % 2), Double($0 % 5) / 5] }
        XCTAssertLessThanOrEqual(try XCTUnwrap(ReaderInk.stroke(many, geometry: geometry, size: size)).path.count, 40000)
    }
    func testExportPreservesVectorOriginalsSharpInkNativeMasksWidthsTextAndDots() throws {
        var pdf = try document(withContent: true)
        var values: [PaperAnnotation] = [], archives: [String: Data] = [:]
        for index in 0..<pdf.pageCount {
            let page = try XCTUnwrap(pdf.page(at: index)), geometry = ReaderGeometry(page: page)
            let w = geometry.box.width, h = geometry.box.height
            // Reference-space controls independent of this page's rotation/UserUnit.
            let reference = ReaderGeometry(page: page, overlayTransform: CGAffineTransform(a: w, b: 0, c: 0, d: h, tx: 0, ty: 0))
            let variablePoints: [PKStrokePoint] = (0..<50).map { i in
                let t = CGFloat(i) / 49
                return PKStrokePoint(location: CGPoint(x: w * (0.2 + 0.6 * t), y: h * 0.4), timeOffset: Double(i) / 120,
                                     size: CGSize(width: 2 + 34 * t, height: 2 + 34 * t), opacity: 1, force: 1, azimuth: 0, altitude: 1)
            }
            let variable = PKStroke(ink: PKInk(.monoline, color: .red), path: PKStrokePath(controlPoints: variablePoints, creationDate: Date(timeIntervalSince1970: 12)))
            let variableNote = PaperAnnotation(id: "variable-\(index)", page: index + 1, type: .pen, color: "#ff0000", points: [[0.2, 0.4], [0.8, 0.4]], size: 2)
            let maskPoints: [PKStrokePoint] = (0..<50).map { i in
                PKStrokePoint(location: CGPoint(x: w * (0.2 + 0.6 * CGFloat(i) / 49), y: h * 0.58), timeOffset: Double(i) / 120,
                              size: CGSize(width: 10, height: 10), opacity: 1, force: 1, azimuth: 0, altitude: 1)
            }
            let masked = PKStroke(ink: PKInk(.monoline, color: .blue), path: PKStrokePath(controlPoints: maskPoints, creationDate: Date(timeIntervalSince1970: 13)),
                                  transform: .identity, mask: UIBezierPath(rect: CGRect(x: 0, y: h * 0.58 - 30, width: w * 0.45, height: 60)))
            let maskNote = PaperAnnotation(id: "masked-\(index)", page: index + 1, type: .question, color: "#0000ff", points: [[0.2, 0.58], [0.8, 0.58]], size: 10)
            archives[variableNote.id] = ReaderInk.nativeArchive(variable, geometry: reference, size: geometry.box.size)
            archives[maskNote.id] = ReaderInk.nativeArchive(masked, geometry: reference, size: geometry.box.size)
            values += [PaperAnnotation(id: "sharp-\(index)", page: index + 1, type: .pen, color: "#007aff", points: [[0.15, 0.16], [0.5, 0.3], [0.85, 0.16]], size: 3),
                       variableNote, maskNote,
                       PaperAnnotation(id: "dot-\(index)", page: index + 1, type: .pen, color: "#000000", points: [[0.8, 0.68]], size: 8),
                       PaperAnnotation(id: "text-\(index)", page: index + 1, type: .text, color: "#000000", x: 0.12, y: 0.72, text: "First line\nSecond line", size: 16)]
            let p = geometry.pdf(CGPoint(x: 0.83, y: 0.87))
            let uploaded = PDFAnnotation(bounds: CGRect(x: p.x, y: p.y - 8, width: 8, height: 8), forType: .square, withProperties: nil)
            uploaded.color = .green; uploaded.interiorColor = .green; page.addAnnotation(uploaded)
        }
        let sourceBytes = try XCTUnwrap(pdf.dataRepresentation())
        let sourceURL = FileManager.default.temporaryDirectory.appendingPathComponent("reader-original-\(UUID().uuidString).pdf")
        try sourceBytes.write(to: sourceURL, options: .atomic)
        defer { try? FileManager.default.removeItem(at: sourceURL) }
        pdf = try XCTUnwrap(PDFDocument(url: sourceURL))
        let sourceHash = SHA256.hash(data: sourceBytes)
        let before = try sourceSnapshots(pdf)
        let originalAttachment = XCTAttachment(data: sourceBytes, uniformTypeIdentifier: "com.adobe.pdf")
        originalAttachment.name = "immutable-original.pdf"; originalAttachment.lifetime = .keepAlways; add(originalAttachment)
        let data = try ReaderExport.export(document: pdf, annotations: values, native: { archives[$0.id] })
        let exportAttachment = XCTAttachment(data: data, uniformTypeIdentifier: "com.adobe.pdf")
        exportAttachment.name = "flattened-export.pdf"; exportAttachment.lifetime = .keepAlways; add(exportAttachment)
        XCTAssertEqual(SHA256.hash(data: try Data(contentsOf: sourceURL)), sourceHash, "The immutable uploaded file must not be rewritten")
        XCTAssertEqual(try sourceSnapshots(pdf), before, "Drawing must not mutate live PDF page/annotation geometry, text, flags, colors or appearance")
        XCTAssertEqual(try sourceSnapshots(try XCTUnwrap(PDFDocument(url: sourceURL))), before, "The on-disk PDF's semantic and visual state must stay unchanged")
        let exported = try XCTUnwrap(PDFDocument(data: data))
        XCTAssertEqual(exported.pageCount, pdf.pageCount)
        XCTAssertTrue((exported.string ?? "").contains("Original vector text"), "Original page text must remain searchable/vector")
        for index in 0..<pdf.pageCount {
            let source = try XCTUnwrap(pdf.page(at: index)), output = try XCTUnwrap(exported.page(at: index))
            let geometry = ReaderGeometry(page: source), size = ReaderExport.pageSize(geometry)
            XCTAssertEqual(output.bounds(for: .mediaBox).width, size.width, accuracy: 0.01)
            XCTAssertEqual(output.bounds(for: .mediaBox).height, size.height, accuracy: 0.01)
            let outputImage = try rasterPage(output)
            let outputAttachment = XCTAttachment(image: outputImage); outputAttachment.name = "export-page-\(index + 1)"; outputAttachment.lifetime = .keepAlways; add(outputAttachment)
            let sourceImage = source.thumbnail(of: size, for: .cropBox)
            let sourceAttachment = XCTAttachment(image: sourceImage); sourceAttachment.name = "original-page-\(index + 1)"; sourceAttachment.lifetime = .keepAlways; add(sourceAttachment)
            let pixels = try ReaderPixels(outputImage)
            func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { geometry.canvas(CGPoint(x: x, y: y), size: size) }
            XCTAssertGreaterThan(pixels.ink(near: point(0.5, 0.3), radius: 2 * geometry.userUnit), 2)
            XCTAssertTrue(pixels.isWhite(at: point(0.5, 0.26)), "Sharp polyline must not become a broad U")
            let broad = pixels.sample(point(0.75, 0.4 + 8 / geometry.box.height))
            XCTAssertGreaterThan(broad[0], 0.6); XCTAssertLessThan(broad[1], 0.5)
            XCTAssertTrue(pixels.isWhite(at: point(0.25, 0.4 + 8 / geometry.box.height)), "Thin end must not become uniformly broad")
            XCTAssertLessThan(pixels.sample(point(0.3, 0.58))[0], 0.5)
            XCTAssertTrue(pixels.isWhite(at: point(0.65, 0.58)), "Erased native region must not reappear from the portable centerline")
            XCTAssertLessThan(pixels.sample(point(0.8, 0.68))[0], 0.3, "One-point ink must export as a dot")
            // Probe text in reference-space rows, so all four rotations and UserUnit use identical assertions.
            let line = UIFont.systemFont(ofSize: 16).lineHeight
            for row in 0..<2 {
                var count = 0
                for y in 2..<Int(line - 1) {
                    for x in 0..<130 {
                        if !pixels.isWhite(at: point(0.12 + CGFloat(x) / geometry.box.width,
                                                    0.72 + (CGFloat(row) * line + CGFloat(y)) / geometry.box.height)) { count += 1 }
                    }
                }
                XCTAssertGreaterThan(count, 20, "Both explicit text lines must be visible")
            }
            let mark = pixels.sample(point((89 - geometry.box.minX) / geometry.box.width, (geometry.box.maxY - 704) / geometry.box.height))
            XCTAssertLessThan(mark[0], 0.3, "Original vector content must retain its crop/rotation position")
            let uploaded = pixels.sample(point(0.83 + 4 / geometry.box.width, 0.87 + 4 / geometry.box.height))
            XCTAssertGreaterThan(uploaded[1], 0.6); XCTAssertLessThan(uploaded[0], 0.4); XCTAssertLessThan(uploaded[2], 0.4)
        }
    }
    func testRasterProbeUsesTopLeftImageCoordinates() throws {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        let image = UIGraphicsImageRenderer(size: CGSize(width: 20, height: 30), format: format).image { context in
            UIColor.white.setFill(); context.fill(CGRect(x: 0, y: 0, width: 20, height: 30))
            UIColor.red.setFill(); context.fill(CGRect(x: 0, y: 0, width: 20, height: 10))
        }
        let pixels = try ReaderPixels(image)
        XCTAssertLessThan(pixels.sample(CGPoint(x: 5, y: 5))[1], 0.1)
        XCTAssertTrue(pixels.isWhite(at: CGPoint(x: 5, y: 25)))
    }
    func testExportFailsForInvalidNativeAndBoundsRasterDensity() throws {
        let pdf = try document()
        let note = PaperAnnotation(id: "invalid", page: 1, type: .pen, color: "#000000", points: [[0.1, 0.2]], size: 3)
        XCTAssertThrowsError(try ReaderExport.export(document: pdf, annotations: [note], native: { _ in Data([1, 2, 3]) }))
        for size in [CGSize(width: 20000, height: 30000), CGSize(width: 0.1, height: 40000), CGSize(width: 600, height: 800)] {
            let scale = ReaderExport.nativeScale(for: size)
            XCTAssertLessThanOrEqual(ceil(size.width * scale) * ceil(size.height * scale), CGFloat(ReaderExport.maximumNativePixels))
            XCTAssertLessThanOrEqual(ceil(max(size.width, size.height) * scale), 8192)
        }
    }
    private func sourceSnapshots(_ document: PDFDocument) throws -> [ReaderSourceSnapshot] {
        func rgba(_ color: UIColor?) -> [CGFloat]? {
            guard let color else { return nil }
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            color.getRed(&r, green: &g, blue: &b, alpha: &a)
            return [r, g, b, a]
        }
        return try (0..<document.pageCount).map { index in
            let page = try XCTUnwrap(document.page(at: index)), geometry = ReaderGeometry(page: page)
            let appearance = try ReaderPixels(page.thumbnail(of: ReaderExport.pageSize(geometry), for: .cropBox))
            let annotations = page.annotations.map { note in
                ReaderOriginalAnnotation(bounds: note.bounds, type: note.type, contents: note.contents, color: rgba(note.color),
                                         interior: rgba(note.interiorColor), shouldDisplay: note.shouldDisplay, shouldPrint: note.shouldPrint)
            }
            return ReaderSourceSnapshot(box: geometry.box, mediaBox: page.bounds(for: .mediaBox), rotation: page.rotation,
                                        userUnit: geometry.userUnit, text: page.string, annotations: annotations, appearance: appearance.digest)
        }
    }
    private func rasterPage(_ page: PDFPage) throws -> UIImage {
        let bounds = page.bounds(for: .mediaBox)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        return UIGraphicsImageRenderer(size: bounds.size, format: format).image { image in
            UIColor.white.setFill(); image.fill(CGRect(origin: .zero, size: bounds.size))
            let context = image.cgContext
            context.translateBy(x: 0, y: bounds.height); context.scaleBy(x: 1, y: -1)
            if let original = page.pageRef {
                context.concatenate(original.getDrawingTransform(.mediaBox, rect: CGRect(origin: .zero, size: bounds.size), rotate: 0, preserveAspectRatio: true))
                context.drawPDFPage(original)
            }
        }
    }
    func testFineInkWidthsHaveIndependentMarkerAndSharedQuestionSetting() {
        var widths = ReaderInkWidths()
        XCTAssertEqual(widths.value(for: .pen), 1)
        XCTAssertEqual(widths.value(for: .highlight), 16)
        for _ in 0..<30 { widths.resize(-1, tool: .pen) }
        XCTAssertEqual(widths.value(for: .pen), 0.25)
        XCTAssertEqual(widths.value(for: .question), 0.25)
        XCTAssertFalse(widths.canResize(-1, tool: .pen))
        widths.resize(1, tool: .question)
        XCTAssertEqual(widths.value(for: .pen), 0.5)
        XCTAssertEqual(widths.value(for: .highlight), 16)
        widths.resize(-1, tool: .highlight)
        XCTAssertEqual(widths.value(for: .highlight), 12)
        XCTAssertEqual(widths.value(for: .pen), 0.5)
        for _ in 0..<30 { widths.resize(1, tool: .pen) }
        XCTAssertEqual(widths.value(for: .pen), 12)
        for tool in [ReaderTool.select, .erase, .text] {
            XCTAssertFalse(widths.canResize(1, tool: tool))
            widths.resize(-1, tool: tool)
        }
        XCTAssertEqual(widths.value(for: .pen), 12)
    }
    func testBottomStripDirectToolsPaletteAndFractionalInkRoundtrip() async throws {
        let service = ReaderFixtureService()
        service.pdfData = try XCTUnwrap(document(withContent: true).dataRepresentation())
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = PaperSession(api: service, paperID: "p", storageDirectory: directory)
        let reader = PaperReaderController(api: SpaceAPI(origin: URL(string: "https://example.invalid")!, cookies: []), paperID: "p", storageDirectory: directory, session: session)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 1032, height: 1376))
        window.rootViewController = reader; window.makeKeyAndVisible()
        defer { reader.invalidateAccess(); window.isHidden = true }
        for _ in 0..<200 where reader.pdfView.document == nil { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertNotNil(reader.pdfView.document)
        reader.view.layoutIfNeeded()
        func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
        func control(_ id: String) throws -> UIButton {
            try XCTUnwrap(descendants(reader.view).first { $0.accessibilityIdentifier == id } as? UIButton)
        }
        let strip = try XCTUnwrap(descendants(reader.view).first { $0.accessibilityIdentifier == "paper.toolbar" } as? ReaderControlStrip)
        XCTAssertGreaterThan(strip.frame.minY, reader.view.bounds.height / 2)
        XCTAssertEqual(reader.pdfView.frame.maxY, strip.frame.minY, accuracy: 0.01)
        for tool in ReaderTool.allCases { XCTAssertEqual(try control("reader.tool." + tool.rawValue).bounds.width, 44) }
        XCTAssertEqual(try control("reader.palette").menu?.children.count, 8)
        XCTAssertTrue(try control("reader.tool.pen").isSelected)
        try control("reader.thinner").sendActions(for: .touchUpInside)
        try control("reader.thinner").sendActions(for: .touchUpInside)
        try control("reader.thinner").sendActions(for: .touchUpInside)
        XCTAssertEqual(reader.thickness, 0.25)
        XCTAssertFalse(try control("reader.thinner").isEnabled)
        reader.setTool(.highlight); XCTAssertEqual(reader.thickness, 16)
        reader.setTool(.question); XCTAssertEqual(reader.thickness, 0.25)
        reader.setTool(.erase); XCTAssertFalse(try control("reader.palette").isEnabled)
        XCTAssertFalse(try control("reader.thicker").isEnabled)
        reader.setTool(.pen)
        let page = try XCTUnwrap(reader.pdfView.document?.page(at: 0))
        let overlay = try XCTUnwrap(reader.pdfView(reader.pdfView, overlayViewFor: page) as? ReaderPageView)
        overlay.frame = CGRect(origin: .zero, size: ReaderGeometry(page: page).displaySize)
        reader.setTool(.pen)
        let inking = try XCTUnwrap(overlay.canvas.tool as? PKInkingTool)
        XCTAssertLessThan(inking.width, 1)
        let point = PKStrokePoint(location: CGPoint(x: 100, y: 100), timeOffset: 0, size: CGSize(width: inking.width, height: inking.width), opacity: 1, force: 1, azimuth: 0, altitude: 1)
        reader.canvasViewDidBeginUsingTool(overlay.canvas)
        overlay.canvas.drawing = PKDrawing(strokes: [PKStroke(ink: PKInk(.monoline, color: .blue), path: PKStrokePath(controlPoints: [point], creationDate: Date()))])
        reader.canvasViewDidEndUsingTool(overlay.canvas)
        XCTAssertEqual(session.annotations.first?.size, 0.25)
        XCTAssertNotNil(session.annotations.first.flatMap { session.nativeStroke(for: $0) })
        XCTAssertTrue(try control("reader.undo").isEnabled)
        try control("reader.undo").sendActions(for: .touchUpInside)
        XCTAssertTrue(session.annotations.isEmpty)
        XCTAssertTrue(try control("reader.redo").isEnabled)
        try control("reader.redo").sendActions(for: .touchUpInside)
        XCTAssertEqual(session.annotations.first?.size, 0.25)
        for (name, size) in [("ipad-portrait", CGSize(width: 1032, height: 1376)), ("ipad-landscape", CGSize(width: 1376, height: 1032)), ("compact", CGSize(width: 390, height: 844))] {
            window.frame.size = size; reader.view.frame.size = size; reader.view.setNeedsLayout(); reader.view.layoutIfNeeded()
            XCTAssertEqual(strip.frame.height, 52, accuracy: 0.01)
            XCTAssertLessThanOrEqual(strip.frame.maxX, reader.view.bounds.width + 0.01)
            if name == "compact" { XCTAssertGreaterThan(strip.contentSize.width, strip.bounds.width) }
            let image = UIGraphicsImageRenderer(bounds: reader.view.bounds).image { _ in reader.view.drawHierarchy(in: reader.view.bounds, afterScreenUpdates: true) }
            let attachment = XCTAttachment(image: image); attachment.name = "reader-controls-" + name; attachment.lifetime = .keepAlways; add(attachment)
        }
    }
    func testReadingViewportStorageIsPrivateValidatedAndSeparateFromAnnotations() {
        let suite = "reader-viewport-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let key = ReaderViewport.key(owner: "https://fixture.test\naccount:one", paperID: "paper")
        let viewport = ReaderViewport(position: ReadingPosition(page: 3, scroll: 0.42, zoom: 1.8), horizontal: 0.12)
        viewport.save(key: key, in: defaults)
        let saved = ReaderViewport.saved(key: key, in: defaults)
        XCTAssertEqual(saved?.position.page, 3); XCTAssertEqual(saved?.position.scroll, 0.42)
        XCTAssertEqual(saved?.position.zoom, 1.8); XCTAssertEqual(saved?.horizontal, 0.12)
        for (owner, paper) in [("https://fixture.test\naccount:two", "paper"), ("https://fixture.test\naccount:one", "other"), ("https://other.test\naccount:one", "paper")] {
            XCTAssertNil(ReaderViewport.saved(key: ReaderViewport.key(owner: owner, paperID: paper), in: defaults))
        }
        for invalid in [ReadingPosition(page: 0, scroll: 0, zoom: 1), ReadingPosition(page: 1, scroll: -1, zoom: 1), ReadingPosition(page: 1, scroll: 0, zoom: .nan), ReadingPosition(page: 1, scroll: 0, zoom: 4)] {
            let value = ReaderViewport(position: invalid, horizontal: 0)
            XCTAssertFalse(value.isValid); value.save(key: "invalid", in: defaults)
            XCTAssertNil(defaults.data(forKey: "invalid"))
        }
        defaults.set(Data("invalid".utf8), forKey: "bad-data")
        XCTAssertNil(ReaderViewport.saved(key: "bad-data", in: defaults))
    }
    func testReaderRestoresSavedViewportAfterAuthorizationAndFollowTakesPrecedence() async throws {
        let suite = "reader-viewport-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let service = ReaderFixtureService()
        service.pdfData = try XCTUnwrap(document(withContent: true).dataRepresentation())
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = ReaderViewport.key(owner: service.storageIdentity, paperID: "p")
        let saved = ReaderViewport(position: ReadingPosition(page: 2, scroll: 0.3, zoom: 1.8), horizontal: 0.1)
        saved.save(key: key, in: defaults)
        for following in [false, true] {
            let session = PaperSession(api: service, paperID: "p", storageDirectory: directory)
            let reader = PaperReaderController(api: SpaceAPI(origin: URL(string: "https://example.invalid")!, cookies: []), paperID: "p", followID: following ? "presenter" : nil, storageDirectory: directory, session: session, preferences: defaults)
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 1032, height: 1376))
            window.rootViewController = reader; window.makeKeyAndVisible()
            for _ in 0..<200 where reader.pdfView.document == nil { try await Task.sleep(nanoseconds: 10_000_000) }
            XCTAssertNotNil(reader.pdfView.document)
            reader.view.layoutIfNeeded()
            let zoom = reader.pdfView.scaleFactor / reader.pdfView.scaleFactorForSizeToFit
            XCTAssertEqual(zoom, following ? 1 : 1.8, accuracy: 0.02)
            XCTAssertTrue(session.annotations.isEmpty)
            if following {
                reader.saveViewport()
                XCTAssertEqual(ReaderViewport.saved(key: key, in: defaults)?.position.scroll, 0.3, "Following must not overwrite the independent reading position")
            }
            reader.invalidateAccess(); window.isHidden = true
            saved.save(key: key, in: defaults)
        }
    }
    func testToolbarPositionPreferenceDefaultsAndRestores() {
        let suite = "reader-position-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(ReaderToolbarPosition.saved(in: defaults), .bottom)
        let api = SpaceAPI(origin: URL(string: "https://example.invalid")!, cookies: [])
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let reader = PaperReaderController(api: api, paperID: "p", storageDirectory: directory, preferences: defaults)
        for position in ReaderToolbarPosition.allCases {
            reader.setToolbarPosition(position)
            XCTAssertFalse(reader.isViewLoaded, "Saving a setting must not open a document")
            XCTAssertEqual(ReaderToolbarPosition.saved(in: defaults), position)
            let reopened = PaperReaderController(api: api, paperID: "other", storageDirectory: directory, preferences: defaults)
            XCTAssertEqual(reopened.toolbarPosition, position)
        }
        defaults.set("invalid", forKey: ReaderToolbarPosition.preferenceKey)
        XCTAssertEqual(ReaderToolbarPosition.saved(in: defaults), .bottom)
    }
    func testToolbarAllEdgesResizeAndReachMoreWithoutChangingInk() async throws {
        let suite = "reader-position-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let service = ReaderFixtureService()
        service.pdfData = try XCTUnwrap(document(withContent: true).dataRepresentation())
        service.annotations = [PaperAnnotation(id: "existing", page: 1, type: .pen, color: "#0033cc", points: [[0.2, 0.3], [0.4, 0.5]], size: 0.25)]
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = PaperSession(api: service, paperID: "p", storageDirectory: directory)
        let reader = PaperReaderController(api: SpaceAPI(origin: URL(string: "https://example.invalid")!, cookies: []), paperID: "p", storageDirectory: directory, session: session, preferences: defaults)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 1032, height: 1376))
        window.rootViewController = reader; window.makeKeyAndVisible()
        defer { reader.invalidateAccess(); window.isHidden = true }
        for _ in 0..<200 where reader.pdfView.document == nil { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertNotNil(reader.pdfView.document)
        reader.resizeInk(-1); reader.setTool(.question)
        let annotations = session.annotations
        func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
        let strip = try XCTUnwrap(descendants(reader.view).first { $0.accessibilityIdentifier == "paper.toolbar" } as? ReaderControlStrip)
        for (name, size) in [("portrait", CGSize(width: 1032, height: 1376)), ("landscape", CGSize(width: 1376, height: 1032)), ("compact", CGSize(width: 390, height: 600))] {
            window.frame.size = size; reader.view.frame.size = size
            for position in ReaderToolbarPosition.allCases {
                reader.setToolbarPosition(position); reader.view.setNeedsLayout(); reader.view.layoutIfNeeded()
                let safe = reader.view.safeAreaLayoutGuide.layoutFrame
                switch position {
                case .bottom:
                    XCTAssertEqual(strip.frame.maxY, safe.maxY, accuracy: 0.1)
                    XCTAssertEqual(reader.pdfView.frame.maxY, strip.frame.minY, accuracy: 0.1)
                case .top:
                    XCTAssertEqual(strip.frame.minY, safe.minY, accuracy: 0.1)
                    XCTAssertEqual(reader.pdfView.frame.minY, strip.frame.maxY, accuracy: 0.1)
                case .left:
                    XCTAssertEqual(strip.frame.minX, safe.minX, accuracy: 0.1)
                    XCTAssertEqual(reader.pdfView.frame.minX, strip.frame.maxX, accuracy: 0.1)
                case .right:
                    XCTAssertEqual(strip.frame.maxX, safe.maxX, accuracy: 0.1)
                    XCTAssertEqual(reader.pdfView.frame.maxX, strip.frame.minX, accuracy: 0.1)
                }
                XCTAssertEqual(position.isVertical ? strip.frame.width : strip.frame.height, 52, accuracy: 0.1)
                XCTAssertLessThanOrEqual(position.isVertical ? strip.contentSize.width : strip.contentSize.height, 52.1)
                let more = try XCTUnwrap(descendants(strip).first { $0.accessibilityIdentifier == "reader.more" } as? UIButton)
                let settings = try XCTUnwrap(more.menu?.children.compactMap { $0 as? UIMenu }.first { $0.title == "Toolbar position" })
                XCTAssertEqual(settings.children.count, 4)
                XCTAssertEqual(settings.children.compactMap { $0 as? UIAction }.first { $0.state == .on }?.title, position.rawValue.capitalized)
                strip.scrollRectToVisible(more.convert(more.bounds, to: strip), animated: false)
                XCTAssertGreaterThan(more.convert(more.bounds, to: strip).intersection(strip.bounds).height, 40)
                XCTAssertGreaterThan(more.convert(more.bounds, to: strip).intersection(strip.bounds).width, 40)
                XCTAssertEqual(session.annotations, annotations)
                XCTAssertEqual(reader.tool, .question); XCTAssertEqual(reader.thickness, 0.75)
                let image = UIGraphicsImageRenderer(bounds: reader.view.bounds).image { _ in reader.view.drawHierarchy(in: reader.view.bounds, afterScreenUpdates: true) }
                let attachment = XCTAttachment(image: image); attachment.name = "reader-position-" + name + "-" + position.rawValue; attachment.lifetime = .keepAlways; add(attachment)
            }
        }
    }
    func testExactControllerInitializerAndNativeContinuousView() {
        let api = SpaceAPI(origin: URL(string: "https://example.invalid")!, cookies: [])
        let controller = PaperReaderController(api: api, paperID: "fixture", followID: "presenter", storageDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        // Constructing the controller must not perform a network request. View loading intentionally omitted.
        XCTAssertFalse(controller.isViewLoaded)
        let keys = controller.keyCommands ?? []
        for input in ["p", "q", "h", "v", "t", "e", "z", "+", "-", "0", UIKeyCommand.inputUpArrow, UIKeyCommand.inputDownArrow] {
            XCTAssertTrue(keys.contains { $0.input == input }, input)
        }
        XCTAssertTrue(keys.contains { $0.input == "z" && $0.modifierFlags == [.command, .shift] })
        XCTAssertFalse(controller.isViewLoaded)
    }
}

@MainActor private final class ReaderFixtureService: PaperService {
    let storageIdentity = "reader-test"
    var annotations: [PaperAnnotation] = []
    var pdfData = Data()
    func metadata(paperID: String) async throws -> PaperMetadata {
        PaperMetadata(paper: PaperInfo(id: paperID, title: "Fixture", spaceID: "s"), annotations: annotations, revision: 1, canEdit: true, guest: false, presenters: [])
    }
    func pdf(paperID: String) async throws -> Data { pdfData }
    func save(paperID: String, revision: Int, annotations: [PaperAnnotation]) async throws -> Int { revision + 1 }
}

@MainActor private final class ReaderOverlayFixture: NSObject, @preconcurrency PDFPageOverlayViewProvider {
    let target: PDFPage
    let shown: XCTestExpectation
    var overlay: ReaderPageView?
    private var fulfilled = false
    init(target: PDFPage, shown: XCTestExpectation) { self.target = target; self.shown = shown }
    func pdfView(_ view: PDFView, overlayViewFor page: PDFPage) -> UIView? {
        let result = ReaderPageView(frame: .zero)
        if page === target { overlay = result }
        return result
    }
    func pdfView(_ view: PDFView, willDisplayOverlayView overlayView: UIView, for page: PDFPage) {
        if page === target && !fulfilled { fulfilled = true; shown.fulfill() }
    }
}

private struct ReaderPixels {
    let width: Int
    let height: Int
    let size: CGSize
    private let bytes: [UInt8]
    init(_ image: UIImage) throws {
        let cg = try XCTUnwrap(image.cgImage)
        width = cg.width; height = cg.height; size = image.size
        var data = [UInt8](repeating: 255, count: width * height * 4)
        let w = width, h = height
        try data.withUnsafeMutableBytes { storage in
            let context = try XCTUnwrap(CGContext(data: storage.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                                 space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
            context.setFillColor(UIColor.white.cgColor); context.fill(CGRect(x: 0, y: 0, width: w, height: h))
            context.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        bytes = data
    }
    var digest: String { SHA256.hash(data: Data(bytes)).map { String(format: "%02x", $0) }.joined() }
    func pixel(x: Int, y: Int) -> [CGFloat] {
        let i = (min(height - 1, max(0, y)) * width + min(width - 1, max(0, x))) * 4
        return (0..<4).map { CGFloat(bytes[i + $0]) / 255 }
    }
    func sample(_ p: CGPoint) -> [CGFloat] { pixel(x: Int(p.x * CGFloat(width) / size.width), y: Int(p.y * CGFloat(height) / size.height)) }
    func isWhite(at p: CGPoint) -> Bool { sample(p).prefix(3).allSatisfy { $0 > 0.96 } }
    func ink(near point: CGPoint, radius: CGFloat) -> Int {
        var count = 0
        for y in -Int(ceil(radius))...Int(ceil(radius)) {
            for x in -Int(ceil(radius))...Int(ceil(radius)) {
                if !isWhite(at: CGPoint(x: point.x + CGFloat(x), y: point.y + CGFloat(y))) { count += 1 }
            }
        }
        return count
    }
}

private struct ReaderOriginalAnnotation: Equatable {
    var bounds: CGRect
    var type: String?
    var contents: String?
    var color: [CGFloat]?
    var interior: [CGFloat]?
    var shouldDisplay: Bool
    var shouldPrint: Bool
}
private struct ReaderSourceSnapshot: Equatable {
    var box: CGRect
    var mediaBox: CGRect
    var rotation: Int
    var userUnit: CGFloat
    var text: String?
    var annotations: [ReaderOriginalAnnotation]
    var appearance: String
}
