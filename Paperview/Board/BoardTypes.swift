import Foundation

struct BoardPoint: Codable, Equatable {
    var x: Double
    var y: Double
}
struct BoardRect: Codable, Equatable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double
}
enum BoardKind: String, Codable, CaseIterable {
    case rectangle, ellipse, diamond, text, line, arrow, pen, image, paper
}
struct BoardAnchor: Codable, Equatable {
    var elementId: String
    var x: Double
    var y: Double
}
struct BoardElement: Codable, Equatable, Identifiable {
    var id: String
    var kind: BoardKind
    var x: Double = 0
    var y: Double = 0
    var width: Double = 0
    var height: Double = 0
    var angle: Double = 0
    var stroke = "#202124"
    var fill = "transparent"
    var strokeWidth: Double = 2
    var opacity: Double = 1
    var z: Double = 0
    var version = 1
    var deleted = false
    var locked = false
    var groupId: String?
    var bold: Bool?
    var italic: Bool?
    var strokeStyle: String?
    var diagramType: String?
    var videoAutoplay: Bool?
    var text: String?
    var fontSize: Double?
    var autoFontSize: Bool?
    var textWrapWidth: Double?
    var fontFamily: String?
    var url: String?
    var assetId: String?
    var paperId: String?
    var paperView: String?
    var paperTitle: String?
    var points: [[Double]]?
    var startAnchor: BoardAnchor?
    var endAnchor: BoardAnchor?

    init(kind: BoardKind, id: String = UUID().uuidString) {
        self.kind = kind
        self.id = id
    }
    func semanticEqual(_ other: BoardElement) -> Bool {
        var a = self, b = other
        a.version = 0; b.version = 0
        return a == b
    }
    var isPath: Bool { [.line, .arrow, .pen].contains(kind) }
    var rect: BoardRect { BoardRect(x: x, y: y, width: width, height: height) }
}
struct BoardAsset: Codable, Equatable {
    var mimeType: String
    var dataURL: String
}
struct BoardDocument: Codable, Equatable {
    var version = 1
    var elements: [BoardElement] = []
    var assets: [String: BoardAsset] = [:]
    static let empty = BoardDocument()
    var ordered: BoardDocument {
        var result = self
        result.elements.sort { $0.z == $1.z ? $0.id < $1.id : $0.z < $1.z }
        return result
    }
    func element(_ id: String) -> BoardElement? { elements.first { $0.id == id } }
    static func == (lhs: BoardDocument, rhs: BoardDocument) -> Bool {
        lhs.version == rhs.version && lhs.assets == rhs.assets && lhs.ordered.elements == rhs.ordered.elements
    }
}
struct BoardRenderItem: Codable {
    var element: BoardElement
    var points: [[Double]]?
}
struct BoardBinding: Codable {
    var anchor: BoardAnchor
    var point: [Double]
}

indirect enum BoardCommand: Codable {
    case put([BoardElement], assets: [String: BoardAsset] = [:])
    case delete([String])
    case move([String], dx: Double, dy: Double)
    case resize(id: String, rect: BoardRect)
    case group([String], groupId: String)
    case ungroup([String])
    case resizeGroup([String], rect: BoardRect)
    case batch([BoardCommand])

    private enum Keys: String, CodingKey {
        case type, elements, assets, ids, id, dx, dy, x, y, width, height, groupId, commands
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        let type = try c.decode(String.self, forKey: .type)
        func rect() throws -> BoardRect {
            try BoardRect(x: c.decode(Double.self, forKey: .x), y: c.decode(Double.self, forKey: .y),
                          width: c.decode(Double.self, forKey: .width), height: c.decode(Double.self, forKey: .height))
        }
        switch type {
        case "put": self = .put(try c.decode([BoardElement].self, forKey: .elements), assets: try c.decodeIfPresent([String: BoardAsset].self, forKey: .assets) ?? [:])
        case "delete": self = .delete(try c.decode([String].self, forKey: .ids))
        case "move": self = .move(try c.decode([String].self, forKey: .ids), dx: try c.decode(Double.self, forKey: .dx), dy: try c.decode(Double.self, forKey: .dy))
        case "resize": self = .resize(id: try c.decode(String.self, forKey: .id), rect: try rect())
        case "group": self = .group(try c.decode([String].self, forKey: .ids), groupId: try c.decode(String.self, forKey: .groupId))
        case "ungroup": self = .ungroup(try c.decode([String].self, forKey: .ids))
        case "resizegroup": self = .resizeGroup(try c.decode([String].self, forKey: .ids), rect: try rect())
        case "batch": self = .batch(try c.decode([BoardCommand].self, forKey: .commands))
        default: throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "Unsupported Space command: \(type)")
        }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        func rect(_ r: BoardRect) throws {
            try c.encode(r.x, forKey: .x); try c.encode(r.y, forKey: .y)
            try c.encode(r.width, forKey: .width); try c.encode(r.height, forKey: .height)
        }
        switch self {
        case let .put(elements, assets):
            try c.encode("put", forKey: .type); try c.encode(elements, forKey: .elements)
            if !assets.isEmpty { try c.encode(assets, forKey: .assets) }
        case let .delete(ids):
            try c.encode("delete", forKey: .type); try c.encode(ids, forKey: .ids)
        case let .move(ids, dx, dy):
            try c.encode("move", forKey: .type); try c.encode(ids, forKey: .ids)
            try c.encode(dx, forKey: .dx); try c.encode(dy, forKey: .dy)
        case let .resize(id, value):
            try c.encode("resize", forKey: .type); try c.encode(id, forKey: .id); try rect(value)
        case let .group(ids, groupId):
            try c.encode("group", forKey: .type); try c.encode(ids, forKey: .ids); try c.encode(groupId, forKey: .groupId)
        case let .ungroup(ids):
            try c.encode("ungroup", forKey: .type); try c.encode(ids, forKey: .ids)
        case let .resizeGroup(ids, value):
            try c.encode("resizegroup", forKey: .type); try c.encode(ids, forKey: .ids); try rect(value)
        case let .batch(commands):
            try c.encode("batch", forKey: .type); try c.encode(commands, forKey: .commands)
        }
    }
}

enum BoardError: Error, LocalizedError {
    case engine(String), unavailable, invalidDocument(String), notAuthorized, journal(String)
    var errorDescription: String? {
        switch self {
        case let .engine(message), let .invalidDocument(message), let .journal(message): return message
        case .unavailable: return "The native Space engine is not included in this build."
        case .notAuthorized: return "Space access is no longer authorized. Pending edits have been retained."
        }
    }
}
