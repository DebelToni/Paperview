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
    var dirty: Bool { hasPendingIntent || hasUnconvertedInk || journal.submission != nil || boardDirty }
    private(set) var boardGeneration = 0
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
    var hasPendingSubmission: Bool { journal.submission != nil }
    // Persisted before PUT, including the local branch before any borrowed remote
    // edits. An unknown response must not turn an in-flight revert into a clean draft.
    private struct Submission: Codable {
        var revision: Int
        var remote: BoardDocument
        var original: BoardDocument
        var sent: BoardDocument
        var acceptedRevision: Int? = nil
    }
    private struct Journal: Codable {
        var version = 1
        var identity: String
        var spaceID: String
        var base: BoardDocument = .empty
        var local: BoardDocument = .empty
        var archives: [String: Archive] = [:]
        var intent: Intent? = nil
        var recoveryInk: [String: Data]? = nil
        var submission: Submission? = nil
    }
    private var journal: Journal
    private var boardDirty = false
    private var localElements: [String: BoardElement] = [:]
    private var journalGeneration = 0
    private struct ChangeState: Equatable {
        var journal: Int
        var board: Int
        var authorized: Bool
        var identity: String
        var space: SpaceSummary?
        var creators: [String: AnnotationCreator]
        var papers: [PaperInfo]
        var conflicts: [BoardConflict]
        var status: String
    }
    private var notified: ChangeState?
    private func notify() {
        let state = ChangeState(journal: journalGeneration, board: boardGeneration, authorized: authorized,
                                identity: api.storageIdentity, space: snapshot?.space, creators: snapshot?.creators ?? [:],
                                papers: snapshot?.papers ?? [], conflicts: conflicts, status: status)
        guard state != notified else { return }
        notified = state; onChange?()
    }
    private func adopt(_ next: Journal) {
        if !sameBoard(journal.local, next.local) {
            boardGeneration += 1
            localElements = Dictionary(next.local.elements.map { ($0.id, $0) }, uniquingKeysWith: { _, b in b })
        }
        boardDirty = !sameBoard(next.local, next.base)
        journal = next; journalGeneration += 1
    }
    private func setSnapshot(_ remote: SpaceSnapshot) {
        let before = storedSnapshot?.space.member == false ? storedSnapshot!.board : journal.local
        let after = remote.space.member ? journal.local : remote.board
        if !sameBoard(before, after) { boardGeneration += 1 }
        snapshot = remote
    }
    private var file: URL?
    private let directory: URL
    private let validate: @MainActor (BoardDocument) throws -> Void
    private var owner: String?
    private var busy = false
    private var editing = false
    private var uploading = false
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
    private func install(_ next: Journal) throws { try write(next); adopt(next) }
    func persist() throws { guard authorized, owner == api.storageIdentity else { throw BoardError.notAuthorized }; try write(journal) }
    func recoveryData() throws -> Data {
        guard authorized, owner == api.storageIdentity else { throw BoardError.notAuthorized }
        return try JSONEncoder().encode(journal)
    }
    func retainUnconvertedInk(_ data: Data, id: String) throws {
        guard authorized, snapshot?.space.member == true, owner == api.storageIdentity else { throw BoardError.notAuthorized }
        var next = journal
        var ink = next.recoveryInk ?? [:]; ink[id] = data; next.recoveryInk = ink
        try install(next); updateStatus(); notify()
    }
    func discardUnconvertedInk() throws {
        guard authorized, snapshot?.space.member == true, owner == api.storageIdentity else { throw BoardError.notAuthorized }
        var next = journal; next.recoveryInk = nil
        try install(next); updateStatus(); notify()
    }
    private func check(_ ticket: Int) throws {
        try Task.checkCancellation()
        guard ticket == generation, owner == api.storageIdentity else { throw BoardError.notAuthorized }
    }
    private func accept(_ value: SpaceSnapshot) throws -> SpaceSnapshot {
        guard value.space.id == spaceID, value.space.revision >= 0 else { throw BoardError.invalidDocument("Unexpected space identity or revision") }
        if let previous = snapshot, value.space.revision < previous.space.revision { throw BoardError.invalidDocument("Out-of-order board response; pending edits retained") }
        var remote = value
        if let previous = snapshot, sameBoard(previous.board, remote.board) {
            // known_revision polls still refresh authorization/metadata. They do not
            // need another Rust handle, index build or full request-size encoding.
            remote.board = previous.board
        } else {
            remote.board = canonicalBoard(remote.board)
            try validate(remote.board)
            guard boardIssues(remote.board).isEmpty else { throw BoardError.invalidDocument("Invalid remote board") }
        }
        return remote
    }
    private func load(_ url: URL, identity: String) throws -> Journal {
        do {
            var loaded = try JSONDecoder().decode(Journal.self, from: Data(contentsOf: url))
            guard loaded.version == 1, loaded.identity == identity, loaded.spaceID == spaceID else { throw BoardError.journal("Journal scope mismatch") }
            loaded.base = canonicalBoard(loaded.base); loaded.local = canonicalBoard(loaded.local)
            try validate(loaded.base); try validate(loaded.local)
            if var intent = loaded.intent {
                intent.original = canonicalBoard(intent.original); intent.local = canonicalBoard(intent.local)
                try validate(intent.original); try validate(intent.local); loaded.intent = intent
            }
            if var submission = loaded.submission {
                submission.remote = canonicalBoard(submission.remote); submission.original = canonicalBoard(submission.original); submission.sent = canonicalBoard(submission.sent)
                try validate(submission.remote); try validate(submission.original); try validate(submission.sent)
                guard submission.revision >= 0, submission.acceptedRevision.map({ $0 > submission.revision }) ?? true else { throw BoardError.journal("Invalid submission revision") }
                loaded.submission = submission
            }
            loaded.archives = loaded.archives.mapValues { Archive(element: canonicalBoardElement($0.element), data: $0.data) }
            return loaded
        } catch { throw BoardError.journal("Board journal is corrupt; retained on disk") }
    }
    func open() async throws {
        guard !busy else { throw BoardError.journal("Board request already in progress") }
        busy = true; defer { busy = false; notify() }
        let ticket = generation
        let priorOwner = owner
        do {
            guard priorOwner == nil || priorOwner == api.storageIdentity else { throw BoardError.notAuthorized }
            let response = try await api.space(id: spaceID)
            try Task.checkCancellation()
            let identity = api.storageIdentity
            guard ticket == generation, priorOwner == nil || priorOwner == identity else { throw BoardError.notAuthorized }
            let remote = try accept(response)
            let url = journalURL(identity)
            var loaded = Journal(identity: identity, spaceID: spaceID, base: remote.board, local: remote.board)
            // Public readers never adopt or write a member's pending draft.
            if remote.space.member && FileManager.default.fileExists(atPath: url.path) {
                loaded = try load(url, identity: identity)
            }
            if !remote.space.member, owner == identity { loaded = journal }
            owner = identity; file = url; adopt(loaded); setSnapshot(remote); authorized = true
            if remote.space.member {
                if !FileManager.default.fileExists(atPath: url.path) { try write(journal) }
                _ = try synchronize(remote, resolutions: [])
            }
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
        let original = canonicalBoard(original), board = canonicalBoard(board)
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
        recomputeConflicts(); updateStatus(); notify()
    }
    private func addArchives(_ native: [String: Data], from board: BoardDocument, to next: inout Journal) {
        guard !native.isEmpty else { return }
        let source = Dictionary(board.elements.map { ($0.id, $0) }, uniquingKeysWith: { _, b in b })
        let composed = Dictionary(next.local.elements.map { ($0.id, $0) }, uniquingKeysWith: { _, b in b })
        for (id, data) in native {
            if let element = source[id], let current = composed[id], current.semanticEqual(element) {
                next.archives[id] = Archive(element: element, data: data)
            }
        }
    }
    private func recognized(_ submission: Submission, by remote: SpaceSnapshot) -> Bool {
        submission.acceptedRevision.map { remote.space.revision >= $0 } ??
            (remote.space.revision > submission.revision && sameBoard(remote.board, submission.sent))
    }
    private func reconciliation(_ remote: SpaceSnapshot, resolutions: [BoardResolution] = []) -> BoardMergeResult {
        guard let submission = journal.submission else { return reconcileBoards(journal.base, journal.local, remote.board, resolutions: resolutions) }
        if recognized(submission, by: remote) { return reconcileBoards(submission.original, journal.local, remote.board, resolutions: resolutions) }
        if uploading { return reconcileBoards(journal.base, journal.local, remote.board, resolutions: resolutions) }
        var result = reconcileBoards(journal.base, journal.local, remote.board, resolutions: resolutions)
        // Neither a network failure nor local == base proves that PUT did not
        // commit. Require fresh, version-bound choices before any uncertain retry.
        func index(_ board: BoardDocument) -> [String: BoardElement] { Dictionary(board.elements.map { ($0.id, $0) }, uniquingKeysWith: { _, b in b }) }
        let before = index(submission.remote), sent = index(submission.sent), original = index(submission.original)
        let ours = localElements, theirs = index(remote.board)
        let ids = Set(before.keys).union(sent.keys).union(original.keys).union(ours.keys).filter { before[$0] != sent[$0] || original[$0] != ours[$0] }
        let decisions = Dictionary(resolutions.map { ($0.id, $0) }, uniquingKeysWith: { _, b in b })
        for id in ids.sorted() {
            if let choice = decisions[id], choice.local.map(canonicalBoardElement) == ours[id], choice.remote.map(canonicalBoardElement) == theirs[id] { continue }
            if !result.conflicts.contains(where: { $0.kind == .element && $0.id == id }) {
                result.conflicts.append(.init(kind: .element, id: id, local: ours[id], remote: theirs[id], message: "The previous save result is unconfirmed. Review before retrying."))
            }
        }
        if ids.isEmpty { result.conflicts.append(.init(kind: .document, id: "unconfirmed-save", message: "The previous save result could not be confirmed. The draft and submission are retained; export recovery before using the server board.")) }
        if !result.conflicts.isEmpty { result.board = nil }
        return result
    }
    private func recomputeConflicts() {
        if let intent = journal.intent { conflicts = boardConflicts(intent.original, intent.local, journal.local) }
        else if let remote = snapshot { conflicts = reconciliation(remote).conflicts }
        else { conflicts = [] }
    }
    // Return a candidate without polluting the durable local branch with borrowed
    // remote edits. A failed PUT must retain both its original base and local draft.
    private func synchronize(_ remote: SpaceSnapshot, resolutions: [BoardResolution]) throws -> BoardDocument? {
        setSnapshot(remote)
        if !boardDirty, journal.submission == nil {
            if !sameBoard(journal.base, remote.board) || !sameBoard(journal.local, remote.board) {
                var next = journal; next.base = remote.board; next.local = remote.board; try install(next)
            }
            if hasPendingIntent { recomputeConflicts() } else { conflicts = [] }
            updateStatus(); return nil
        }
        let result = reconciliation(remote, resolutions: resolutions)
        conflicts = result.conflicts
        guard let merged = result.board, conflicts.isEmpty else {
            if hasPendingIntent { recomputeConflicts() }
            updateStatus(); return nil
        }
        try validate(merged)
        if let submission = journal.submission, recognized(submission, by: remote) {
            // This is an observed/acknowledged server state, never an unsaved
            // composition. Rebase only the edits completed since that submission.
            var next = journal; next.base = remote.board; next.local = merged; next.submission = nil
            try install(next)
        } else if journal.submission == nil, sameBoard(merged, remote.board) {
            var next = journal; next.base = remote.board; next.local = remote.board; try install(next)
        }
        if hasPendingIntent { recomputeConflicts() }
        updateStatus()
        return !hasPendingIntent && (journal.submission != nil || !sameBoard(merged, remote.board)) ? merged : nil
    }
    func refresh() async { await sync(resolutions: []) }
    func resolve(_ resolutions: [BoardResolution]) async {
        guard authorized, !busy, owner == api.storageIdentity, snapshot?.space.member == true else { return }
        if journal.intent != nil {
            await sync(resolutions: [])
            guard authorized, !busy, owner == api.storageIdentity, snapshot?.space.member == true, let intent = journal.intent else { return }
            do {
                let result = reconcileBoards(intent.original, intent.local, journal.local, resolutions: resolutions)
                guard result.conflicts.isEmpty, let composed = result.board else {
                    conflicts = result.conflicts; updateStatus(); notify(); return
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
        busy = true; defer { busy = false; uploading = false; notify() }
        let ticket = generation
        do {
            for attempt in 0..<3 {
                let response = try await api.space(id: spaceID); try check(ticket)
                let remote = try accept(response)
                guard remote.space.member else { setSnapshot(remote); status = "Read only; pending edits retained"; return }
                if snapshot?.space.member == false, let file, FileManager.default.fileExists(atPath: file.path) {
                    adopt(try load(file, identity: api.storageIdentity))
                }
                guard let candidate = try synchronize(remote, resolutions: resolutions), !hasPendingIntent, conflicts.isEmpty else { return }
                var sent = canonicalBoard(candidate)
                // The server also retains omitted tombstones and their assets.
                // Submit that exact form so the acknowledgement has a known base.
                let ids = Set(sent.elements.map(\.id))
                for element in remote.board.elements where element.deleted && !ids.contains(element.id) {
                    sent.elements.append(element)
                    if let id = element.assetId { sent.assets[id] = remote.board.assets[id] }
                }
                sent = sent.ordered; try validate(sent)
                let priorSubmission = journal.submission
                let submission = Submission(revision: remote.space.revision, remote: remote.board, original: journal.local, sent: sent)
                var pending = journal; pending.submission = submission
                try install(pending)
                do {
                    uploading = true
                    let revision = try await api.saveBoard(id: spaceID, revision: remote.space.revision, board: sent)
                    uploading = false
                    try check(ticket)
                    guard revision > remote.space.revision else { throw PaperError.invalidResponse }
                    var next = journal
                    let result = reconcileBoards(submission.original, journal.local, sent)
                    if let composed = result.board {
                        try validate(composed); next.base = sent; next.local = composed; next.submission = nil
                    } else {
                        var accepted = submission; accepted.acceptedRevision = revision; next.submission = accepted
                    }
                    // edit() may have journaled a new edit or a revert during PUT.
                    // Rebase that intent rather than replacing it with the sent board.
                    try install(next)
                    var accepted = remote; accepted.board = sent; accepted.space.revision = revision; setSnapshot(accepted)
                    recomputeConflicts(); updateStatus(); return
                } catch PaperError.http(409, _) {
                    uploading = false
                    // A definite rejection did not commit this submission. Restore
                    // an older uncertain receipt, if one still requires review.
                    var next = journal; next.submission = priorSubmission; try install(next)
                    if attempt == 2 { status = "Space is changing; pending edits retained" }
                }
            }
        } catch { uploading = false; fail(error) }
    }
    func useServer() async throws {
        guard authorized, !busy, snapshot?.space.member == true else { throw BoardError.notAuthorized }
        busy = true; defer { busy = false; notify() }
        let ticket = generation, reviewed = journalGeneration
        do {
            let response = try await api.space(id: spaceID); try check(ticket)
            let remote = try accept(response)
            guard remote.space.member else { throw BoardError.notAuthorized }
            guard journalGeneration == reviewed else { throw BoardError.journal("Draft changed while fetching server copy; review again") }
            var next = journal; next.base = remote.board; next.local = remote.board; next.intent = nil; next.recoveryInk = nil; next.submission = nil
            try install(next); setSnapshot(remote); conflicts = []; updateStatus()
        } catch { fail(error); throw error }
    }
    func nativeStroke(for element: BoardElement) -> Data? {
        guard authorized, snapshot?.space.member == true, owner == api.storageIdentity, let current = localElements[element.id],
              !current.deleted, current.semanticEqual(canonicalBoardElement(element)), let archive = journal.archives[element.id],
              archive.element.semanticEqual(canonicalBoardElement(element)) else { return nil }
        return archive.data
    }
    func invalidateAccess() {
        generation += 1; boardGeneration += 1; authorized = false; snapshot = nil; conflicts = []
        status = "Space access is no longer authorized; pending edits retained"; notify()
    }
    private func updateStatus() {
        status = hasUnconvertedInk ? "Unconverted Pencil ink retained; export recovery" : journal.submission != nil && !uploading ? "Previous board save needs confirmation; edits retained" : hasPendingIntent || !conflicts.isEmpty ? "Conflicting board edits need a choice" : dirty ? "Pending edits" : "Saved"
    }
    private func fail(_ error: Error) {
        if (error as? PaperError)?.deniesAccess == true { invalidateAccess() }
        if let e = error as? BoardError, case .notAuthorized = e { invalidateAccess() }
        status = error.localizedDescription; notify()
    }
}
