import Foundation

struct SpaceSummary: Codable, Equatable, Identifiable {
    var id: String; var title: String; var visibility: String; var creatorId: String
    var revision: Int; var member: Bool; var shared: Bool; var createdAt: Double
    enum CodingKeys: String, CodingKey { case id, title, visibility, revision, member, shared; case creatorId = "creator_id", createdAt = "created_at" }
}
struct SpaceSnapshot: Codable { var space: SpaceSummary; var board: BoardDocument; var creators: [String: AnnotationCreator]; var papers: [PaperInfo] }
struct SpaceIdentity: Codable {
    var id: String; var email: String; var nickname: String; var isAdmin: Bool; var approved: Bool
    enum CodingKeys: String, CodingKey { case id, email, nickname, approved; case isAdmin = "is_admin" }
}
@MainActor protocol BoardService {
    var storageIdentity: String { get }
    func space(id: String) async throws -> SpaceSnapshot
    func saveBoard(id: String, revision: Int, board: BoardDocument) async throws -> Int
}
struct SpaceJoinRequest: Codable {
    var id: String; var spaceID: String; var spaceTitle: String; var userID: String; var nickname: String; var createdAt: Double
    enum CodingKeys: String, CodingKey { case id, nickname; case spaceID = "space_id", spaceTitle = "space_title", userID = "user_id", createdAt = "created_at" }
}
struct SpaceOutgoing: Codable { var spaceID: String; var status: String; enum CodingKeys: String, CodingKey { case status; case spaceID = "space_id" } }
struct SpaceListing: Codable { var spaces: [SpaceSummary]; var requests: [SpaceJoinRequest]; var outgoing: [SpaceOutgoing] }
struct SpaceHistory: Codable { var id: String; var revision: Int; var actor: String; var kind: String; var createdAt: Double; enum CodingKeys: String, CodingKey { case id, revision, actor, kind; case createdAt = "created_at" } }
struct SpaceAgent: Codable { var id: String; var name: String; var createdAt: Double; var lastUsedAt: Double?; var revokedAt: Double?; enum CodingKeys: String, CodingKey { case id, name; case createdAt = "created_at", lastUsedAt = "last_used_at", revokedAt = "revoked_at" } }
struct SpaceAgentAccess: Codable { var apiBase: String; var spaceID: String; var token: String; var guideURL: String; var contextURL: String; enum CodingKeys: String, CodingKey { case token; case apiBase = "api_base", spaceID = "space_id", guideURL = "guide_url", contextURL = "context_url" } }
struct CreatedSpaceAgent: Codable { var agent: SpaceAgent; var access: SpaceAgentAccess }
struct SpacePaperUpload: Codable { var paper: PaperInfo; var revision: Int }
struct SpaceMediaPreview: Codable { var asset: BoardAsset; var width: Double; var height: Double; var autoplay: Bool }
struct SpaceDiagramResult: Codable { var revision: Int; var elementId: String; var assetId: String; var width: Double; var height: Double }

struct SpaceCDNSettings: Codable { var origin: String?; var hasToken: Bool; enum CodingKeys: String, CodingKey { case origin; case hasToken = "has_token" } }
struct SpaceSuggestion: Codable { var id: String; var title: String; var body: String; var status: String; var author: String; var createdAt: Double; enum CodingKeys: String, CodingKey { case id, title, body, status, author; case createdAt = "created_at" } }
