import UIKit
import UniformTypeIdentifiers

@MainActor enum SpacePanels {
    static func presentAccount(from: UIViewController, api: SpaceAPI, onSignOut: @escaping () -> Void) {
        from.present(UINavigationController(rootViewController: SpaceAccountController(api: api, onSignOut: onSignOut)), animated: true)
    }
    enum Kind { case settings, history, papers, agents, imports }
    static func present(kind: Kind, from: UIViewController, api: SpaceAPI, session: BoardSession, onOpenPaper: ((String) -> Void)? = nil) {
        guard let snapshot = session.snapshot, session.authorized else { return }
        let panel = SpacePanelController(kind: kind, api: api, session: session, snapshot: snapshot)
        panel.onOpenPaper = onOpenPaper
        let navigation = UINavigationController(rootViewController: panel); navigation.modalPresentationStyle = .pageSheet
        from.present(navigation, animated: true)
    }
    static func presentSettings(from: UIViewController, api: SpaceAPI, session: BoardSession) { present(kind: .settings, from: from, api: api, session: session) }
    static func presentHistory(from: UIViewController, api: SpaceAPI, session: BoardSession) { present(kind: .history, from: from, api: api, session: session) }
    static func presentPapers(from: UIViewController, api: SpaceAPI, session: BoardSession, onOpenPaper: ((String) -> Void)? = nil) { present(kind: .papers, from: from, api: api, session: session, onOpenPaper: onOpenPaper) }
    static func presentAgents(from: UIViewController, api: SpaceAPI, session: BoardSession) { present(kind: .agents, from: from, api: api, session: session) }
    static func presentImports(from: UIViewController, api: SpaceAPI, session: BoardSession) { present(kind: .imports, from: from, api: api, session: session) }
}

