import XCTest
import UIKit
import PDFKit
import PencilKit
@testable import Paperview

@MainActor final class CreatorTests: XCTestCase {
    func testHostedCreatorSurvivesRefreshAndDismissesOnAuthorityOrDeletion() async throws {
        for reason in ["principal", "access", "deleted"] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let service = CreatorRefreshService()
            let session = PaperSession(api: service, paperID: "p", storageDirectory: directory)
            let reader = PaperReaderController(api: SpaceAPI(origin: URL(string: "https://example.invalid")!, cookies: []),
                                              paperID: "p", storageDirectory: directory, session: session)
            let window = UIWindow(frame: UIScreen.main.bounds)
            window.rootViewController = reader; window.makeKeyAndVisible()
            defer { window.isHidden = true }
            reader.loadViewIfNeeded()
            for _ in 0..<100 {
                if reader.pdfView.document != nil { break }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            XCTAssertNotNil(reader.pdfView.document)
            reader.showCreator(id: "mark")
            for _ in 0..<100 {
                if reader.presentedViewController?.isBeingPresented == false { break }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            let alert = try XCTUnwrap(reader.presentedViewController as? UIAlertController)
            for _ in 0..<3 { await session.refresh() }
            XCTAssertTrue(reader.presentedViewController === alert, "Ordinary polling must not dismiss creator info")
            service.value.creators["mark"] = AnnotationCreator(name: "Acknowledged creator", kind: .agent)
            await session.refresh()
            XCTAssertTrue(reader.presentedViewController === alert)
            XCTAssertEqual(alert.message, "Acknowledged creator (agent)")
            switch reason {
            case "principal": service.value.selfID = "different-principal"
            case "access": service.denied = true
            default: service.value.annotations = []
            }
            await session.refresh()
            for _ in 0..<100 {
                if reader.presentedViewController == nil { break }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            XCTAssertNil(reader.presentedViewController, "Must dismiss on \(reason)")
        }
    }
    func testTapCounterAllowsReadonlyWithoutDrawingSerialization() async {
        let overlay = ReaderPageView(frame: .zero)
        XCTAssertFalse(overlay.editingEnabled)
        let recognizer = ReaderLinkRecognizer(target: nil, action: nil)
        var reads = 0
        recognizer.snapshot = { reads += 1; return [1: overlay.drawingChangeCount] }
        let activated = expectation(description: "Unchanged read-only tap")
        recognizer.tapped = { _, _ in activated.fulfill() }
        recognizer.finishTap(at: .zero, type: .direct, initial: [1: 0])
        await fulfillment(of: [activated], timeout: 1)
        XCTAssertEqual(reads, 1)
        XCTAssertEqual(overlay.drawingChangeCount, 0)
    }
    func testDeferredTapCancelledByFinalLassoChange() async {
        let overlay = ReaderPageView(frame: .zero)
        let recognizer = ReaderLinkRecognizer(target: nil, action: nil)
        recognizer.snapshot = { [1: overlay.drawingChangeCount] }
        let activated = expectation(description: "Changed drawing cannot activate creator or link")
        activated.isInverted = true
        recognizer.tapped = { _, _ in activated.fulfill() }
        recognizer.finishTap(at: .zero, type: .indirectPointer, initial: [1: 0])
        overlay.noteDrawingChange()
        await fulfillment(of: [activated], timeout: 0.1)
        XCTAssertEqual(overlay.drawingChangeCount, 1)
    }
    func testUnchangedCounterStillActivatesOriginalPDFLink() async {
        let document = PDFDocument()
        let page = PDFPage()
        document.insert(page, at: 0)
        let pdfView = PDFView(); pdfView.document = document
        let link = PDFAnnotation(bounds: CGRect(x: 10, y: 10, width: 100, height: 20), forType: .link, withProperties: nil)
        let url = URL(string: "https://example.com/paper")!
        link.action = PDFActionURL(url: url); page.addAnnotation(link)
        let recognizer = ReaderLinkRecognizer(target: nil, action: nil)
        recognizer.snapshot = { [1: 0] }
        let opened = expectation(description: "Original PDF link opens once")
        recognizer.tapped = { _, type in
            XCTAssertTrue(ReaderLinks.allows(type, tool: .pen, editing: false))
            XCTAssertTrue(ReaderLinks.activate(link, in: pdfView) { target in
                XCTAssertEqual(target, url); opened.fulfill()
            })
        }
        recognizer.finishTap(at: .zero, type: .direct, initial: [1: 0])
        await fulfillment(of: [opened], timeout: 1)
    }
    func testOnlyUserDrawingChangesIncrementCounter() {
        let overlay = ReaderPageView(frame: .zero)
        overlay.applying = true
        overlay.noteDrawingChange()
        XCTAssertEqual(overlay.drawingChangeCount, 0)
        overlay.applying = false
        overlay.active = true // Delegate callbacks during a live contact must still count.
        overlay.noteDrawingChange()
        overlay.noteDrawingChange()
        XCTAssertEqual(overlay.drawingChangeCount, 2)
    }
    private func stroke(_ transform: CGAffineTransform = .identity) -> PKStroke {
        let points = [CGPoint(x: 10, y: 20), CGPoint(x: 100, y: 20)].enumerated().map { i, point in
            PKStrokePoint(location: point, timeOffset: Double(i), size: CGSize(width: 4, height: 4), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        }
        return PKStroke(ink: PKInk(.pen, color: .blue), path: PKStrokePath(controlPoints: points, creationDate: Date(timeIntervalSince1970: 1)), transform: transform, mask: nil)
    }
    private func overlay() -> ReaderPageView {
        let view = ReaderPageView(frame: CGRect(x: 0, y: 0, width: 400, height: 600))
        view.layoutIfNeeded()
        let value = PaperAnnotation(id: "original-id", page: 1, type: .question, color: "#ff2d55")
        view.values = [value]
        view.canvas.drawing = PKDrawing(strokes: [stroke()])
        view.baseline = view.canvas.drawing.strokes.map(ReaderInk.archive)
        return view
    }
    func testRenderedPathNotBoundingBoxAndInspectionDoesNotMutate() throws {
        let view = overlay()
        let before = view.canvas.drawing.strokes
        let baseline = view.baseline
        let values = view.values
        XCTAssertEqual(view.annotationID(at: CGPoint(x: 50, y: 20)), "original-id")
        XCTAssertNil(view.annotationID(at: CGPoint(x: 50, y: 50)))
        let after = view.canvas.drawing.strokes
        XCTAssertEqual(before.count, after.count)
        for (a, b) in zip(before, after) {
            XCTAssertEqual(a.transform, b.transform)
            XCTAssertEqual(a.randomSeed, b.randomSeed)
            XCTAssertEqual(a.path.count, b.path.count)
            for i in a.path.indices {
                XCTAssertEqual(a.path[i].location, b.path[i].location)
                XCTAssertEqual(a.path[i].size, b.path[i].size)
                XCTAssertEqual(a.path[i].force, b.path[i].force)
            }
        }
        XCTAssertEqual(values, view.values)
        XCTAssertFalse(view.active)
        XCTAssertFalse(view.eraseContact)
        XCTAssertTrue(view.erasedText.isEmpty)
        XCTAssertEqual(view.baseline, baseline)
    }
    func testTransformedStrokeKeepsOriginalID() {
        let view = overlay()
        let transform = CGAffineTransform(a: 0, b: 2, c: -2, d: 0, tx: 200, ty: 50)
        view.canvas.drawing = view.canvas.drawing.transformed(using: transform)
        XCTAssertEqual(view.annotationID(at: CGPoint(x: 160, y: 150)), "original-id")
        XCTAssertNil(view.annotationID(at: CGPoint(x: 50, y: 20)))
    }
    func testTextUsesRenderedRotatedLabelBounds() {
        let view = overlay()
        let label = UILabel(frame: CGRect(x: 0, y: 0, width: 100, height: 25))
        label.accessibilityIdentifier = "text-id"
        label.transform = CGAffineTransform(rotationAngle: .pi / 2)
        label.center = CGPoint(x: 200, y: 200)
        view.textLayer.addSubview(label)
        view.textValues["text-id"] = PaperAnnotation(id: "text-id", page: 1, type: .text, color: "#007aff")
        XCTAssertEqual(view.annotationID(at: label.convert(CGPoint(x: 90, y: 10), to: view)), "text-id")
        XCTAssertNil(view.annotationID(at: label.convert(CGPoint(x: 110, y: 10), to: view)))
        label.isHidden = true
        XCTAssertNil(view.annotationID(at: CGPoint(x: 200, y: 200)))
    }
    func testCropRotationUserUnitAndZoomOverlayGeometry() throws {
        for rotation in [0, 90, 180, 270] {
            let objects = ["<< /Type /Catalog /Pages 2 0 R >>", "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
                           "<< /Type /Page /Parent 2 0 R /MediaBox [10 20 610 820] /CropBox [30 40 580 780] /Rotate \(rotation) /UserUnit 2 /Resources << >> >>"]
            var pdf = "%PDF-1.7\n", offsets = [0]
            for (index, object) in objects.enumerated() {
                offsets.append(pdf.utf8.count)
                pdf += "\(index + 1) 0 obj\n\(object)\nendobj\n"
            }
            let xref = pdf.utf8.count
            pdf += "xref\n0 4\n0000000000 65535 f \n"
            for offset in offsets.dropFirst() { pdf += String(format: "%010d 00000 n \n", offset) }
            pdf += "trailer\n<< /Size 4 /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF"
            let document = try XCTUnwrap(PDFDocument(data: Data(pdf.utf8)))
            let page = try XCTUnwrap(document.page(at: 0))
            let geometry = ReaderGeometry(page: page)
            for zoom in [CGFloat(0.5), CGFloat(1), CGFloat(3)] {
                let size = CGSize(width: geometry.displaySize.width * zoom, height: geometry.displaySize.height * zoom)
                let view = ReaderPageView(frame: CGRect(origin: .zero, size: size)); view.layoutIfNeeded()
                let value = PaperAnnotation(id: "rotated", page: 1, type: .highlight, color: "#ffcc00", points: [[0.2, 0.3], [0.8, 0.3]], size: 4)
                let rendered = try XCTUnwrap(ReaderInk.stroke(value, geometry: geometry, size: size, native: nil))
                view.values = [value]; view.canvas.drawing = PKDrawing(strokes: [rendered])
                view.baseline = view.canvas.drawing.strokes.map(ReaderInk.archive)
                let before = page.bounds(for: .cropBox)
                XCTAssertEqual(view.annotationID(at: geometry.canvas(CGPoint(x: 0.5, y: 0.3), size: size)), "rotated")
                XCTAssertEqual(before, page.bounds(for: .cropBox))
                XCTAssertEqual(document.pageCount, 1)
                XCTAssertTrue(page.annotations.isEmpty)
            }
        }
    }
    func testKindsAndRequiredNetworkMapOutsidePortableSchema() throws {
        let json = #"{"paper":{"id":"p","title":"Paper","space_id":"s"},"annotations":[],"revision":1,"can_edit":false,"guest":true,"presenters":[],"creators":{"a":{"name":"Researcher","kind":"human"},"b":{"name":"Worker","kind":"agent"},"c":{"name":null,"kind":"guest"},"d":{"name":null,"kind":"historical"},"e":{"name":null,"kind":"unknown"}}}"#
        let data = Data(json.utf8)
        var metadata = try JSONDecoder().decode(PaperMetadata.self, from: data)
        XCTAssertEqual(metadata.creators["a"]?.description, "Researcher")
        XCTAssertEqual(metadata.creators["b"]?.description, "Worker (agent)")
        XCTAssertEqual(metadata.creators["c"]?.description, "Guest")
        XCTAssertEqual(metadata.creators["d"]?.description, "Unknown (historical)")
        XCTAssertEqual(metadata.creators["e"]?.description, "Unknown")
        XCTAssertNil(metadata.creators["unrelated-id"])
        metadata.annotations = [PaperAnnotation(id: "old", page: 1, type: .pen, color: "#007aff")]
        XCTAssertEqual(metadata.creatorDescription(for: "old"), "Unknown")
        XCTAssertEqual(metadata.creatorDescription(for: "local-new"), "Unsaved annotation: creator unavailable")
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "creators")
        XCTAssertThrowsError(try JSONDecoder().decode(PaperMetadata.self, from: JSONSerialization.data(withJSONObject: object)))
        let annotation = PaperAnnotation(id: "a", page: 1, type: .pen, color: "#007aff")
        let portable = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(annotation)) as? [String: Any])
        XCTAssertNil(portable["creators"])
        XCTAssertNil(portable["creator"])
        XCTAssertNil(portable["groupId"])
    }
}

@MainActor private final class CreatorRefreshService: PaperService {
    let storageIdentity = "creator-refresh-fixture"
    var denied = false
    var value = PaperMetadata(paper: PaperInfo(id: "p", title: "Fixture", spaceID: "s"),
                              annotations: [PaperAnnotation(id: "mark", page: 1, type: .text, color: "#007aff", x: 0.2, y: 0.2, text: "Note")],
                              revision: 1, canEdit: false, guest: false, presenters: [], selfID: "principal",
                              creators: ["mark": AnnotationCreator(name: "Original creator", kind: .human)])
    func metadata(paperID: String) async throws -> PaperMetadata {
        if denied { throw PaperError.unauthorized }; return value
    }
    func pdf(paperID: String) async throws -> Data {
        UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 400, height: 600)).pdfData { $0.beginPage() }
    }
    func save(paperID: String, revision: Int, annotations: [PaperAnnotation]) async throws -> Int {
        XCTFail("Inspection must never save annotations"); return revision
    }
}
