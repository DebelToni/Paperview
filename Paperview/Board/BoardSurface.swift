import UIKit
import PencilKit

enum BoardTool: String, CaseIterable { case select, hand, rectangle, arrow, pen, text, erase }

struct BoardViewport: Codable, Equatable {
    var x: Double = 0
    var y: Double = 0
    var zoom: Double = 1
    func screen(_ point: BoardPoint) -> CGPoint { CGPoint(x: point.x * zoom + x, y: point.y * zoom + y) }
    func world(_ point: CGPoint) -> BoardPoint { BoardPoint(x: (point.x - x) / zoom, y: (point.y - y) / zoom) }
}

@MainActor final class BoardSurface: UIView, PKCanvasViewDelegate, UIGestureRecognizerDelegate, UITextViewDelegate {
    let engine: BoardEngine
    let renderer = BoardRenderer()
    var tool: BoardTool = .select { didSet { if tool != oldValue { cancelGesture(); updateInput() } } }
    var strokeColor = "#202124" { didSet { updateInput() } }
    var fillColor = "transparent"
    var strokeWidth: Double = 2 { didSet { updateInput() } }
    private(set) var selection: [String] = []
    private(set) var viewport = BoardViewport()
    private(set) var isUsingTool = false
    var editable = true { didSet { if editable != oldValue { renderer.invalidateNativeInk(); if !editable { cancelGesture() }; updateInput() } } }
    var papers: [PaperInfo] = []
    var nativeStroke: ((BoardElement) -> Data?)? { didSet { renderer.nativeStroke = nativeStroke } }
    var onCommand: ((BoardCommand, [String: Data]) -> Bool)?
    private struct RetainedInk {
        var command: BoardCommand?
        var archives: [String: Data]
        var drawing: PKDrawing
        var data: Data
        var recoveryID: String
    }
    private var retainedInk: RetainedInk?
    var onUnconvertedInk: ((Data, String) -> Bool)?
    var hasRetainedInk: Bool { retainedInk != nil }
    func retainedInkData() -> Data? { retainedInk?.data }
    func acknowledgeRetainedInk() {
        retainedInk = nil; retainedViewport = nil; ignoringInk = true; ink.drawing = PKDrawing(); ignoringInk = false
        updateInput(); reload()
    }
    func retryRetainedInk() {
        guard let retainedInk else { return }
        if let command = retainedInk.command {
            if onCommand?(command, retainedInk.archives) == true { acknowledgeRetainedInk() }
        } else { _ = onUnconvertedInk?(retainedInk.data, retainedInk.recoveryID) }
    }
    var onSelection: (([String]) -> Void)?
    var onOpen: ((BoardElement?) -> Void)?
    var onViewport: ((BoardViewport) -> Void)?
    var onError: ((Error) -> Void)?
    var onToolContactEnded: (() -> Void)?
    var visuals: (any BoardVisualProvider)? { get { renderer.visuals } set { renderer.visuals = newValue; setNeedsDisplay() } }

    private let ink = BoardContactCanvas()
    private var items: [BoardRenderItem] = []
    private var contentGeneration: UInt64?
    private var itemGeneration: UInt64?
    private var queryRect: CGRect?
    private var queryZoom: Double = 1
    private var elements: [String: BoardElement] = [:]
    private var elementOrder: [String: Int] = [:]
    private var groups: [String: [String]] = [:]
    private var nextZ: Double = 1
    private var selectedIDs = Set<String>()
    private var selectionBounds: BoardRect?
    private var retainedViewport: BoardViewport?
    // Deterministic work counters for large synthetic-board regressions.
    private(set) var documentIndexCount = 0
    private(set) var viewportQueryCount = 0
    private(set) var selectionBoundsCount = 0
    private var start: BoardPoint?
    private var current: BoardPoint?
    private var originalBounds: BoardRect?
    private var resize = false
    private var endpoint: Int?
    private var endpointElement: BoardElement?
    private var contactViewport = BoardViewport()
    private var contactColor = "#202124"
    private var contactWidth: Double = 2
    private var layoutSize = CGSize.zero
    private var ignoringInk = false
    private var editor: UITextView?
    var isEditingText: Bool { editor != nil }
    private var editingElement: BoardElement?
    private var editingOriginal: BoardElement?
    var editingTextElement: BoardElement? {
        guard var element = editingElement else { return nil }
        element.text = editor?.text ?? element.text
        return element
    }
    @discardableResult func updateTextAppearance(_ change: (inout BoardElement) -> Void) -> Bool {
        guard var element = editingTextElement, let editor else { return false }
        change(&element); editingElement = element
        let font = BoardRenderer.font(element)
        editor.font = font.withSize(font.pointSize * viewport.zoom)
        editor.textColor = BoardRenderer.color(element.stroke)
        return true
    }
    private var pan: UIPanGestureRecognizer!
    private var pinch: UIPinchGestureRecognizer!
    private var pointerPan: UIPanGestureRecognizer!
    private var openGesture: UITapGestureRecognizer!
    private var selectionRect: CGRect?
    private var erasedIDs = Set<String>()
    private var activeTouch: UITouch?
    private var navigating = false

