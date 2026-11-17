import XCTest
import UIKit
@testable import Paperview

@MainActor final class BoardMediaTests: XCTestCase {
    func testEmbeddedMediaAcceptsOnlyMatchingBase64Data() throws {
        let data = Data([0, 1, 2, 3])
        let asset = BoardAsset(mimeType: "video/mp4", dataURL: "data:video/mp4;base64," + data.base64EncodedString())
        XCTAssertEqual(try BoardVisualStore.embedded(asset, mime: "video/mp4"), data)
        XCTAssertThrowsError(try BoardVisualStore.embedded(asset, mime: "image/gif"))
    }
    func testRemoteAndMalformedSourcesNeverBecomeMediaRequests() {
        for source in ["https://example.invalid/movie.mp4", "file:///tmp/movie.mp4", "data:video/mp4;base64,%%%", "data:text/html;base64,AAAA", "data:video/mp4,hello"] {
            XCTAssertThrowsError(try BoardVisualStore.embedded(BoardAsset(mimeType: "video/mp4", dataURL: source), mime: "video/mp4"))
        }
    }
    func testRasterAdmissionRejectsHugeAndNonfiniteTargets() {
        for size in [CGSize(width: CGFloat.infinity, height: 1), CGSize(width: 0, height: 20), CGSize(width: 8193, height: 1), CGSize(width: 4000, height: 4000)] {
            XCTAssertThrowsError(try BoardVisualStore.dimensions(size))
        }
    }
    func testRasterAdmissionAccountsForTwoSimultaneousBuffers() throws {
        let size = try BoardVisualStore.dimensions(CGSize(width: 4000, height: 3000))
        XCTAssertEqual(Int(size.width * size.height) * 2, BoardVisualStore.pixelBudget)
        XCTAssertThrowsError(try BoardVisualStore.dimensions(CGSize(width: 4000.01, height: 3000)))
        XCTAssertEqual(try BoardVisualStore.dimensions(CGSize(width: 20.2, height: 30.1)), CGSize(width: 21, height: 31))
    }
}

@MainActor private final class MediaBoardService: BoardService {
    var storageIdentity = "synthetic-media-owner"
    var remote = SpaceSnapshot(space: SpaceSummary(id: "s", title: "Synthetic", visibility: "private", creatorId: "one", revision: 1, member: true, shared: false, createdAt: 0), board: .empty, creators: [:], papers: [])
    func space(id: String) async throws -> SpaceSnapshot { remote }
    func saveBoard(id: String, revision: Int, board: BoardDocument) async throws -> Int {
        remote.board = board; remote.space.revision += 1; return remote.space.revision
    }
}

