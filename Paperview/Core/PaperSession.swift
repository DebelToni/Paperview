import Foundation
import CryptoKit

@MainActor final class PaperSession {
    let api: any PaperService
    let paperID: String
    private(set) var metadata: PaperMetadata?
    private(set) var annotations: [PaperAnnotation] = []
    private(set) var conflicts: [AnnotationConflict] = []
    private(set) var status = "Not opened"
    var onChange: (() -> Void)?
    private struct Delta: Codable, Equatable { var original: PaperAnnotation?; var local: PaperAnnotation? }
    private struct Archive: Codable { var annotation: PaperAnnotation; var data: Data }
    private struct Journal: Codable {
        var version = 4
        var ownerIdentity: String
        var pending: [String: Delta] = [:]
        var order: [String] = []
        var archives: [String: Archive] = [:]
    }
    private var journal = Journal(ownerIdentity: "")
    private let storageDirectory: URL
    private var file: URL?
    private var activeSelfID: String?
    private var ownerIdentity: String?
    private var inFlight: [String: Delta] = [:]
    private var generation = 0
    private var busy = false
    private var authorized = false
    private var denied = false
    init(api: any PaperService, paperID: String, storageDirectory: URL) {
        self.api = api; self.paperID = paperID
        self.storageDirectory = storageDirectory
    }
    func open() async throws -> Data {
        guard !busy else { throw PaperError.invalidResponse }
        let ticket = generation
        busy = true; defer { busy = false }
        do {
            let remote = try await api.metadata(paperID: paperID)
            try check(ticket)
            guard metadata == nil || metadata?.selfID == remote.selfID else { throw PaperError.unauthorized }
            guard remote.paper.id == paperID else { throw PaperError.invalidResponse }
            let identity = api.storageIdentity
            guard ownerIdentity == nil || ownerIdentity == identity else { throw PaperError.unauthorized }
            let key = identity + "|" + paperID
            let name = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
            let journalFile = storageDirectory.appendingPathComponent(name + ".json")
            var loaded = Journal(ownerIdentity: identity)
            if FileManager.default.fileExists(atPath: journalFile.path) {
                do {
                    loaded = try JSONDecoder().decode(Journal.self, from: Data(contentsOf: journalFile))
                    guard loaded.version == 4, Set(loaded.order).count == loaded.order.count,
                          Set(loaded.pending.keys).isSubset(of: Set(loaded.order)), loaded.pending.allSatisfy({ key, value in
                        (value.original == nil || value.original?.id == key) && (value.local == nil || value.local?.id == key)
                    }) else { throw PaperError.corruptJournal }
                } catch { throw PaperError.corruptJournal }
            }
            guard loaded.ownerIdentity == identity else { throw PaperError.unauthorized }
            file = journalFile; journal = loaded
            ownerIdentity = identity; activeSelfID = remote.selfID
            authorized = true; denied = false
            try merge(remote)
            let data = try await api.pdf(paperID: paperID)
            try check(ticket)
            updateStatus(); onChange?(); return data
        } catch { fail(error); throw error }
    }
    private func write(_ value: Journal) throws {
        guard let file else { throw PaperError.unauthorized }
        let manager = FileManager.default
        try manager.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(value).write(to: file, options: [.atomic, .completeFileProtection])
    }
    func persist() throws { guard authorized else { throw PaperError.unauthorized }; try write(journal) }
    func edit(_ value: PaperAnnotation?, id: String) throws {
        let base: PaperAnnotation?
        if let existing = journal.pending[id] { base = existing.original }
        else { base = metadata?.annotations.first(where: { $0.id == id }) }
        try edit([AnnotationEdit(id: id, original: base, value: value)])
    }
    func edit(_ edits: [AnnotationEdit]) throws {
        guard authorized, !denied, metadata?.canEdit == true else { throw PaperError.unauthorized }
        guard Set(edits.map(\.id)).count == edits.count else { throw PaperError.invalidResponse }
        var next = journal
        for edit in edits {
            guard !edit.id.isEmpty, edit.id.count <= 200,
                  edit.original == nil || edit.original?.id == edit.id,
                  edit.value == nil || edit.value?.id == edit.id,
                  edit.native == nil || edit.value != nil else { throw PaperError.invalidResponse }
            if let value = edit.value { try validate(value) }
            if !next.order.contains(edit.id) { next.order.append(edit.id) }
            if inFlight[edit.id] == nil && edit.value == edit.original && edit.value == metadata?.annotations.first(where: { $0.id == edit.id }) { next.pending.removeValue(forKey: edit.id) }
            else { next.pending[edit.id] = Delta(original: edit.original, local: edit.value) }
            if let data = edit.native, let value = edit.value {
                next.archives[edit.id] = Archive(annotation: value, data: data)
            }
        }
        var values = Dictionary(uniqueKeysWithValues: (metadata?.annotations ?? []).map { ($0.id, $0) })
        for (id, delta) in next.pending { values[id] = delta.local }
        guard values.count <= 10000, next.pending.count <= 10000 else { throw PaperError.oversized }
        guard try JSONEncoder().encode(Array(values.values)).count <= 25 * 1024 * 1024 - 1024 else { throw PaperError.oversized }
        next.order.removeAll { next.pending[$0] == nil }
        try write(next); journal = next
        rebuild(); updateStatus(); onChange?()
    }
    private func validate(_ value: PaperAnnotation) throws {
        func unit(_ x: Double) -> Bool { x.isFinite && (0...1).contains(x) }
        guard (1...10000).contains(value.page),
              value.color.range(of: "^#(?:[0-9a-fA-F]{3}|[0-9a-fA-F]{4}|[0-9a-fA-F]{6}|[0-9a-fA-F]{8})$", options: .regularExpression) != nil,
              value.points == nil || (value.points!.count <= 20000 && value.points!.allSatisfy { $0.count == 2 && $0.allSatisfy(unit) }),
              value.x == nil || unit(value.x!), value.y == nil || unit(value.y!),
              value.size == nil || (value.size!.isFinite && value.size! > 0 && value.size! <= 200),
              (value.text?.unicodeScalars.count ?? 0) <= 10000,
              value.type == .text ? (value.x != nil && value.y != nil && value.text != nil) : !(value.points?.isEmpty ?? true)
        else { throw PaperError.invalidResponse }
    }
    private func updateStatus() {
        status = !conflicts.isEmpty ? "Conflicting annotations need a choice" : (journal.pending.isEmpty ? "Saved" : "Pending edits")
    }
    private func check(_ ticket: Int) throws {
        try Task.checkCancellation()
        guard ticket == generation, ownerIdentity == nil || ownerIdentity == api.storageIdentity else { throw PaperError.unauthorized }
    }
    func invalidateAccess() {
        generation += 1; denied = true; authorized = false
        metadata = nil; annotations = []; conflicts = []
        status = "Paper access is no longer authorized"; onChange?()
    }
    private func applying(_ pending: [String: Delta], to base: [PaperAnnotation]) -> [PaperAnnotation] {
        let existing = Set(base.map(\.id))
        var result = base.compactMap { value in
            if let delta = pending[value.id] { return delta.local }
            return value
        }
        for id in journal.order where !existing.contains(id) {
            if let value = pending[id]?.local { result.append(value) }
        }
        return result
    }
    private func rebuild() {
        guard let metadata else { return }
        annotations = applying(journal.pending, to: metadata.annotations)
        conflicts = journal.pending.compactMap { id, delta in
            let remote = metadata.annotations.first { $0.id == id }
            return remote != delta.original && remote != delta.local ? AnnotationConflict(id: id, local: delta.local, remote: remote, original: delta.original) : nil
        }.sorted { $0.id < $1.id }
    }
    private func merge(_ remote: PaperMetadata) throws {
        guard remote.paper.id == paperID, Set(remote.annotations.map(\.id)).count == remote.annotations.count else { throw PaperError.invalidResponse }
        guard remote.selfID == activeSelfID, api.storageIdentity == ownerIdentity else { throw PaperError.unauthorized }
        var next = journal
        for (id, delta) in next.pending where remote.annotations.first(where: { $0.id == id }) == delta.local { next.pending.removeValue(forKey: id) }
        try write(next); journal = next; metadata = remote; rebuild()
    }
    func resolve(id: String, keepMine: Bool) throws {
        guard authorized, !denied, metadata?.canEdit == true else { throw PaperError.unauthorized }
        guard let conflict = conflicts.first(where: { $0.id == id }) else { return }
        var next = journal
        if keepMine { next.pending[id] = Delta(original: conflict.remote, local: conflict.local) }
        else { next.pending.removeValue(forKey: id) }
        try write(next); journal = next; rebuild(); updateStatus(); onChange?()
    }
    func refresh() async {
        guard authorized, !denied, !busy else { return }
        let ticket = generation
        busy = true; defer { busy = false; onChange?() }
        do {
            for attempt in 0..<3 {
                let fetched = try await api.metadata(paperID: paperID)
                try check(ticket)
                try merge(fetched)
                guard metadata?.canEdit == true else {
                    status = journal.pending.isEmpty ? "Read only" : "Read only; pending edits retained"
                    return
                }
                let blocked = Set(conflicts.map(\.id))
                let submitted = journal.pending.filter { !blocked.contains($0.key) }
                guard !submitted.isEmpty, var remote = metadata else {
                    status = conflicts.isEmpty ? "Saved" : "Conflicting annotations need a choice"; return
                }
                let sent = applying(submitted, to: remote.annotations)
                do {
                    inFlight = submitted
                    defer { inFlight = [:] }
                    let revision = try await api.save(paperID: paperID, revision: remote.revision, annotations: sent)
                    try check(ticket)
                    var next = journal
                    for (id, delta) in submitted {
                        if next.pending[id] == delta { next.pending.removeValue(forKey: id) }
                        else if let newer = next.pending[id] { next.pending[id] = Delta(original: delta.local, local: newer.local) }
                        // A user reverting an in-flight edit must undo the submitted value.
                        else if delta.local != delta.original { next.pending[id] = Delta(original: delta.local, local: delta.original) }
                    }
                    try write(next); journal = next
                    remote.revision = revision; remote.annotations = sent; metadata = remote; rebuild()
                    updateStatus(); return
                } catch PaperError.http(409, _) {
                    if attempt == 2 { status = "Space is changing; pending edits retained" }
                }
            }
        } catch { fail(error) }
    }
    func flush() async { await refresh() }
    private func fail(_ error: Error) {
        if let error = error as? PaperError, error.deniesAccess {
            generation += 1; denied = true; authorized = false; metadata = nil; annotations = []; conflicts = []
        }
        status = error.localizedDescription; onChange?()
    }
    func saveNativeStroke(_ data: Data, annotation: PaperAnnotation) throws {
        guard authorized, !denied, annotations.contains(annotation) else { throw PaperError.unauthorized }
        var next = journal; next.archives[annotation.id] = Archive(annotation: annotation, data: data)
        try write(next); journal = next
    }
    func nativeStroke(for annotation: PaperAnnotation) -> Data? {
        guard authorized, !denied, annotations.contains(annotation), let archive = journal.archives[annotation.id], archive.annotation == annotation else { return nil }
        return archive.data
    }
}
