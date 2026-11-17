import UIKit
import PDFKit
import AVFoundation
import ImageIO
import CryptoKit
import CoreImage

/// Authorized, transient board resources. No remote URL supplied by an element is opened.
@MainActor final class BoardVisualStore: BoardVisualProvider {
    enum Failure: Error, LocalizedError {
        case unsupported, oversized, invalidMedia
        var errorDescription: String? {
            switch self {
            case .unsupported: return "This media format cannot be previewed natively."
            case .oversized: return "Media exceeds the native preview resource limit."
            case .invalidMedia: return "The embedded media is invalid."
            }
        }
    }
    nonisolated static let pixelBudget = 24_000_000
    nonisolated static let sourceBudget = 64 * 1024 * 1024
    private let api: SpaceAPI
    private let session: BoardSession
    var onChange: (() -> Void)?
    var onError: ((Error) -> Void)?
    private var generation = 0
    private var revision: Int?
    private var stopped = false
    private var disposed = false
    private var tasks: [String: Task<Void, Never>] = [:]
    private var failures = Set<String>()
    private var reserved: [String: Int] = [:]
    private var videoFiles: [String: (url: URL, bytes: Int)] = [:]
    private struct Raster { var image: UIImage; var pixels: Int; var used: TimeInterval; var source: String }
    private var rasters: [String: Raster] = [:]
    private var papers: [String: (data: Data, count: Int)] = [:]
    private var text: [String: (signature: BoardTextLayout.Signature, width: CGFloat, layout: BoardTextLayout, used: TimeInterval)] = [:]
    private var paperIndex: [String: PaperInfo] = [:]
    private var latestPaperRaster: [String: String] = [:]
    private(set) var documentIndexCount = 0
    private(set) var textLayoutCount = 0
    private struct Movie { var elementID: String; var url: URL; var generator: AVAssetImageGenerator; var player: AVPlayer; var output: AVPlayerItemVideoOutput; var size: CGSize; var start: TimeInterval; var seen: TimeInterval }
    private var movies: [String: Movie] = [:]
    private var gifs: [String: (source: CGImageSource, frame: Int, next: TimeInterval, seen: TimeInterval, bytes: Int)] = [:]
    private let imageContext = CIContext(options: [.cacheIntermediates: false])
    private var timer: Timer?
    private var directory: URL?
    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    init(api: SpaceAPI, session: BoardSession) { self.api = api; self.session = session }

    private var elements: [String: BoardElement] = [:]
    private var fingerprints: [String: (asset: BoardAsset, digest: String)] = [:]
    private(set) var fingerprintCount = 0
    private var paperRevisions: [String: Int] = [:]

