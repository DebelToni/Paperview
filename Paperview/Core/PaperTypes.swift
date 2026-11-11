import Foundation

enum AnnotationKind: String, Codable { case pen, question, highlight, text }
struct PaperAnnotation: Codable, Equatable, Identifiable {
    var id: String
    var page: Int
    var type: AnnotationKind
    var color: String
    var points: [[Double]]? = nil
    var x: Double? = nil
    var y: Double? = nil
    var text: String? = nil
    var size: Double? = nil
}
struct PaperInfo: Codable, Equatable {
    var id: String
    var title: String
    var spaceID: String
    var abstract: String? = nil
    var isRead: Bool? = nil
    enum CodingKeys: String, CodingKey { case id, title, abstract; case spaceID = "space_id", isRead = "is_read" }
}
struct Presenter: Codable, Equatable, Identifiable {
    var id: String
    var nickname: String
    var page: Int
    var scroll: Double
    var zoom: Double
    var updatedAt: Double
    enum CodingKeys: String, CodingKey { case id, nickname, page, scroll, zoom; case updatedAt = "updated_at" }
}
enum AnnotationCreatorKind: String, Codable { case human, agent, guest, historical, unknown }
struct AnnotationCreator: Codable, Equatable {
    var name: String?
    var kind: AnnotationCreatorKind
    var description: String {
        switch kind {
        case .unknown: return "Unknown"
        case .historical: return name.map { "\($0) (historical)" } ?? "Unknown (historical)"
        case .guest: return name.map { "\($0) (guest)" } ?? "Guest"
        case .agent: return name.map { "\($0) (agent)" } ?? "Unnamed agent"
        case .human: return name.map { "\($0)" } ?? "Unknown"
        }
    }
}
struct PaperMetadata: Codable {
    var paper: PaperInfo
    var annotations: [PaperAnnotation]
    var revision: Int
    var canEdit: Bool
    var guest: Bool
    var presenters: [Presenter]
    var selfID: String? = nil
    var creators: [String: AnnotationCreator] = [:]
    func creatorDescription(for id: String) -> String {
        if let creator = creators[id] { return creator.description }
        return annotations.contains(where: { $0.id == id }) ? "Unknown" : "Unsaved annotation: creator unavailable"
    }
    enum CodingKeys: String, CodingKey { case paper, annotations, revision, guest, presenters, creators; case canEdit = "can_edit", selfID = "self_id" }
}
struct ReadingPosition: Codable { var page: Int; var scroll: Double; var zoom: Double }
struct PresenceResponse: Codable {
    var selfID: String?
    var presenters: [Presenter]
    enum CodingKeys: String, CodingKey { case presenters; case selfID = "self_id" }
}
struct AnnotationConflict: Identifiable {
    var id: String
    var local: PaperAnnotation?
    var remote: PaperAnnotation?
    var original: PaperAnnotation?
}
enum PaperError: Error, LocalizedError {
    case http(Int, String), invalidURL, oversized, invalidResponse, unauthorized, corruptJournal
    var errorDescription: String? {
        switch self {
        case let .http(code, detail): return "HTTP \(code): \(detail)"
        case .invalidURL: return "Unsafe Space URL"
        case .oversized: return "Response exceeds size limit"
        case .invalidResponse: return "Invalid Space response"
        case .unauthorized: return "Paper access is no longer authorized"
        case .corruptJournal: return "Pending annotation journal is corrupt; it has been preserved"
        }
    }
    var deniesAccess: Bool {
        if case let .http(code, _) = self { return [401,403,404].contains(code) }
        if case .unauthorized = self { return true }; return false
    }
}
@MainActor protocol PaperService: AnyObject {
    var storageIdentity: String { get }
    func metadata(paperID: String) async throws -> PaperMetadata
    func pdf(paperID: String) async throws -> Data
    func save(paperID: String, revision: Int, annotations: [PaperAnnotation]) async throws -> Int
}

struct AnnotationEdit {
    var id: String
    var original: PaperAnnotation?
    var value: PaperAnnotation?
    var native: Data? = nil
}
