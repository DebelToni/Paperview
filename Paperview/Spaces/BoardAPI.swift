import Foundation

extension SpaceAPI: BoardService {
    static func validPathID(_ id: String) -> Bool {
        !id.isEmpty && id.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 }
    }
    private func endpoint(_ parts: [String]) throws -> URL {
        guard parts.allSatisfy(Self.validPathID) else { throw PaperError.invalidURL }
        return parts.reduce(origin.appendingPathComponent("api")) { $0.appendingPathComponent($1) }
    }
    private func call<T: Decodable>(_ parts: [String], method: String = "GET", body: Data? = nil) async throws -> T {
        try JSONDecoder().decode(T.self, from: await nativeRequest(target: endpoint(parts), method: method, body: body))
    }
    private func json<T: Encodable>(_ value: T) throws -> Data { try JSONEncoder().encode(value) }
    func identity() async throws -> SpaceIdentity? {
        struct Me: Decodable { var user: SpaceIdentity? }
        let me: Me = try await call(["me"])
        try Task.checkCancellation()
        if let user = me.user { guard user.approved else { throw PaperError.unauthorized }; try bindAccount(user.id) }
        else { try bindAnonymous() }
        return me.user
    }
    private func requireAccount() async throws { guard try await identity() != nil else { throw PaperError.unauthorized } }
    func listing() async throws -> SpaceListing {
        let result: SpaceListing = try await call(["spaces"])
        guard result.spaces.allSatisfy({ Self.validPathID($0.id) }), result.requests.allSatisfy({ Self.validPathID($0.id) && Self.validPathID($0.spaceID) }), result.outgoing.allSatisfy({ Self.validPathID($0.spaceID) }) else { throw PaperError.invalidResponse }
        return result
    }
    func space(id: String) async throws -> SpaceSnapshot {
        guard Self.validPathID(id) else { throw PaperError.invalidURL }
        let user = try await identity()
        let cached = nativeSpaceCache.flatMap { $0.space.id == id ? $0 : nil }
        var components = URLComponents(url: try endpoint(["spaces", id]), resolvingAgainstBaseURL: false)!
        if let cached { components.queryItems = [URLQueryItem(name: "known_revision", value: String(cached.space.revision))] }
        guard let target = components.url else { throw PaperError.invalidURL }
        struct Poll: Decodable {
            var space: SpaceSummary
            var board: BoardDocument?
            var creators: [String: AnnotationCreator]
            var papers: [PaperInfo]
        }
        let result = try JSONDecoder().decode(Poll.self, from: await nativeRequest(target: target))
        guard result.space.id == id, result.papers.allSatisfy({ $0.spaceID == id }), user != nil || !result.space.member else { throw PaperError.invalidResponse }
        let board: BoardDocument
        if let changed = result.board { board = changed }
        else {
            guard let cached, cached.space.revision == result.space.revision else { throw PaperError.invalidResponse }
            board = cached.board
        }
        let snapshot = SpaceSnapshot(space: result.space, board: board, creators: result.creators, papers: result.papers)
        nativeSpaceCache = snapshot
        return snapshot
    }
    func saveBoard(id: String, revision: Int, board: BoardDocument) async throws -> Int {
        struct Body: Encodable { var revision: Int; var board: BoardDocument }; struct Result: Decodable { var revision: Int }
        guard Self.validPathID(id) else { throw PaperError.invalidURL }
        try await requireAccount()
        let result: Result = try await call(["spaces", id, "board"], method: "PUT", body: json(Body(revision: revision, board: board)))
        return result.revision
    }
    func createSpace(title: String, visibility: String) async throws -> SpaceSummary {
        try await requireAccount()
        let result: SpaceSummary = try await call(["spaces"], method: "POST", body: json(["title": title, "visibility": visibility]))
        guard Self.validPathID(result.id) else { throw PaperError.invalidResponse }; return result
    }
    func updateSpace(id: String, title: String, visibility: String, revision: Int) async throws -> SpaceSummary {
        struct Body: Encodable { var title: String; var visibility: String; var revision: Int }
        let result: SpaceSummary = try await call(["spaces", id], method: "PATCH", body: json(Body(title: title, visibility: visibility, revision: revision)))
        guard result.id == id else { throw PaperError.invalidResponse }; return result
    }
    private struct OK: Decodable { }
    func requestJoin(id: String) async throws { let _: OK = try await call(["spaces", id, "join"], method: "POST", body: Data("{}".utf8)) }
    func answerJoin(spaceID: String, requestID: String, approve: Bool) async throws { let _: OK = try await call(["spaces", spaceID, "requests", requestID], method: "POST", body: json(["approve": approve])) }
    func acceptInvitation(token: String) async throws -> String {
        struct Result: Decodable { var space_id: String }
        let result: Result = try await call(["space-invites", token, "accept"], method: "POST", body: Data("{}".utf8))
        guard Self.validPathID(result.space_id) else { throw PaperError.invalidResponse }; return result.space_id
    }
    func invitation(id: String) async throws -> URL {
        struct Result: Decodable { var url: String }
        let result: Result = try await call(["spaces", id, "invites"], method: "POST", body: Data("{}".utf8))
        return try safeURL(result.url)
    }
    private func safeURL(_ value: String) throws -> URL {
        guard let url = URL(string: value, relativeTo: origin)?.absoluteURL, url.scheme == origin.scheme, url.host == origin.host, url.port == origin.port, url.user == nil, url.password == nil else { throw PaperError.invalidResponse }; return url
    }
    func history(id: String) async throws -> [SpaceHistory] { struct Result: Decodable { var history: [SpaceHistory] }; let result: Result = try await call(["spaces", id, "history"]); return result.history }
    func restore(id: String, historyID: String, revision: Int) async throws -> Int {
        struct Body: Encodable { var history_id: String; var revision: Int }; struct Result: Decodable { var revision: Int }
        guard Self.validPathID(historyID) else { throw PaperError.invalidURL }
        let result: Result = try await call(["spaces", id, "restore"], method: "POST", body: json(Body(history_id: historyID, revision: revision))); return result.revision
    }
    func agents(id: String) async throws -> [SpaceAgent] { struct Result: Decodable { var agents: [SpaceAgent] }; let result: Result = try await call(["spaces", id, "agents"]); return result.agents }
    func createAgent(id: String, name: String) async throws -> CreatedSpaceAgent {
        let result: CreatedSpaceAgent = try await call(["spaces", id, "agents"], method: "POST", body: json(["name": name]))
        guard result.access.spaceID == id, result.access.token.hasPrefix("sag_") else { throw PaperError.invalidResponse }
        _ = try safeURL(result.access.apiBase); _ = try safeURL(result.access.guideURL); _ = try safeURL(result.access.contextURL)
        return result
    }
    func revokeAgent(id: String, agentID: String) async throws { let _: OK = try await call(["spaces", id, "agents", agentID], method: "DELETE") }
    func importPaper(id: String, url: String, arxiv: Bool) async throws -> SpacePaperUpload {
        let result: SpacePaperUpload = try await call(["spaces", id, "papers", arxiv ? "arxiv" : "url"], method: "POST", body: json(["url": url]))
        guard result.paper.spaceID == id else { throw PaperError.invalidResponse }; return result
    }
    private func multipart(id: String, suffix: String, data: Data, filename: String, mime: String, max: Int) async throws -> Data {
        guard data.count <= max else { throw PaperError.oversized }
        let boundary = "Paperview-" + UUID().uuidString
        // Never interpolate untrusted filename/header bytes.
        let name = filename.unicodeScalars.filter { CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._- ")).contains($0) }.map(String.init).joined()
        var body = Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(name.isEmpty ? "upload" : name)\"\r\nContent-Type: \(mime)\r\n\r\n".utf8)
        body.append(data); body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        return try await nativeRequest(target: endpoint(["spaces", id, suffix]), method: "POST", body: body, contentType: "multipart/form-data; boundary=\(boundary)")
    }
    func uploadPDF(id: String, data: Data, filename: String) async throws -> SpacePaperUpload {
        let result = try JSONDecoder().decode(SpacePaperUpload.self, from: await multipart(id: id, suffix: "papers", data: data, filename: filename, mime: "application/pdf", max: 40 * 1024 * 1024))
        guard result.paper.spaceID == id else { throw PaperError.invalidResponse }; return result
    }
    func mediaPreview(id: String, data: Data, filename: String) async throws -> SpaceMediaPreview {
        try JSONDecoder().decode(SpaceMediaPreview.self, from: await multipart(id: id, suffix: "media-preview", data: data, filename: filename, mime: "application/octet-stream", max: 16 * 1024 * 1024))
    }
    func diagram(id: String, revision: Int, format: String, source: String, x: Double, y: Double, width: Double? = nil, height: Double? = nil) async throws -> SpaceDiagramResult {
        struct Body: Encodable { var revision: Int; var format: String; var source: String; var x: Double; var y: Double; var width: Double?; var height: Double? }
        guard ["svg", "mermaid", "html"].contains(format), source.utf8.count <= 100000 else { throw PaperError.invalidResponse }
        return try await call(["spaces", id, "diagrams"], method: "POST", body: json(Body(revision: revision, format: format, source: source, x: x, y: y, width: width, height: height)))
    }
    func htmlPrivateAsset(id: String, elementID: String, path: String) async throws -> NativePayload {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count >= 2, ["public", "private"].contains(String(parts[0])),
              parts.dropFirst().allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
              !path.contains("\\"), !path.contains("%"), !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              path.utf8.count <= 2048 else { throw PaperError.invalidURL }
        return try await nativePayload(target: endpoint(["spaces", id, "html", elementID, "cdn-asset"]), method: "POST", body: json(["path": path]), limit: 8 * 1024 * 1024, accept: "application/octet-stream")
    }
    func cdnSettings() async throws -> SpaceCDNSettings { try await call(["settings", "cdn"]) }
    func saveCDN(origin: String, token: String) async throws {
        guard let url = URL(string: origin), url.scheme == "https", url.host != nil, url.user == nil, url.password == nil, url.query == nil, url.fragment == nil, url.path.isEmpty || url.path == "/" else { throw PaperError.invalidURL }
        let _: OK = try await call(["settings", "cdn"], method: "PUT", body: json(["origin": origin, "token": token]))
    }
    func disconnectCDN() async throws { let _: OK = try await call(["settings", "cdn"], method: "DELETE") }
    func logout() async throws { let _: OK = try await call(["logout"], method: "POST", body: Data("{}".utf8)) }
    func suggestions() async throws -> [SpaceSuggestion] { struct Result: Decodable { var suggestions: [SpaceSuggestion] }; let result: Result = try await call(["suggestions"]); return result.suggestions }
    func suggest(title: String, body: String) async throws { let _: OK = try await call(["suggestions"], method: "POST", body: json(["title": title, "body": body])) }
    func updateSuggestion(id: String, status: String) async throws {
        guard ["open", "approved", "done", "declined"].contains(status) else { throw PaperError.invalidResponse }
        let _: OK = try await call(["suggestions", id], method: "PATCH", body: json(["status": status]))
    }

    func htmlFrame(id: String, elementID: String, channel: String) async throws -> NativePayload {
        guard channel.utf8.count == 32, channel.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { throw PaperError.invalidURL }
        let url = try endpoint(["spaces", id, "html", elementID, "frame"])
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "channel", value: channel)]
        guard let target = components.url else { throw PaperError.invalidURL }
        return try await nativePayload(target: target, accept: "text/html")
    }

}