extension BoardMediaTests {
    func testNewAndEditedTextUsesAuthorizedDraftLayoutBeforeUpload() async throws {
        let service = MediaBoardService(), directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:directory) }
        let session = BoardSession(api:service,spaceID:"s",storageDirectory:directory,validate:{ _ in })
        try await session.open()
        let store = BoardVisualStore(api:SpaceAPI(origin:URL(string:"http://127.0.0.1:1")!,cookies:[]),session:session)
        defer { store.dispose() }
        var draft = BoardElement(kind:.text); draft.text = "# New **local** text $x^2$"
        let size = try XCTUnwrap(store.measureText(for:draft,constrainedTo:240))
        XCTAssertGreaterThan(size.height,0)
        try session.edit(BoardDocument(elements:[draft]))
        store.invalidate(); draft.text = "An edited draft before saving"
        XCTAssertNotNil(store.measureText(for:draft,constrainedTo:120))
        var rendered = false
        _ = UIGraphicsImageRenderer(size:CGSize(width:240,height:100)).image {
            rendered = store.drawText(for:draft,in:$0.cgContext,rect:CGRect(x:0,y:0,width:240,height:100))
        }
        XCTAssertTrue(rendered)
        session.invalidateAccess()
        XCTAssertNil(store.measureText(for:draft,constrainedTo:240))
    }
    func testPreviewRejectsDifferentPayloadUnderReusedAssetID() async throws {
        let service = MediaBoardService(), directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:directory) }
        var movie = BoardElement(kind:.image,id:"movie"); movie.assetId = "asset"
        let old = BoardAsset(mimeType:"video/mp4",dataURL:"data:video/mp4;base64,AAECAw==")
        let next = BoardAsset(mimeType:"video/mp4",dataURL:"data:video/mp4;base64,BAUGBw==")
        service.remote.board = BoardDocument(elements:[movie],assets:["asset":old])
        let session = BoardSession(api:service,spaceID:"s",storageDirectory:directory,validate:{ _ in })
        try await session.open()
        let store = BoardVisualStore(api:SpaceAPI(origin:URL(string:"http://127.0.0.1:1")!,cookies:[]),session:session)
        defer { store.dispose() }
        let url = try store.videoURL(for:movie)
        service.remote.board.assets["asset"] = next; service.remote.space.revision += 1
        await session.refresh(); store.invalidate()
        let before = try FileManager.default.contentsOfDirectory(atPath:url.deletingLastPathComponent().path)
        XCTAssertNil(store.preview(for:movie,asset:old,targetSize:CGSize(width:100,height:100)))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath:url.deletingLastPathComponent().path),before)
    }
    func testImmutableFingerprintAndPlayableFileSurviveRevisionAndSuspend() async throws {
        let service = MediaBoardService()
        var movie = BoardElement(kind: .image, id: "movie")
        movie.assetId = "asset"
        let asset = BoardAsset(mimeType: "video/mp4", dataURL: "data:video/mp4;base64," + Data([0, 1, 2, 3]).base64EncodedString())
        service.remote.board = BoardDocument(elements: [movie], assets: ["asset": asset])
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = BoardSession(api: service, spaceID: "s", storageDirectory: directory, validate: { _ in })
        try await session.open()
        let api = SpaceAPI(origin: URL(string: "http://127.0.0.1:1")!, cookies: [])
        let store = BoardVisualStore(api: api, session: session)
        defer { store.dispose() }
        let url = try store.videoURL(for: movie)
        XCTAssertEqual(store.fingerprintCount, 1)
        for _ in 0..<20 { XCTAssertEqual(try store.videoURL(for: movie), url) }
        store.invalidate()
        XCTAssertEqual(store.fingerprintCount, 1)
        service.remote.space.revision += 1
        await session.refresh()
        store.invalidate()
        XCTAssertEqual(try store.videoURL(for: movie), url)
        XCTAssertEqual(store.fingerprintCount, 1)
        store.suspend()
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        store.resume()
        XCTAssertEqual(try store.videoURL(for: movie), url)
        service.remote.board.assets["asset"] = BoardAsset(mimeType: "video/mp4", dataURL: "data:video/mp4;base64,BAUGBw==")
        service.remote.space.revision += 1
        await session.refresh()
        store.invalidate()
        XCTAssertEqual(store.fingerprintCount, 2)
        XCTAssertNotEqual(try store.videoURL(for: movie), url)
        XCTAssertFalse(FileManager.default.fileExists(atPath:url.path),"Removed source files must release the transient source budget")
        store.dispose()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }
}


extension BoardMediaTests {
    func testPreviewResolutionBucketsSurviveFractionalPinchAndCapExtremeZoom() throws {
        let first = try BoardVisualStore.previewSize(CGSize(width: 400, height: 300))
        for factor in [1.001, 1.01, 1.05, 1.1] {
            XCTAssertEqual(try BoardVisualStore.previewSize(CGSize(width: 400 * factor, height: 300 * factor)), first)
        }
        let extreme = try BoardVisualStore.previewSize(CGSize(width: 80_000_000, height: 60_000_000))
        XCTAssertLessThanOrEqual(extreme.width, 8192); XCTAssertLessThanOrEqual(extreme.height, 8192)
        XCTAssertLessThanOrEqual(extreme.width * extreme.height * 2, Double(BoardVisualStore.pixelBudget))
        XCTAssertThrowsError(try BoardVisualStore.previewSize(CGSize(width: CGFloat.infinity, height: 10)))
    }

