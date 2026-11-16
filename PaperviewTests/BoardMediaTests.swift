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
