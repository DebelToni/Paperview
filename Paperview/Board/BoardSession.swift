import Foundation

@MainActor final class BoardSession {
    let api: any BoardService
    let spaceID: String
    private var storedSnapshot: SpaceSnapshot?
    private(set) var snapshot: SpaceSnapshot? {
        get { authorized && owner == api.storageIdentity ? storedSnapshot : nil }
        set { storedSnapshot = newValue }
    }
    var board: BoardDocument { authorized && owner == api.storageIdentity ? (snapshot?.space.member == false ? snapshot!.board : journal.local) : .empty }
    var base: BoardDocument { authorized && owner == api.storageIdentity ? (snapshot?.space.member == false ? snapshot!.board : journal.base) : .empty }
    private(set) var conflicts: [BoardConflict] = []
    private(set) var status = "Not opened"
    var dirty: Bool { hasPendingIntent || hasUnconvertedInk || !sameBoard(journal.local, journal.base) }
    var hasUnconvertedInk: Bool { journal.recoveryInk?.isEmpty == false }
    private(set) var authorized = false
    var onChange: (() -> Void)?
    private struct Archive: Codable { var element: BoardElement; var data: Data }
    private struct Intent: Codable, Equatable {
        var original: BoardDocument
        var local: BoardDocument
        var native: [String: Data]
    }
    var hasPendingIntent: Bool { journal.intent != nil }
    private struct Journal: Codable {
        var version = 1
        var identity: String
        var spaceID: String
        var base: BoardDocument = .empty
        var local: BoardDocument = .empty
        var archives: [String: Archive] = [:]
        var intent: Intent? = nil
        var recoveryInk: [String: Data]? = nil
    }
    private var journal: Journal
    private var file: URL?
    private let directory: URL
    private let validate: @MainActor (BoardDocument) throws -> Void
    private var owner: String?
    private var busy = false
    private var editing = false
    private var generation = 0
    init(api: any BoardService, spaceID: String, storageDirectory: URL,
         validate: @escaping @MainActor (BoardDocument) throws -> Void = { try BoardEngine.validate($0) }) {
        self.api = api; self.spaceID = spaceID; directory = storageDirectory; self.validate = validate
        journal = Journal(identity: "", spaceID: spaceID)
    }
    // A reversible UTF-8 encoding avoids hash dependencies on Linux. Split the key
    // into directories so long origins/IDs cannot exceed a filesystem component.
    private func journalURL(_ identity: String) -> URL {
        let key = Data((identity + "\u{0}" + spaceID).utf8).map { String(format: "%02x", $0) }.joined()
        var url = directory.appendingPathComponent("boards", isDirectory: true)
        var start = key.startIndex
        while start < key.endIndex {
            let end = key.index(start, offsetBy: 100, limitedBy: key.endIndex) ?? key.endIndex
            url.appendPathComponent(String(key[start..<end]), isDirectory: true); start = end
        }
        return url.appendingPathComponent("draft.json")
    }
    private func write(_ next: Journal) throws {
        guard let file else { throw BoardError.notAuthorized }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let data = try JSONEncoder().encode(next)
        #if os(iOS)
        try data.write(to: file, options: [.atomic, .completeFileProtection])
        #else
        try data.write(to: file, options: .atomic)
        #endif
    }
    private func install(_ next: Journal) throws { try write(next); journal = next }
    func persist() throws { guard authorized, owner == api.storageIdentity else { throw BoardError.notAuthorized }; try write(journal) }
    func recoveryData() throws -> Data {
        guard authorized, owner == api.storageIdentity else { throw BoardError.notAuthorized }
        return try JSONEncoder().encode(journal)
    }
    func retainUnconvertedInk(_ data: Data, id: String) throws {
        guard authorized, snapshot?.space.member == true, owner == api.storageIdentity else { throw BoardError.notAuthorized }
        var next = journal
        var ink = next.recoveryInk ?? [:]; ink[id] = data; next.recoveryInk = ink
        try install(next); updateStatus(); onChange?()
    }
    func discardUnconvertedInk() throws {
        guard authorized, snapshot?.space.member == true, owner == api.storageIdentity else { throw BoardError.notAuthorized }
        var next = journal; next.recoveryInk = nil
        try install(next); updateStatus(); onChange?()
    }
    private func check(_ ticket: Int) throws {
        try Task.checkCancellation()
        guard ticket == generation, owner == api.storageIdentity else { throw BoardError.notAuthorized }
    }
    private func accept(_ remote: SpaceSnapshot) throws {
        guard remote.space.id == spaceID else { throw BoardError.invalidDocument("Unexpected space identity") }
        try validate(remote.board)
        guard boardIssues(remote.board).isEmpty else { throw BoardError.invalidDocument("Invalid remote board") }
    }
    func open() async throws {
        guard !busy else { throw BoardError.journal("Board request already in progress") }
        busy = true; defer { busy = false; onChange?() }
        let ticket = generation
        let priorOwner = owner
        do {
            guard priorOwner == nil || priorOwner == api.storageIdentity else { throw BoardError.notAuthorized }
            let remote = try await api.space(id: spaceID)
            let identity = api.storageIdentity
            guard ticket == generation, priorOwner == nil || priorOwner == identity else { throw BoardError.notAuthorized }
            try accept(remote)
            let url = journalURL(identity)
            var loaded = Journal(identity: identity, spaceID: spaceID, base: remote.board, local: remote.board)
            // Public readers never adopt or write a member's pending draft.
            if remote.space.member && FileManager.default.fileExists(atPath: url.path) {
                do {
                    loaded = try JSONDecoder().decode(Journal.self, from: Data(contentsOf: url))
                    guard loaded.version == 1, loaded.identity == identity, loaded.spaceID == spaceID else { throw BoardError.journal("Journal scope mismatch") }
                    try validate(loaded.base); try validate(loaded.local)
                    if let intent = loaded.intent { try validate(intent.original); try validate(intent.local) }
                } catch { throw BoardError.journal("Board journal is corrupt; retained on disk") }
            }
            if !remote.space.member, owner == identity { loaded = journal }
            owner = identity; file = url; journal = loaded; snapshot = remote; authorized = true
            if remote.space.member { try synchronize(remote, resolutions: []) }
            else { status = "Read only" }
        } catch { fail(error); throw error }
    }
    func edit(_ board: BoardDocument, native: [String: Data] = [:]) throws {
        try edit(board, from: journal.local, native: native)
    }
    func edit(_ board: BoardDocument, from original: BoardDocument, native: [String: Data] = [:]) throws {
        guard authorized, snapshot?.space.member == true, owner == api.storageIdentity else { throw BoardError.notAuthorized }
        guard !editing, !hasPendingIntent else { throw BoardError.journal("Review the pending contact before editing") }
        editing = true
        defer { editing = false }
        let ticket = generation
        try validate(original); try validate(board)
        guard boardIssues(original).isEmpty, boardIssues(board).isEmpty else { throw BoardError.invalidDocument("Invalid board composition") }
        for id in native.keys {
            guard let element = board.element(id), !element.deleted else { throw BoardError.invalidDocument("Native archive has no live element") }
        }
        var next = journal
        if let composed = mergeBoards(original, board, journal.local) {
            try validate(composed)
            next.local = composed
            addArchives(native, from: board, to: &next)
        } else {
            next.intent = Intent(original: original, local: board, native: native)
        }
        for id in native.keys { next.recoveryInk?.removeValue(forKey: id) }
        try check(ticket)
        try install(next)
        recomputeConflicts(); updateStatus(); onChange?()
    }
    private func addArchives(_ native: [String: Data], from board: BoardDocument, to next: inout Journal) {
        for (id, data) in native {
            if let element = board.element(id), let composed = next.local.element(id), composed.semanticEqual(element) {
                next.archives[id] = Archive(element: element, data: data)
            }
        }
    }
    private func recomputeConflicts() {
        if let intent = journal.intent {
            conflicts = boardConflicts(intent.original, intent.local, journal.local)
        } else if let remote = snapshot {
            conflicts = boardConflicts(journal.base, journal.local, remote.board)
        } else { conflicts = [] }
    }
    private func synchronize(_ remote: SpaceSnapshot, resolutions: [BoardResolution]) throws {
        snapshot = remote
        let merged: BoardDocument?
        if dirty {
            conflicts = boardConflicts(journal.base, journal.local, remote.board, resolutions: resolutions)
            merged = mergeBoards(journal.base, journal.local, remote.board, resolutions: resolutions)
        } else { conflicts = []; merged = remote.board }
        guard let merged, conflicts.isEmpty else {
            if hasPendingIntent { recomputeConflicts() }
            updateStatus(); return
        }
        try validate(merged)
        var next = journal; next.local = merged
        // An unsaved composition never becomes a merge baseline.
        if sameBoard(merged, remote.board) { next.base = remote.board }
        try install(next); recomputeConflicts(); updateStatus()
    }
    func refresh() async { await sync(resolutions: []) }
    func resolve(_ resolutions: [BoardResolution]) async {
        guard authorized, !busy, owner == api.storageIdentity, snapshot?.space.member == true else { return }
        if let intent = journal.intent {
            do {
                let choices = boardConflicts(intent.original, intent.local, journal.local, resolutions: resolutions)
                guard choices.isEmpty, let composed = mergeBoards(intent.original, intent.local, journal.local, resolutions: resolutions) else {
                    conflicts = choices; updateStatus(); onChange?(); return
                }
                try validate(composed)
                var next = journal; next.local = composed; next.intent = nil
                addArchives(intent.native, from: intent.local, to: &next)
                try install(next)
                recomputeConflicts(); updateStatus()
            } catch { fail(error); return }
            await sync(resolutions: [])
        } else { await sync(resolutions: resolutions) }
    }
    private func sync(resolutions: [BoardResolution]) async {
        guard authorized, !busy, owner == api.storageIdentity else { return }
        busy = true; defer { busy = false; onChange?() }
        let ticket = generation
        do {
            for attempt in 0..<3 {
                let remote = try await api.space(id: spaceID); try check(ticket); try accept(remote)
                guard remote.space.member else { snapshot = remote; status = "Read only; pending edits retained"; return }
                if snapshot?.space.member == false, let file, FileManager.default.fileExists(atPath: file.path) {
                    let retained = try JSONDecoder().decode(Journal.self, from: Data(contentsOf: file))
                    guard retained.version == 1, retained.identity == owner, retained.spaceID == spaceID else { throw BoardError.journal("Journal scope mismatch") }
                    try validate(retained.base); try validate(retained.local)
                    if let intent = retained.intent { try validate(intent.original); try validate(intent.local) }
                    journal = retained
                }
                try synchronize(remote, resolutions: resolutions)
                guard !hasPendingIntent, conflicts.isEmpty, !sameBoard(journal.local, remote.board) else { return }
                let sent = journal.local
                // Persist full original baseline and submitted draft before the PUT.
                try persist()
                do {
                    let revision = try await api.saveBoard(id: spaceID, revision: remote.space.revision, board: sent)
                    try check(ticket)
                    var next = journal; next.base = sent
                    // edit() may have replaced local during the await. Never roll it back.
                    try install(next)
                    var accepted = remote; accepted.board = sent; accepted.space.revision = revision; snapshot = accepted
                    recomputeConflicts(); updateStatus(); return
                } catch PaperError.http(409, _) {
                    if attempt == 2 { status = "Space is changing; pending edits retained" }
                }
            }
        } catch { fail(error) }
    }
    func useServer() async throws {
        guard authorized, !busy, snapshot?.space.member == true else { throw BoardError.notAuthorized }
        busy = true; defer { busy = false; onChange?() }
        let ticket = generation, reviewed = journal.local, reviewedIntent = journal.intent
        do {
            let remote = try await api.space(id: spaceID); try check(ticket); try accept(remote)
            guard remote.space.member else { throw BoardError.notAuthorized }
            guard journal.local == reviewed, journal.intent == reviewedIntent else { throw BoardError.journal("Draft changed while fetching server copy; review again") }
            var next = journal; next.base = remote.board; next.local = remote.board; next.intent = nil; next.recoveryInk = nil
            try install(next); snapshot = remote; conflicts = []; updateStatus()
        } catch { fail(error); throw error }
    }
    func nativeStroke(for element: BoardElement) -> Data? {
        guard authorized, snapshot?.space.member == true, owner == api.storageIdentity, let current = journal.local.element(element.id),
              !current.deleted, current.semanticEqual(element), let archive = journal.archives[element.id],
              archive.element.semanticEqual(element) else { return nil }
        return archive.data
    }
    func invalidateAccess() {
        generation += 1; authorized = false; snapshot = nil; conflicts = []
        status = "Space access is no longer authorized; pending edits retained"; onChange?()
    }
    private func updateStatus() {
        status = hasUnconvertedInk ? "Unconverted Pencil ink retained; export recovery" : hasPendingIntent || !conflicts.isEmpty ? "Conflicting board edits need a choice" : dirty ? "Pending edits" : "Saved"
    }
    private func fail(_ error: Error) {
        if (error as? PaperError)?.deniesAccess == true { invalidateAccess() }
        if let e = error as? BoardError, case .notAuthorized = e { invalidateAccess() }
        status = error.localizedDescription; onChange?()
    }
}