@MainActor private final class SpacePanelController: UITableViewController, UIDocumentPickerDelegate {
    struct Row { var title: String; var detail: String? = nil; var action: () -> Void }
    let kind: SpacePanels.Kind; let api: SpaceAPI; let session: BoardSession
    var snapshot: SpaceSnapshot; var rows: [Row] = []; var history: [SpaceHistory] = []; var agents: [SpaceAgent] = []
    var onOpenPaper: ((String) -> Void)?
    private var busy = false
    init(kind: SpacePanels.Kind, api: SpaceAPI, session: BoardSession, snapshot: SpaceSnapshot) {
        self.kind = kind; self.api = api; self.session = session; self.snapshot = snapshot; super.init(style: .plain)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) unsupported") }
    override func viewDidLoad() {
        super.viewDidLoad(); view.backgroundColor = .white
        navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .done, target: self, action: #selector(close))
        navigationItem.leftBarButtonItem = UIBarButtonItem(barButtonSystemItem: .refresh, target: self, action: #selector(load))
        switch kind { case .settings: title = "Space settings"; case .history: title = "History"; case .papers: title = "Papers"; case .agents: title = "Agent access"; case .imports: title = "Add PDF" }
        load()
    }
    @objc private func close() { dismiss(animated: true) }
    @objc private func load() {
        run {
            self.snapshot = try await self.api.space(id: self.snapshot.space.id)
            switch self.kind {
            case .history: self.history = try await self.api.history(id: self.snapshot.space.id)
            case .agents: self.agents = try await self.api.agents(id: self.snapshot.space.id)
            default: break
            }
            self.rebuild()
        }
    }
    private func rebuild() {
        rows = []
        switch kind {
        case .settings:
            rows.append(Row(title: snapshot.space.title, detail: snapshot.space.visibility) { [weak self] in self?.settings() })
            if snapshot.space.member { rows.append(Row(title: "Create membership invitation") { [weak self] in self?.invite() }) }
        case .history:
            for item in history { rows.append(Row(title: "Revision \(item.revision)", detail: "\(item.kind) · \(item.actor)") { [weak self] in self?.restore(item) }) }
        case .papers:
            for paper in snapshot.papers {
                rows.append(Row(title: paper.title, detail: paper.isRead == true ? "Read" : nil) { [weak self] in self?.paper(paper) })
            }
        case .agents:
            rows.append(Row(title: "Create access") { [weak self] in self?.createAgent() })
            for agent in agents { rows.append(Row(title: agent.name, detail: agent.revokedAt == nil ? "Revoke" : "Revoked") { [weak self] in if agent.revokedAt == nil { self?.revoke(agent) } }) }
        case .imports:
            rows.append(Row(title: "Choose PDF") { [weak self] in self?.choosePDF() })
            rows.append(Row(title: "Import arXiv") { [weak self] in self?.importURL(arxiv: true) })
            rows.append(Row(title: "Import PDF URL") { [weak self] in self?.importURL(arxiv: false) })
        }
        tableView.reloadData()
    }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { rows.count }
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let row = rows[indexPath.row]; let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        cell.textLabel?.text = row.title; cell.detailTextLabel?.text = row.detail; cell.accessoryType = .disclosureIndicator; return cell
    }
    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) { tableView.deselectRow(at: indexPath, animated: true); guard !busy else { return }; rows[indexPath.row].action() }
    private func run(_ action: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }; busy = true; navigationItem.leftBarButtonItem?.isEnabled = false
        Task {
            defer { busy = false; navigationItem.leftBarButtonItem?.isEnabled = true }
            do { try await action() } catch {
                if (error as? PaperError)?.deniesAccess == true { session.invalidateAccess(); rows = []; tableView.reloadData() }
                message(error.localizedDescription)
            }
        }
    }
    private func message(_ text: String) { let alert = UIAlertController(title: title, message: text, preferredStyle: .alert); alert.addAction(UIAlertAction(title: "OK", style: .default)); present(alert, animated: true) }
    private func confirm(_ title: String, message: String? = nil, action: @escaping () -> Void) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel)); alert.addAction(UIAlertAction(title: "Confirm", style: .destructive) { _ in action() }); present(alert, animated: true)
    }
    private func prompt(_ title: String, value: String = "", action: @escaping (String) -> Void) {
        let alert = UIAlertController(title: title, message: nil, preferredStyle: .alert)
        alert.addTextField { $0.text = value; $0.autocorrectionType = .no; $0.autocapitalizationType = .none }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel)); alert.addAction(UIAlertAction(title: "Continue", style: .default) { [weak alert] _ in if let value = alert?.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty { action(value) } }); present(alert, animated: true)
    }
    private func settings() {
        guard snapshot.space.member else { return }
        prompt("Title", value: snapshot.space.title) { [weak self] title in
            guard let self, title.count <= 120 else { return }
            let expected = self.snapshot.space.revision
            let alert = UIAlertController(title: "Visibility", message: nil, preferredStyle: .alert)
            for visibility in ["private", "public", "preview"] {
                alert.addAction(UIAlertAction(title: visibility.capitalized, style: .default) { [weak self] _ in
                    self?.run { guard let self else { return }; _ = try await self.api.updateSpace(id: self.snapshot.space.id, title: title, visibility: visibility, revision: expected); await self.session.refresh(); self.loadAfterMutation() }
                })
            }
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel)); self.present(alert, animated: true)
        }
    }
    private func loadAfterMutation() { if let snapshot = session.snapshot { self.snapshot = snapshot }; rebuild() }
    private func restore(_ item: SpaceHistory) {
        guard !session.dirty else { message("Save or resolve board edits before restoring."); return }
        guard snapshot.space.member, item.revision != snapshot.space.revision else { return }
        let revision = snapshot.space.revision
        confirm("Restore revision \(item.revision)?", message: "Replaces board, PDFs, annotations and settings. Current content remains in history.") { [weak self] in
            guard let self else { return }; self.run {
                guard !self.session.dirty else { throw NSError(domain: "Space", code: 1, userInfo: [NSLocalizedDescriptionKey: "Save or resolve board edits before restoring."]) }
                _ = try await self.api.restore(id: self.snapshot.space.id, historyID: item.id, revision: revision)
                await self.session.refresh(); self.loadAfterMutation(); self.history = try await self.api.history(id: self.snapshot.space.id); self.rebuild()
            }
        }
    }
    private func invite() { run { let url = try await self.api.invitation(id: self.snapshot.space.id); self.showText(title: "Membership invitation", text: url.absoluteString, secret: false) } }
    private func showText(title: String, text: String, secret: Bool) {
        let controller = SpaceCopyController(title: title, text: text, secret: secret)
        navigationController?.pushViewController(controller, animated: true)
    }
    private func createAgent() {
        prompt("Agent name") { [weak self] name in self?.run {
            guard let self else { return }
            let result = try await self.api.createAgent(id: self.snapshot.space.id, name: name)
            self.agents.append(result.agent); self.rebuild()
            let a = result.access
            self.showText(title: "Copy now · shown once", text: "Space ID: \(a.spaceID)\nAPI: \(a.apiBase)\nBearer token: \(a.token)\nGuide: \(a.guideURL)\nContext: \(a.contextURL)\n\nUse this token only in the Authorization header for this origin and space. Fetch current state before edits; preserve unrelated content and reconcile revision conflicts. Keep the credential private.", secret: true)
        } }
    }
    private func revoke(_ agent: SpaceAgent) {
        confirm("Revoke \(agent.name)?") { [weak self] in self?.run { guard let self else { return }; try await self.api.revokeAgent(id: self.snapshot.space.id, agentID: agent.id); self.agents = try await self.api.agents(id: self.snapshot.space.id); self.rebuild() } }
    }
    private func paper(_ paper: PaperInfo) {
        let alert = UIAlertController(title: paper.title, message: nil, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Open", style: .default) { [weak self] _ in guard let self else { return }; self.dismiss(animated: true) { self.onOpenPaper?(paper.id) } })
        if snapshot.space.member { alert.addAction(UIAlertAction(title: paper.isRead == true ? "Mark unread" : "Mark read", style: .default) { [weak self] _ in self?.run { guard let self else { return }; try await self.api.markRead(paperID: paper.id, read: paper.isRead != true); self.snapshot = try await self.api.space(id: self.snapshot.space.id); self.rebuild() } }) }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel)); present(alert, animated: true)
    }
    private func importURL(arxiv: Bool) {
        guard snapshot.space.member else { return }
        prompt(arxiv ? "arXiv URL" : "PDF URL") { [weak self] url in self?.run { guard let self else { return }; _ = try await self.api.importPaper(id: self.snapshot.space.id, url: url, arxiv: arxiv); await self.session.refresh(); self.loadAfterMutation() } }
    }
    private func choosePDF() { guard snapshot.space.member else { return }; let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.pdf], asCopy: true); picker.delegate = self; picker.allowsMultipleSelection = false; present(picker, animated: true) }
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first else { return }
        run {
            let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= 40 * 1024 * 1024 else { throw PaperError.oversized }
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            _ = try await self.api.uploadPDF(id: self.snapshot.space.id, data: data, filename: url.lastPathComponent)
            await self.session.refresh(); self.loadAfterMutation()
        }
    }
}