    func testMoreThan64VisibleTextLayoutsSurviveMoveVersionAndMetadataUpdates() async throws {
        let service = MediaBoardService(), directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let elements = (0..<100).map { index -> BoardElement in
            var e = BoardElement(kind: .text, id: "t-\(index)"); e.text = "**Synthetic** text \(index)"; e.width = 200; e.height = 60
            return e
        }
        service.remote.board = BoardDocument(elements: elements)
        let session = BoardSession(api: service, spaceID: "s", storageDirectory: directory, validate: { _ in })
        try await session.open()
        let store = BoardVisualStore(api: SpaceAPI(origin: URL(string: "http://127.0.0.1:1")!, cookies: []), session: session)
        defer { store.dispose() }
        for e in elements { XCTAssertNotNil(store.measureText(for: e, constrainedTo: 200)) }
        XCTAssertEqual(store.textLayoutCount, 100)
        for _ in 0..<3 { for var e in elements {
            e.x += 10; e.y += 20; e.angle = 0.7; e.z += 100; e.version += 1
            XCTAssertNotNil(store.measureText(for: e, constrainedTo: 200))
        } }
        XCTAssertEqual(store.textLayoutCount, 100)
        let indexed = store.documentIndexCount
        service.remote.space.revision += 1
        await session.refresh()
        XCTAssertNotNil(store.measureText(for: elements[0], constrainedTo: 200))
        XCTAssertEqual(store.documentIndexCount, indexed, "Revision freshness must not reindex the full board during paint")
        store.invalidate()
        for e in elements { XCTAssertNotNil(store.measureText(for: e, constrainedTo: 200)) }
        XCTAssertEqual(store.textLayoutCount, 100)
    }

    func testEmbeddedImageDecodeSurvivesUnrelatedAssetsAndRejectsReusedSource() async throws {
        func asset(_ color: UIColor) throws -> BoardAsset {
            let image = UIGraphicsImageRenderer(size: CGSize(width: 32, height: 32)).image { output in
                color.setFill(); output.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
            }
            return BoardAsset(mimeType: "image/png", dataURL: "data:image/png;base64," + (try XCTUnwrap(image.pngData())).base64EncodedString())
        }
        let red = try asset(.red), blue = try asset(.blue)
        var element = BoardElement(kind: .image); element.assetId = "image"; element.width = 64; element.height = 64
        let item = BoardRenderItem(element: element, points: nil), renderer = BoardRenderer()
        func frame(_ assets: [String: BoardAsset]) -> UIImage {
            UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64)).image { output in
                renderer.draw([item], board: BoardDocument(assets: assets), in: output.cgContext, zoom: 1)
            }
        }
        renderer.updateAssets(["image": red])
        let decoded = expectation(description: "bounded embedded image decoded")
        renderer.onChange = { decoded.fulfill() }
        _ = frame(["image": red]); await fulfillment(of: [decoded], timeout: 5); renderer.onChange = nil
        XCTAssertEqual(renderer.imageDecodeCount, 1)
        renderer.updateAssets(["image": red, "unrelated": blue])
        for _ in 0..<20 { _ = frame(["image": red, "unrelated": blue]) }
        XCTAssertEqual(renderer.imageDecodeCount, 1)
        renderer.updateAssets([:]); renderer.updateAssets(["image": blue])
        let replaced = expectation(description: "reused ID decoded from new immutable source")
        renderer.onChange = { replaced.fulfill() }
        _ = frame(["image": blue]); await fulfillment(of: [replaced], timeout: 5); renderer.onChange = nil
        XCTAssertEqual(renderer.imageDecodeCount, 2)
        let cg = try XCTUnwrap(frame(["image": blue]).cgImage)
        var bytes = [UInt8](repeating: 0, count: 64 * 64 * 4)
        let c = try XCTUnwrap(CGContext(data: &bytes, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 64 * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        c.draw(cg, in: CGRect(x: 0, y: 0, width: 64, height: 64))
        let middle = (32 * 64 + 32) * 4
        XCTAssertGreaterThan(bytes[middle + 2], 240); XCTAssertLessThan(bytes[middle], 20)
    }
}
