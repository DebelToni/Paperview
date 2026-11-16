import UIKit

@MainActor final class SpaceHomeController: UITableViewController {
    let api: SpaceAPI
    var onOpenSpace: ((String) -> Void)?
    var onOpenPaper: ((String) -> Void)?
    var onSignIn: (() -> Void)?
    var onAccount: (() -> Void)?
    private var user: SpaceIdentity?
    private var listing: SpaceListing?
    private let tabs = UISegmentedControl(items: ["Spaces", "Discover", "Requests"])
    private var busy = false
    private var timer: Timer?
    init(api: SpaceAPI) { self.api = api; super.init(style: .plain) }
    required init?(coder: NSCoder) { fatalError("init(coder:) unsupported") }
    override func viewDidLoad() {
        super.viewDidLoad(); title = "Space"; view.backgroundColor = .white
        tableView.accessibilityIdentifier = "space.home"
        tabs.accessibilityIdentifier = "space.sections"
        navigationItem.titleView = tabs; tabs.selectedSegmentIndex = 0
        tabs.addTarget(self, action: #selector(changeTab), for: .valueChanged)
        navigationItem.leftBarButtonItem = UIBarButtonItem(title: "Account", style: .plain, target: self, action: #selector(account))
        navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .add, target: self, action: #selector(create))
        refreshControl = UIRefreshControl(); refreshControl?.addTarget(self, action: #selector(reloadData), for: .valueChanged)
    }
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated); reloadData()
        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in Task { @MainActor in self?.reloadData() } }
    }
    override func viewWillDisappear(_ animated: Bool) { super.viewWillDisappear(animated); timer?.invalidate(); timer = nil }
    @objc private func changeTab() { tableView.reloadData() }
    @objc private func account() { if user == nil { onSignIn?() } else { onAccount?() } }
    @objc private func reloadData() {
        guard !busy else { return }; busy = true
        Task {
            defer { busy = false; refreshControl?.endRefreshing() }
            do {
                let identity = try await api.identity()
                let data = try await api.listing()
                user = identity; listing = data
                if identity == nil { tabs.selectedSegmentIndex = 1 }
                navigationItem.leftBarButtonItem?.title = identity == nil ? "Sign in" : "Account"
                tableView.backgroundView = nil; tableView.reloadData()
            } catch { user = nil; listing = nil; tableView.reloadData(); showError(error) }
        }
    }
    private var spaces: [SpaceSummary] { listing?.spaces.filter { tabs.selectedSegmentIndex == 0 ? $0.member : !$0.member } ?? [] }
    override func numberOfSections(in tableView: UITableView) -> Int { tabs.selectedSegmentIndex == 2 ? 2 : 1 }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        if tabs.selectedSegmentIndex == 2 { return section == 0 ? listing?.requests.count ?? 0 : listing?.outgoing.count ?? 0 }; return spaces.count
    }
    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? { tabs.selectedSegmentIndex == 2 ? (section == 0 ? "Incoming" : "Your requests") : nil }
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        if tabs.selectedSegmentIndex == 2 {
            if indexPath.section == 0, let request = listing?.requests[indexPath.row] { cell.textLabel?.text = request.nickname; cell.detailTextLabel?.text = request.spaceTitle; cell.accessoryType = .disclosureIndicator }
            else if let outgoing = listing?.outgoing[indexPath.row] { cell.textLabel?.text = listing?.spaces.first { $0.id == outgoing.spaceID }?.title ?? "Space"; cell.detailTextLabel?.text = outgoing.status }
        } else { let space = spaces[indexPath.row]; cell.accessibilityIdentifier = "space.row." + space.id; cell.textLabel?.text = space.title; cell.detailTextLabel?.text = space.visibility + (space.shared ? " · Shared" : ""); cell.accessoryType = .disclosureIndicator }
        return cell
    }
    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        if tabs.selectedSegmentIndex == 2 {
            guard indexPath.section == 0, let request = listing?.requests[indexPath.row] else { return }
            let alert = UIAlertController(title: request.nickname, message: request.spaceTitle, preferredStyle: .alert)
            for approve in [true, false] { alert.addAction(UIAlertAction(title: approve ? "Accept" : "Decline", style: approve ? .default : .destructive) { [weak self] _ in self?.perform { try await self?.api.answerJoin(spaceID: request.spaceID, requestID: request.id, approve: approve) } }) }
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel)); present(alert, animated: true); return
        }
        let space = spaces[indexPath.row]
        if space.member { onOpenSpace?(space.id); return }
        let alert = UIAlertController(title: space.title, message: nil, preferredStyle: .alert)
        if space.visibility == "public" { alert.addAction(UIAlertAction(title: "Read", style: .default) { [weak self] _ in self?.onOpenSpace?(space.id) }) }
        let pending = listing?.outgoing.contains { $0.spaceID == space.id && $0.status == "pending" } == true
        let join = UIAlertAction(title: pending ? "Requested" : "Request to join", style: .default) { [weak self] _ in
            guard let self else { return }; guard self.user != nil else { self.onSignIn?(); return }; self.perform { try await self.api.requestJoin(id: space.id) }
        }; join.isEnabled = !pending; alert.addAction(join); alert.addAction(UIAlertAction(title: "Cancel", style: .cancel)); present(alert, animated: true)
    }
    @objc private func create() {
        guard user != nil else { onSignIn?(); return }
        let alert = UIAlertController(title: "New space", message: nil, preferredStyle: .alert); alert.addTextField { $0.placeholder = "Title"; $0.autocorrectionType = .no }
        for visibility in ["private", "public", "preview"] { alert.addAction(UIAlertAction(title: visibility.capitalized, style: .default) { [weak self, weak alert] _ in
            guard let self, let title = alert?.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty, title.count <= 120 else { return }
            self.perform { let result = try await self.api.createSpace(title: title, visibility: visibility); self.onOpenSpace?(result.id) }
        }) }; alert.addAction(UIAlertAction(title: "Cancel", style: .cancel)); present(alert, animated: true)
    }
    private func perform(_ action: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }; busy = true
        Task { do { try await action(); busy = false; reloadData() } catch { busy = false; showError(error) } }
    }
    private func showError(_ error: Error) { let alert = UIAlertController(title: "Space", message: error.localizedDescription, preferredStyle: .alert); alert.addAction(UIAlertAction(title: "OK", style: .default)); if presentedViewController == nil { present(alert, animated: true) } }
}
