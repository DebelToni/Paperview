import UIKit
import PDFKit
import PencilKit

/// Observes intent without competing with PDFView scrolling or PencilKit's recognizers.
@MainActor private final class ReaderIntentRecognizer: UIGestureRecognizer {
    override func canPrevent(_ other: UIGestureRecognizer) -> Bool { false }
    override func canBePrevented(by other: UIGestureRecognizer) -> Bool { false }
    var onIntent: (() -> Void)?
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) { onIntent?(); state = .failed }
}

/// Watches Pencil contacts without recognizing a gesture or competing with PencilKit.
@MainActor private final class ReaderEraseRecognizer: UIGestureRecognizer {
    var begin: ((CGPoint) -> Bool)?
    var move: ((CGPoint) -> Void)?
    var end: (() -> Void)?
    private var tracking = false
    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let touch = touches.first(where: { $0.type == .pencil }), let view else { return }
        tracking = begin?(touch.location(in: view)) == true
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard tracking, let touch = touches.first(where: { $0.type == .pencil }), let view else { return }
        for sample in event.coalescedTouches(for: touch) ?? [touch] { move?(sample.location(in: view)) }
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        guard touches.contains(where: { $0.type == .pencil }) else { return }
        if tracking {
            if let touch = touches.first(where: { $0.type == .pencil }), let view { move?(touch.location(in: view)) }
            end?()
        }
        tracking = false; state = .failed
    }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        if tracking { end?() }; tracking = false; state = .failed
    }
    override func reset() { super.reset(); tracking = false }
}

/// Passive tap observation: never cancels scrolling, selection, or PencilKit input.
@MainActor final class ReaderLinkRecognizer: UIGestureRecognizer {
    var tapped: ((CGPoint, UITouch.TouchType) -> Void)?
    var snapshot: (() -> [Int: Int])?
    private var initialSnapshot: [Int: Int] = [:]
    private var start: CGPoint?
    private var began: TimeInterval = 0
    override func canPrevent(_ other: UIGestureRecognizer) -> Bool { false }
    override func canBePrevented(by other: UIGestureRecognizer) -> Bool { false }
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard start == nil, touches.count == 1, event.allTouches?.count == 1,
              let touch = touches.first, touch.type != .pencil, let view else { state = .failed; return }
        start = touch.location(in: view); began = touch.timestamp
        initialSnapshot = snapshot?() ?? [:]
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let start, let touch = touches.first, let view else { return }
        let point = touch.location(in: view)
        if hypot(point.x - start.x, point.y - start.y) > 8 { state = .failed }
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        if let start, let touch = touches.first, let view {
            let point = touch.location(in: view)
            if touch.timestamp - began < 0.3, hypot(point.x - start.x, point.y - start.y) <= 8 {
                finishTap(at: point, type: touch.type, initial: initialSnapshot)
            }
        }
        state = .failed
    }
    /// PencilKit may deliver its final lasso change after this observer's touchesEnded.
    func finishTap(at point: CGPoint, type: UITouch.TouchType, initial: [Int: Int]) {
        DispatchQueue.main.async { [weak self] in
            guard let self, initial == (self.snapshot?() ?? [:]) else { return }
            self.tapped?(point, type)
        }
    }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) { state = .failed }
    override func reset() { super.reset(); start = nil }
}

/// PDFKit coordinates remain authoritative, including crop origins, rotation and UserUnit.
@MainActor enum ReaderLinks {
    static func allows(_ type: UITouch.TouchType, tool: ReaderTool, editing: Bool) -> Bool {
        type != .pencil && (!editing || (tool != .text && tool != .select))
    }
    static func safeURL(_ url: URL) -> URL? {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = parts.scheme?.lowercased(),
              !url.absoluteString.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
        switch scheme {
        case "http", "https":
            guard let host = parts.host, !host.isEmpty, parts.user == nil, parts.password == nil else { return nil }
        case "mailto":
            guard !parts.path.isEmpty else { return nil }
        default: return nil
        }
        return url
    }
    static func link(on page: PDFPage, at point: CGPoint) -> PDFAnnotation? {
        page.annotations.reversed().first { annotation in
            guard annotation.type == "Link", annotation.shouldDisplay, annotation.bounds.contains(point) else { return false }
            guard let quads = annotation.quadrilateralPoints, !quads.isEmpty else { return true }
            let local = CGPoint(x: point.x - annotation.bounds.minX, y: point.y - annotation.bounds.minY)
            for start in stride(from: 0, through: quads.count - 4, by: 4) {
                let polygon = UIBezierPath()
                polygon.move(to: quads[start].cgPointValue)
                for offset in [1, 3, 2] { polygon.addLine(to: quads[start + offset].cgPointValue) }
                polygon.close()
                if polygon.contains(local) { return true }
            }
            return false
        }
    }
    @discardableResult static func activate(_ annotation: PDFAnnotation, in view: PDFView, open: (URL) -> Void) -> Bool {
        guard annotation.type == "Link", annotation.shouldDisplay, let document = view.document else { return false }
        if let action = annotation.action as? PDFActionURL {
            guard let url = action.url, let safe = safeURL(url) else { return false }
            open(safe); return true
        }
        if let action = annotation.action as? PDFActionNamed {
            let index = view.currentPage.map { document.index(for: $0) } ?? 0
            let target: Int
            switch action.name {
            case .firstPage: target = 0
            case .lastPage: target = document.pageCount - 1
            case .nextPage: target = index + 1
            case .previousPage: target = index - 1
            default: return false
            }
            guard target >= 0, target < document.pageCount, let page = document.page(at: target) else { return false }
            view.go(to: page); return true
        }
        let destination = (annotation.action as? PDFActionGoTo)?.destination ?? (annotation.action == nil ? annotation.destination : nil)
        guard let destination, let page = destination.page, document.index(for: page) != NSNotFound else { return false }
        view.go(to: destination); return true
    }
}

@MainActor final class ReaderPageView: UIView {
    let canvas = PKCanvasView()
    let textLayer = UIView()
    var values: [PaperAnnotation] = []
    var baseline: [Data] = []
    var textValues: [String: PaperAnnotation] = [:]
    var erasedText: [String: PaperAnnotation] = [:]
    var eraseContact = false
    private var erasePoint: CGPoint?

    /// Read the rendered overlay only. No portable/native state is changed by inspection.
    func annotationID(at point: CGPoint, tolerance: CGFloat = 5) -> String? {
        for label in textLayer.subviews.reversed() where !label.isHidden {
            if label.bounds.contains(label.convert(point, from: self)),
               let id = label.accessibilityIdentifier, textValues[id] != nil { return id }
        }
        let strokes = canvas.drawing.strokes
        // render/commit keep values in drawing order. Never archive strokes on the tap path.
        guard !active, !applying, !failedWrite, strokes.count == values.count else { return nil }
        let canvasPoint = canvas.convert(point, from: self)
        for index in strokes.indices.reversed() {
            if Self.hits(strokes[index], point: canvasPoint, tolerance: tolerance) { return values[index].id }
        }
        return nil
    }
    static func hits(_ stroke: PKStroke, point: CGPoint, tolerance: CGFloat) -> Bool {
        let transform = stroke.transform
        let scale = max(hypot(transform.a, transform.b), hypot(transform.c, transform.d))
        var previous: CGPoint?
        var previousRadius: CGFloat = 0
        for sample in stroke.path.interpolatedPoints(by: .distance(1)) {
            let p = sample.location.applying(transform)
            let radius = max(sample.size.width, sample.size.height) * scale / 2
            if let a = previous {
                let dx = p.x - a.x, dy = p.y - a.y
                let length = dx * dx + dy * dy
                let t = length > 0 ? max(0, min(1, ((point.x - a.x) * dx + (point.y - a.y) * dy) / length)) : 0
                let nearest = CGPoint(x: a.x + t * dx, y: a.y + t * dy)
                if hypot(point.x - nearest.x, point.y - nearest.y) <= tolerance + max(radius, previousRadius) {
                    if stroke.mask == nil || stroke.mask!.contains(nearest.applying(transform.inverted())) { return true }
                }
            } else if hypot(point.x - p.x, point.y - p.y) <= tolerance + radius,
                      stroke.mask == nil || stroke.mask!.contains(sample.location) { return true }
            previous = p; previousRadius = radius
        }
        return false
    }