    init(engine: BoardEngine) {
        self.engine = engine
        super.init(frame: .zero)
        backgroundColor = .white; isMultipleTouchEnabled = true; clipsToBounds = true
        isAccessibilityElement = true; accessibilityLabel = "Drawing canvas"; accessibilityTraits.insert(.allowsDirectInteraction)
        ink.backgroundColor = .clear; ink.isOpaque = false; ink.drawingPolicy = .pencilOnly
        ink.isScrollEnabled = false; ink.delegate = self
        ink.panGestureRecognizer.isEnabled = false; ink.pinchGestureRecognizer?.isEnabled = false
        ink.contactBegan = { [weak self] in self?.beginInkContact() }
        ink.contactCancelled = { [weak self] in self?.cancelGesture() }
        addSubview(ink)
        pan = UIPanGestureRecognizer(target: self, action: #selector(panned(_:)))
        pan.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        pan.minimumNumberOfTouches = 2; pan.maximumNumberOfTouches = 2
        pan.delegate = self; addGestureRecognizer(pan)
        pointerPan = UIPanGestureRecognizer(target: self, action: #selector(scrolled(_:)))
        pointerPan.allowedTouchTypes = []; pointerPan.allowedScrollTypesMask = .all
        pointerPan.delegate = self; addGestureRecognizer(pointerPan)
        pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinched(_:)))
        pinch.delegate = self; addGestureRecognizer(pinch)
        openGesture = UITapGestureRecognizer(target: self, action: #selector(opened(_:)))
        openGesture.numberOfTapsRequired = 2
        openGesture.allowedTouchTypes = [UITouch.TouchType.direct, .indirectPointer].map { NSNumber(value: $0.rawValue) }
        openGesture.delegate = self; addGestureRecognizer(openGesture)
        renderer.onChange = { [weak self] in self?.invalidateVisuals() }
        renderer.onError = { [weak self] in self?.onError?($0) }
        updateInput(); reload()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layoutSubviews() { super.layoutSubviews(); if bounds.size != layoutSize { reload() } }

    private func beginInkContact() {
        guard editable, tool == .pen, !hasRetainedInk, !isUsingTool else { return }
        contactViewport = viewport; contactColor = strokeColor; contactWidth = strokeWidth; isUsingTool = true
    }
    private func updateInput() {
        guard !isUsingTool else { return }
        ink.isUserInteractionEnabled = editable && !hasRetainedInk && tool == .pen
        // Pencil-only children still receive finger hit tests. Their ancestor owns navigation.
        pan.minimumNumberOfTouches = tool == .pen || tool == .hand || !editable || hasRetainedInk ? 1 : 2
        ink.tool = PKInkingTool(.monoline, color: BoardRenderer.color(strokeColor), width: strokeWidth * viewport.zoom)
    }
    func invalidateVisuals() { setNeedsDisplay() }

    private func indexDocument() throws {
        guard contentGeneration != engine.contentGeneration else { return }
        elements.removeAll(keepingCapacity: true); elementOrder.removeAll(keepingCapacity: true); groups.removeAll(keepingCapacity: true)
        nextZ = 1
        for (index, e) in engine.board.elements.enumerated() {
            elements[e.id] = e; elementOrder[e.id] = index; nextZ = max(nextZ, e.z + 1)
            if !e.deleted, let group = e.groupId { groups[group, default: []].append(e.id) }
        }
        contentGeneration = engine.contentGeneration; documentIndexCount += 1
        renderer.updateAssets(engine.board.assets); renderer.invalidateNativeInk()
        let live = selection.filter { elements[$0]?.deleted == false }
        if live != selection { selection = live; selectedIDs = Set(live); onSelection?(selection) }
        try updateSelectionBounds()
    }
    private func updateSelectionBounds() throws {
        guard !selection.isEmpty else { selectionBounds = nil; return }
        selectionBoundsCount += 1; selectionBounds = try engine.bounds(selection)
    }

    /// UIKit coalesces invalidations. Only a painted frame crosses the Rust query/JSON boundary.
    func prepareFrame() {
        guard !isUsingTool || navigating else { return }
        do {
            try indexDocument()
            let a = viewport.world(.zero)
            let visible = CGRect(x: a.x, y: a.y, width: bounds.width / viewport.zoom, height: bounds.height / viewport.zoom)
            if itemGeneration != contentGeneration || queryRect?.contains(visible) != true ||
                viewport.zoom / queryZoom < 0.8 || viewport.zoom / queryZoom > 1.25 {
                // Retain a bounded near-viewport query while panning. Resource
                // providers still see only items intersecting the actual clip.
                let padded = visible.insetBy(dx: -128 / viewport.zoom, dy: -128 / viewport.zoom)
                // Prefetch must obey the same scalar limits as a visible-only query.
                // Clipping its padding never changes document coordinates.
                let limit: CGFloat = 10_000_000
                let x = max(-limit, min(limit, padded.minX)), y = max(-limit, min(limit, padded.minY))
                let region = CGRect(x: x, y: y, width: max(0, min(limit, padded.maxX - x)), height: max(0, min(limit, padded.maxY - y)))
                items = try engine.query(BoardRect(x: region.minX, y: region.minY, width: region.width, height: region.height))
                itemGeneration = contentGeneration; queryRect = region; queryZoom = viewport.zoom; viewportQueryCount += 1
            }
            if let retainedInk, retainedViewport != viewport {
                ignoringInk = true; ink.drawing = BoardInk.screenDrawing(retainedInk.drawing, viewport: viewport); ignoringInk = false
                retainedViewport = viewport
            }
        } catch { onError?(error) }
    }
    func reload() {
        // The controller defers replacement during contact; also keep our transient view intact.
        guard !isUsingTool else { return }
        if layoutSize.width > 0, layoutSize.height > 0, bounds.size != layoutSize {
            viewport.x += (bounds.width-layoutSize.width)/2; viewport.y += (bounds.height-layoutSize.height)/2
            onViewport?(viewport)
        }
        layoutSize = bounds.size; ink.frame = bounds
        do { try indexDocument(); setNeedsDisplay(); updateAccessibilityViewport() } catch { onError?(error) }
    }
    func select(_ ids: [String]) {
        do {
            try indexDocument()
            var selected = Set(ids.filter { elements[$0]?.deleted == false })
            for id in ids { if let group = elements[id]?.groupId { selected.formUnion(groups[group] ?? []) } }
            let values = selected.sorted { elementOrder[$0, default: 0] < elementOrder[$1, default: 0] }
            if values != selection { selection = values; selectedIDs = selected; try updateSelectionBounds(); onSelection?(selection) }
            setNeedsDisplay()
        } catch { onError?(error) }
    }
    func fit() {
        do {
            guard let rect = try engine.bounds(), bounds.width > 0, bounds.height > 0 else { return }
            let scale = min((bounds.width - 64) / max(rect.width, 1), (bounds.height - 64) / max(rect.height, 1))
            let z = max(0.05, min(8, scale))
            setViewport(BoardViewport(x: bounds.midX - (rect.x + rect.width / 2) * z,
                                      y: bounds.midY - (rect.y + rect.height / 2) * z, zoom: z))
        } catch { onError?(error) }
    }
    func zoom(by factor: Double) { zoom(by: factor, at: CGPoint(x: bounds.midX, y: bounds.midY)) }
    private func zoom(by factor: Double, at point: CGPoint) {
        guard factor.isFinite, factor > 0 else { return }
        let world = viewport.world(point), z = max(0.05, min(8, viewport.zoom * factor))
        setViewport(BoardViewport(x: point.x - world.x * z, y: point.y - world.y * z, zoom: z))
    }
    func setViewport(_ value: BoardViewport) {
        guard !isUsingTool, value.x.isFinite, value.y.isFinite, value.zoom.isFinite, value.zoom > 0 else { return }
        let next = BoardViewport(x: value.x, y: value.y, zoom: max(0.05, min(8, value.zoom)))
        guard next != viewport else { return }
        let zoomChanged = next.zoom != viewport.zoom; viewport = next
        if zoomChanged { updateInput() }
        setNeedsDisplay(); updateAccessibilityViewport(); onViewport?(viewport)
    }
    private func updateAccessibilityViewport() {
        let center = viewport.world(CGPoint(x: bounds.midX, y: bounds.midY))
        accessibilityValue = String(format: "Zoom %.0f%%, center %.1f, %.1f", viewport.zoom * 100, center.x, center.y)
    }
    func cancelGesture() {
        activeTouch = nil; navigating = false
        erasedIDs.removeAll()
        start = nil; current = nil; originalBounds = nil; resize = false; endpoint = nil; endpointElement = nil; selectionRect = nil
        if !hasRetainedInk { ignoringInk = true; ink.drawing = PKDrawing(); ignoringInk = false }
        editor?.delegate = nil; editor?.removeFromSuperview(); editor = nil; editingElement = nil; editingOriginal = nil; isAccessibilityElement = true
        let active = isUsingTool; isUsingTool = false
        if active { onToolContactEnded?() }; updateInput(); reload()
    }
    override func draw(_ rect: CGRect) {
        guard let c = UIGraphicsGetCurrentContext() else { return }
        prepareFrame()
        c.saveGState(); c.translateBy(x: viewport.x, y: viewport.y); c.scaleBy(x: viewport.zoom, y: viewport.zoom)
        var painted = items
        let moving = editable && !navigating && tool == .select && !resize && endpoint == nil && selectionRect == nil && start != nil
        let offset = moving ? CGPoint(x: (current?.x ?? 0) - (start?.x ?? 0), y: (current?.y ?? 0) - (start?.y ?? 0)) : .zero
        if let a = start, let b = current, tool == .rectangle || tool == .arrow {
            let box = Self.rect(a, b)
            var e = BoardElement(kind: tool == .rectangle ? .rectangle : .arrow)
            e.x = box.x; e.y = box.y; e.width = box.width; e.height = box.height
            e.stroke = strokeColor; e.fill = fillColor; e.strokeWidth = strokeWidth
            let draft = BoardRenderItem(element: e, points: tool == .arrow ? [[a.x, a.y], [b.x, b.y]] : nil)
            if tool == .rectangle { painted.insert(draft, at: painted.firstIndex(where: { $0.element.kind != .rectangle }) ?? painted.endIndex) }
            else { painted.append(draft) }
        }
        var hidden = erasedIDs
        if let editingElement, editingElement.kind == .text { hidden.insert(editingElement.id) }
        renderer.draw(painted, board: engine.board, in: c, zoom: viewport.zoom, displayScale: contentScaleFactor,
                      moving: moving ? selectedIDs : [], offset: offset, hidden: hidden)
        if let original = selectionBounds, !selection.isEmpty {
            let box = BoardRect(x: original.x + offset.x, y: original.y + offset.y, width: original.width, height: original.height)
            c.setStrokeColor(UIColor.systemBlue.cgColor); c.setLineWidth(1 / viewport.zoom)
            c.stroke(box.cgRect)
            if editable {
                let handle = CGRect(x: box.x + box.width - 5 / viewport.zoom, y: box.y + box.height - 5 / viewport.zoom, width: 10 / viewport.zoom, height: 10 / viewport.zoom)
                c.setFillColor(UIColor.white.cgColor); c.fill(handle); c.stroke(handle)
            }
            if editable, selection.count == 1, let item = items.first(where: { $0.element.id == selection[0] }),
               ["line", "arrow"].contains(item.element.kind.rawValue), let points = item.points {
                for p in [points.first, points.last].compactMap({ $0 }) where p.count >= 2 {
                    c.strokeEllipse(in: CGRect(x: p[0] + offset.x - 5 / viewport.zoom, y: p[1] + offset.y - 5 / viewport.zoom, width: 10 / viewport.zoom, height: 10 / viewport.zoom))
                }
            }
        }
        if let a = start, let b = current, !navigating, tool != .rectangle, tool != .arrow, (resize || selectionRect != nil) {
            c.setStrokeColor(UIColor.systemBlue.cgColor); c.setLineWidth(1 / viewport.zoom)
            if tool == .arrow { c.move(to: a.cgPoint); c.addLine(to: b.cgPoint); c.strokePath() }
            else if tool == .rectangle || selectionRect != nil || resize { c.stroke(Self.rect(a, b).cgRect) }
            else if let box = originalBounds { c.stroke(CGRect(x: box.x + b.x - a.x, y: box.y + b.y - a.y, width: box.width, height: box.height)) }
        }
        c.restoreGState()
    }
    static func rect(_ a: BoardPoint, _ b: BoardPoint) -> BoardRect {
        BoardRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
    }

    func canvasViewDidBeginUsingTool(_ canvasView: PKCanvasView) { beginInkContact() }
    func canvasViewDidEndUsingTool(_ canvasView: PKCanvasView) {
        guard !ignoringInk, isUsingTool else { return }
        let drawing = BoardInk.worldDrawing(canvasView.drawing, viewport: contactViewport)
        var converted: [BoardElement] = [], archives: [String: Data] = [:]
        var z = nextZ
        var failed = false
        for stroke in drawing.strokes {
            if let e = BoardInk.element(from: stroke, color: contactColor, width: contactWidth, z: z) {
                converted.append(e); archives[e.id] = PKDrawing(strokes: [stroke]).dataRepresentation(); z += 1
            } else { failed = true }
        }
        // A contact is atomic. Never save a partial conversion or clear richer raw ink.
        if !drawing.strokes.isEmpty {
            let data = drawing.dataRepresentation(), recoveryID = UUID().uuidString
            let command: BoardCommand? = failed ? nil : .put(converted)
            retainedInk = RetainedInk(command: command, archives: archives, drawing: drawing, data: data, recoveryID: recoveryID)
            retainedViewport = contactViewport
            if let command {
                if onCommand?(command, archives) == true { acknowledgeRetainedInk() }
            } else {
                _ = onUnconvertedInk?(data, recoveryID)
                onError?(BoardError.invalidDocument("The complete Pencil contact is retained for recovery because it could not be converted."))
            }
        }
        isUsingTool = false; updateInput(); onToolContactEnded?(); reload()
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard activeTouch == nil, !isUsingTool,
              let touch = touches.first(where: { $0.type == .pencil || $0.type == .direct || $0.type == .indirectPointer }) else { return }
        // Pen-mode fingers are handled by the ancestor's one-finger pan recognizer.
        guard tool != .pen, touch.type != .pencil || (editable && !hasRetainedInk) else { return }
        prepareFrame()
        activeTouch = touch
        let point = touch.location(in: self)
        let world = viewport.world(point)
        let handle = editable && nearSelectionHandle(world, radius: touch.type == .direct ? 20 : 12)
        navigating = tool == .hand || hasRetainedInk || (!editable && tool != .select) ||
            (tool == .select && touch.type == .direct && !handle && (try? engine.hit(world, tolerance: 6 / viewport.zoom)) == nil)
        if navigating { start = viewport.world(point); current = start; isUsingTool = true }
        else { begin(at: point) }
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = activeTouch, touches.contains(touch), start != nil else { return }
        let next = viewport.world(touch.location(in: self))
        if navigating, let previous = current {
            viewport.x += (next.x - previous.x) * viewport.zoom
            viewport.y += (next.y - previous.y) * viewport.zoom
            current = viewport.world(touch.location(in: self)); setNeedsDisplay(); updateAccessibilityViewport(); onViewport?(viewport); return
        }
        if tool == .erase { collectErased(from: current ?? next, to: next) }
        current = next; setNeedsDisplay()
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = activeTouch, touches.contains(touch), start != nil else { return }
        activeTouch = nil
        if navigating { navigating = false; start = nil; current = nil; isUsingTool = false; onToolContactEnded?(); reload() }
        else { finish(at: touch.location(in: self)) }
    }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        if let touch = activeTouch, touches.contains(touch) { cancelGesture() }
    }

    func begin(at point: CGPoint) {
        guard !hasRetainedInk, !isUsingTool, editable || tool == .select else { return }
        prepareFrame()
        let p = viewport.world(point); start = p; current = p; isUsingTool = true
        do {
            if tool == .erase { collectErased(from: p, to: p) }
            if tool == .select {
                if let box = selectionBounds, !selection.isEmpty, editable {
                    originalBounds = box
                    let radius = (activeTouch?.type == .direct ? 20.0 : 12.0) / viewport.zoom
                    resize = hypot(p.x - box.x - box.width, p.y - box.y - box.height) < radius
                    if selection.count == 1, let item = items.first(where: { $0.element.id == selection[0] }), ["line", "arrow"].contains(item.element.kind.rawValue), let points = item.points {
                        for (i, v) in [(0, points.first), (1, points.last)] {
                            if let v, v.count >= 2, hypot(p.x - v[0], p.y - v[1]) < radius { endpoint = i; endpointElement = item.element; resize = false }
                        }
                    }
                    if resize || endpoint != nil { return }
                }
                if let id = try engine.hit(p, tolerance: 6 / viewport.zoom) {
                    if !selection.contains(id) { select([id]) }
                    originalBounds = selectionBounds
                } else { select([]); originalBounds = nil; selectionRect = .zero }
            }
        } catch { onError?(error); cancelGesture() }
        setNeedsDisplay()
    }

    func finish(at location: CGPoint) {
        guard let a = start else { return }
        let b = viewport.world(location), rect = Self.rect(a, b)
        defer {
            start = nil; current = nil; originalBounds = nil; selectionRect = nil; resize = false; endpoint = nil; endpointElement = nil
            if editor == nil { isUsingTool = false; onToolContactEnded?(); reload() }
        }
        do {
            switch tool {
            case .select:
                if selectionRect != nil { select(try engine.query(rect).filter { !$0.element.locked }.map { $0.element.id }); return }
                guard editable else { return }
                if var e = endpointElement, let endpoint {
                    guard a.x != b.x || a.y != b.y else { return }
                    guard let resolved = items.first(where: { $0.element.id == e.id })?.points, resolved.count >= 2 else { return }
                    // Flatten resolved geometry before replacing one endpoint, avoiding double rotation.
                    e.angle = 0
                    e.points = resolved.map { [$0[0] - e.x, $0[1] - e.y] }
                    let index = endpoint == 0 ? 0 : resolved.count - 1
                    let toward = resolved[endpoint == 0 ? resolved.count - 1 : 0]
                    let binding = try engine.binding(b, tolerance: 12 / viewport.zoom, toward: BoardPoint(x: toward[0], y: toward[1]), exclude: [e.id])
                    let p = binding?.point ?? [b.x, b.y]
                    e.points?[index] = [p[0] - e.x, p[1] - e.y]
                    if endpoint == 0 { e.startAnchor = binding?.anchor } else { e.endAnchor = binding?.anchor }
                    if let points = e.points, let minX = points.map({ $0[0] }).min(), let minY = points.map({ $0[1] }).min(), let maxX = points.map({ $0[0] }).max(), let maxY = points.map({ $0[1] }).max() {
                        e.x += minX; e.y += minY; e.width = maxX - minX; e.height = maxY - minY
                        e.points = points.map { [$0[0] - minX, $0[1] - minY] }
                    }
                    onCommand?(.put([e]), [:])
                } else if resize, let box = originalBounds {
                    guard a.x != b.x || a.y != b.y else { return }
                    let w = max(1, box.width + b.x - a.x), h = max(1, box.height + b.y - a.y)
                    if selection.count > 1 {
                        let factor = box.width > 0 ? w / box.width : h / max(box.height, 1)
                        onCommand?(.resizeGroup(selection, rect: BoardRect(x: box.x, y: box.y, width: box.width * factor, height: box.height * factor)), [:])
                    } else if let id = selection.first, var e = elements[id] {
                        let width = max(1, e.width + b.x - a.x), height = max(1, e.height + b.y - a.y)
                        if e.kind == .text {
                            e.textWrapWidth = width
                            guard let size = visuals?.measureText(for: e, width: width), size.width.isFinite, size.height.isFinite, size.width >= 0, size.height >= 0 else {
                                onError?(NSError(domain: "BoardLayout", code: 1, userInfo: [NSLocalizedDescriptionKey: "Rich text layout unavailable; resize was not saved."])); return
                            }
                            e.width = ceil(size.width); e.height = ceil(size.height)
                            onCommand?(.put([e]), [:])
                        } else { onCommand?(.resize(id: id, rect: BoardRect(x: e.x, y: e.y, width: width, height: height)), [:]) }
                    }
                } else if !selection.isEmpty, hypot(b.x - a.x, b.y - a.y) > 1 / viewport.zoom { onCommand?(.move(selection, dx: b.x - a.x, dy: b.y - a.y), [:]) }
            case .rectangle, .arrow:
                guard hypot(b.x - a.x, b.y - a.y) > 2 / viewport.zoom else { return }
                var e = BoardElement(kind: tool == .rectangle ? .rectangle : .arrow)
                e.x = rect.x; e.y = rect.y; e.width = rect.width; e.height = rect.height
                e.stroke = strokeColor; e.fill = fillColor; e.strokeWidth = strokeWidth
                e.z = nextZ
                if tool == .arrow {
                    let first = try engine.binding(a, tolerance: 12 / viewport.zoom, toward: b)
                    let last = try engine.binding(b, tolerance: 12 / viewport.zoom, toward: a)
                    let p = first?.point ?? [a.x, a.y], q = last?.point ?? [b.x, b.y]
                    e.points = [[p[0] - e.x, p[1] - e.y], [q[0] - e.x, q[1] - e.y]]
                    e.startAnchor = first?.anchor; e.endAnchor = last?.anchor
                }
                onCommand?(.put([e]), [:])
            case .erase:
                collectErased(from: current ?? a, to: b)
                if !erasedIDs.isEmpty { onCommand?(.delete(erasedIDs.sorted()), [:]) }
                erasedIDs.removeAll()
            case .text:
                var e = BoardElement(kind: .text); e.x = b.x; e.y = b.y; e.stroke = strokeColor
                e.autoFontSize = true; e.fontSize = 24; e.textWrapWidth = 0
                e.z = nextZ
                beginText(e)
            default: break
            }
        } catch { onError?(error) }
    }

    private func collectErased(from a: BoardPoint, to b: BoardPoint) {
        let count = max(1, min(1024, Int(ceil(hypot(b.x - a.x, b.y - a.y) * viewport.zoom / 4))))
        do {
            for i in 0...count {
                let t = Double(i) / Double(count)
                if let id = try engine.hit(BoardPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t), tolerance: 8 / viewport.zoom) { erasedIDs.insert(id) }
            }
        } catch { onError?(error) }
    }

