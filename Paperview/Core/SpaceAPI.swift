import Foundation
import CryptoKit

private final class NoRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
@MainActor final class SpaceAPI: PaperService {
    let origin: URL
    private(set) var storageIdentity: String
    private var boundOwner: String?
    private let cookies: [HTTPCookie]
    private let session: URLSession
    private let redirect = NoRedirect()
    init(origin: URL, cookies: [HTTPCookie], protocolClasses: [AnyClass]? = nil) {
        self.origin = origin
        self.cookies = cookies
        let identity = origin.absoluteString + "\n" + cookies.map { "\($0.domain)|\($0.path)|\($0.name)=\($0.value)" }.sorted().joined(separator: "\n")
        storageIdentity = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = protocolClasses
        config.httpCookieStorage = nil; config.httpShouldSetCookies = false
        config.urlCache = nil; config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 30
        session = URLSession(configuration: config)
    }
    private func url(_ id: String, _ suffix: String = "") throws -> URL {
        guard ["http", "https"].contains(origin.scheme ?? ""), origin.host != nil,
              origin.user == nil, origin.password == nil, origin.query == nil, origin.fragment == nil,
              origin.path.isEmpty || origin.path == "/", !id.isEmpty,
              id.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-" )).contains($0) }) else { throw PaperError.invalidURL }
        return origin.appendingPathComponent("api/papers/\(id)\(suffix)")
    }
    private func request(_ id: String, _ suffix: String = "", method: String = "GET", body: Data? = nil, pdf: Bool = false, me: Bool = false) async throws -> Data {
        let paperURL = try url(id, suffix)
        let target = me ? origin.appendingPathComponent("api/me") : paperURL
        var req = URLRequest(url: target)
        req.httpMethod = method; req.httpBody = body; req.httpShouldHandleCookies = false
        req.setValue(pdf ? "application/pdf" : "application/json", forHTTPHeaderField: "Accept")
        if method != "GET" {
            req.setValue(origin.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")), forHTTPHeaderField: "Origin")
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let selected = cookies.filter { cookie in
            let domain = cookie.domain.hasPrefix(".") ? String(cookie.domain.dropFirst()) : cookie.domain
            let host = target.host ?? ""
            let domainOK = host == domain || (cookie.domain.hasPrefix(".") && host.hasSuffix("." + domain))
            let path = target.path
            let pathOK = path == cookie.path || (path.hasPrefix(cookie.path) && (cookie.path.hasSuffix("/") || path.dropFirst(cookie.path.count).hasPrefix("/")))
            return domainOK && pathOK && (!cookie.isSecure || target.scheme == "https") && (cookie.expiresDate == nil || cookie.expiresDate! > Date())
        }
        for (key, value) in HTTPCookie.requestHeaderFields(with: selected) { req.setValue(value, forHTTPHeaderField: key) }
        let limit = pdf ? 40 * 1024 * 1024 + 1024 : 25 * 1024 * 1024
        if let body, body.count > 25 * 1024 * 1024 { throw PaperError.oversized }
        return try await Self.transfer(req, session: session, redirect: redirect, limit: limit)
    }
    // Keep bounded streaming off the UI actor, including PDF byte iteration.
    private nonisolated static func transfer(_ request: URLRequest, session: URLSession, redirect: NoRedirect, limit: Int) async throws -> Data {
        let (bytes, response) = try await session.bytes(for: request, delegate: redirect)
        guard let http = response as? HTTPURLResponse, http.url == request.url else { throw PaperError.invalidResponse }
        guard response.expectedContentLength <= limit else { throw PaperError.oversized }
        var data = Data()
        for try await byte in bytes {
            guard data.count < limit else { throw PaperError.oversized }; data.append(byte)
        }
        guard (200..<300).contains(http.statusCode) else {
            struct Detail: Decodable { var detail: String }
            throw PaperError.http(http.statusCode, (try? JSONDecoder().decode(Detail.self, from: data).detail) ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode))
        }
        return data
    }
    func metadata(paperID: String) async throws -> PaperMetadata {
        let metadata = try JSONDecoder().decode(PaperMetadata.self, from: await request(paperID))
        guard metadata.paper.id == paperID else { throw PaperError.invalidResponse }
        let owner: String
        if metadata.guest {
            guard let grant = metadata.selfID, !grant.isEmpty else { throw PaperError.unauthorized }
            owner = "guest:" + grant
        } else {
            struct User: Decodable { var id: String }
            struct Me: Decodable { var user: User? }
            let me = try JSONDecoder().decode(Me.self, from: await request("me", me: true))
            if let user = me.user {
                guard !user.id.isEmpty else { throw PaperError.invalidResponse }
                owner = "account:" + user.id
            } else {
                guard !metadata.canEdit else { throw PaperError.unauthorized }
                owner = "anonymous"
            }
        }
        try Task.checkCancellation()
        // Session cookies are immutable. Never let one live API instance switch owners.
        guard boundOwner == nil || boundOwner == owner else { throw PaperError.unauthorized }
        boundOwner = owner
        let server = origin.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        storageIdentity = server + "\n" + owner
        return metadata
    }
    func pdf(paperID: String) async throws -> Data { try await request(paperID, "/file", pdf: true) }
    func save(paperID: String, revision: Int, annotations: [PaperAnnotation]) async throws -> Int {
        struct Body: Encodable { var revision: Int; var annotations: [PaperAnnotation] }
        struct Result: Decodable { var revision: Int }
        return try JSONDecoder().decode(Result.self, from: await request(paperID, "/annotations", method: "PUT", body: JSONEncoder().encode(Body(revision: revision, annotations: annotations)))).revision
    }
    func presence(paperID: String, presenting: Bool, position: ReadingPosition) async throws -> PresenceResponse {
        struct Body: Encodable { var presenting: Bool; var page: Int; var scroll: Double; var zoom: Double }
        return try JSONDecoder().decode(PresenceResponse.self, from: await request(paperID, "/presence", method: "POST", body: JSONEncoder().encode(Body(presenting: presenting, page: position.page, scroll: position.scroll, zoom: position.zoom))))
    }
    func presenters(paperID: String) async throws -> [Presenter] { try JSONDecoder().decode(PresenceResponse.self, from: await request(paperID, "/presence")).presenters }
    func share(paperID: String, guest: Bool) async throws -> URL {
        struct Body: Encodable { var guest: Bool }; struct Result: Decodable { var url: String }
        let result = try JSONDecoder().decode(Result.self, from: await request(paperID, "/share", method: "POST", body: JSONEncoder().encode(Body(guest: guest))))
        guard let value = URL(string: result.url, relativeTo: origin)?.absoluteURL,
              value.scheme == origin.scheme, value.host == origin.host, value.port == origin.port,
              value.user == nil, value.password == nil else { throw PaperError.invalidURL }
        return value
    }
    func markRead(paperID: String, read: Bool) async throws {
        struct Body: Encodable { var read: Bool }
        _ = try await request(paperID, "/read", method: "PUT", body: JSONEncoder().encode(Body(read: read)))
    }
}