    /// Convert the swept segment into each label's local coordinates, including page rotation.
    func sweepErase(to point: CGPoint) {
        let previous = erasePoint ?? point
        erasePoint = point
        for label in textLayer.subviews {
            guard let id = label.accessibilityIdentifier, let value = textValues[id], erasedText[id] == nil else { continue }
            let a = label.convert(previous, from: self), b = label.convert(point, from: self)
            if Self.intersects(a, b, rect: label.bounds) { erasedText[id] = value; label.isHidden = true }
        }
    }
    func beginErase(at point: CGPoint) -> Bool {
        guard editingEnabled, readerTool == .erase, !failedWrite else { return false }
        eraseContact = true; active = true; erasePoint = nil
        sweepErase(to: point); return true
    }
    func endErase() { eraseContact = false; erasePoint = nil }
    private static func intersects(_ a: CGPoint, _ b: CGPoint, rect: CGRect) -> Bool {
        var lower: CGFloat = 0, upper: CGFloat = 1
        for (start, delta, minimum, maximum) in [(a.x, b.x - a.x, rect.minX, rect.maxX), (a.y, b.y - a.y, rect.minY, rect.maxY)] {
            if delta == 0 { if start < minimum || start > maximum { return false } }
            else {
                let t0 = (minimum - start) / delta, t1 = (maximum - start) / delta
                lower = max(lower, min(t0, t1)); upper = min(upper, max(t0, t1))
                if lower > upper { return false }
            }
        }
        return true
    }
    private(set) var drawingChangeCount = 0
    func noteDrawingChange() {
        if !applying { drawingChangeCount += 1 }
    }
    var applying = false
    var active = false
    var failedWrite = false
    var retryWrite: (() -> Void)?
    var onLayout: (() -> Void)?
    var textTap: UITapGestureRecognizer?
    private var priorSize = CGSize.zero
    var editingEnabled = false
    var readerTool: ReaderTool = .pen
    var configuredToolKey = ""
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.drawingPolicy = .pencilOnly
        canvas.isScrollEnabled = false
        canvas.minimumZoomScale = 1; canvas.maximumZoomScale = 1
        textLayer.isUserInteractionEnabled = false
        addSubview(canvas); addSubview(textLayer)
        canvas.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        textLayer.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    }
    func acceptsTouch(_ type: UITouch.TouchType) -> Bool {
        guard editingEnabled else { return false }
        return type == .pencil || readerTool == .select || readerTool == .text
    }
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let touch = event?.allTouches?.min { a, b in
            let x = a.location(in: self), y = b.location(in: self)
            return hypot(x.x - point.x, x.y - point.y) < hypot(y.x - point.x, y.y - point.y)
        }
        if let touch, !acceptsTouch(touch.type) { return nil }
        guard editingEnabled else { return nil }
        if readerTool == .text { return bounds.contains(point) ? self : nil }
        return super.hitTest(point, with: event)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layoutSubviews() {
        super.layoutSubviews(); canvas.frame = bounds; textLayer.frame = bounds
        if priorSize != bounds.size { priorSize = bounds.size; onLayout?() }
    }
}

@MainActor final class PaperReaderController: UIViewController, PDFViewDelegate, @preconcurrency PDFPageOverlayViewProvider, PKCanvasViewDelegate, UIPencilInteractionDelegate {
    private let api: SpaceAPI
    private let paperID: String
    private let session: PaperSession
    private var followID: String?
    let pdfView = PDFView()
    var openOriginalLink: (URL) -> Void = { UIApplication.shared.open($0) }
    private let toolbar = ReaderControlStrip()
    private let preferences: UserDefaults
    private(set) var toolbarPosition: ReaderToolbarPosition
    private var toolbarLayout: [NSLayoutConstraint] = []
    private var viewportKey: String?
    private let status = UILabel()
    private lazy var pageCountElement: UIAccessibilityElement = {
        let element = UIAccessibilityElement(accessibilityContainer: view!)
        element.accessibilityIdentifier = "reader.page-count"; element.accessibilityLabel = "Page"
        element.accessibilityTraits = .staticText; return element
    }()
    private var overlays: [Int: ReaderPageView] = [:]
    private var task: Task<Void, Never>?
    private var opening: Task<Void, Never>?
    private var isOpening = false
    private var actionTask: Task<Void, Never>?
    private var presenceRequest: Task<PresenceResponse, Error>?
    private var toolbarSignature = ""
    private var previousPopEnabled: Bool?
    private var visible = false
    private(set) var tool = ReaderTool.pen
    private var queuedQuickErase = false
    private var eraseReturnTool: ReaderTool?
    private var pendingManualTool: ReaderTool?
    private var inkWidths = ReaderInkWidths()
    var thickness: CGFloat { inkWidths.value(for: tool) }
    private var colors: [ReaderTool: String] = [.pen: "#007aff", .question: "#ff2d55", .highlight: "#ffcc00", .text: "#007aff"]
    private var presentingPosition = false
    private var applyingPosition = false
    private var conflictShown: String?
    private weak var creatorAlert: UIAlertController?
    private var creatorContext: (id: String, principal: String?)?
    private var readerError: String?
    private var currentPresenters: [Presenter] = []
    private struct Change { var before: PaperAnnotation?; var after: PaperAnnotation?; var id: String; var nativeBefore: Data? = nil; var nativeAfter: Data? = nil }
    private var undoStack: [[Change]] = []
    private var redoStack: [[Change]] = []
    private struct CapturedBase { var value: PaperAnnotation? }
    private var capturedBases: [String: CapturedBase] = [:]
    private var nativeHistory: [String: Data] = [:]
    private func nativeKey(_ value: PaperAnnotation) -> String { let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys; return (try? encoder.encode(value).base64EncodedString()) ?? value.id }
    private func captureBase(_ value: PaperAnnotation) {
        let server = session.metadata?.annotations.first { $0.id == value.id }
        let original: PaperAnnotation?
        if let conflict = session.conflicts.first(where: { $0.id == value.id }) { original = conflict.original } else { original = server }
        capturedBases[nativeKey(value)] = CapturedBase(value: value == server ? value : original)
    }
    private func original(for value: PaperAnnotation?) -> PaperAnnotation? {
        guard let value else { return nil }
        if let base = capturedBases[nativeKey(value)] { return base.value }; return value
    }
    private var contact: Bool { overlays.values.contains(where: { $0.active || $0.failedWrite }) }

    init(api: SpaceAPI, paperID: String, followID: String? = nil, storageDirectory: URL, session: PaperSession? = nil, preferences: UserDefaults = .standard) {
        self.preferences = preferences; self.toolbarPosition = ReaderToolbarPosition.saved(in: preferences)
        self.api = api; self.paperID = paperID; self.followID = followID
        self.session = session ?? PaperSession(api: api, paperID: paperID, storageDirectory: storageDirectory)
        super.init(nibName: nil, bundle: nil)
    }
    /// PDFKit's default URL opener must never bypass our touch/tool and URL policy.
    /// The passive observer is the sole URL activation route, avoiding duplicate opens.
    func pdfViewWillClick(onLink sender: PDFView, with url: URL) {}

