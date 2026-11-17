import Foundation
#if canImport(CSpaceEngine)
import CSpaceEngine
#endif

/// The same Rust engine used by the website, linked as a local Apple framework.
/// Live Pencil samples never enter this dispatcher; only completed edits do.
@MainActor final class BoardEngine {
    private var handle: UInt32?
    private(set) var board: BoardDocument
    private(set) var canUndo = false
    private(set) var canRedo = false
    private(set) var contentGeneration: UInt64 = 0

    private struct Reply: Decodable {
        var ok: Bool
        var error: String?
        var handle: UInt32?
        var board: BoardDocument?
        var canUndo: Bool?
        var canRedo: Bool?
        var id: String?
        var items: [BoardRenderItem]?
        var bounds: BoardRect?
        var binding: BoardBinding?
    }
    private static func object<T: Encodable>(_ value: T) throws -> Any {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(value), options: .fragmentsAllowed)
    }
    private static func dispatch(_ request: [String: Any]) throws -> Reply {
        #if canImport(CSpaceEngine)
        let data = try JSONSerialization.data(withJSONObject: request, options: [.sortedKeys])
        guard data.count <= 25 * 1024 * 1024, let json = String(data: data, encoding: .utf8) else {
            throw BoardError.invalidDocument("Native engine request exceeds 25 MiB.")
        }
        return try json.withCString { request in
            guard let pointer = space_engine_dispatch(request) else { throw BoardError.engine("Native engine returned no response.") }
            defer { space_engine_free(pointer) }
            let count = strlen(pointer)
            guard count <= 25 * 1024 * 1024 else { throw BoardError.engine("Native engine response exceeds 25 MiB.") }
            let reply = try JSONDecoder().decode(Reply.self, from: Data(bytes: pointer, count: count))
            guard reply.ok else { throw BoardError.engine(reply.error ?? "Native engine rejected the operation.") }
            return reply
        }
        #else
        throw BoardError.unavailable
        #endif
    }
    init(board: BoardDocument) throws {
        self.board = board
        let reply = try Self.dispatch(["op": "create", "board": Self.object(board)])
        guard let handle = reply.handle else { throw BoardError.engine("Native engine did not create a document handle.") }
        self.handle = handle
        do { try accept(reply) }
        catch { _ = try? Self.dispatch(["op": "destroy", "handle": handle]); self.handle = nil; throw error }
    }
    deinit {
        // C ABI handles are process-local, and the Rust registry synchronizes disposal.
        #if canImport(CSpaceEngine)
        if let handle, let data = try? JSONSerialization.data(withJSONObject: ["op": "destroy", "handle": handle]),
           let text = String(data: data, encoding: .utf8) {
            text.withCString { request in
                if let reply = space_engine_dispatch(request) { space_engine_free(reply) }
            }
        }
        #endif
    }
    static func validate(_ board: BoardDocument) throws { _ = try BoardEngine(board: board) }
    private func request(_ op: String, _ fields: [String: Any] = [:]) throws -> Reply {
        guard let handle else { throw BoardError.engine("Native document is closed.") }
        var request = fields; request["op"] = op; request["handle"] = handle
        return try Self.dispatch(request)
    }
    private func accept(_ reply: Reply) throws {
        guard let board = reply.board, let undo = reply.canUndo, let redo = reply.canRedo else {
            throw BoardError.engine("Native engine returned incomplete document state.")
        }
        self.board = board; canUndo = undo; canRedo = redo
        contentGeneration += 1
    }
    func replace(_ board: BoardDocument) throws { try accept(request("replace", ["board": Self.object(board)])) }
    @discardableResult func apply(_ command: BoardCommand) throws -> BoardDocument {
        try accept(request("apply", ["command": Self.object(command)])); return board
    }
    @discardableResult func undo() throws -> BoardDocument { try accept(request("undo")); return board }
    @discardableResult func redo() throws -> BoardDocument { try accept(request("redo")); return board }
    func hit(_ point: BoardPoint, tolerance: Double) throws -> String? {
        try request("hit", ["x": point.x, "y": point.y, "tolerance": tolerance]).id
    }
    func query(_ rect: BoardRect) throws -> [BoardRenderItem] {
        guard let items = try request("query", ["rect": Self.object(rect)]).items else {
            throw BoardError.engine("Native engine returned no render items.")
        }
        return items
    }
    func bounds(_ ids: [String]? = nil) throws -> BoardRect? {
        try request("bounds", ids.map { ["ids": $0] } ?? [:]).bounds
    }
    func binding(_ point: BoardPoint, tolerance: Double, toward: BoardPoint? = nil, exclude: [String] = []) throws -> BoardBinding? {
        var fields: [String: Any] = ["x": point.x, "y": point.y, "tolerance": tolerance, "exclude": exclude]
        if let toward { fields["toward"] = [toward.x, toward.y] }
        return try request("binding", fields).binding
    }
}