    private func stopDecoders() {
        movies.values.forEach { $0.player.pause(); $0.generator.cancelAllCGImageGeneration() }
        movies.removeAll(); gifs.removeAll()
        timer?.invalidate(); timer = nil
    }
    private func clearContent() {
        generation += 1
        tasks.values.forEach { $0.cancel() }; tasks.removeAll(); reserved.removeAll()
        stopDecoders()
        papers.removeAll(); rasters.removeAll(); text.removeAll(); failures.removeAll()
        videoFiles.removeAll(); elements.removeAll(); fingerprints.removeAll(); paperRevisions.removeAll()
        paperIndex.removeAll(); latestPaperRaster.removeAll()
        if let directory { try? FileManager.default.removeItem(at: directory) }; directory = nil
        revision = nil
    }
    func invalidate() {
        guard !disposed, session.authorized, let snapshot = session.snapshot else { clearContent(); return }
        // The journal's authorized local composition includes completed unsaved edits.
        let document = session.board
        elements = Dictionary(document.elements.filter { !$0.deleted }.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        documentIndexCount += 1
        paperIndex = Dictionary(snapshot.papers.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        let paperIDs = Set(paperIndex.keys)
        papers = papers.filter { paperIDs.contains($0.key) }
        let assets = document.assets
        fingerprints = fingerprints.filter { assets[$0.key] != nil }
        for (id, asset) in assets {
            if let cached = fingerprints[id], cached.asset == asset { continue }
            fingerprintCount += 1
            let digest = SHA256.hash(data: Data(asset.dataURL.utf8)).map { String(format: "%02x", $0) }.joined()
            fingerprints[id] = (asset, asset.mimeType + ":" + digest)
        }
        // Originals and playable files are immutable. A revision only makes PDF
        // annotation renders dirty; keep the authorized old raster until replaced.
        let valid = Set(elements.values.map { sourceKey($0) })
        for (key,file) in videoFiles where !valid.contains(key) {
            do {
                if FileManager.default.fileExists(atPath:file.url.path) { try FileManager.default.removeItem(at:file.url) }
                videoFiles.removeValue(forKey:key)
            } catch { report(error,key:"eviction:"+key) }
        }
        for (key, movie) in movies where !valid.contains(key) {
            movie.player.pause(); movie.generator.cancelAllCGImageGeneration(); movies.removeValue(forKey: key)
        }
        gifs = gifs.filter { valid.contains($0.key) }
        rasters = rasters.filter { valid.contains($0.value.source) }
        paperRevisions = paperRevisions.filter { rasters[$0.key] != nil }
        latestPaperRaster = latestPaperRaster.filter { valid.contains($0.key) && rasters[$0.value] != nil }
        revision = snapshot.space.revision
        // Moving/reordering/version bumps cannot change glyph layout.
        text = text.filter { entry in elements[entry.key].map { BoardTextLayout.Signature($0) == entry.value.signature } == true }
    }
    func suspend() {
        stopped = true; generation += 1
        tasks.values.forEach { $0.cancel() }; tasks.removeAll(); reserved.removeAll()
        stopDecoders()
    }
    func resume() { guard !disposed else { return }; stopped = false; invalidate(); onChange?() }
    func dispose() { disposed = true; stopped = true; clearContent() }

    private func checkAccess() -> Bool {
        guard !disposed, session.authorized, session.snapshot != nil else { clearContent(); return false }
        guard !stopped else { return false }
        if revision == nil { invalidate() }
        else if revision != session.snapshot?.space.revision {
            // Metadata/annotation freshness is independent of the active board.
            // The controller explicitly invalidates on document composition changes.
            revision = session.snapshot?.space.revision
            paperIndex = Dictionary((session.snapshot?.papers ?? []).map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        }
        return true
    }
    private func sourceKey(_ e: BoardElement) -> String {
        e.id + ":" + (e.paperId ?? "") + ":" + (e.paperView ?? "") + ":" + (e.assetId.flatMap { fingerprints[$0]?.digest } ?? "")
    }
    private func matches(_ e: BoardElement) -> Bool {
        guard let latest = elements[e.id], latest.paperId == e.paperId,
              latest.paperView == e.paperView, latest.assetId == e.assetId else { return false }
        // Old elements cannot express an asset payload change under a reused ID.
        // Require their complete snapshot value to remain current.
        return latest == e
    }
    private func current(_ e: BoardElement, key: String, token: Int) -> Bool {
        checkAccess() && token == generation && matches(e) && sourceKey(e) == key
    }
    func paperInfo(for element: BoardElement) -> PaperInfo? {
        guard checkAccess(), let id = element.paperId else { return nil }
        return paperIndex[id]
    }
    private func report(_ error: Error, key: String) { if failures.insert(key).inserted { onError?(error) } }
    private func reserve(_ pixels: Int, preserving: String? = nil) throws {
        guard pixels > 0, pixels <= Self.pixelBudget / 2 else { throw Failure.oversized }
        // Reserve both the pending decode and its composed result before allocating either.
        while rasters.values.reduce(0, { $0 + $1.pixels }) + reserved.values.reduce(0, +) + movies.values.reduce(0, { $0 + Int($1.size.width * $1.size.height) * 2 }) + pixels * 2 > Self.pixelBudget {
            guard let oldest = rasters.filter { $0.key != preserving }.min(by: { $0.value.used < $1.value.used })?.key else { throw Failure.oversized }
            rasters.removeValue(forKey: oldest)
        }
    }
    private func put(_ image: UIImage, key: String, source: String? = nil) {
        guard let cg = image.cgImage else { return }
        rasters[key] = Raster(image: image, pixels: cg.width * cg.height, used: now, source: source ?? key)
    }
    static func dimensions(_ size: CGSize) throws -> CGSize {
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else { throw Failure.invalidMedia }
        let w = ceil(size.width), h = ceil(size.height)
        guard w <= 8192, h <= 8192, w * h <= Double(Self.pixelBudget / 2) else { throw Failure.oversized }
        return CGSize(width: w, height: h)
    }
    static func previewSize(_ target: CGSize) throws -> CGSize {
        guard target.width.isFinite, target.height.isFinite, target.width > 0, target.height > 0 else { throw Failure.invalidMedia }
        let longest = max(target.width, target.height)
        let bucket = pow(2, ceil(log2(max(128, longest)) * 2) / 2)
        // Resolution is bounded; the original remains intact even at extreme zoom.
        let scale = min(bucket / longest, 8192 / longest, sqrt(6_000_000 / (target.width * target.height)))
        return try dimensions(CGSize(width: max(1, floor(target.width * scale + 1e-8)), height: max(1, floor(target.height * scale + 1e-8))))
    }
    func preview(for element: BoardElement, asset: BoardAsset?, targetSize: CGSize) -> UIImage? {
        guard checkAccess(), matches(element) else { return nil }
        if let id = element.assetId, asset != fingerprints[id]?.asset { return nil }
        let key = sourceKey(element)
        do {
            let size = try Self.previewSize(targetSize)
            if element.kind == .paper {
                guard element.paperView == "page", let id = element.paperId,
                      paperIndex[id] != nil else { return nil }
                let rasterKey = key + ":\(Int(size.width))x\(Int(size.height))"
                if paperRevisions[rasterKey] == revision, var cached = rasters[rasterKey] { cached.used = now; rasters[rasterKey] = cached; return cached.image }
                if tasks[key] == nil && tasks.count < 2 && !failures.contains(key) { loadPaper(element, key: key, rasterKey: rasterKey, size: size) }
                if var cached = rasters[rasterKey] { cached.used = now; rasters[rasterKey] = cached; return cached.image }
                if let previous = latestPaperRaster[key], var cached = rasters[previous] {
                    cached.used = now; rasters[previous] = cached; return cached.image
                }
                return nil
            }
            guard let id = element.assetId, let asset = fingerprints[id]?.asset else { return nil }
            if asset.mimeType == "video/mp4" {
                let url = try videoURL(for: element)
                if movies[key] == nil && movies.count + gifs.count < 4 {
                    try reserve(Int(size.width * size.height))
                    let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
                    generator.appliesPreferredTrackTransform = true; generator.maximumSize = size
                    let item = AVPlayerItem(url: url)
                    let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: Int(size.width), kCVPixelBufferHeightKey as String: Int(size.height)])
                    item.add(output)
                    let player = AVPlayer(playerItem: item)
                    movies[key] = Movie(elementID: element.id, url: url, generator: generator, player: player, output: output, size: size, start: now, seen: now)
                    startTimer()
                }
                movies[key]?.seen = now
                if rasters[key] == nil { requestMovie(element, key: key, size: size, autoplay: false) }
            } else if asset.mimeType == "image/gif", element.videoAutoplay == true {
                if gifs[key] == nil && movies.count + gifs.count < 4 {
                    let data = try Self.embedded(asset, mime: "image/gif")
                    guard sourceBytes + data.count <= Self.sourceBudget, let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { throw Failure.oversized }
                    gifs[key] = (source, 0, 0, now, data.count); startTimer()
                }
                gifs[key]?.seen = now
                try updateGIF(key: key, size: size)
            } else { return nil } // Static images remain the renderer's responsibility.
            if var cached = rasters[key] { cached.used = now; rasters[key] = cached; return cached.image }
        } catch { report(error, key: key) }
        return nil
    }
    private var sourceBytes: Int { videoFiles.values.reduce(0) { $0 + $1.bytes } + papers.values.reduce(0) { $0 + $1.data.count } + gifs.values.reduce(0) { $0 + $1.bytes } }
    private func loadPaper(_ e: BoardElement, key: String, rasterKey: String, size: CGSize) {
        let token = generation
        let renderRevision = revision
        tasks[key] = Task { [weak self] in
            guard let self, let id = e.paperId else { return }
            defer { if token == self.generation { self.tasks.removeValue(forKey: key); self.onChange?() } }
            do {
                let metadata = try await api.metadata(paperID: id)
                guard current(e, key: key, token: token), metadata.paper.spaceID == session.spaceID else { return }
                let data: Data
                if let cached = papers[id] { data = cached.data } else { data = try await api.pdf(paperID: id) }
                guard current(e, key: key, token: token) else { return }
                guard data.count <= Self.sourceBudget, sourceBytes + (papers[id] == nil ? data.count : 0) <= Self.sourceBudget,
                      let document = PDFDocument(data: data) else { throw Failure.oversized }
                papers[id] = (data, document.pageCount)
                onChange?()
                guard e.paperView == "page" else { return }
                guard document.pageCount == 1 else { throw Failure.unsupported }
                try reserve(Int(size.width * size.height), preserving: rasterKey)
                let flattened = try ReaderExport.export(document: document, annotations: metadata.annotations, native: { _ in nil })
                guard let page = PDFDocument(data: flattened)?.page(at: 0), let ref = page.pageRef else { throw Failure.invalidMedia }
                let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
                let image = UIGraphicsImageRenderer(size: size, format: format).image { output in
                    let c = output.cgContext, rect = CGRect(origin: .zero, size: size)
                    UIColor.white.setFill(); c.fill(rect)
                    c.translateBy(x: 0, y: size.height); c.scaleBy(x: 1, y: -1)
                    c.concatenate(ref.getDrawingTransform(.cropBox, rect: rect, rotate: 0, preserveAspectRatio: true)); c.drawPDFPage(ref)
                }
                guard current(e, key: key, token: token) else { return }
                guard revision == renderRevision else { return }
                // Keep one useful resolution per source instead of every pinch sample.
                if let old = latestPaperRaster[key], old != rasterKey {
                    rasters.removeValue(forKey: old); paperRevisions.removeValue(forKey: old)
                }
                put(image, key: rasterKey, source: key); latestPaperRaster[key] = rasterKey
                paperRevisions[rasterKey] = renderRevision; onChange?()
            } catch { if current(e, key: key, token: token) { report(error, key: key) } }
        }
    }
    func pdfPageCount(for element: BoardElement) -> Int? {
        guard checkAccess(), matches(element), let id = element.paperId,
              paperIndex[id] != nil else { return nil }
        if let count = papers[id]?.count { return count }
        let key = sourceKey(element)
        if tasks[key] == nil && !failures.contains(key) { loadPaper(element, key: key, rasterKey: key + ":menu", size: CGSize(width: 256, height: 256)) }
        return nil
    }

    nonisolated static func embedded(_ asset: BoardAsset, mime: String) throws -> Data {
        guard asset.mimeType == mime, asset.dataURL.hasPrefix("data:\(mime);base64,"),
              asset.dataURL.utf8.count <= (sourceBudget * 4 / 3 + 128),
              let comma = asset.dataURL.firstIndex(of: ","),
              let data = Data(base64Encoded: String(asset.dataURL[asset.dataURL.index(after: comma)...])), data.count <= sourceBudget else { throw Failure.invalidMedia }
        return data
    }
    func videoURL(for element: BoardElement) throws -> URL {
        guard checkAccess(), matches(element),
              let id = element.assetId, let asset = fingerprints[id]?.asset else { throw PaperError.unauthorized }
        let key = sourceKey(element)
        if let movie = movies[key] { return movie.url }
        if let file = videoFiles[key] { return file.url }
        let data = try Self.embedded(asset, mime: "video/mp4")
        guard sourceBytes + data.count <= Self.sourceBudget else { throw Failure.oversized }
        if directory == nil {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("board-media-" + UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.protectionKey: FileProtectionType.complete])
            var resource = dir; var values = URLResourceValues(); values.isExcludedFromBackup = true; try resource.setResourceValues(values)
            directory = dir
        }
        // Element IDs never become filesystem paths.
        let safe = directory!.appendingPathComponent(SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined() + ".mp4")
        if !FileManager.default.fileExists(atPath: safe.path) { try data.write(to: safe, options: [.atomic, .completeFileProtection]) }
        videoFiles[key] = (safe, data.count)
        return safe
    }
    private func requestMovie(_ e: BoardElement, key: String, size: CGSize, autoplay: Bool) {
        guard tasks[key] == nil, !failures.contains(key), let movie = movies[key] else { return }
        let token = generation
        do { try reserve(Int(size.width * size.height)); reserved[key] = Int(size.width * size.height) * 2 } catch { report(error, key: key); return }
        tasks[key] = Task { [weak self] in
            guard let self else { return }
            defer { if token == generation { tasks.removeValue(forKey: key); reserved.removeValue(forKey: key) } }
            do {
                let duration = try await movie.generator.asset.load(.duration).seconds
                guard duration.isFinite, duration > 0 else { throw Failure.invalidMedia }
                let seconds = autoplay ? max(0, now - movie.start).truncatingRemainder(dividingBy: duration) : 0
                let result = try await movie.generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600))
                guard current(e, key: key, token: token) else { return }
                let image = result.image
                guard image.width * image.height <= Int(size.width * size.height) else { throw Failure.oversized }
                reserved.removeValue(forKey: key)
                try reserve(image.width * image.height); put(UIImage(cgImage: image), key: key); onChange?()
            } catch { if current(e, key: key, token: token) { report(error, key: key) } }
        }
    }
    private func updateGIF(key: String, size: CGSize) throws {
        guard var gif = gifs[key], now >= gif.next else { return }
        let count = CGImageSourceGetCount(gif.source); guard count > 0 else { throw Failure.invalidMedia }
        let properties = CGImageSourceCopyPropertiesAtIndex(gif.source, gif.frame, nil) as? [CFString: Any]
        guard let w = properties?[kCGImagePropertyPixelWidth] as? Int, let h = properties?[kCGImagePropertyPixelHeight] as? Int,
              w > 0, h > 0, w <= 8192, h <= 8192, w * h <= Self.pixelBudget / 2 else { throw Failure.oversized }
        try reserve(w * h)
        guard let image = CGImageSourceCreateImageAtIndex(gif.source, gif.frame, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else { throw Failure.invalidMedia }
        let timing = properties?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
        let delay = (timing?[kCGImagePropertyGIFUnclampedDelayTime] as? Double) ?? (timing?[kCGImagePropertyGIFDelayTime] as? Double) ?? 0.1
        gif.frame = (gif.frame + 1) % count; gif.next = now + max(0.02, delay); gifs[key] = gif
        put(UIImage(cgImage: image), key: key)
    }
    private func startTimer() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }
    private func tick() {
        guard checkAccess() else { return }
        for (key, movie) in movies {
            guard now - movie.seen < 0.5 else { movie.player.pause(); movie.generator.cancelAllCGImageGeneration(); movies.removeValue(forKey: key); rasters.removeValue(forKey: key); continue }
            if let e = elements[movie.elementID], e.videoAutoplay == true {
                if movie.player.currentItem?.status == .readyToPlay {
                    if let duration = movie.player.currentItem?.duration.seconds, duration.isFinite,
                       movie.player.currentTime().seconds >= duration { movie.player.seek(to: .zero) }
                    movie.player.play()
                    let time = movie.output.itemTime(forHostTime: CACurrentMediaTime())
                    if movie.output.hasNewPixelBuffer(forItemTime: time),
                       let buffer = movie.output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) {
                        do {
                            // Account for the native decoded buffer, scaled output and old raster.
                            let pixels = CVPixelBufferGetWidth(buffer) * CVPixelBufferGetHeight(buffer)
                            try reserve(max(pixels, Int(movie.size.width * movie.size.height)))
                            let source = CIImage(cvPixelBuffer: buffer)
                            let scale = min(movie.size.width / source.extent.width, movie.size.height / source.extent.height)
                            let scaled = source.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                            if let image = imageContext.createCGImage(scaled, from: scaled.extent) {
                                put(UIImage(cgImage: image), key: key); onChange?()
                            }
                        } catch { movie.player.pause(); report(error, key: key) }
                    }
                }
            } else { movie.player.pause() }
        }
        for (key, gif) in gifs where now - gif.seen >= 0.5 { gifs.removeValue(forKey: key); rasters.removeValue(forKey: key) }
        if !gifs.isEmpty { onChange?() }
        if movies.isEmpty && gifs.isEmpty { timer?.invalidate(); timer = nil }
    }
    private func layout(_ e: BoardElement, width: CGFloat) throws -> BoardTextLayout {
        let signature = BoardTextLayout.Signature(e)
        if var cached = text[e.id], cached.signature == signature, cached.width == width {
            cached.used = now; text[e.id] = cached; return cached.layout
        }
        let value = try BoardTextLayout(element: e, width: width); textLayoutCount += 1
        text.removeValue(forKey: e.id)
        var cost = text.values.reduce(0) { $0 + $1.layout.estimatedCost }
        while cost + value.estimatedCost > 16 * 1024 * 1024,
              let oldest = text.min(by: { $0.value.used < $1.value.used })?.key {
            cost -= text.removeValue(forKey: oldest)!.layout.estimatedCost
        }
        if value.estimatedCost <= 16 * 1024 * 1024 { text[e.id] = (signature, width, value, now) }
        return value
    }
    func measureText(for element: BoardElement, constrainedTo width: Double) -> CGSize? {
        guard checkAccess() else { return nil }
        do { return try layout(element, width: CGFloat(width)).size } catch { report(error, key: "text:\(element.id):\(element.version)"); return nil }
    }
    func drawText(for element: BoardElement, in context: CGContext, rect: CGRect) -> Bool {
        guard checkAccess() else { return false }
        do { let value = try layout(element, width: rect.width); value.draw(in: context, at: rect.origin); return true }
        catch { report(error, key: "text:\(element.id):\(element.version)"); return false }
    }
    func links(for element: BoardElement, width: CGFloat) -> [BoardTextLayout.Link] {
        guard checkAccess() else { return [] }; return (try? layout(element, width: width).links) ?? []
    }
}