    private func beginText(_ element: BoardElement) {
        guard editable else { return }
        let text = UITextView(); text.backgroundColor = .white; text.layer.borderColor = UIColor.systemBlue.cgColor; text.layer.borderWidth = 1
        let font = BoardRenderer.font(element)
        text.font = font.withSize(font.pointSize * viewport.zoom)
        text.autocorrectionType = .no; text.spellCheckingType = .no; text.autocapitalizationType = .none; text.inlinePredictionType = .no
        text.smartQuotesType = .no; text.smartDashesType = .no; text.smartInsertDeleteType = .no
        text.accessibilityIdentifier = "board.text-editor"
        text.textColor = BoardRenderer.color(element.stroke); text.text = element.text
        let point = viewport.screen(BoardPoint(x: element.x, y: element.y))
        text.translatesAutoresizingMaskIntoConstraints = false
        let toolbar = UIToolbar(); toolbar.sizeToFit()
        toolbar.items = [UIBarButtonItem(barButtonSystemItem: .cancel, target: self, action: #selector(cancelText)),
                         UIBarButtonItem(systemItem: .flexibleSpace),
                         UIBarButtonItem(barButtonSystemItem: .done, target: self, action: #selector(finishText))]
        text.inputAccessoryView = toolbar
        editingElement = element; editingOriginal = element; editor = text; text.delegate = self
        isUsingTool = true; isAccessibilityElement = false; addSubview(text)
        let top = text.topAnchor.constraint(equalTo: topAnchor, constant: max(8, point.y))
        let left = text.leadingAnchor.constraint(equalTo: leadingAnchor, constant: max(8, point.x))
        let width = text.widthAnchor.constraint(equalToConstant: 400), height = text.heightAnchor.constraint(equalToConstant: 160)
        [top, left, width, height].forEach { $0.priority = .defaultHigh }
        NSLayoutConstraint.activate([top, left, width, height,
            text.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 8),
            text.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            text.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: 8),
            text.bottomAnchor.constraint(lessThanOrEqualTo: keyboardLayoutGuide.topAnchor, constant: -8)])
        text.becomeFirstResponder(); setNeedsDisplay()
    }
    func prepareContextMenu() -> Bool {
        guard !isEditingText, [.select, .hand, .pen].contains(tool) else { return false }
        // UIKit asks for configuration at touch-down, before it knows whether
        // this will be a drag. Only actual menu presentation may cancel contact.
        return !isUsingTool || activeTouch?.type == .direct || activeTouch?.type == .indirectPointer
    }
    @discardableResult func finishEditingText() -> Bool {
        guard let editor else { return true }
        if editor.isFirstResponder { editor.resignFirstResponder() } else { textViewDidEndEditing(editor) }
        return self.editor == nil
    }
    @objc private func finishText() { _ = finishEditingText() }
    @objc private func cancelText() { cancelGesture() }
    func textViewDidEndEditing(_ textView: UITextView) {
        guard var e = editingElement else { return }
        let source = textView.text ?? ""
        guard source.unicodeScalars.count <= 100000 else {
            onError?(BoardError.invalidDocument("Text exceeds 100,000 characters; the editor has retained it.")); textView.becomeFirstResponder(); return
        }
        let isNew = elements[e.id] == nil
        if source != (editingOriginal?.text ?? "") || editingOriginal?.text != nil { e.text = source }
        else { e.text = nil }
        if e != editingOriginal, !(isNew && source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
            if e.kind == .text {
                if e.autoFontSize == true {
                    let words = source.split(whereSeparator: { $0.isWhitespace }).count
                    e.fontSize = words < 100 ? 24 : (words < 1000 ? 18 : 14)
                }
                let cap = e.textWrapWidth ?? e.width
                let layoutWidth = cap > 0 ? cap : 1e7
                guard let size = visuals?.measureText(for: e, width: layoutWidth), size.width.isFinite, size.height.isFinite, size.width >= 0, size.height >= 0 else {
                    onError?(BoardError.invalidDocument("Rich text layout unavailable; text remains in the editor.")); textView.becomeFirstResponder(); return
                }
                e.width = max(12, ceil(size.width)); e.height = ceil(size.height)
            }
            guard onCommand?(.put([e]), [:]) == true else { textView.becomeFirstResponder(); return }
        }
        textView.delegate = nil; textView.removeFromSuperview(); editor = nil; editingElement = nil; editingOriginal = nil
        isUsingTool = false; isAccessibilityElement = true; onToolContactEnded?(); reload()
    }

    @objc private func opened(_ gesture: UITapGestureRecognizer) {
        guard !isUsingTool else { _ = finishEditingText(); return }
        prepareFrame()
        do {
            let point = viewport.world(gesture.location(in: self))
            let id = try engine.hit(point, tolerance: 6 / viewport.zoom)
            var e = id.flatMap { elements[$0] }
            if let group = e?.groupId {
                let texts = (groups[group] ?? []).compactMap { elements[$0] }.filter { !$0.deleted && !$0.locked && $0.kind == .text }.filter { item in
                    let dx = point.x - item.x - item.width / 2, dy = point.y - item.y - item.height / 2
                    let x = dx * cos(item.angle) + dy * sin(item.angle) + item.width / 2
                    let y = -dx * sin(item.angle) + dy * cos(item.angle) + item.height / 2
                    return x >= 0 && y >= 0 && x <= item.width && y <= item.height
                }.sorted { $0.z == $1.z ? $0.id > $1.id : $0.z > $1.z }
                if let text = texts.first { e = text }
            }
            if let e, [.text,.rectangle,.ellipse,.diamond].contains(e.kind), !e.locked, editable { beginText(e) }
            else { onOpen?(e) }
        } catch { onError?(error) }
    }
    @objc private func panned(_ gesture: UIPanGestureRecognizer) {
        guard !isUsingTool else { gesture.setTranslation(.zero, in: self); return }
        let delta = gesture.translation(in: self); gesture.setTranslation(.zero, in: self)
        setViewport(BoardViewport(x: viewport.x + delta.x, y: viewport.y + delta.y, zoom: viewport.zoom))
    }
    @objc private func scrolled(_ gesture: UIPanGestureRecognizer) { panned(gesture) }
    @objc private func pinched(_ gesture: UIPinchGestureRecognizer) {
        guard !isUsingTool else { gesture.scale = 1; return }
        zoom(by: gesture.scale, at: gesture.location(in: self)); gesture.scale = 1
    }
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === openGesture || gestureRecognizer === pan || gestureRecognizer === pointerPan || gestureRecognizer === pinch else {
            // UIKit's context-menu recognizer owns its own eligibility. Blocking
            // every unknown recognizer while a raw finger is down prevents it opening.
            return super.gestureRecognizerShouldBegin(gestureRecognizer)
        }
        if gestureRecognizer === openGesture {
            guard tool == .pen || tool == .select || tool == .hand || !editable else { return false }
            if isUsingTool, activeTouch?.type == .direct || activeTouch?.type == .indirectPointer { cancelGesture() }
            return !isUsingTool
        }
        // Navigation can cancel an unfinished finger draft, never an active Pencil/editor.
        if isUsingTool, activeTouch?.type == .direct,
           gestureRecognizer === pinch || (gestureRecognizer === pan && (pan.numberOfTouches >= 2 || !editable)) {
            cancelGesture()
        }
        return !isUsingTool
    }
    private func nearSelectionHandle(_ point: BoardPoint, radius: Double) -> Bool {
        let tolerance = radius / viewport.zoom
        if let box = selectionBounds, hypot(point.x - box.x - box.width, point.y - box.y - box.height) < tolerance { return true }
        guard selection.count == 1, let item = items.first(where: { $0.element.id == selection[0] }),
              item.element.kind == .line || item.element.kind == .arrow, let points = item.points else { return false }
        return [points.first, points.last].compactMap { $0 }.contains { $0.count >= 2 && hypot(point.x - $0[0], point.y - $0[1]) < tolerance }
    }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        (gestureRecognizer === pan || gestureRecognizer === pointerPan || gestureRecognizer === pinch) && (otherGestureRecognizer === pan || otherGestureRecognizer === pointerPan || otherGestureRecognizer === pinch)
    }
}