@MainActor private final class SpaceCopyController: UIViewController {
    private let text: UITextView = { let view = UITextView(); view.isEditable = false; view.font = .preferredFont(forTextStyle: .body); return view }()
    private var value: String; private let secret: Bool
    init(title: String, text: String, secret: Bool) { value = text; self.secret = secret; super.init(nibName: nil, bundle: nil); self.title = title }
    required init?(coder: NSCoder) { fatalError("init(coder:) unsupported") }
    override func viewDidLoad() { super.viewDidLoad(); view.backgroundColor = .white; text.text = value; text.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(text); NSLayoutConstraint.activate([text.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16), text.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16), text.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor), text.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor)]); navigationItem.rightBarButtonItem = UIBarButtonItem(title: "Copy", style: .plain, target: self, action: #selector(copyText)) }
    @objc private func copyText() { UIPasteboard.general.setItems([[UIPasteboard.typeAutomatic: value]], options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(300)]) }
    override func viewDidDisappear(_ animated: Bool) { super.viewDidDisappear(animated); if secret { value = ""; text.text = "" } }
}


@MainActor private final class SpaceAccountController: UITableViewController {
    let api: SpaceAPI; let onSignOut: () -> Void
    var suggestions: [SpaceSuggestion] = []; var cdn: SpaceCDNSettings?; var busy = false
    init(api: SpaceAPI, onSignOut: @escaping () -> Void) { self.api = api; self.onSignOut = onSignOut; super.init(style: .plain) }
    required init?(coder: NSCoder) { fatalError("init(coder:) unsupported") }
    override func viewDidLoad() { super.viewDidLoad(); title = "Account"; view.backgroundColor = .white; navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .done, target: self, action: #selector(close)); refresh() }
    @objc private func close() { dismiss(animated: true) }
    private func refresh() { run { self.cdn = try await self.api.cdnSettings(); self.suggestions = try await self.api.suggestions(); self.tableView.reloadData() } }
    private func run(_ operation: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }; busy = true
        Task { defer { busy = false }; do { try await operation() } catch { if (error as? PaperError)?.deniesAccess == true { suggestions = []; cdn = nil; tableView.reloadData() }; alert(error.localizedDescription) } }
    }
    private func alert(_ message: String) { let a = UIAlertController(title: "Account", message: message, preferredStyle: .alert); a.addAction(UIAlertAction(title: "OK", style: .default)); present(a, animated: true) }
    override func numberOfSections(in tableView: UITableView) -> Int { 3 }
    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? { section == 0 ? "CDN" : section == 1 ? "Suggestions" : nil }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { section == 0 ? (cdn?.origin == nil ? 1 : 2) : section == 1 ? suggestions.count + 1 : 1 }
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        if indexPath.section == 0 { cell.textLabel?.text = indexPath.row == 0 ? cdn?.origin ?? "Connect CDN" : "Disconnect CDN" }
        else if indexPath.section == 1 { if indexPath.row == 0 { cell.textLabel?.text = "New suggestion" } else { let item = suggestions[indexPath.row - 1]; cell.textLabel?.text = item.title; cell.detailTextLabel?.text = item.status } }
        else { cell.textLabel?.text = "Sign out" }; cell.accessoryType = .disclosureIndicator; return cell
    }
    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true); guard !busy else { return }
        if indexPath.section == 0 {
            if indexPath.row == 1 { confirm("Disconnect CDN?") { [weak self] in self?.run { guard let self else { return }; try await self.api.disconnectCDN(); self.cdn = try await self.api.cdnSettings(); self.tableView.reloadData() } }; return }
            let a = UIAlertController(title: "CDN", message: nil, preferredStyle: .alert)
            a.addTextField { $0.placeholder = "https://cdn.example.com"; $0.text = self.cdn?.origin; $0.autocapitalizationType = .none; $0.autocorrectionType = .no }
            a.addTextField { $0.placeholder = "Read token"; $0.isSecureTextEntry = true; $0.autocapitalizationType = .none; $0.autocorrectionType = .no }
            a.addAction(UIAlertAction(title: "Cancel", style: .cancel)); a.addAction(UIAlertAction(title: "Save", style: .default) { [weak self, weak a] _ in
                guard let origin = a?.textFields?[0].text, let token = a?.textFields?[1].text else { return }; a?.textFields?[1].text = ""
                self?.run { guard let self else { return }; try await self.api.saveCDN(origin: origin, token: token); self.cdn = try await self.api.cdnSettings(); self.tableView.reloadData() }
            }); present(a, animated: true)
        } else if indexPath.section == 1 {
            if indexPath.row == 0 {
                let a = UIAlertController(title: "Suggestion", message: nil, preferredStyle: .alert); a.addTextField { $0.placeholder = "Title" }; a.addTextField { $0.placeholder = "Suggestion" }
                a.addAction(UIAlertAction(title: "Cancel", style: .cancel)); a.addAction(UIAlertAction(title: "Submit", style: .default) { [weak self, weak a] _ in
                    guard let title = a?.textFields?[0].text, let body = a?.textFields?[1].text, !title.isEmpty, title.count <= 120, !body.isEmpty, body.count <= 20000 else { return }
                    self?.run { guard let self else { return }; try await self.api.suggest(title: title, body: body); self.suggestions = try await self.api.suggestions(); self.tableView.reloadData() }
                }); present(a, animated: true)
            } else {
                let item = suggestions[indexPath.row - 1]; let a = UIAlertController(title: item.title, message: item.body, preferredStyle: .alert)
                for status in ["open", "approved", "done", "declined"] { a.addAction(UIAlertAction(title: status.capitalized, style: .default) { [weak self] _ in self?.run { guard let self else { return }; try await self.api.updateSuggestion(id: item.id, status: status); self.suggestions = try await self.api.suggestions(); self.tableView.reloadData() } }) }
                a.addAction(UIAlertAction(title: "Cancel", style: .cancel)); present(a, animated: true)
            }
        } else { confirm("Sign out?") { [weak self] in self?.run { guard let self else { return }; try await self.api.logout(); self.dismiss(animated: true) { self.onSignOut() } } } }
    }
    private func confirm(_ title: String, action: @escaping () -> Void) { let a = UIAlertController(title: title, message: nil, preferredStyle: .alert); a.addAction(UIAlertAction(title: "Cancel", style: .cancel)); a.addAction(UIAlertAction(title: "Confirm", style: .destructive) { _ in action() }); present(a, animated: true) }
}
