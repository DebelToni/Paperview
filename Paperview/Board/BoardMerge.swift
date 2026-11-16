import Foundation

struct BoardReviewedItem: Codable, Equatable {
    var id: String
    var local: BoardElement?
    var remote: BoardElement?
}
struct BoardConflict: Codable, Equatable, Identifiable {
    enum Kind: String, Codable { case element, asset, document }
    var kind: Kind
    var id: String
    var local: BoardElement? = nil
    var remote: BoardElement? = nil
    var related: [BoardReviewedItem] = []
    var message: String? = nil
}
struct BoardResolution: Codable, Equatable {
    enum Choice: String, Codable { case local, remote }
    var id: String
    var local: BoardElement?
    var remote: BoardElement?
    var related: [BoardReviewedItem]
    var choice: Choice
    init(conflict: BoardConflict, choice: Choice) {
        id = conflict.id; local = conflict.local; remote = conflict.remote
        related = conflict.related; self.choice = choice
    }
}
struct BoardIssue: Equatable {
    var id: String
    var message: String
    var items: [String]? = nil
}
func sameBoard(_ a: BoardDocument, _ b: BoardDocument) -> Bool { a == b }
private func anchorIssues(_ board: BoardDocument) -> [BoardIssue] {
    let items = Dictionary(board.elements.map { ($0.id, $0) }, uniquingKeysWith: { _, b in b })
    var result: [BoardIssue] = []
    for e in board.elements {
        for (key, anchor) in [("startAnchor", e.startAnchor), ("endAnchor", e.endAnchor)] {
            if let a = anchor, a.elementId == e.id || (!e.deleted && (items[a.elementId] == nil || items[a.elementId]!.deleted)) {
                result.append(BoardIssue(id: "\(key):\(e.id)", message: "\(e.kind == .line ? "Line" : "Arrow") \(e.id) references missing or deleted target \(a.elementId).", items: [e.id, a.elementId]))
            }
        }
    }
    return result
}
func boardIssues(_ board: BoardDocument) -> [BoardIssue] {
    var result: [BoardIssue] = []
    if board.elements.count > 50000 { result.append(.init(id: "element-limit", message: "Merged board exceeds 50,000 elements, including deleted items.")) }
    if board.assets.count > 1000 { result.append(.init(id: "asset-limit", message: "Merged board exceeds 1,000 immutable assets.")) }
    for e in board.elements {
        if let id = e.assetId, board.assets[id] == nil { result.append(.init(id: "missing-asset:\(e.id)", message: "Item \(e.id) references missing image asset \(id).")) }
    }
    result += anchorIssues(board)
    let limit = 25 * 1024 * 1024
    if board.assets.values.reduce(0, { $0 + $1.dataURL.utf8.count }) > limit { result.append(.init(id: "asset-bytes", message: "Merged image assets exceed 25 MiB.")) }
    struct Envelope: Encodable { let op = "replace"; let handle: UInt32 = .max; let board: BoardDocument }
    let encoder = JSONEncoder(); encoder.outputFormatting = [.withoutEscapingSlashes]
    if (try? encoder.encode(Envelope(board: board)).count).map({ $0 > limit }) ?? true { result.append(.init(id: "body-limit", message: "Merged board exceeds the 25 MiB request limit.")) }
    return result
}
private func groupMembershipConflict(_ b: [String: BoardElement], _ l: [String: BoardElement], _ r: [String: BoardElement]) -> Bool {
    func memberships(_ items: [String: BoardElement]) -> [String: Set<String>] {
        var groups: [String: Set<String>] = [:]
        for e in items.values where !e.deleted { if let g = e.groupId, !g.isEmpty { groups[g, default: []].insert(e.id) } }
        return groups
    }
    let bg = memberships(b), lg = memberships(l), rg = memberships(r)
    for g in Set(bg.keys).union(lg.keys).union(rg.keys) {
        let bm = bg[g] ?? [], lm = lg[g] ?? [], rm = rg[g] ?? []
        let lc = bm != lm, rc = bm != rm
        if !lc && !rc { continue }
        let ids = bm.union(lm).union(rm)
        if ids.allSatisfy({ l[$0] == r[$0] }) { continue }
        if (lc && ids.contains(where: { b[$0] != r[$0] })) || (rc && ids.contains(where: { b[$0] != l[$0] })) { return true }
    }
    return false
}
private func reconcile(_ base: BoardDocument, _ local: BoardDocument, _ remote: BoardDocument, _ resolutions: [BoardResolution]) -> (BoardDocument?, [BoardConflict]) {
    func index(_ board: BoardDocument) -> [String: BoardElement] { Dictionary(board.elements.map { ($0.id, $0) }, uniquingKeysWith: { _, b in b }) }
    let before = index(base), ours = index(local), theirs = index(remote)
    var chosen: [String: BoardElement] = [:], required = Set<String>(), unresolved = Set<String>()
    var conflicts: [BoardConflict] = []
    if groupMembershipConflict(before, ours, theirs) { conflicts.append(.init(kind: .document, id: "group-membership", message: "Group membership changed concurrently with edits to its members. Per-item choices cannot merge this group atomically.")) }
    func snapshot(_ id: String) -> BoardReviewedItem { .init(id: id, local: ours[id], remote: theirs[id]) }
    for id in Set(theirs.keys).union(ours.keys).union(before.keys) {
        let b = before[id], l = ours[id], r = theirs[id]
        if l == b { chosen[id] = r }
        else if r == b || l == r { chosen[id] = l }
        else { required.insert(id); chosen[id] = l }
    }
    var assets: [String: BoardAsset] = [:]
    for id in Set(base.assets.keys).union(local.assets.keys).union(remote.assets.keys) {
        let values = [base.assets[id], local.assets[id], remote.assets[id]].compactMap { $0 }
        if values.contains(where: { $0 != values.first! }) { conflicts.append(.init(kind: .asset, id: id)) }
        assets[id] = values.first
    }
    func candidate() -> BoardDocument { BoardDocument(elements: Array(chosen.values), assets: assets).ordered }
    let initialIssues = anchorIssues(candidate())
    let decisions = Dictionary(resolutions.map { ($0.id, $0) }, uniquingKeysWith: { _, b in b })
    for (id, resolution) in decisions {
        let reviewed = [BoardReviewedItem(id: id, local: resolution.local, remote: resolution.remote)] + resolution.related
        if reviewed.allSatisfy({ $0.local == ours[$0.id] && $0.remote == theirs[$0.id] }) { chosen[id] = resolution.choice == .local ? ours[id] : theirs[id] }
        else { unresolved.formUnion(reviewed.map(\.id)) }
    }
    for id in required where decisions[id] == nil { unresolved.insert(id) }
    let board = candidate(), issues = boardIssues(board)
    for issue in issues {
        if let items = issue.items { unresolved.formUnion(items) }
        else { conflicts.append(.init(kind: .document, id: issue.id, message: issue.message)) }
    }
    var links: [String: Set<String>] = [:]
    for issue in initialIssues + issues {
        if let ids = issue.items { links[ids[0], default: []].insert(ids[1]); links[ids[1], default: []].insert(ids[0]) }
    }
    for id in unresolved.sorted() { conflicts.append(.init(kind: .element, id: id, local: ours[id], remote: theirs[id], related: (links[id] ?? []).filter { $0 != id }.sorted().map(snapshot))) }
    return (conflicts.isEmpty ? board : nil, conflicts)
}
func mergeBoards(_ base: BoardDocument, _ local: BoardDocument, _ remote: BoardDocument, resolutions: [BoardResolution] = []) -> BoardDocument? { reconcile(base, local, remote, resolutions).0 }
func boardConflicts(_ base: BoardDocument, _ local: BoardDocument, _ remote: BoardDocument, resolutions: [BoardResolution] = []) -> [BoardConflict] { reconcile(base, local, remote, resolutions).1 }
