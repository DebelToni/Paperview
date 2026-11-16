import Foundation

/// Unknown portable fields must stop editing, never disappear on a native roundtrip.
/// Metadata envelopes remain forward-compatible; the document itself is lossless or rejected.
private struct BoardWireKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}
private func boardKeys(_ decoder: Decoder, allowed: Set<String>) throws {
    let container = try decoder.container(keyedBy: BoardWireKey.self)
    if let unexpected = container.allKeys.first(where: { !allowed.contains($0.stringValue) }) {
        throw DecodingError.dataCorruptedError(forKey: unexpected, in: container, debugDescription: "Unsupported portable Space field: \(unexpected.stringValue). Update Paperview before editing this document.")
    }
}
private extension KeyedDecodingContainer {
    func portableOptional<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> T? {
        if contains(key), try decodeNil(forKey: key) {
            throw DecodingError.dataCorruptedError(forKey: key, in: self, debugDescription: "Portable fields cannot be explicitly null.")
        }
        return try decodeIfPresent(type, forKey: key)
    }
}
extension BoardElement {
    private enum Wire: String, CodingKey, CaseIterable {
        case id, kind, x, y, width, height, angle, stroke, fill, strokeWidth, opacity, z, version, deleted, locked
        case groupId, bold, italic, strokeStyle, diagramType, videoAutoplay, text, fontSize, autoFontSize, textWrapWidth, fontFamily, url, assetId, paperId, paperView, paperTitle, points, startAnchor, endAnchor
    }
    init(from decoder: Decoder) throws {
        try boardKeys(decoder, allowed: Set(Wire.allCases.map(\.rawValue)))
        let c = try decoder.container(keyedBy: Wire.self)
        self.init(kind: try c.decode(BoardKind.self, forKey: .kind), id: try c.decode(String.self, forKey: .id))
        x = try c.decode(Double.self, forKey: .x); y = try c.decode(Double.self, forKey: .y)
        width = try c.decode(Double.self, forKey: .width); height = try c.decode(Double.self, forKey: .height)
        angle = try c.decode(Double.self, forKey: .angle)
        stroke = try c.decode(String.self, forKey: .stroke); fill = try c.decode(String.self, forKey: .fill)
        strokeWidth = try c.decode(Double.self, forKey: .strokeWidth); opacity = try c.decode(Double.self, forKey: .opacity)
        z = try c.decode(Double.self, forKey: .z); version = try c.decode(Int.self, forKey: .version)
        deleted = try c.decode(Bool.self, forKey: .deleted); locked = try c.decode(Bool.self, forKey: .locked)
        groupId = try c.portableOptional(String.self, forKey: .groupId)
        bold = try c.portableOptional(Bool.self, forKey: .bold); italic = try c.portableOptional(Bool.self, forKey: .italic)
        strokeStyle = try c.portableOptional(String.self, forKey: .strokeStyle)
        diagramType = try c.portableOptional(String.self, forKey: .diagramType)
        videoAutoplay = try c.portableOptional(Bool.self, forKey: .videoAutoplay)
        text = try c.portableOptional(String.self, forKey: .text); fontSize = try c.portableOptional(Double.self, forKey: .fontSize)
        autoFontSize = try c.portableOptional(Bool.self, forKey: .autoFontSize)
        textWrapWidth = try c.portableOptional(Double.self, forKey: .textWrapWidth)
        fontFamily = try c.portableOptional(String.self, forKey: .fontFamily); url = try c.portableOptional(String.self, forKey: .url)
        assetId = try c.portableOptional(String.self, forKey: .assetId); paperId = try c.portableOptional(String.self, forKey: .paperId)
        paperView = try c.portableOptional(String.self, forKey: .paperView); paperTitle = try c.portableOptional(String.self, forKey: .paperTitle)
        points = try c.portableOptional([[Double]].self, forKey: .points)
        startAnchor = try c.portableOptional(BoardAnchor.self, forKey: .startAnchor); endAnchor = try c.portableOptional(BoardAnchor.self, forKey: .endAnchor)
    }
}
extension BoardDocument {
    private enum Wire: String, CodingKey { case version, elements, assets }
    init(from decoder: Decoder) throws {
        try boardKeys(decoder, allowed: ["version","elements","assets"])
        let c = try decoder.container(keyedBy: Wire.self)
        version = try c.decode(Int.self, forKey: .version)
        elements = try c.decode([BoardElement].self, forKey: .elements)
        assets = try c.decode([String: BoardAsset].self, forKey: .assets)
    }
}
extension BoardAsset {
    private enum Wire: String, CodingKey { case mimeType, dataURL }
    init(from decoder: Decoder) throws {
        try boardKeys(decoder, allowed: ["mimeType","dataURL"])
        let c = try decoder.container(keyedBy: Wire.self)
        mimeType = try c.decode(String.self, forKey: .mimeType); dataURL = try c.decode(String.self, forKey: .dataURL)
    }
}
extension BoardAnchor {
    private enum Wire: String, CodingKey { case elementId, x, y }
    init(from decoder: Decoder) throws {
        try boardKeys(decoder, allowed: ["elementId","x","y"])
        let c = try decoder.container(keyedBy: Wire.self)
        elementId = try c.decode(String.self, forKey: .elementId); x = try c.decode(Double.self, forKey: .x); y = try c.decode(Double.self, forKey: .y)
    }
}
