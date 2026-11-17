import UIKit
import PencilKit
import UniformTypeIdentifiers
import AVKit
import ImageIO

/// Native document UI. WebKit is never part of the board's rendering/input path.
@MainActor final class BoardViewController: UIViewController, UIDocumentPickerDelegate, UIDropInteractionDelegate, UIPencilInteractionDelegate, UIContextMenuInteractionDelegate {
    let api: SpaceAPI
    let session: BoardSession
    var onOpenPaper: ((String) -> Void)?
    var onInteractHTML: ((BoardElement) -> Void)?
    private(set) var engine: BoardEngine?
    private(set) var surface: BoardSurface?
    private var visuals: BoardVisualStore?
    private var boardContextMenu: UIContextMenuInteraction?
    private var visualGeneration: UInt64?
    private var visualPapers: [PaperInfo] = []
    private var timer: Timer?
    private let strip = UIStackView()
    private let scroll = UIScrollView()
    private let status = UILabel()
    private let retry = UIButton(type: .system)
    private var buttons: [BoardTool: UIButton] = [:]
    private let undoButton = UIButton(type: .system), redoButton = UIButton(type: .system)
    private let colorButton = UIButton(type: .system), widthButton = UIButton(type: .system), moreButton = UIButton(type: .system)
    private let selectionButton = UIButton(type: .system)
    private lazy var papersItem: UIBarButtonItem = {
        let item = UIBarButtonItem(image: UIImage(systemName: "doc.on.doc"), style: .plain, target: self, action: #selector(showPapers))
        item.accessibilityLabel = "Papers"; item.accessibilityIdentifier = "board.papers"
        return item
    }()
    private lazy var openItem: UIBarButtonItem = {
        let item = UIBarButtonItem(title: "Open PDF", style: .plain, target: self, action: #selector(openSelectedPaper))
        item.accessibilityIdentifier = "board.open-paper"
        return item
    }()
    private var applying = false
    private var opening = false
    private var contentPopWasEnabled: Bool?
    private struct PendingJournal {
        var document: BoardDocument
        var original: BoardDocument
        var native: [String: Data]
        var command: BoardCommand?
    }
    private var pendingJournal: PendingJournal?
    private struct SavedViewport: Codable { var center: BoardPoint; var zoom: Double }
    private var pendingViewport: BoardViewport?
    private var viewportTimer: Timer?
    private var importBusy = false
    private var pendingCreatedSelection: [String] = []
    private var quickEraseReturn: BoardTool?
    private var queuedErase = false
    private var temporaryPanReturn: BoardTool?
    private var restorePanAfterContact = false
    private var tool: BoardTool = .pen
    private var stroke = "#202124", fill = "transparent"
    private var width: Double = 2

    init(api: SpaceAPI, spaceID: String, storageDirectory: URL) {
        self.api = api
        session = BoardSession(api: api, spaceID: spaceID, storageDirectory: storageDirectory)
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var canBecomeFirstResponder: Bool { true }
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .white
        view.accessibilityIdentifier = "space.board"
        navigationItem.largeTitleDisplayMode = .never
        navigationItem.rightBarButtonItem = papersItem
        configureStrip()
        status.textAlignment = .center; status.font = .systemFont(ofSize: 15); status.numberOfLines = 3
        status.accessibilityIdentifier = "board.status"; status.translatesAutoresizingMaskIntoConstraints = false
        retry.setTitle("Retry", for: .normal); retry.addTarget(self, action: #selector(retryOpen), for: .touchUpInside)
        retry.translatesAutoresizingMaskIntoConstraints = false; retry.isHidden = true
        view.addSubview(status); view.addSubview(retry)
        NSLayoutConstraint.activate([status.centerXAnchor.constraint(equalTo: view.centerXAnchor), status.centerYAnchor.constraint(equalTo: view.centerYAnchor), status.leadingAnchor.constraint(greaterThanOrEqualTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 24), status.trailingAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -24), retry.topAnchor.constraint(equalTo: status.bottomAnchor, constant: 12), retry.centerXAnchor.constraint(equalTo: view.centerXAnchor)])
        session.onChange = { [weak self] in self?.changed() }
        let pencil = UIPencilInteraction(); pencil.delegate = self; view.addInteraction(pencil)
        NotificationCenter.default.addObserver(self, selector: #selector(suspended), name: UIApplication.didEnterBackgroundNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(resumed), name: UIApplication.willEnterForegroundNotification, object: nil)
        open()
    }
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(false, animated: animated)
        if #available(iOS 26.0, *), let gesture = navigationController?.interactiveContentPopGestureRecognizer {
            if contentPopWasEnabled == nil { contentPopWasEnabled = gesture.isEnabled }
            // Horizontal canvas gestures must not become full-screen Back gestures.
            gesture.isEnabled = false
        }
        visuals?.resume(); startTimer(); changed()
        if session.authorized, pendingJournal == nil { Task { await session.refresh() } }
    }
    override func viewDidAppear(_ animated: Bool) { super.viewDidAppear(animated); becomeFirstResponder() }
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if #available(iOS 26.0, *), let enabled = contentPopWasEnabled {
            navigationController?.interactiveContentPopGestureRecognizer?.isEnabled = enabled
            contentPopWasEnabled = nil
        }
        timer?.invalidate(); timer = nil; persistViewport(); visuals?.suspend()
        if session.authorized { do { try session.persist() } catch { show(error) } }
    }
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isMovingFromParent { visuals?.dispose() }
    }
    private func startTimer() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.viewIfLoaded?.window != nil, self.pendingJournal == nil else { return }
                await self.session.refresh()
            }
        }
    }
    @objc private func suspended() {
        timer?.invalidate(); timer = nil; persistViewport(); visuals?.suspend()
        if session.authorized { do { try session.persist() } catch { show(error) } }
    }
    @objc private func resumed() { if viewIfLoaded?.window != nil { visuals?.resume(); startTimer(); Task { await session.refresh() } } }
    private func open() {
        guard !opening else { return }; opening = true; status.isHidden = false; status.text = "Opening space…"; retry.isHidden = true
        Task {
            defer { opening = false }
            do { try await session.open(); changed() }
            catch { status.isHidden = false; status.text = error.localizedDescription; retry.isHidden = false }
        }
    }
    @objc private func retryOpen() {
        if let pending = pendingJournal {
            applying = true
            do {
                let latest = session.board
                try session.edit(pending.document, from: pending.original, native: pending.native)
                if !session.hasPendingIntent, let command = pending.command {
                    try engine?.replace(latest); try engine?.apply(command)
                } else if !session.hasPendingIntent { try engine?.replace(session.board) }
                pendingJournal = nil; surface?.acknowledgeRetainedInk(); applying = false; changed(); Task { await session.refresh() }
            } catch { applying = false; show(error) }
        } else if surface?.hasRetainedInk == true { surface?.retryRetainedInk(); changed() }
        else if session.hasUnconvertedInk { reviewInkRecovery() }
        else { open() }
    }
    private func changed() {
        guard isViewLoaded, !applying else { return }
        guard session.authorized, let snapshot = session.snapshot else {
            surface?.cancelGesture(); surface?.removeFromSuperview(); surface = nil; engine = nil; boardContextMenu = nil
            visuals?.dispose(); visuals = nil; visualGeneration = nil; visualPapers = []
            presentedViewController?.dismiss(animated:false)
            status.isHidden = false; status.text = session.status; retry.isHidden = false; updateControls(); return
        }
        navigationItem.title = snapshot.space.title
        if !snapshot.space.member, surface?.editable == true { surface?.editable = false }
        if surface?.isUsingTool == true { updateControls(); return }
        do {
            if engine == nil {
                let engine = try BoardEngine(board: session.board); self.engine = engine
                let surface = BoardSurface(engine: engine); self.surface = surface
                surface.translatesAutoresizingMaskIntoConstraints = false; surface.accessibilityIdentifier = "board.canvas"
                view.insertSubview(surface, at: 0)
                NSLayoutConstraint.activate([surface.leadingAnchor.constraint(equalTo: view.leadingAnchor), surface.trailingAnchor.constraint(equalTo: view.trailingAnchor), surface.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor), surface.bottomAnchor.constraint(equalTo: scroll.topAnchor)])
                let visuals = BoardVisualStore(api: api, session: session); self.visuals = visuals
                visuals.onChange = { [weak self] in self?.surface?.invalidateVisuals() }
                visuals.onError = { [weak self] error in self?.show(error) }
                surface.visuals = visuals; surface.nativeStroke = { [weak self] in self?.session.nativeStroke(for: $0) }
                surface.onCommand = { [weak self] command, native in self?.commit(command, native: native) ?? false }
                surface.onUnconvertedInk = { [weak self] data, id in
                    guard let self else { return false }
                    do { try self.session.retainUnconvertedInk(data, id: id); return true }
                    catch { self.show(error); return false }
                }
                surface.onSelection = { [weak self] _ in self?.updateControls() }
                surface.onOpen = { [weak self] element in self?.openElement(element) }
                surface.onError = { [weak self] error in self?.show(error) }
                surface.onToolContactEnded = { [weak self] in self?.contactEnded() }
                surface.onViewport = { [weak self] viewport in self?.viewportChanged(viewport) }
                surface.addInteraction(UIDropInteraction(delegate: self))
                boardContextMenu = UIContextMenuInteraction(delegate: self)
                view.layoutIfNeeded()
                if let viewport = loadViewport() { surface.setViewport(viewport) } else { surface.fit() }
                surface.tool = tool; surface.strokeColor = stroke; surface.fillColor = fill; surface.strokeWidth = width
            } else if pendingJournal == nil, surface?.hasRetainedInk != true, engine?.board != session.board { try engine?.replace(session.board) }
            invalidateVisualsIfNeeded()
            surface?.papers = snapshot.papers
            surface?.editable = snapshot.space.member && pendingJournal == nil && surface?.hasRetainedInk != true && !session.hasUnconvertedInk && session.conflicts.isEmpty && !session.hasPendingIntent
            surface?.reload()
            let retained = pendingJournal != nil || surface?.hasRetainedInk == true || session.hasUnconvertedInk
            status.isHidden = !retained
            if retained { status.text = "This edit is retained. Retry saving or export recovery before continuing." }
            retry.isHidden = !retained
            navigationItem.prompt = pendingJournal != nil ? "Edit retained in memory; retry local saving" : session.dirty || !session.conflicts.isEmpty ? session.status : nil
            updateControls()
        } catch { status.isHidden = false; status.text = error.localizedDescription; retry.isHidden = false; surface?.editable = false }
    }
    private func invalidateVisualsIfNeeded() {
        guard let engine, let snapshot = session.snapshot,
              visualGeneration != engine.contentGeneration || visualPapers != snapshot.papers else { return }
        visuals?.invalidate()
        visualGeneration = engine.contentGeneration; visualPapers = snapshot.papers
    }
    @discardableResult private func commit(_ command: BoardCommand, native: [String: Data] = [:], originalDocument: BoardDocument? = nil) -> Bool {
        guard let engine, session.snapshot?.space.member == true, session.conflicts.isEmpty, !session.hasPendingIntent, pendingJournal == nil, !session.hasUnconvertedInk || !native.isEmpty else { return false }
        do {
            // A refresh may finish during Pencil contact or a title editor. Compose
            // from the exact original document, not a stale replacement.
            let original = originalDocument ?? engine.board, latest = session.board
            let candidate = try BoardEngine(board: original)
            let document = try candidate.apply(command)
            applying = true
            do { try session.edit(document, from: original, native: native) }
            catch {
                pendingJournal = PendingJournal(document: document, original: original, native: native, command: command)
                if native.isEmpty { try engine.replace(document) }
                surface?.editable = false; applying = false; retry.isHidden = false
                navigationItem.prompt = "Edit retained in memory; retry local saving"
                surface?.reload(); throw error
            }
            if !session.hasPendingIntent {
                if latest != original { try engine.replace(latest) }
                let actual = try engine.apply(command)
                guard actual == session.board else { throw BoardError.engine("Native command result did not match the journaled edit.") }
            }
            if !session.hasPendingIntent, case let .put(elements, _) = command {
                let created = elements.filter { original.element($0.id) == nil && $0.kind != .pen }.map(\.id)
                if !created.isEmpty { pendingCreatedSelection = created }
            }
            applying = false; invalidateVisualsIfNeeded(); surface?.reload(); updateControls()
            if surface?.isUsingTool != true { selectCreatedObjects(); changed() }
            return true
        } catch {
            applying = false
            if let ink = surface?.retainedInkData(), let id = native.keys.sorted().first {
                applying = true
                do { try session.retainUnconvertedInk(ink, id: id); applying = false }
                catch { applying = false; show(BoardError.journal("The completed stroke is retained only in memory because local saving failed: \(error.localizedDescription)")); return false }
            }
            show(error); return false
        }
    }
    private func history(redo: Bool = false) {
        guard let engine, session.snapshot?.space.member == true, session.conflicts.isEmpty, !session.hasPendingIntent, pendingJournal == nil, surface?.isUsingTool == false else { return }
        do {
            if engine.board != session.board { try engine.replace(session.board) }
            let original = engine.board
            let document = try (redo ? engine.redo() : engine.undo())
            applying = true
            do { try session.edit(document, from: original) }
            catch {
                pendingJournal = PendingJournal(document: document, original: original, native: [:], command: nil)
                surface?.editable = false; retry.isHidden = false
                navigationItem.prompt = "Edit retained in memory; retry local saving"; throw error
            }
            applying = false; changed()
        } catch { applying = false; show(error) }
    }
    private func selectCreatedObjects() {
        guard !pendingCreatedSelection.isEmpty else { return }
        let ids = pendingCreatedSelection; pendingCreatedSelection = []
        selectTool(.select); surface?.select(ids)
    }
    private func contactEnded() {
        selectCreatedObjects()
        if restorePanAfterContact, let previous = temporaryPanReturn {
            temporaryPanReturn = nil; restorePanAfterContact = false; selectTool(previous, explicit: false)
        }
        if queuedErase { queuedErase = false; selectTool(.erase, explicit: false) }
        else if let previous = quickEraseReturn, tool == .erase { quickEraseReturn = nil; selectTool(previous, explicit: false) }
        changed()
    }
    func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveSqueeze squeeze: UIPencilInteraction.Squeeze) {
        guard squeeze.phase == .ended, session.snapshot?.space.member == true else { return }
        if quickEraseReturn == nil { quickEraseReturn = tool }
        if surface?.isUsingTool == true { queuedErase = true } else { selectTool(.erase, explicit: false) }
    }
    func pencilInteractionDidTap(_ interaction: UIPencilInteraction) {
        guard surface?.isUsingTool == false else { return }
        if tool == .erase, let previous = quickEraseReturn { quickEraseReturn = nil; selectTool(previous, explicit: false) }
        else { quickEraseReturn = tool; selectTool(.erase, explicit: false) }
    }
    private var selectedElements: [BoardElement] { guard let surface, let engine else { return [] }; return engine.board.elements.filter { surface.selection.contains($0.id) && !$0.deleted } }
    private var center: BoardPoint { surface.map { $0.viewport.world(CGPoint(x: $0.bounds.midX, y: $0.bounds.midY)) } ?? BoardPoint(x: 0, y: 0) }
    private func nextZ() -> Double { (engine?.board.elements.map(\.z).max() ?? 0) + 1 }
    private func selectTool(_ value: BoardTool, explicit: Bool = true) {
        if surface?.isEditingText == true, surface?.finishEditingText() != true { return }
        guard surface?.isUsingTool != true else { return }
        if explicit { quickEraseReturn = nil; queuedErase = false; temporaryPanReturn = nil; restorePanAfterContact = false }
        tool = value
        if value != .select && value != .hand { surface?.select([]) }
        surface?.tool = value; updateControls()
    }
    private func configureStrip() {
        scroll.translatesAutoresizingMaskIntoConstraints = false; scroll.showsHorizontalScrollIndicator = false
        scroll.backgroundColor = .white; scroll.accessibilityIdentifier = "board.toolbar"
        strip.axis = .horizontal; strip.spacing = 4; strip.alignment = .center; strip.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll); scroll.addSubview(strip)
        NSLayoutConstraint.activate([scroll.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor), scroll.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor), scroll.heightAnchor.constraint(equalToConstant: 54), strip.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 8), strip.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -8), strip.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor), strip.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor), strip.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor)])
        let values: [(BoardTool, String, String)] = [(.select,"cursorarrow","Select"),(.hand,"hand.draw","Pan"),(.rectangle,"rectangle","Rectangle"),(.arrow,"arrow.up.right","Arrow"),(.pen,"pencil.tip","Pen"),(.text,"textformat","Text"),(.erase,"eraser","Eraser")]
        for (value, symbol, label) in values {
            let button = makeButton(symbol, label: label, id: "board.tool.\(value.rawValue)") { [weak self] in self?.selectTool(value) }
            buttons[value] = button; strip.addArrangedSubview(button)
        }
        configure(undoButton, symbol: "arrow.uturn.backward", label: "Undo", id: "board.undo") { [weak self] in self?.history() }
        configure(redoButton, symbol: "arrow.uturn.forward", label: "Redo", id: "board.redo") { [weak self] in self?.history(redo: true) }
        configure(colorButton, symbol: "circle.fill", label: "Color", id: "board.color") { }
        configure(widthButton, symbol: "lineweight", label: "Stroke width", id: "board.width") { }
        configure(moreButton, symbol: "ellipsis", label: "More", id: "board.more") { }
        colorButton.showsMenuAsPrimaryAction = true; widthButton.showsMenuAsPrimaryAction = true; moreButton.showsMenuAsPrimaryAction = true
        // Build on presentation. Replacing a visible menu during the two-second
        // collaboration poll dismisses its submenu and interrupts interaction.
        colorButton.menu = UIMenu(children: [UIDeferredMenuElement.uncached { [weak self] complete in Task { @MainActor in complete(self?.colorMenu().children ?? []) } }])
        widthButton.menu = UIMenu(children: [UIDeferredMenuElement.uncached { [weak self] complete in Task { @MainActor in complete(self?.widthMenu().children ?? []) } }])
        moreButton.menu = UIMenu(children: [UIDeferredMenuElement.uncached { [weak self] complete in Task { @MainActor in complete(self?.moreMenu().children ?? []) } }])
        configure(selectionButton, symbol: "slider.horizontal.3", label: "Selection", id: "board.selection") { }
        selectionButton.showsMenuAsPrimaryAction = true
        selectionButton.menu = UIMenu(children: [UIDeferredMenuElement.uncached { [weak self] complete in Task { @MainActor in complete(self?.selectionMenu().children ?? []) } }])
        for button in [undoButton, redoButton, colorButton, widthButton, selectionButton, moreButton] { strip.addArrangedSubview(button) }
    }
    private func makeButton(_ symbol: String, label: String, id: String, action: @escaping () -> Void) -> UIButton {
        let result = UIButton(type: .system); configure(result, symbol: symbol, label: label, id: id, action: action); return result
    }
    private func configure(_ button: UIButton, symbol: String, label: String, id: String, action: @escaping () -> Void) {
        button.setImage(UIImage(systemName: symbol), for: .normal); button.accessibilityLabel = label; button.accessibilityIdentifier = id
        button.widthAnchor.constraint(equalToConstant: 44).isActive = true; button.heightAnchor.constraint(equalToConstant: 44).isActive = true
        button.addAction(UIAction { _ in action() }, for: .touchUpInside)
        button.layer.cornerRadius = 8
    }
    private func updateControls() {
        if let surface, let menu = boardContextMenu {
            let enabled = [.select, .hand, .pen].contains(tool) && !surface.isEditingText
            if enabled, menu.view == nil { surface.addInteraction(menu) }
            else if !enabled, menu.view != nil { surface.removeInteraction(menu) }
        }
        let member = session.snapshot?.space.member == true && pendingJournal == nil && surface?.hasRetainedInk != true && !session.hasUnconvertedInk && session.conflicts.isEmpty && !session.hasPendingIntent
        for (value, button) in buttons {
            button.isSelected = tool == value; button.backgroundColor = tool == value ? UIColor.systemBlue.withAlphaComponent(0.12) : .clear
            button.isEnabled = member || value == .select || value == .hand
        }
        undoButton.isEnabled = member && (engine?.canUndo ?? false); redoButton.isEnabled = member && (engine?.canRedo ?? false)
        colorButton.isEnabled = member; widthButton.isEnabled = member
        let elements = selectedElements
        selectionButton.isHidden = elements.isEmpty || surface?.isEditingText == true
        let opensPaper = elements.count == 1 && elements[0].kind == .paper && elements[0].paperId != nil
        let rightItems = opensPaper ? [papersItem, openItem] : [papersItem]
        if navigationItem.rightBarButtonItems != rightItems { navigationItem.rightBarButtonItems = rightItems }
        papersItem.isEnabled = session.authorized
        colorButton.tintColor = BoardRenderer.color(surface?.editingTextElement?.stroke ?? elements.first?.stroke ?? stroke)
        widthButton.accessibilityValue = "\(elements.first?.strokeWidth ?? width)"
    }
    private func colorMenu() -> UIMenu {
        let choices = [("Black","#202124"),("Red","#d5473f"),("Blue","#306dc4"),("Green","#358257"),("Purple","#9362b7"),("Transparent","transparent")]
        func colors(fill: Bool) -> UIMenu {
            UIMenu(title: fill ? "Fill" : "Stroke", children: choices.map { label, hex in
                UIAction(title: label, state: (fill ? selectedElements.first?.fill ?? self.fill : selectedElements.first?.stroke ?? stroke) == hex ? .on : .off) { [weak self] _ in
                    self?.changeStyle { element in if fill { element.fill = hex } else { element.stroke = hex } }
                    if fill { self?.fill = hex; self?.surface?.fillColor = hex } else { self?.stroke = hex; self?.surface?.strokeColor = hex }
                    self?.updateControls()
                }
            } + [UIAction(title: "Custom…", image: UIImage(systemName: "eyedropper")) { [weak self] _ in self?.customColor(fill: fill) }])
        }
        return UIMenu(children: [colors(fill: false), colors(fill: true)])
    }
    private func widthMenu() -> UIMenu {
        UIMenu(children: [0.25,0.5,1,2,4,8,12].map { value in UIAction(title: "\(value)", state: (selectedElements.first?.strokeWidth ?? width) == value ? .on : .off) { [weak self] _ in
            self?.width = value; self?.surface?.strokeWidth = value; self?.changeStyle { $0.strokeWidth = value }; self?.updateControls()
        } } + [UIAction(title: "Exact width…") { [weak self] _ in self?.numberPrompt("Stroke width", value: self?.width ?? 2, range: 0.1...200) { value in self?.width = value; self?.surface?.strokeWidth = value; self?.changeStyle { $0.strokeWidth = value } } }])
    }
    private func changeStyle(_ change: (inout BoardElement) -> Void) {
        if surface?.updateTextAppearance(change) == true { updateControls(); return }
        guard selectedElements.allSatisfy({ !$0.locked }) else { return }
        var elements: [BoardElement] = []
        for original in selectedElements {
            var element = original; change(&element)
            if element.kind == .text, element.fontSize != original.fontSize || element.bold != original.bold || element.italic != original.italic || element.fontFamily != original.fontFamily || element.textWrapWidth != original.textWrapWidth {
                let cap = element.textWrapWidth == 0 ? 1e7 : max(1, element.textWrapWidth ?? element.width)
                guard let size = visuals?.measureText(for: element, constrainedTo: cap) else { return }
                element.width = Double(size.width); element.height = Double(size.height)
            }
            elements.append(element)
        }
        if !elements.isEmpty { commit(.put(elements)) }
    }
    private func moreMenu() -> UIMenu {
        let editable = session.snapshot?.space.member == true
        var groups: [UIMenuElement] = [UIMenu(title: "View", children: [action("Fit to content", "arrow.up.left.and.arrow.down.right") { self.surface?.fit() }, action("Zoom in", "plus.magnifyingglass") { self.surface?.zoom(by: 1.2) }, action("Zoom out", "minus.magnifyingglass") { self.surface?.zoom(by: 1/1.2) }])]
        if editable {
            groups.append(UIMenu(title: "Add", children: [action("Paste", "clipboard") { self.paste() }, action("Image, video or PDF…", "photo.on.rectangle") { self.chooseFile() }, action("Import PDF URL…", "link") { self.importURLPrompt() }, action("Add diagram…", "square.stack.3d.up") { self.addDiagram() }]))
        }
        if surface?.isEditingText == true { groups.append(textStyleMenu()) }
        if editable {
            groups += [action("History", "clock.arrow.circlepath") { SpacePanels.presentHistory(from: self, api: self.api, session: self.session) }, action("Settings and invitation", "slider.horizontal.3") { SpacePanels.presentSettings(from: self, api: self.api, session: self.session) }, action("Agent access", "person.crop.square") { SpacePanels.presentAgents(from: self, api: self.api, session: self.session) }]
        } else if session.authorized {
            groups.append(action("Request to join", "person.badge.plus") { self.run { try await self.api.requestJoin(id: self.session.spaceID); await self.session.refresh() } })
        }
        if !session.conflicts.isEmpty || session.hasPendingIntent { groups.append(action("Review conflicts", "exclamationmark.arrow.triangle.2.circlepath") { self.reviewConflicts() }) }
        groups.append(action("Export board JSON", "square.and.arrow.up") { self.exportDraft() })
        return UIMenu(children: groups)
    }
    private func selectionMenu() -> UIMenu {
        let elements = selectedElements
        var items: [UIMenuElement] = []
        if let element = elements.first, elements.count == 1 {
            if element.kind == .paper { items.append(action("Open PDF", "doc") { self.openElement(element) }); items += paperActions(element) }
            if element.diagramType == "html" { items.append(action("Interact", "hand.tap") { self.onInteractHTML?(element) }) }
            if let url = element.url, let target = safeExternal(url) {
                items.append(action("Open link", "link") { self.openLink(target) })
                items.append(action("Copy source link", "doc.on.doc") { UIPasteboard.general.setItems([[UTType.url.identifier:target]],options:[.localOnly:true,.expirationDate:Date().addingTimeInterval(300)]) })
            }
            if element.kind == .text {
                let links = visuals?.links(for:element,width:element.width) ?? []
                if !links.isEmpty { items.append(UIMenu(title:"Links",children:links.map { link in self.action(link.url.absoluteString,"link") { self.openLink(link.url) } })) }
            }
            if element.kind == .image, let id = element.assetId, engine?.board.assets[id]?.mimeType == "video/mp4" { items.append(action("Play video", "play.fill") { self.playVideo(element) }) }
            if element.kind == .arrow { items.append(action("Convert to line", "line.diagonal") { self.changeStyle { $0.kind = .line } }) }
            let creator = session.snapshot?.creators[element.id]?.description ?? "Unknown"
            items.append(UIAction(title: "Created by \(creator)", attributes: .disabled) { _ in })
        }
        if session.snapshot?.space.member == true {
            if elements.count >= 2 { items.append(action("Group", "square.3.layers.3d") { self.commit(.group(elements.map(\.id), groupId: UUID().uuidString)) }) }
            if elements.contains(where: { $0.groupId != nil }) { items.append(action("Ungroup", "square.3.layers.3d.slash") { self.commit(.ungroup(elements.map(\.id))) }) }
            if elements.contains(where: { $0.kind == .text || $0.text != nil && $0.kind != .paper && $0.kind != .image }) { items.append(textStyleMenu()) }
            if elements.contains(where: { [.line,.arrow].contains($0.kind) }) {
                items.append(UIMenu(title: "Line style", children: ["solid","dotted"].map { value in action(value.capitalized, nil) { self.changeStyle { if [.line,.arrow].contains($0.kind) { $0.strokeStyle = value } } } }))
            }
            items.append(action("Delete", "trash", destructive: true) { self.commit(.delete(elements.map(\.id))); self.surface?.select([]) })
        }
        return UIMenu(title: "Selection", children: items)
    }
    private func textStyleMenu() -> UIMenu {
        UIMenu(title: "Text", children: [action("Bold", "bold") { self.changeStyle { if $0.kind == .text || $0.text != nil { $0.bold = !($0.bold ?? false) } } }, action("Italic", "italic") { self.changeStyle { if $0.kind == .text || $0.text != nil { $0.italic = !($0.italic ?? false) } } }, action("Font size…", "textformat.size") { self.numberPrompt("Font size", value: self.selectedElements.first?.fontSize ?? 24, range: 1...512) { value in self.changeTextSize(value) } }, action("Automatic font size", "textformat.abc") { self.changeTextSize(nil) }])
    }
    private func changeTextSize(_ size: Double?) {
        if let draft = surface?.editingTextElement {
            let words = (draft.text ?? "").split(whereSeparator: \.isWhitespace).count
            surface?.updateTextAppearance { element in
                element.fontSize = size ?? (words >= 1000 ? 14 : words >= 100 ? 18 : 24)
                if element.kind == .text { element.autoFontSize = size == nil }
            }
            updateControls(); return
        }
        let elements = selectedElements.map { original -> BoardElement in
            var element = original
            guard element.kind == .text || element.text != nil && ![.image,.paper].contains(element.kind) else { return element }
            if element.kind == .text {
                element.autoFontSize = size == nil
                let words = (element.text ?? "").split(whereSeparator: \.isWhitespace).count
                element.fontSize = size ?? (words >= 1000 ? 14 : words >= 100 ? 18 : 24)
                if let measured = visuals?.measureText(for: element, constrainedTo: element.textWrapWidth == 0 ? 1e7 : max(1, element.textWrapWidth ?? element.width)) { element.width = Double(measured.width); element.height = Double(measured.height) }
            } else if let size { element.fontSize = size }
            return element
        }
        commit(.put(elements))
    }
    private func paperActions(_ element: BoardElement) -> [UIMenuElement] {
        guard let id = element.paperId, let paper = session.snapshot?.papers.first(where: { $0.id == id }), session.snapshot?.space.member == true else { return [] }
        var result: [UIMenuElement] = [action(paper.isRead == true ? "Mark unread" : "Mark read", "checkmark.circle") { self.run { try await self.api.markRead(paperID: id, read: paper.isRead != true); await self.session.refresh() } }, action("Edit cover title…", "text.cursor") { self.editCoverTitle(element, fallback: paper.title) }]
        if element.paperView == "page" || visuals?.pdfPageCount(for: element) == 1 {
            result.append(action(element.paperView == "page" ? "Show as card" : "Show as image", "doc.richtext") { self.changeStyle { $0.paperView = element.paperView == "page" ? "card" : "page" } })
        }
        return result
    }
    private func editCoverTitle(_ element: BoardElement, fallback: String) {
        guard let original = engine?.board, let target = original.element(element.id), !target.locked else { return }
        let editor = BoardSourceController(title: "Cover title", source: target.paperTitle ?? fallback, font: .systemFont(ofSize: 16)) { [weak self] value in
            guard value.utf8.count <= 1000 else { throw BoardError.invalidDocument("Cover title exceeds 1,000 bytes.") }
            var changed = target; changed.paperTitle = value
            guard let self, self.commit(.put([changed]), originalDocument: original) else {
                throw BoardError.journal("Title was not accepted. Retry local saving or resolve pending board edits, then retry this title.")
            }
            return true
        }
        present(UINavigationController(rootViewController: editor), animated: true)
    }
    private func action(_ title: String, _ symbol: String?, destructive: Bool = false, _ body: @escaping () -> Void) -> UIAction {
        UIAction(title: title, image: symbol.flatMap(UIImage.init(systemName:)), attributes: destructive ? .destructive : []) { _ in body() }
    }
    @objc private func showPapers() {
        SpacePanels.presentPapers(from: self, api: api, session: session, onOpenPaper: onOpenPaper, onAddPaper: { [weak self] in self?.chooseFile(onlyPDF: true) })
    }
    @objc private func openSelectedPaper() {
        let elements = selectedElements
        guard elements.count == 1, elements[0].kind == .paper else { return }
        openElement(elements[0])
    }
    private func openElement(_ element: BoardElement?) {
        guard let element else { return }
        if element.kind == .paper, let id = element.paperId { onOpenPaper?(id) }
        else if element.diagramType == "html" { onInteractHTML?(element) }
        else if element.kind == .image, let id = element.assetId, engine?.board.assets[id]?.mimeType == "video/mp4" { playVideo(element) }
        else if let link = element.url, let url = safeExternal(link) { openLink(url) }
    }
    private func safeExternal(_ raw: String) -> URL? {
        if raw.hasPrefix("/paper/"), let url = URL(string: raw, relativeTo: api.origin)?.absoluteURL { return url }
        guard let url = URL(string: raw), ["http","https","mailto"].contains(url.scheme?.lowercased() ?? ""), url.user == nil, url.password == nil else { return nil }; return url
    }
    private func playVideo(_ element: BoardElement) {
        do { guard let visuals else { return }; let player = AVPlayerViewController(); player.player = AVPlayer(url: try visuals.videoURL(for: element)); present(player, animated: true) { player.player?.play() } }
        catch { show(error) }
    }
    private func reviewConflicts() {
        let conflicts = session.conflicts
        guard !conflicts.isEmpty else { if session.hasPendingIntent { Task { await session.resolve([]) } }; return }
        if conflicts.contains(where: { $0.kind != .element }) {
            let text = conflicts.compactMap(\.message).joined(separator: "\n")
            let alert = UIAlertController(title: "Board conflict", message: text.isEmpty ? "Immutable image assets conflict. Export your edits before choosing the server board." : text, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "Export edits", style: .default) { _ in self.exportDraft() })
            alert.addAction(UIAlertAction(title: "Use server board…", style: .destructive) { _ in self.confirmServerBoard() })
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel)); present(alert, animated: true); return
        }
        review(conflicts, index: 0, decisions: [])
    }
    private func review(_ conflicts: [BoardConflict], index: Int, decisions: [BoardResolution]) {
        guard index < conflicts.count else { Task { await session.resolve(decisions) }; return }
        let conflict = conflicts[index]
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let local = conflict.local.flatMap { try? encoder.encode($0) }.flatMap { String(data: $0, encoding: .utf8) } ?? "Absent"
        let remote = conflict.remote.flatMap { try? encoder.encode($0) }.flatMap { String(data: $0, encoding: .utf8) } ?? "Absent"
        let alert = UIAlertController(title: "Item \(index + 1) of \(conflicts.count)", message: "\(conflict.id)\n\nMine:\n\(local)\n\nServer:\n\(remote)", preferredStyle: .alert)
        for (title, choice) in [("Keep mine", BoardResolution.Choice.local), ("Use server", .remote)] { alert.addAction(UIAlertAction(title: title, style: .default) { _ in self.review(conflicts, index: index + 1, decisions: decisions + [BoardResolution(conflict: conflict, choice: choice)]) }) }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel)); present(alert, animated: true)
    }
    private func confirmServerBoard() {
        let alert = UIAlertController(title: "Discard your board edits?", message: "Export your edits first if you need them. The current server board will replace this draft.", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Use server board", style: .destructive) { _ in self.run { try await self.session.useServer() } }); alert.addAction(UIAlertAction(title: "Cancel", style: .cancel)); present(alert, animated: true)
    }
    private func exportDraft() {
        guard session.authorized else { show(BoardError.notAuthorized); return }
        do {
            let document = pendingJournal?.document ?? engine?.board ?? session.board
            let recovery = session.hasPendingIntent || session.hasPendingSubmission || session.hasUnconvertedInk || pendingJournal != nil || surface?.hasRetainedInk == true
            struct Recovery: Encodable {
                let version = 1
                var spaceID: String
                var board: BoardDocument
                var sessionJournal: Data
                var unconvertedInk: Data?
            }
            let data = try recovery ? JSONEncoder().encode(Recovery(spaceID: session.spaceID, board: document, sessionJournal: session.recoveryData(), unconvertedInk: surface?.retainedInkData())) : JSONEncoder().encode(document)
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SpaceExports", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let url = directory.appendingPathComponent(UUID().uuidString + (recovery ? ".space-recovery.json" : ".space.json"))
            try data.write(to: url, options: [.atomic,.completeFileProtection])
            var resource = URLResourceValues(); resource.isExcludedFromBackup = true; var mutable = url; try mutable.setResourceValues(resource)
            let share = UIActivityViewController(activityItems: [url], applicationActivities: nil)
            share.completionWithItemsHandler = { _, _, _, _ in try? FileManager.default.removeItem(at: url) }
            share.popoverPresentationController?.sourceView = moreButton; present(share, animated: true)
        } catch { show(error) }
    }
    private func reviewInkRecovery() {
        let alert = UIAlertController(title: "Pencil ink recovery", message: "The complete native stroke was retained, but could not be converted into a shared board edit. Export recovery before discarding it.", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Export recovery", style: .default) { _ in self.exportDraft() })
        alert.addAction(UIAlertAction(title: "Discard this unconverted ink", style: .destructive) { _ in
            do { try self.session.discardUnconvertedInk(); self.surface?.acknowledgeRetainedInk(); self.changed() }
            catch { self.show(error) }
        })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel)); present(alert, animated: true)
    }
    private var viewportKey: String { "space:canvas:native:v2:\(api.storageIdentity):\(session.spaceID)" }
    private func viewportChanged(_ viewport: BoardViewport) {
        pendingViewport = viewport
        if viewportTimer == nil { viewportTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: false) { [weak self] _ in Task { @MainActor in self?.persistViewport() } } }
    }
    private func persistViewport() {
        viewportTimer?.invalidate(); viewportTimer = nil
        guard session.authorized, let viewport = pendingViewport, let surface, surface.bounds.width > 0, surface.bounds.height > 0 else { return }
        let saved = SavedViewport(center: viewport.world(CGPoint(x: surface.bounds.midX, y: surface.bounds.midY)), zoom: viewport.zoom)
        guard let data = try? JSONEncoder().encode(saved) else { return }
        UserDefaults.standard.set(data, forKey: viewportKey)
    }
    private func loadViewport() -> BoardViewport? {
        guard let surface, let data = UserDefaults.standard.data(forKey: viewportKey), let value = try? JSONDecoder().decode(SavedViewport.self, from: data), value.zoom.isFinite, (0.05...8).contains(value.zoom), [value.center.x,value.center.y].allSatisfy({ $0.isFinite && abs($0) <= 1e9 }) else { return nil }
        return BoardViewport(x: surface.bounds.midX-value.center.x*value.zoom, y: surface.bounds.midY-value.center.y*value.zoom, zoom: value.zoom)
    }
    private func show(_ error: Error) {
        guard viewIfLoaded?.window != nil, presentedViewController == nil else { navigationItem.prompt = error.localizedDescription; return }
        let alert = UIAlertController(title: "Space", message: error.localizedDescription, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default)); present(alert, animated: true)
    }
    private func run(_ action: @escaping @MainActor () async throws -> Void) { Task { do { try await action(); changed() } catch { show(error) } } }
    private func runImport(_ action: @escaping @MainActor () async throws -> Void) {
        guard !importBusy else { show(BoardError.invalidDocument("An import is already in progress.")); return }
        importBusy = true
        Task {
            defer { importBusy = false }
            do { try await action(); changed() } catch { show(error) }
        }
    }
    private func textPrompt(_ title: String, value: String = "", action: @escaping (String) -> Void) {
        let alert = UIAlertController(title: title, message: nil, preferredStyle: .alert)
        alert.addTextField { field in field.text = value; field.autocorrectionType = .no; field.spellCheckingType = .no; field.autocapitalizationType = .none; field.inlinePredictionType = .no }
        alert.addAction(UIAlertAction(title: "Save", style: .default) { _ in action(alert.textFields?.first?.text ?? "") }); alert.addAction(UIAlertAction(title: "Cancel", style: .cancel)); present(alert, animated: true)
    }
    private func numberPrompt(_ title: String, value: Double, range: ClosedRange<Double>, action: @escaping (Double) -> Void) {
        textPrompt(title, value: String(value)) { text in guard let value = Double(text), value.isFinite, range.contains(value) else { self.show(BoardError.invalidDocument("Enter a number in \(range.lowerBound)…\(range.upperBound).")); return }; action(value) }
    }
    private func customColor(fill: Bool) { textPrompt(fill ? "Fill color" : "Stroke color", value: fill ? self.fill : stroke) { text in
        guard text.range(of: "^#(?:[0-9a-fA-F]{3}|[0-9a-fA-F]{6}|[0-9a-fA-F]{8})$", options: .regularExpression) != nil || text == "transparent" else { self.show(BoardError.invalidDocument("Use a hexadecimal color or transparent.")); return }
        if fill { self.fill = text; self.surface?.fillColor = text } else { self.stroke = text; self.surface?.strokeColor = text }
        self.changeStyle { if fill { $0.fill = text } else { $0.stroke = text } }; self.updateControls()
    } }
    func contextMenuInteraction(_ interaction: UIContextMenuInteraction, configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
        guard let surface, let engine, surface.prepareContextMenu() else { return nil }
        do { surface.select(try engine.hit(surface.viewport.world(location), tolerance: 8 / surface.viewport.zoom).map { [$0] } ?? []) }
        catch { show(error); return nil }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in
            let selection = self.selectedElements.isEmpty ? [] : self.selectionMenu().children
            return UIMenu(children: selection + self.moreMenu().children)
        }
    }
    func contextMenuInteraction(_ interaction: UIContextMenuInteraction, willDisplayMenuFor configuration: UIContextMenuConfiguration, animator: UIContextMenuInteractionAnimating?) {
        if surface?.prepareContextMenu() == true { surface?.cancelGesture() }
    }
    override var keyCommands: [UIKeyCommand]? {
        guard presentedViewController == nil else { return [] }
        if surface?.isEditingText == true { return [UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(cancelInlineText))] }
        let commands: [(String, UIKeyModifierFlags, Selector, String)] = [
            ("z", .command, #selector(undoKey), "Undo"), ("z", [.command,.shift], #selector(redoKey), "Redo"),
            ("g", .command, #selector(groupKey), "Group"), ("g", [.command,.shift], #selector(ungroupKey), "Ungroup"),
            ("v", .command, #selector(pasteKey), "Paste"), ("a", .command, #selector(selectAllKey), "Select all"),
            ("+", .command, #selector(zoomInKey), "Zoom in"), ("-", .command, #selector(zoomOutKey), "Zoom out"),
            ("0", .command, #selector(resetZoomKey), "Reset zoom"), ("\u{8}", [], #selector(deleteKey), "Delete selection"),
            ("f", [], #selector(fitKey), "Fit to content"), (UIKeyCommand.inputEscape, [], #selector(clearSelectionKey), "Select tool"),
            ("=", [], #selector(zoomInKey), "Zoom in"), ("+", [], #selector(zoomInKey), "Zoom in"), ("-", [], #selector(zoomOutKey), "Zoom out")]
        return commands.map { item in
            let command = UIKeyCommand(input: item.0, modifierFlags: item.1, action: item.2)
            command.discoverabilityTitle = item.3; return command
        } + ["1","2","3","4","5","6","v","r","a","p","t","e"].map { UIKeyCommand(input: $0, modifierFlags: [], action: #selector(toolKey(_:))) }
    }
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if presentedViewController == nil, surface?.isEditingText != true, surface?.isUsingTool == false,
           presses.contains(where: { $0.key?.charactersIgnoringModifiers == " " && $0.key?.modifierFlags.isEmpty == true }) {
            if temporaryPanReturn == nil { temporaryPanReturn = tool; selectTool(.hand, explicit: false) }
            return
        }
        super.pressesBegan(presses, with: event)
    }
    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if temporaryPanReturn != nil, presses.contains(where: { $0.key?.charactersIgnoringModifiers == " " }) {
            endTemporaryPan(); return
        }
        super.pressesEnded(presses, with: event)
    }
    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        endTemporaryPan(); super.pressesCancelled(presses, with: event)
    }
    private func endTemporaryPan() {
        guard let previous = temporaryPanReturn else { return }
        if surface?.isUsingTool == true { restorePanAfterContact = true }
        else { temporaryPanReturn = nil; restorePanAfterContact = false; selectTool(previous, explicit: false) }
    }
    @objc private func clearSelectionKey() { surface?.cancelGesture(); selectTool(.select); surface?.select([]) }
    @objc private func cancelInlineText() { surface?.cancelGesture() }
    @objc private func undoKey() { history() }
    @objc private func redoKey() { history(redo: true) }
    @objc private func groupKey() { if selectedElements.count >= 2 { commit(.group(selectedElements.map(\.id), groupId: UUID().uuidString)) } }
    @objc private func ungroupKey() { commit(.ungroup(selectedElements.map(\.id))) }
    @objc private func pasteKey() { paste() }
    @objc private func selectAllKey() { surface?.select(engine?.board.elements.filter { !$0.deleted && !$0.locked }.map(\.id) ?? []) }
    @objc private func zoomInKey() { surface?.zoom(by: 1.2) }
    @objc private func zoomOutKey() { surface?.zoom(by: 1/1.2) }
    @objc private func resetZoomKey() { if let surface { surface.zoom(by: 1/surface.viewport.zoom) } }
    @objc private func deleteKey() { commit(.delete(selectedElements.map(\.id))); surface?.select([]) }
    @objc private func fitKey() { surface?.fit() }
    @objc private func toolKey(_ command: UIKeyCommand) {
        let tools: [String:BoardTool] = ["1":.select,"2":.hand,"3":.rectangle,"4":.arrow,"5":.pen,"6":.text,"v":.select,"r":.rectangle,"a":.arrow,"p":.pen,"t":.text,"e":.erase]
        if let input = command.input, let tool = tools[input] { selectTool(tool) }
    }

    private func chooseFile(onlyPDF: Bool = false) {
        guard session.snapshot?.space.member == true, !importBusy else { return }
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: onlyPDF ? [.pdf] : [.image,.movie,.pdf], asCopy: true)
        picker.allowsMultipleSelection = true; picker.delegate = self; present(picker, animated: true)
    }
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        let point = center
        runImport {
            for (index, url) in urls.enumerated() {
                let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
                let values = try url.resourceValues(forKeys: [.fileSizeKey,.contentTypeKey])
                let type = values.contentType ?? UTType(filenameExtension: url.pathExtension) ?? .data
                let limit = type.conforms(to: .pdf) ? 40 * 1024 * 1024 : 16 * 1024 * 1024
                guard let size = values.fileSize, size <= limit else { throw PaperError.oversized }
                let data = try Data(contentsOf: url)
                try await self.importData(data, type: type, filename: url.lastPathComponent, at: BoardPoint(x: point.x + Double(index) * 24, y: point.y + Double(index) * 24))
            }
        }
    }
    private func importData(_ data: Data, type: UTType, filename: String, at point: BoardPoint) async throws {
        guard session.snapshot?.space.member == true, session.conflicts.isEmpty, pendingJournal == nil else { throw BoardError.invalidDocument("Resolve pending board edits before importing.") }
        if type.conforms(to: .pdf) {
            guard data.count <= 40 * 1024 * 1024 else { throw PaperError.oversized }
            let result = try await api.uploadPDF(id: session.spaceID, data: data, filename: filename)
            await session.refresh(); try addPaper(result.paper, at: point)
        } else if type.conforms(to: .movie) || type == .gif {
            let result = try await api.mediaPreview(id: session.spaceID, data: data, filename: filename)
            guard session.authorized else { throw BoardError.notAuthorized }
            let scale = min(1,640/max(1,result.width),480/max(1,result.height))
            let assetId = UUID().uuidString
            var element = BoardElement(kind: .image); element.assetId = assetId; element.videoAutoplay = result.autoplay
            element.x = point.x; element.y = point.y; element.width = result.width * scale; element.height = result.height * scale; element.z = nextZ()
            guard commit(.put([element], assets: [assetId:result.asset])) else { throw BoardError.journal("Media import needs attention. Resolve retained edits and retry local saving before importing again.") }
        } else if type.conforms(to: .image) {
            guard data.count <= 16 * 1024 * 1024 else { throw PaperError.oversized }
            guard let source = CGImageSourceCreateWithData(data as CFData,nil),
                  let metadata = CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [CFString:Any],
                  let imageWidth = metadata[kCGImagePropertyPixelWidth] as? NSNumber,
                  let imageHeight = metadata[kCGImagePropertyPixelHeight] as? NSNumber,
                  imageWidth.doubleValue > 0, imageHeight.doubleValue > 0,
                  imageWidth.doubleValue * imageHeight.doubleValue <= 24_000_000,
                  let image = UIImage(data:data), let png = image.pngData(), png.count <= 16 * 1024 * 1024 else { throw BoardError.invalidDocument("Image cannot be decoded within the canvas limits.") }
            let assetId = UUID().uuidString, scale = min(1,640/image.size.width,480/image.size.height)
            var element = BoardElement(kind:.image); element.assetId = assetId
            element.x = point.x; element.y = point.y; element.width = Double(image.size.width * scale); element.height = Double(image.size.height * scale); element.z = nextZ()
            guard commit(.put([element],assets:[assetId:BoardAsset(mimeType:"image/png",dataURL:"data:image/png;base64," + png.base64EncodedString())])) else { throw BoardError.journal("Image import needs attention. Resolve retained edits and retry local saving before importing again.") }
        } else { throw BoardError.invalidDocument("Use an image, video or PDF.") }
    }
    private func openLink(_ url: URL) {
        if NativeSpaceRoute.parse(url,bridge:WebBridge(origin:api.origin)) != nil, let app = navigationController as? SpaceAppController { app.open(url) }
        else { UIApplication.shared.open(url) }
    }
    private func addPaper(_ paper: PaperInfo, at point: BoardPoint, sourceURL: String? = nil) throws {
        guard session.authorized, session.snapshot?.space.member == true, session.conflicts.isEmpty else { throw BoardError.invalidDocument("PDF was kept in Papers. Card insertion is blocked until board conflicts are resolved.") }
        var element = BoardElement(kind:.paper); element.paperId = paper.id; element.text = paper.title
        if let sourceURL {
            guard let target = safeExternal(sourceURL.trimmingCharacters(in:.whitespacesAndNewlines)) else { throw PaperError.invalidURL }
            element.url = target.absoluteString
        }
        element.x = point.x - 180; element.y = point.y - 140; element.width = 360; element.height = 280
        element.stroke = "#c4c9d2"; element.fill = "#f6f7f9"; element.z = nextZ()
        guard commit(.put([element])) else { throw BoardError.journal("PDF imported and kept in Papers. Resolve retained board edits and retry local saving before adding another card.") }
    }
    private func paste() {
        guard session.snapshot?.space.member == true, !importBusy, surface?.isUsingTool == false else { return }
        let pasteboard = UIPasteboard.general, point = center
        if let images = pasteboard.images, !images.isEmpty {
            runImport {
                for (index,image) in images.enumerated() {
                    guard let data = image.pngData() else { throw BoardError.invalidDocument("Clipboard image cannot be decoded.") }
                    try await self.importData(data,type:.png,filename:"clipboard.png",at:BoardPoint(x:point.x + Double(index)*24,y:point.y + Double(index)*24))
                }
            }
        } else if let text = pasteboard.string, !text.isEmpty { pasteText(text, at:point) }
    }
    private func pasteText(_ text: String, at point: BoardPoint) {
        runImport { try await self.importText(text, at: point) }
    }
    private func importText(_ text: String, at point: BoardPoint) async throws {
        guard text.count <= 100000 else { throw BoardError.invalidDocument("Pasted text exceeds 100,000 characters.") }
        let source = text.trimmingCharacters(in:.whitespacesAndNewlines)
        if BoardURLImports.isYouTube(source) {
            let preview: BoardYouTubePreview
            do { preview = try await api.youtubePreview(url: source) }
            catch {
                if (error as? PaperError)?.deniesAccess == true { session.invalidateAccess(); throw error }
                try addText(text, at: point)
                throw BoardError.invalidDocument("YouTube preview unavailable. The link was kept: \(error.localizedDescription)")
            }
            guard session.authorized, session.snapshot?.space.member == true else { throw BoardError.notAuthorized }
            let asset = UUID().uuidString
            var element = BoardElement(kind: .image); element.assetId = asset; element.url = preview.url; element.text = preview.title
            element.x = point.x; element.y = point.y; element.width = 360; element.height = 247; element.z = nextZ()
            guard commit(.put([element], assets: [asset: preview.thumbnail])) else { throw BoardError.journal("Preview import needs attention. Resolve retained edits and retry local saving before importing again.") }
            return
        }
        if let url = URL(string:source), ["http","https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil {
            let arxiv = ["arxiv.org","www.arxiv.org"].contains(url.host?.lowercased() ?? "")
            if arxiv || url.path.lowercased().hasSuffix(".pdf") {
                let result = try await api.importPaper(id: session.spaceID, url: source, arxiv: arxiv)
                await session.refresh(); try addPaper(result.paper, at: point, sourceURL: source); return
            }
        }
        try addText(text, at: point)
    }
    private func addText(_ text: String, at point: BoardPoint) throws {
        var element = BoardElement(kind:.text); element.x = point.x; element.y = point.y; element.text = text
        element.stroke = stroke; element.fontFamily = "sans-serif"; element.autoFontSize = true; element.textWrapWidth = 0
        let words = text.split(whereSeparator:\.isWhitespace).count; element.fontSize = words >= 1000 ? 14 : words >= 100 ? 18 : 24
        element.z = nextZ()
        if let url = safeExternal(text.trimmingCharacters(in:.whitespacesAndNewlines)), !text.contains(where:\.isWhitespace) { element.url = url.absoluteString }
        if let size = visuals?.measureText(for:element,constrainedTo:1e7) { element.width = max(12,Double(size.width)); element.height = Double(size.height) }
        else { element.width = 240; element.height = element.fontSize! * 1.3 }
        guard commit(.put([element])) else { throw BoardError.journal("Text import needs attention. Resolve retained edits and retry local saving before pasting again.") }
        surface?.select([element.id])
    }
    private func importURLPrompt() {
        textPrompt("PDF URL") { url in let point = self.center; self.runImport {
            guard let parsed = URL(string:url), ["http","https"].contains(parsed.scheme?.lowercased() ?? "") else { throw PaperError.invalidURL }
            let arxiv = ["arxiv.org","www.arxiv.org"].contains(parsed.host?.lowercased() ?? "")
            let result = try await self.api.importPaper(id:self.session.spaceID,url:url,arxiv:arxiv); await self.session.refresh(); try self.addPaper(result.paper,at:point,sourceURL:url)
        } }
    }
    private func addDiagram() {
        let menu = UIAlertController(title:"Diagram",message:nil,preferredStyle:.actionSheet)
        for format in ["svg","mermaid","html"] {
            menu.addAction(UIAlertAction(title:format.uppercased(),style:.default) { _ in
                let editor = BoardSourceController(title:format.uppercased(),source:"") { source in
                    let point = self.center
                    await self.session.refresh()
                    guard self.session.snapshot?.space.member == true, !self.session.hasPendingIntent, self.pendingJournal == nil, !self.session.hasUnconvertedInk, !self.session.dirty, self.session.conflicts.isEmpty, let snapshot = self.session.snapshot else { throw BoardError.invalidDocument("Save or resolve board edits before adding a diagram.") }
                    _ = try await self.api.diagram(id:self.session.spaceID,revision:snapshot.space.revision,format:format,source:source,x:point.x,y:point.y)
                    await self.session.refresh()
                    return true
                }
                self.present(UINavigationController(rootViewController:editor),animated:true)
            })
        }
        menu.addAction(UIAlertAction(title:"Cancel",style:.cancel)); menu.popoverPresentationController?.sourceView = moreButton; present(menu,animated:true)
    }
    func dropInteraction(_ interaction: UIDropInteraction, canHandle session: UIDropSession) -> Bool {
        self.session.snapshot?.space.member == true && session.hasItemsConforming(toTypeIdentifiers:[UTType.pdf.identifier,UTType.image.identifier,UTType.movie.identifier,UTType.plainText.identifier])
    }
    func dropInteraction(_ interaction: UIDropInteraction, sessionDidUpdate session: UIDropSession) -> UIDropProposal { UIDropProposal(operation:.copy) }
    func dropInteraction(_ interaction: UIDropInteraction, performDrop drop: UIDropSession) {
        guard let surface else { return }
        let point = surface.viewport.world(drop.location(in: surface))
        let providers = drop.items.map(\.itemProvider)
        runImport {
            var failures: [String] = []
            for (index, provider) in providers.enumerated() {
                do {
                let target = BoardPoint(x: point.x + Double(index) * 24, y: point.y + Double(index) * 24)
                if provider.canLoadObject(ofClass: NSString.self) && !provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) && !provider.hasItemConformingToTypeIdentifier(UTType.pdf.identifier) {
                    let text: String = try await withCheckedThrowingContinuation { continuation in
                        provider.loadObject(ofClass: NSString.self) { value, error in
                            if let error { continuation.resume(throwing: error) }
                            else if let text = value as? String { continuation.resume(returning: text) }
                            else { continuation.resume(throwing: PaperError.invalidResponse) }
                        }
                    }
                    try await self.importText(text, at: target)
                } else if let identifier = provider.registeredTypeIdentifiers.first(where: { id in UTType(id).map { $0.conforms(to: .image) || $0.conforms(to: .movie) || $0.conforms(to: .pdf) } ?? false }), let type = UTType(identifier) {
                    let data: Data = try await withCheckedThrowingContinuation { continuation in
                        provider.loadFileRepresentation(forTypeIdentifier: identifier) { url, error in
                            continuation.resume(with: Result {
                                guard let url else { throw error ?? PaperError.invalidResponse }
                                let limit = type.conforms(to: .pdf) ? 40 * 1024 * 1024 : 16 * 1024 * 1024
                                let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
                                let data = try handle.read(upToCount: limit + 1) ?? Data()
                                guard data.count <= limit else { throw PaperError.oversized }
                                return data
                            })
                        }
                    }
                    try await self.importData(data, type: type, filename: provider.suggestedName ?? "upload", at: target)
                } else { throw BoardError.invalidDocument("The dropped item is not an image, video, PDF or text.") }
                } catch { failures.append("Item \(index + 1): \(error.localizedDescription)") }
            }
            if !failures.isEmpty { throw BoardError.invalidDocument(failures.joined(separator: "\n")) }
        }
    }
}

@MainActor final class BoardSourceController: UIViewController {
    private let source = UITextView()
    private let errorLabel = UILabel()
    private let initial: String
    private let font: UIFont
    private let onSave: (String) async throws -> Bool
    private var saving = false
    init(title: String, source: String, font: UIFont = .monospacedSystemFont(ofSize: 16, weight: .regular), onSave: @escaping (String) async throws -> Bool) {
        initial = source; self.font = font; self.onSave = onSave
        super.init(nibName: nil, bundle: nil); self.title = title
        // Only the explicit Cancel action may discard an unsubmitted draft.
        isModalInPresentation = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidLoad() {
        super.viewDidLoad(); view.backgroundColor = .white
        navigationController?.isModalInPresentation = true
        source.text = initial; source.font = font
        source.autocorrectionType = .no; source.spellCheckingType = .no; source.autocapitalizationType = .none; source.inlinePredictionType = .no
        source.smartQuotesType = .no; source.smartDashesType = .no; source.smartInsertDeleteType = .no
        source.translatesAutoresizingMaskIntoConstraints = false; source.accessibilityIdentifier = "board.source"
        errorLabel.translatesAutoresizingMaskIntoConstraints = false; errorLabel.numberOfLines = 0
        errorLabel.textColor = .systemRed; errorLabel.font = .systemFont(ofSize: 16)
        errorLabel.accessibilityIdentifier = "board.source.error"
        view.addSubview(source); view.addSubview(errorLabel)
        NSLayoutConstraint.activate([
            errorLabel.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 12),
            errorLabel.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -12),
            errorLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            source.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            source.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            source.topAnchor.constraint(equalTo: errorLabel.bottomAnchor),
            source.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor)])
        navigationItem.leftBarButtonItem = UIBarButtonItem(barButtonSystemItem: .cancel, target: self, action: #selector(cancel))
        navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .save, target: self, action: #selector(save))
    }
    @objc private func cancel() { guard !saving else { return }; dismiss(animated: true) }
    @objc private func save() {
        guard !saving else { return }
        let value = source.text ?? ""
        guard value.utf8.count <= 100000 else { errorLabel.text = "Source exceeds 100,000 bytes."; return }
        saving = true; source.isEditable = false; errorLabel.text = nil
        navigationItem.leftBarButtonItem?.isEnabled = false; navigationItem.rightBarButtonItem?.isEnabled = false
        Task {
            defer {
                saving = false; source.isEditable = true
                navigationItem.leftBarButtonItem?.isEnabled = true; navigationItem.rightBarButtonItem?.isEnabled = true
            }
            do {
                guard try await onSave(value) else {
                    errorLabel.text = "Edit was not accepted. Resolve pending edits and retry."; return
                }
                dismiss(animated: true)
            } catch { errorLabel.text = error.localizedDescription }
        }
    }
}