    func invalidateAccess() {
        saveViewport()
        task?.cancel(); opening?.cancel(); actionTask?.cancel()
        stopPresenting(); session.invalidateAccess()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { task?.cancel(); opening?.cancel(); actionTask?.cancel(); NotificationCenter.default.removeObserver(self) }
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(white: 0.96, alpha: 1)
        view.accessibilityIdentifier = "paper.reader"
        toolbar.accessibilityIdentifier = "paper.toolbar"
        pdfView.accessibilityIdentifier = "reader.document"
        status.accessibilityIdentifier = "reader.status"
        pdfView.displayMode = .singlePageContinuous
        pdfView.displayDirection = .vertical
        pdfView.displaysPageBreaks = true
        pdfView.autoScales = true
        pdfView.delegate = self
        pdfView.pageOverlayViewProvider = self
        pdfView.isInMarkupMode = true
        for child in [pdfView, toolbar, status] { child.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(child) }
        view.accessibilityElements = [toolbar, pageCountElement, pdfView, status]
        status.textAlignment = .center; status.numberOfLines = 3
        NSLayoutConstraint.activate([
            status.centerXAnchor.constraint(equalTo: view.centerXAnchor), status.centerYAnchor.constraint(equalTo: view.centerYAnchor), status.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, multiplier: 0.85)
        ])
        layoutToolbar()
        let intent = ReaderIntentRecognizer(target: nil, action: nil)
        intent.cancelsTouchesInView = false
        intent.onIntent = { [weak self] in self?.followID = nil }
        pdfView.addGestureRecognizer(intent)
        let links = ReaderLinkRecognizer(target: nil, action: nil)
        links.cancelsTouchesInView = false
        links.delaysTouchesBegan = false; links.delaysTouchesEnded = false
        links.snapshot = { [weak self] in self?.overlays.mapValues { $0.drawingChangeCount } ?? [:] }
        links.tapped = { [weak self] point, type in
            guard let self, type != .pencil, self.session.metadata != nil,
                  let page = self.pdfView.page(for: point, nearest: false) else { return }
            // The text recognizer owns its editor and creator message, avoiding two alerts.
            if self.tool == .text && self.session.metadata?.canEdit == true { return }
            if let document = self.pdfView.document,
               let overlay = self.overlays[document.index(for: page) + 1],
               let id = overlay.annotationID(at: overlay.convert(point, from: self.pdfView),
                                             tolerance: self.inspectionTolerance(overlay)) {
                self.showCreator(id: id); return
            }
            guard ReaderLinks.allows(type, tool: self.tool, editing: self.session.metadata?.canEdit == true),
                  let annotation = ReaderLinks.link(on: page, at: self.pdfView.convert(point, to: page)) else { return }
            self.followID = nil
            ReaderLinks.activate(annotation, in: self.pdfView, open: self.openOriginalLink)
        }
        pdfView.addGestureRecognizer(links)
        session.onChange = { [weak self] in self?.changed() }
        let pencil = UIPencilInteraction(); pencil.delegate = self; view.addInteraction(pencil)
        NotificationCenter.default.addObserver(self, selector: #selector(background), name: UIApplication.willResignActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(foreground), name: UIApplication.didBecomeActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(updateAccessibility), name: .PDFViewPageChanged, object: pdfView)
        buildToolbar(); load()
    }
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated); navigationController?.setNavigationBarHidden(true, animated: animated)
        previousPopEnabled = navigationController?.interactivePopGestureRecognizer?.isEnabled
        navigationController?.interactivePopGestureRecognizer?.isEnabled = false
        visible = true; startPolling()
    }
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated); saveViewport(); visible = false; task?.cancel(); task = nil; opening?.cancel(); actionTask?.cancel()
        dismissCreator()
        stopPresenting(); persist(); let retained = session
        Task { await retained.flush() }
        if let previousPopEnabled { navigationController?.interactivePopGestureRecognizer?.isEnabled = previousPopEnabled }
        previousPopEnabled = nil
        navigationController?.setNavigationBarHidden(false, animated: animated)
    }
    func setToolbarPosition(_ position: ReaderToolbarPosition) {
        guard position != toolbarPosition, !contact else { return }
        let anchor = self.position(), horizontal = horizontalPosition()
        toolbarPosition = position; preferences.set(position.rawValue, forKey: ReaderToolbarPosition.preferenceKey)
        guard isViewLoaded else { return }
        layoutToolbar(); view.layoutIfNeeded()
        if pdfView.document != nil { seek(anchor, horizontal: horizontal) }
        buildToolbar(); saveViewport()
    }
    private func layoutToolbar() {
        NSLayoutConstraint.deactivate(toolbarLayout)
        toolbar.setPosition(toolbarPosition)
        let safe = view.safeAreaLayoutGuide
        if toolbarPosition.isVertical {
            toolbarLayout = [toolbar.topAnchor.constraint(equalTo: safe.topAnchor), toolbar.bottomAnchor.constraint(equalTo: safe.bottomAnchor),
                             pdfView.topAnchor.constraint(equalTo: safe.topAnchor), pdfView.bottomAnchor.constraint(equalTo: view.bottomAnchor)]
            if toolbarPosition == .left {
                toolbarLayout += [toolbar.leadingAnchor.constraint(equalTo: safe.leadingAnchor), pdfView.leadingAnchor.constraint(equalTo: toolbar.trailingAnchor), pdfView.trailingAnchor.constraint(equalTo: view.trailingAnchor)]
            } else {
                toolbarLayout += [toolbar.trailingAnchor.constraint(equalTo: safe.trailingAnchor), pdfView.leadingAnchor.constraint(equalTo: view.leadingAnchor), pdfView.trailingAnchor.constraint(equalTo: toolbar.leadingAnchor)]
            }
        } else {
            toolbarLayout = [toolbar.leadingAnchor.constraint(equalTo: safe.leadingAnchor), toolbar.trailingAnchor.constraint(equalTo: safe.trailingAnchor),
                             pdfView.leadingAnchor.constraint(equalTo: view.leadingAnchor), pdfView.trailingAnchor.constraint(equalTo: view.trailingAnchor)]
            if toolbarPosition == .top {
                toolbarLayout += [toolbar.topAnchor.constraint(equalTo: safe.topAnchor), pdfView.topAnchor.constraint(equalTo: toolbar.bottomAnchor), pdfView.bottomAnchor.constraint(equalTo: view.bottomAnchor)]
            } else {
                toolbarLayout += [toolbar.bottomAnchor.constraint(equalTo: safe.bottomAnchor), pdfView.topAnchor.constraint(equalTo: safe.topAnchor), pdfView.bottomAnchor.constraint(equalTo: toolbar.topAnchor)]
            }
        }
        NSLayoutConstraint.activate(toolbarLayout)
    }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        pageCountElement.accessibilityFrameInContainerSpace = toolbar.frame
        configureZoomLimits()
    }
    private func configureZoomLimits() {
        guard pdfView.document != nil else { return }
        let fit = pdfView.scaleFactorForSizeToFit
        guard fit.isFinite, fit > 0 else { return }
        if abs(pdfView.minScaleFactor - fit * 0.5) > 0.001 { pdfView.minScaleFactor = fit * 0.5 }
        if abs(pdfView.maxScaleFactor - fit * 3) > 0.001 { pdfView.maxScaleFactor = fit * 3 }
    }
    @objc private func updateAccessibility() {
        let page = pdfView.document == nil ? 0 : position().page, count = pdfView.document?.pageCount ?? 0
        pageCountElement.accessibilityValue = "\(page) of \(count)"
        toolbar.accessibilityValue = "Page \(page) of \(count). " + session.status
        pdfView.accessibilityValue = "Page \(page) of \(count)"
        buildToolbar()
    }
    override var canBecomeFirstResponder: Bool { true }
    override func viewDidAppear(_ animated: Bool) { super.viewDidAppear(animated); becomeFirstResponder() }
    override var keyCommands: [UIKeyCommand]? {
        guard presentedViewController == nil else { return [] }
        let specs: [(String, UIKeyModifierFlags, String)] = [
            (UIKeyCommand.inputUpArrow, .alternate, "Previous page"), (UIKeyCommand.inputDownArrow, .alternate, "Next page"),
            ("p", [], "Pen"), ("q", [], "Question"), ("h", [], "Highlight"), ("v", [], "Select"), ("t", [], "Text"), ("e", [], "Quick erase"),
            ("z", .command, "Undo"), ("z", [.command, .shift], "Redo"),
            ("+", .command, "Zoom in"), ("=", .command, "Zoom in"), ("-", .command, "Zoom out"), ("0", .command, "Reset zoom")
        ]
        return specs.map { input, modifiers, title in
            let key = UIKeyCommand(input: input, modifierFlags: modifiers, action: #selector(keyPressed(_:)))
            key.discoverabilityTitle = title; key.wantsPriorityOverSystemBehavior = true; return key
        }
    }
    @objc private func keyPressed(_ key: UIKeyCommand) {
        guard presentedViewController == nil, let input = key.input else { return }
        if key.modifierFlags.contains(.alternate) {
            followID = nil
            let delta = input == UIKeyCommand.inputUpArrow ? -1 : 1
            if let document = pdfView.document, let page = document.page(at: min(document.pageCount - 1, max(0, position().page - 1 + delta))) { pdfView.go(to: page) }
        } else if key.modifierFlags.contains(.command) {
            switch input {
            case "z": if session.metadata?.canEdit == true { key.modifierFlags.contains(.shift) ? redo() : undo() }
            case "+", "=": changeZoom(1.2)
            case "-": changeZoom(1 / 1.2)
            case "0": changeZoom(nil)
            default: break
            }
        } else if session.metadata?.canEdit == true {
            let tools: [String: ReaderTool] = ["p": .pen, "q": .question, "h": .highlight, "v": .select, "t": .text, "e": .erase]
            if let choice = tools[input] { setTool(choice) }
        }
    }
    private func changeZoom(_ multiplier: CGFloat?) {
        followID = nil
        var anchor = position()
        anchor.zoom = multiplier.map { min(3, max(0.5, anchor.zoom * Double($0))) } ?? 1
        seek(anchor, horizontal: horizontalPosition()); saveViewport()
    }
    private func seek(_ position: ReadingPosition, horizontal: Double = 0) {
        guard let page = pdfView.document?.page(at: position.page - 1) else { return }
        applyingPosition = true; defer { applyingPosition = false }
        pdfView.autoScales = false; configureZoomLimits()
        pdfView.scaleFactor = pdfView.scaleFactorForSizeToFit * CGFloat(position.zoom)
        let geometry = ReaderGeometry(page: page)
        let normalized = geometry.normalized(CGPoint(x: CGFloat(horizontal) * geometry.displaySize.width, y: CGFloat(position.scroll) * geometry.displaySize.height), size: geometry.displaySize)
        pdfView.go(to: PDFDestination(page: page, at: geometry.pdf(normalized)))
    }
    @objc private func background() {
        saveViewport()
        task?.cancel(); task = nil; actionTask?.cancel()
        stopPresenting(); persist()
        let retained = session; Task { await retained.flush() }
    }
    @objc private func foreground() { if visible { startPolling() } }
    private func stopPresenting() {
        guard presentingPosition || presenceRequest != nil else { return }
        presentingPosition = false; buildToolbar()
        let api = api, id = paperID, lastPosition = position(), previous = presenceRequest
        // Order the final false after any in-flight true, without retaining the reader.
        presenceRequest = Task {
            if let previous { _ = try? await previous.value }
            return try await api.presence(paperID: id, presenting: false, position: lastPosition)
        }
    }
    private func publishPresence(presenting: Bool, position: ReadingPosition) async throws -> PresenceResponse {
        let api = api, id = paperID, previous = presenceRequest
        let request = Task {
            if let previous { _ = try? await previous.value }
            try Task.checkCancellation()
            return try await api.presence(paperID: id, presenting: presenting, position: position)
        }
        presenceRequest = request
        return try await request.value
    }
    private func togglePresentation() {
        presentingPosition.toggle(); buildToolbar()
        actionTask = Task { [weak self] in await self?.updatePresence() }
    }
    private func persist() {
        guard session.metadata != nil else { return }
        for (index, overlay) in overlays where overlay.active || overlay.failedWrite {
            if overlay.failedWrite { overlay.retryWrite?() } else { commit(overlay, page: index) }
        }
        do { try session.persist() } catch { showError(error) }
    }
    private func load() {
        guard !isOpening else { return }
        isOpening = true; status.isHidden = false; status.text = "Opening PDF…"; buildToolbar()
        opening = Task { [weak self] in
            guard let self else { return }
            defer { isOpening = false; buildToolbar() }
            do {
                let data = try await session.open()
                guard !Task.isCancelled else { return }
                guard let document = PDFDocument(data: data), document.pageCount > 0 else { throw PaperError.invalidResponse }
                pdfView.document = document; view.layoutIfNeeded(); pdfView.layoutDocumentView(); configureZoomLimits(); status.isHidden = true; restoreViewport(); changed()
                // Stop following only for intentional direct manipulation, never programmatic seeks.
                for scroll in scrollViews(pdfView) { scroll.panGestureRecognizer.addTarget(self, action: #selector(scrolled(_:))); scroll.pinchGestureRecognizer?.addTarget(self, action: #selector(scrolled(_:))) }
            } catch { status.isHidden = false; status.text = error.localizedDescription + "\nUse Retry to reopen."; buildToolbar() }
        }
    }
    private func scrollViews(_ root: UIView) -> [UIScrollView] {
        (root as? UIScrollView).map { [$0] } ?? root.subviews.flatMap { scrollViews($0) }
    }
    @objc private func scrolled(_ gesture: UIGestureRecognizer) {
        if gesture.state == .began && !applyingPosition { followID = nil }
        if gesture.state == .ended || gesture.state == .cancelled { saveViewport() }
    }
    private func startPolling() {
        guard task == nil, visible, UIApplication.shared.applicationState == .active else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard self != nil else { return }
                await self?.pollOnce()
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }
    private func pollOnce() async {
        guard visible, session.metadata != nil, UIApplication.shared.applicationState == .active, !contact else { return }
        saveViewport()
        await session.refresh()
        if !Task.isCancelled && visible && UIApplication.shared.applicationState == .active && !contact { await updatePresence() }
    }
    private func changed() {
        guard isViewLoaded else { return }
        refreshCreator()
        if session.metadata == nil, pdfView.document != nil {
            viewportKey = nil
            let oldOverlays = Array(overlays.values); overlays.removeAll()
            oldOverlays.forEach { $0.canvas.delegate = nil; $0.canvas.drawing = PKDrawing(); $0.removeFromSuperview() }
            pdfView.document = nil
            nativeHistory.removeAll(); capturedBases.removeAll(); undoStack.removeAll(); redoStack.removeAll()
            presentingPosition = false; followID = nil; currentPresenters = []
            if let alert = presentedViewController as? UIAlertController { alert.textFields?.forEach { $0.text = "" }; alert.dismiss(animated: false) }
            conflictShown = nil
            status.isHidden = false; status.text = session.status
        }
        updateAccessibility()
        for (index, overlay) in overlays where !overlay.active && !overlay.failedWrite && !overlay.applying && tool != .select { render(overlay, page: index) }
        updateTools(); buildToolbar()
        if let conflict = session.conflicts.first, conflictShown == nil, visible, UIApplication.shared.applicationState == .active, presentedViewController == nil {
            conflictShown = conflict.id
            let alert = UIAlertController(title: "Annotation conflict", message: conflict.id, preferredStyle: .alert)
            for (title, mine) in [("Keep mine", true), ("Use server", false)] {
                alert.addAction(UIAlertAction(title: title, style: .default) { [weak self] _ in
                    guard let self else { return }; conflictShown = nil
                    do { try session.resolve(id: conflict.id, keepMine: mine); if let value = session.annotations.first(where: { $0.id == conflict.id }) { captureBase(value) } } catch { showError(error) }
                })
            }
            present(alert, animated: true)
        }
    }
    private func button(_ symbol: String, _ label: String, _ action: @escaping () -> Void) -> UIButton {
        let item = UIButton(type: .system)
        item.setImage(UIImage(systemName: symbol), for: .normal)
        item.addAction(UIAction { _ in action() }, for: .touchUpInside)
        item.tintColor = .label; item.layer.cornerRadius = 6
        item.accessibilityLabel = label
        item.accessibilityIdentifier = label == "Close" ? "reader.close" : "reader." + label.lowercased().replacingOccurrences(of: " ", with: "-")
        NSLayoutConstraint.activate([item.widthAnchor.constraint(equalToConstant: 44), item.heightAnchor.constraint(equalToConstant: 44)])
        return item
    }
    private func menuButton(_ symbol: String, _ label: String, _ identifier: String, _ menu: UIMenu) -> UIButton {
        let item = button(symbol, label) {}
        item.menu = menu; item.showsMenuAsPrimaryAction = true
        item.accessibilityIdentifier = identifier; return item
    }
    private func buildToolbar() {
        let signature = [tool.rawValue, String(session.metadata?.canEdit ?? false), String(session.metadata?.guest ?? true), String(session.metadata?.paper.isRead ?? false),
                         readerError ?? session.status, followID ?? "", String(presentingPosition), String(pdfView.document == nil), String(isOpening),
                         currentPresenters.sorted { $0.id < $1.id }.map { $0.id + $0.nickname }.joined(separator: "|"),
                         String(position().page), String(pdfView.document?.pageCount ?? 0), String(Double(thickness)), colors[tool] ?? "",
                         String(undoStack.count), String(redoStack.count), toolbarPosition.rawValue].joined(separator: ";")
        guard signature != toolbarSignature else { return }; toolbarSignature = signature
        var items: [UIView] = [button("chevron.left", "Close") { [weak self] in self?.requestClose() }]
        if pdfView.document == nil {
            let retry = button("arrow.clockwise", "Retry") { [weak self] in self?.load() }
            retry.isEnabled = !isOpening; items.append(retry)
        } else {
            let page = position().page, count = pdfView.document?.pageCount ?? 0
            let previous = button("chevron.left", "Previous page") { [weak self] in self?.navigatePage(-1) }
            previous.isEnabled = page > 1; items.append(previous)
            let counter = button("", "Page number") { [weak self] in self?.jumpToPage() }
            counter.setTitle("\(page)/\(count)", for: .normal)
            counter.titleLabel?.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
            counter.accessibilityValue = "\(page) of \(count)"; items.append(counter)
            let next = button("chevron.right", "Next page") { [weak self] in self?.navigatePage(1) }
            next.isEnabled = page < count; items.append(next)
            if session.metadata?.canEdit == true {
                for choice in ReaderTool.allCases {
                    let item = button(choice.symbol, choice.rawValue.capitalized) { [weak self] in self?.setTool(choice) }
                    item.accessibilityIdentifier = "reader.tool." + choice.rawValue
                    item.isSelected = tool == choice
                    item.backgroundColor = item.isSelected ? UIColor(white: 0.86, alpha: 1) : .clear
                    if item.isSelected { item.accessibilityTraits.insert(.selected) }
                    if choice == .question { item.tintColor = ReaderInk.color("#ff2d55") }
                    items.append(item)
                }
                let thinner = button("minus", "Thinner") { [weak self] in self?.resizeInk(-1) }
                thinner.isEnabled = inkWidths.canResize(-1, tool: tool); items.append(thinner)
                let width = UILabel(); width.text = String(format: "%g", Double(thickness))
                width.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular); width.textAlignment = .center
                NSLayoutConstraint.activate([width.widthAnchor.constraint(equalToConstant: 44), width.heightAnchor.constraint(equalToConstant: 44)])
                width.accessibilityIdentifier = "reader.width"; width.accessibilityLabel = "Ink thickness"
                width.accessibilityValue = String(format: "%g pt", Double(thickness))
                width.alpha = [.pen, .question, .highlight].contains(tool) ? 1 : 0.35; items.append(width)
                let thicker = button("plus", "Thicker") { [weak self] in self?.resizeInk(1) }
                thicker.isEnabled = inkWidths.canResize(1, tool: tool); items.append(thicker)
                let palette = [("Black", "#000000"), ("Blue", "#007aff"), ("Green", "#34c759"), ("Orange", "#ff9500"), ("Yellow", "#ffcc00"), ("Red", "#ff3b30"), ("Ink blue", "#0033cc"), ("Pink", "#ff2d55")].map { name, hex in
                    UIAction(title: name, image: UIImage(systemName: "circle.fill")?.withTintColor(ReaderInk.color(hex), renderingMode: .alwaysOriginal), state: colors[tool] == hex ? .on : .off) { [weak self] _ in
                        guard let self, !contact else { return }; colors[tool] = hex; updateTools(); buildToolbar()
                    }
                }
                let color = menuButton("circle.fill", "Ink color", "reader.palette", UIMenu(children: palette))
                color.tintColor = ReaderInk.color(colors[tool] ?? "#007aff"); color.accessibilityValue = colors[tool]
                color.isEnabled = ![.select, .erase].contains(tool); items.append(color)
                let undo = button("arrow.uturn.backward", "Undo") { [weak self] in self?.undo() }
                undo.isEnabled = !undoStack.isEmpty; items.append(undo)
                let redo = button("arrow.uturn.forward", "Redo") { [weak self] in self?.redo() }
                redo.isEnabled = !redoStack.isEmpty; items.append(redo)
            }
            let more: [UIMenuElement] = [UIAction(title: readerError ?? session.status, attributes: .disabled, handler: { _ in }), UIAction(title: "Export annotated PDF", image: UIImage(systemName: "square.and.arrow.up")) { [weak self] _ in self?.exportPDF() }]
            let positions = UIMenu(title: "Toolbar position", children: ReaderToolbarPosition.allCases.map { position in
                UIAction(title: position.rawValue.capitalized, state: position == toolbarPosition ? .on : .off) { [weak self] _ in self?.setToolbarPosition(position) }
            })
            var actions: [UIMenuElement] = more + [positions,
                UIAction(title: "Zoom out", image: UIImage(systemName: "minus.magnifyingglass")) { [weak self] _ in self?.changeZoom(1 / 1.2) },
                UIAction(title: "Zoom in", image: UIImage(systemName: "plus.magnifyingglass")) { [weak self] _ in self?.changeZoom(1.2) },
                UIAction(title: "Reset zoom", image: UIImage(systemName: "arrow.up.left.and.arrow.down.right")) { [weak self] _ in self?.changeZoom(nil) }
            ]
            if readerError != nil { actions.append(UIAction(title: "Retry saving") { [weak self] _ in self?.persist() }) }
            if session.metadata?.guest == false && session.metadata?.canEdit == true {
                actions.append(UIAction(title: presentingPosition ? "Stop presenting" : "Present", state: presentingPosition ? .on : .off) { [weak self] _ in self?.togglePresentation() })
                for guest in [false, true] { actions.append(UIAction(title: guest ? "Share guest link" : "Share member link") { [weak self] _ in self?.share(guest: guest) }) }
                if let read = session.metadata?.paper.isRead { actions.append(UIAction(title: read ? "Mark unread" : "Mark read") { [weak self] _ in guard let self else { return }; self.actionTask = Task { do { try await self.api.markRead(paperID: self.paperID, read: !read); await self.session.refresh() } catch { self.showError(error) } } }) }
            }
            let presenters = currentPresenters.isEmpty ? (session.metadata?.presenters ?? []) : currentPresenters
            for person in presenters { actions.append(UIAction(title: "Follow \(person.nickname)") { [weak self] _ in self?.followID = person.id }) }
            if followID != nil { actions.append(UIAction(title: "Stop following") { [weak self] _ in self?.followID = nil }) }
            items.append(menuButton("ellipsis.circle", "More", "reader.more", UIMenu(children: actions)))
        }
        toolbar.setControls(items)
    }
    private func requestClose() {
        persist()
        guard !overlays.values.contains(where: { $0.failedWrite }) else { return }
        navigationController?.popViewController(animated: true)
    }
    private func navigatePage(_ delta: Int) {
        guard let document = pdfView.document, let page = document.page(at: min(document.pageCount - 1, max(0, position().page - 1 + delta))) else { return }
        followID = nil; pdfView.go(to: page)
    }
    private func jumpToPage() {
        guard let document = pdfView.document else { return }
        let alert = UIAlertController(title: "Go to page", message: nil, preferredStyle: .alert)
        alert.addTextField { field in field.keyboardType = .numberPad; field.text = String(self.position().page); field.accessibilityLabel = "Page number" }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Go", style: .default) { [weak self] _ in
            guard let self, let text = alert.textFields?.first?.text, let number = Int(text), let page = document.page(at: number - 1) else { return }
            followID = nil; pdfView.go(to: page)
        })
        present(alert, animated: true)
    }
    func resizeInk(_ step: Int) {
        guard !contact else { return }
        inkWidths.resize(step, tool: tool); updateTools(); buildToolbar()
    }
    func setTool(_ value: ReaderTool) {
        // Explicit choices cancel any temporary override without interrupting a live stroke.
        queuedQuickErase = false; eraseReturnTool = nil
        if overlays.values.contains(where: { $0.active }) { pendingManualTool = value; return }
        pendingManualTool = nil; applyTool(value)
    }
    private func applyTool(_ value: ReaderTool) {
        tool = value
        if value != .select { for (page, overlay) in overlays { render(overlay, page: page) } }
        updateTools(); buildToolbar()
    }
    private func updateTools() {
        for (index, overlay) in overlays {
            let widthScale = (pdfView.document?.page(at: index - 1)).map { geometry(page: $0, overlay: overlay).scale(size: overlay.bounds.size) } ?? 1
            overlay.editingEnabled = session.metadata?.canEdit == true && !overlay.failedWrite
            overlay.readerTool = tool
            overlay.textTap?.isEnabled = tool == .text
            overlay.canvas.isUserInteractionEnabled = session.metadata?.canEdit == true && !overlay.failedWrite && tool != .text
            guard widthScale.isFinite, widthScale > 0 else { continue }
            let key = tool.rawValue + ":" + (colors[tool] ?? "") + ":" + String(Double(thickness)) + ":" + String(Int((widthScale * 1_000_000).rounded()))
            guard overlay.configuredToolKey != key else { continue }; overlay.configuredToolKey = key
            switch tool {
            case .select: overlay.canvas.tool = PKLassoTool()
            case .erase: overlay.canvas.tool = PKEraserTool(.vector)
            default:
                let color = ReaderInk.color(colors[tool] ?? "#007aff")
                overlay.canvas.tool = PKInkingTool(tool == .highlight ? .marker : .monoline, color: color.withAlphaComponent(color.cgColor.alpha * (tool == .highlight ? 0.28 : 1)), width: thickness * widthScale)
            }
        }
    }
    func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveSqueeze squeeze: UIPencilInteraction.Squeeze) {
        guard squeeze.phase == .ended else { return }
        requestQuickErase(duringContact: overlays.values.contains(where: { $0.active }))
    }
    func requestQuickErase(duringContact: Bool) {
        if let selected = pendingManualTool {
            eraseReturnTool = selected; pendingManualTool = nil
        } else if eraseReturnTool == nil { eraseReturnTool = tool }
        if duringContact { queuedQuickErase = true }
        else { applyTool(.erase) }
    }
    func finishToolContact() {
        if let selected = pendingManualTool {
            pendingManualTool = nil; applyTool(selected); return
        }
        if queuedQuickErase { queuedQuickErase = false; applyTool(.erase) }
        else if let previous = eraseReturnTool, tool == .erase {
            eraseReturnTool = nil; applyTool(previous)
        }
    }
    func pdfView(_ view: PDFView, overlayViewFor page: PDFPage) -> UIView? {
        guard let document = view.document else { return nil }
        let index = document.index(for: page) + 1
        if let retained = overlays[index], retained.failedWrite { return retained }
        let overlay = ReaderPageView(frame: CGRect(origin: .zero, size: ReaderGeometry(page: page).displaySize))
        overlay.canvas.frame = overlay.bounds; overlay.textLayer.frame = overlay.bounds
        overlay.accessibilityIdentifier = "reader.page.\(index)"
        overlay.canvas.accessibilityIdentifier = "reader.ink.\(index)"
        overlay.canvas.delegate = self
        let eraser = ReaderEraseRecognizer()
        eraser.cancelsTouchesInView = false; eraser.delaysTouchesBegan = false; eraser.delaysTouchesEnded = false
        eraser.begin = { [weak self, weak overlay] point in
            guard let self, let overlay, overlay.beginErase(at: point) else { return false }
            followID = nil; return true
        }
        eraser.move = { [weak overlay] point in overlay?.sweepErase(to: point) }
        eraser.end = { [weak self, weak overlay] in
            // PencilKit must finish changing its drawing before the shared batch is captured.
            DispatchQueue.main.async { [weak self, weak overlay] in
                guard let self, let overlay else { return }
                finishErase(overlay, page: index)
            }
        }
        overlay.addGestureRecognizer(eraser)
        overlay.onLayout = { [weak self, weak overlay] in
            guard let self, let overlay, !overlay.active, !overlay.applying, tool != .select else { return }
            render(overlay, page: index); updateTools()
        }
        let tap = UITapGestureRecognizer(target: self, action: #selector(textTapped(_:))); tap.cancelsTouchesInView = false
        tap.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue), NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)]
        overlay.textTap = tap
        overlay.addGestureRecognizer(tap)
        overlays[index] = overlay; render(overlay, page: index); updateTools(); return overlay
    }
    func pdfView(_ pdfView: PDFView, willEndDisplayingOverlayView overlayView: UIView, for page: PDFPage) {
        guard let document = pdfView.document else { return }
        let index = document.index(for: page) + 1
        if let overlay = overlayView as? ReaderPageView, overlay.failedWrite { return }
        if overlays[index] === overlayView { overlays.removeValue(forKey: index) }
    }
    private func geometry(page: PDFPage, overlay: ReaderPageView) -> ReaderGeometry {
        ReaderGeometry(page: page, pdfView: pdfView, overlay: overlay)
    }
    func pdfView(_ view: PDFView, willDisplayOverlayView overlayView: UIView, for page: PDFPage) {
        guard let overlay = overlayView as? ReaderPageView, let document = view.document else { return }
        let index = document.index(for: page) + 1
        Task { [weak self, weak overlay] in
            guard let self, let overlay, !overlay.active else { return }; render(overlay, page: index); updateTools()
        }
    }
    private func render(_ overlay: ReaderPageView, page index: Int) {
        guard !overlay.failedWrite else { return }
        guard let page = pdfView.document?.page(at: index - 1), overlay.bounds.width > 0 else { return }
        let geometry = geometry(page: page, overlay: overlay)
        let pageValues = session.annotations.filter { $0.page == index }
        pageValues.forEach(captureBase)
        let values = pageValues.filter { $0.type != .text }
        overlay.applying = true
        let pairs = values.compactMap { value -> (PaperAnnotation, PKStroke)? in
            guard let stroke = ReaderInk.stroke(value, geometry: geometry, size: overlay.bounds.size, native: session.nativeStroke(for: value)) else { return nil }
            return (value, stroke)
        }
        if pairs.count != values.count { readerError = "Some ink cannot be restored; original data retained." }
        overlay.values = pairs.map { $0.0 }
        overlay.canvas.drawing = PKDrawing(strokes: pairs.map { $0.1 })
        overlay.baseline = overlay.canvas.drawing.strokes.map(ReaderInk.archive)
        for (value, stroke) in zip(overlay.values, overlay.canvas.drawing.strokes) where nativeHistory[nativeKey(value)] == nil {
            nativeHistory[nativeKey(value)] = session.nativeStroke(for: value) ?? ReaderInk.nativeArchive(stroke, geometry: geometry, size: overlay.bounds.size)
        }
        overlay.applying = false
        overlay.textLayer.subviews.forEach { $0.removeFromSuperview() }
        overlay.textValues = [:]
        for value in session.annotations where value.page == index && value.type == .text {
            let label = UILabel(); label.numberOfLines = 0; label.text = value.text; label.textColor = ReaderInk.color(value.color)
            label.font = .systemFont(ofSize: CGFloat(value.size ?? 16) * geometry.scale(size: overlay.bounds.size)); label.sizeToFit()
            let origin = geometry.canvas(.zero, size: overlay.bounds.size)
            let right = geometry.canvas(CGPoint(x: 1, y: 0), size: overlay.bounds.size)
            label.layer.anchorPoint = .zero
            label.transform = CGAffineTransform(rotationAngle: atan2(right.y - origin.y, right.x - origin.x))
            label.layer.position = geometry.canvas(CGPoint(x: value.x ?? 0, y: value.y ?? 0), size: overlay.bounds.size)
            label.accessibilityIdentifier = value.id
            overlay.textValues[value.id] = value
            overlay.textLayer.addSubview(label)
        }
    }
    func canvasViewDidBeginUsingTool(_ canvasView: PKCanvasView) {
        overlays.values.first { $0.canvas === canvasView }?.active = true; followID = nil
    }
    func canvasViewDidEndUsingTool(_ canvasView: PKCanvasView) {
        guard let (index, overlay) = overlays.first(where: { $0.value.canvas === canvasView }) else { return }
        guard !overlay.eraseContact else { return }
        commit(overlay, page: index); overlay.active = false
        finishToolContact()
    }
    func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
        // Lasso transformations can complete outside the tool-contact callback.
        guard let (index, overlay) = overlays.first(where: { $0.value.canvas === canvasView }) else { return }
        overlay.noteDrawingChange()
        guard !overlay.applying, !overlay.active else { return }
        commit(overlay, page: index)
    }
    func finishErase(_ overlay: ReaderPageView, page index: Int) {
        guard overlay.eraseContact else { return }
        commit(overlay, page: index)
        overlay.endErase(); overlay.active = false
        finishToolContact()
        if !overlay.failedWrite { render(overlay, page: index) }
    }
    private func commit(_ overlay: ReaderPageView, page index: Int) {
        guard !overlay.applying, let page = pdfView.document?.page(at: index - 1) else { return }
        let strokes = overlay.canvas.drawing.strokes
        let archives = strokes.map(ReaderInk.archive)
        guard archives != overlay.baseline || !overlay.erasedText.isEmpty else { return }
        let geometry = geometry(page: page, overlay: overlay)
        overlay.applying = true
        defer { overlay.applying = false }
        var used = Set<Int>(); var capturedValues: [PaperAnnotation] = []; var changes: [Change] = []; var native: [(PaperAnnotation, Data)] = []
        let matches = ReaderInk.matchingIndices(before: overlay.baseline, after: archives)
        for (i, stroke) in strokes.enumerated() {
            let matched = matches[i]
            let exact = matched.flatMap { overlay.baseline[$0] == archives[i] ? $0 : nil }
            if let matched { used.insert(matched) }
            let before = matched.map { overlay.values[$0] }
            var value = exact != nil ? before! : ReaderInk.annotation(stroke, previous: before, page: index, tool: tool, color: colors[tool] ?? "#007aff", geometry: geometry, size: overlay.bounds.size)
            if before == nil && [.pen, .question, .highlight].contains(tool) { value.size = Double(thickness) }
            capturedValues.append(value)
            if exact == nil { changes.append(Change(before: before, after: value, id: value.id)); native.append((value, ReaderInk.nativeArchive(stroke, geometry: geometry, size: overlay.bounds.size))) }
        }
        for i in overlay.values.indices where !used.contains(i) { let value = overlay.values[i]; changes.append(Change(before: value, after: nil, id: value.id)) }
        changes += overlay.erasedText.values.sorted { $0.id < $1.id }.map { Change(before: $0, after: nil, id: $0.id) }
        saveChanges(changes, native: native, values: capturedValues, overlay: overlay, page: index)
    }
    private func saveChanges(_ changes: [Change], native: [(PaperAnnotation, Data)], values capturedValues: [PaperAnnotation], overlay: ReaderPageView, page index: Int) {
        overlay.applying = true
        defer { overlay.applying = false }
        do {
            let captured = Dictionary(uniqueKeysWithValues: native.map { ($0.0.id, $0.1) })
            let history = changes.map { change in
                Change(before: change.before, after: change.after, id: change.id,
                       nativeBefore: change.before.flatMap { nativeHistory[nativeKey($0)] },
                       nativeAfter: captured[change.id] ?? change.after.flatMap { nativeHistory[nativeKey($0)] })
            }
            try session.edit(changes.map { AnnotationEdit(id: $0.id, original: original(for: $0.before), value: $0.after, native: captured[$0.id]) })
            for (value, data) in native { nativeHistory[nativeKey(value)] = data }
            readerError = nil; overlay.failedWrite = false; overlay.retryWrite = nil
            overlay.erasedText = [:]
            if !changes.isEmpty { undoStack.append(history); redoStack = [] }
            overlay.values = capturedValues
            overlay.baseline = overlay.canvas.drawing.strokes.map(ReaderInk.archive)
            capturedValues.forEach(captureBase)
            updateTools(); buildToolbar()
        } catch {
            overlay.failedWrite = true; overlay.editingEnabled = false; overlay.canvas.isUserInteractionEnabled = false
            overlay.retryWrite = { [weak self, weak overlay] in
                guard let self, let overlay else { return }; saveChanges(changes, native: native, values: capturedValues, overlay: overlay, page: index)
            }
            showError(error)
        }
    }
    private func applyHistory(_ changes: [Change], reverse: Bool) -> Bool {
        guard !overlays.values.contains(where: { $0.failedWrite }) else { return false }
        do {
            let edits = changes.map { change -> AnnotationEdit in
                let value = reverse ? change.before : change.after
                return AnnotationEdit(id: change.id, original: original(for: reverse ? change.after : change.before), value: value,
                                      native: reverse ? change.nativeBefore : change.nativeAfter)
            }
            try session.edit(edits)
            for edit in edits { if let value = edit.value, let native = edit.native { nativeHistory[nativeKey(value)] = native } }
            readerError = nil; changed(); return true
        } catch { showError(error); return false }
    }
    func undo() { if let changes = undoStack.last, applyHistory(changes, reverse: true) { undoStack.removeLast(); redoStack.append(changes); if tool == .select { setTool(.pen) }; buildToolbar() } }
    func redo() { if let changes = redoStack.last, applyHistory(changes, reverse: false) { redoStack.removeLast(); undoStack.append(changes); if tool == .select { setTool(.pen) }; buildToolbar() } }
    private func inspectionTolerance(_ overlay: ReaderPageView) -> CGFloat {
        // Keep the extra hit slop at five screen points, independent of PDF zoom.
        let a = overlay.convert(CGPoint.zero, to: pdfView)
        let b = overlay.convert(CGPoint(x: 1, y: 0), to: pdfView)
        return 5 / max(0.001, hypot(b.x - a.x, b.y - a.y))
    }
    private func creatorMessage(id: String) -> String {
        guard let metadata = session.metadata else { return "Unknown" }
        return metadata.creatorDescription(for: id)
    }
    private func dismissCreator() {
        creatorAlert?.dismiss(animated: false)
        creatorAlert = nil; creatorContext = nil
    }
    private func refreshCreator() {
        guard let alert = creatorAlert, let context = creatorContext,
              alert.presentingViewController != nil else {
            creatorAlert = nil; creatorContext = nil; return
        }
        guard let metadata = session.metadata, metadata.selfID == context.principal,
              session.annotations.contains(where: { $0.id == context.id }) else {
            dismissCreator(); return
        }
        alert.message = creatorMessage(id: context.id)
    }
    func showCreator(id: String) {
        guard session.metadata != nil, presentedViewController == nil else { return }
        let alert = UIAlertController(title: "Creator", message: creatorMessage(id: id), preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .cancel) { [weak self] _ in
            self?.creatorAlert = nil; self?.creatorContext = nil
        })
        creatorContext = (id, session.metadata?.selfID)
        creatorAlert = alert
        present(alert, animated: true)
    }
    @objc private func textTapped(_ tap: UITapGestureRecognizer) {
        guard tool == .text, session.metadata?.canEdit == true, let overlay = tap.view as? ReaderPageView, let index = overlays.first(where: { $0.value === overlay })?.key, let page = pdfView.document?.page(at: index - 1) else { return }
        followID = nil
        let position = geometry(page: page, overlay: overlay).normalized(tap.location(in: overlay), size: overlay.bounds.size)
        let hit = overlay.annotationID(at: tap.location(in: overlay), tolerance: inspectionTolerance(overlay))
        let existing = hit.flatMap { id in session.annotations.first { $0.id == id && $0.type == .text } }
        if let hit, existing == nil { showCreator(id: hit); return }
        let capturedOriginal = original(for: existing)
        let alert = UIAlertController(title: "Text", message: existing.map { "Creator: " + creatorMessage(id: $0.id) }, preferredStyle: .alert)
        alert.addTextField {
            $0.text = existing?.text; $0.placeholder = "Annotation"
            $0.autocorrectionType = .no; $0.spellCheckingType = .no
            $0.autocapitalizationType = .none; $0.inlinePredictionType = .no
            $0.textContentType = nil
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Save", style: .default) { [weak self] _ in
            guard let self else { return }
            let text = alert.textFields?.first?.text ?? ""
            let value = PaperAnnotation(id: existing?.id ?? UUID().uuidString, page: index, type: .text, color: existing?.color ?? colors[.text]!, x: existing?.x ?? Double(position.x), y: existing?.y ?? Double(position.y), text: text, size: existing?.size ?? 16)
            do { try session.edit([AnnotationEdit(id: value.id, original: capturedOriginal, value: text.isEmpty ? nil : value)]); undoStack.append([Change(before: existing, after: text.isEmpty ? nil : value, id: value.id)]); redoStack = []; buildToolbar() } catch { showError(error) }
        })
        present(alert, animated: true)
    }
    func saveViewport() {
        guard let key = viewportKey, session.metadata != nil, pdfView.document != nil, !applyingPosition, followID == nil,
              key == ReaderViewport.key(owner: session.api.storageIdentity, paperID: paperID) else { return }
        ReaderViewport(position: position(), horizontal: horizontalPosition()).save(key: key, in: preferences)
    }
    private func restoreViewport() {
        guard let document = pdfView.document, session.metadata != nil else { return }
        let key = ReaderViewport.key(owner: session.api.storageIdentity, paperID: paperID)
        // Bind only after fresh authorization. A follow link owns the opening viewport.
        if followID == nil, let viewport = ReaderViewport.saved(key: key, in: preferences), viewport.position.page <= document.pageCount {
            seek(viewport.position, horizontal: viewport.horizontal)
        }
        viewportKey = key
    }
    private func horizontalPosition() -> Double {
        guard let page = pdfView.page(for: CGPoint(x: pdfView.bounds.midX, y: pdfView.bounds.minY), nearest: true) else { return 0 }
        let rect = pdfView.convert(ReaderGeometry(page: page).box, from: page)
        return Double(min(1, max(0, (pdfView.bounds.minX - rect.minX) / max(0.01, rect.width))))
    }
    private func position() -> ReadingPosition {
        guard let page = pdfView.page(for: CGPoint(x: pdfView.bounds.midX, y: pdfView.bounds.minY), nearest: true), let document = pdfView.document else { return ReadingPosition(page: 1, scroll: 0, zoom: 1) }
        let rect = pdfView.convert(ReaderGeometry(page: page).box, from: page)
        return ReadingPosition(page: document.index(for: page) + 1, scroll: Double(min(1, max(0, (pdfView.bounds.minY - rect.minY) / max(0.01, rect.height)))), zoom: Double(min(3, max(0.5, pdfView.scaleFactor / max(0.01, pdfView.scaleFactorForSizeToFit)))))
    }
    private func updatePresence() async {
        guard visible, session.metadata != nil, UIApplication.shared.applicationState == .active, !Task.isCancelled else { return }
        do {
            let people: [Presenter]
            if session.metadata?.canEdit == true { people = try await publishPresence(presenting: presentingPosition && session.metadata?.guest == false, position: position()).presenters }
            else { people = try await api.presenters(paperID: paperID) }
            guard visible, UIApplication.shared.applicationState == .active, !Task.isCancelled else { return }
            currentPresenters = people; buildToolbar()
            guard !contact, let person = people.first(where: { $0.id == followID }) else { return }
            seek(ReadingPosition(page: person.page, scroll: person.scroll, zoom: person.zoom))
        } catch { toolbar.accessibilityValue = error.localizedDescription }
    }
    private func share(guest: Bool) {
        actionTask?.cancel()
        actionTask = Task { do {
            guard visible, UIApplication.shared.applicationState == .active, session.metadata?.guest == false, session.metadata?.canEdit == true else { return }
            presentingPosition = true
            _ = try await publishPresence(presenting: true, position: position())
            try Task.checkCancellation()
            let url = try await api.share(paperID: paperID, guest: guest)
            try Task.checkCancellation(); shareItems([url])
        } catch { showError(error) } }
    }
    private func shareItems(_ items: [Any], cleanupURL: URL? = nil) {
        guard visible, presentedViewController == nil else { if let cleanupURL { try? FileManager.default.removeItem(at: cleanupURL) }; return }
        let sheet = UIActivityViewController(activityItems: items, applicationActivities: nil)
        sheet.completionWithItemsHandler = { _, _, _, _ in if let cleanupURL { try? FileManager.default.removeItem(at: cleanupURL) } }
        sheet.popoverPresentationController?.sourceView = toolbar
        present(sheet, animated: true)
    }
    private func exportPDF() {
        guard let document = pdfView.document else { return }
        let data: Data
        do { data = try ReaderExport.export(document: document, annotations: session.annotations, native: { self.session.nativeStroke(for: $0) }) }
        catch { showError(error); return }
        var url = FileManager.default.temporaryDirectory.appendingPathComponent("Paper-\(UUID().uuidString).pdf")
        do {
            try data.write(to: url, options: [.atomic, .completeFileProtection])
            var resources = URLResourceValues(); resources.isExcludedFromBackup = true; try url.setResourceValues(resources)
            shareItems([url], cleanupURL: url)
        } catch { try? FileManager.default.removeItem(at: url); showError(error) }
    }
    private func showError(_ error: Error) {
        readerError = error.localizedDescription; buildToolbar()
        guard visible, UIApplication.shared.applicationState == .active, presentedViewController == nil else { status.isHidden = false; status.text = error.localizedDescription; return }
        let alert = UIAlertController(title: "Paper not saved", message: error.localizedDescription, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default)); present(alert, animated: true)
    }
}
