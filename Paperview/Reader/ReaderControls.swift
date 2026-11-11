import UIKit

struct ReaderInkWidths {
    static let pen: [CGFloat] = [0.25, 0.5, 0.75, 1, 1.5, 2, 2.5, 3, 4, 5, 6, 8, 10, 12]
    static let marker: [CGFloat] = [4, 6, 8, 10, 12, 16, 20, 24, 32]
    private var penIndex = 3
    private var markerIndex = 5

    func value(for tool: ReaderTool) -> CGFloat { tool == .highlight ? Self.marker[markerIndex] : Self.pen[penIndex] }
    func canResize(_ step: Int, tool: ReaderTool) -> Bool {
        guard [.pen, .question, .highlight].contains(tool) else { return false }
        let index = tool == .highlight ? markerIndex : penIndex
        return (tool == .highlight ? Self.marker : Self.pen).indices.contains(index + step)
    }
    mutating func resize(_ step: Int, tool: ReaderTool) {
        guard canResize(step, tool: tool) else { return }
        if tool == .highlight { markerIndex += step } else { penIndex += step }
    }
}

enum ReaderToolbarPosition: String, CaseIterable {
    case bottom, top, left, right
    static let preferenceKey = "reader.toolbarPosition"
    var isVertical: Bool { self == .left || self == .right }
    static func saved(in defaults: UserDefaults) -> Self {
        Self(rawValue: defaults.string(forKey: preferenceKey) ?? "") ?? .bottom
    }
}

/// One edge-mounted strip. Compact windows scroll along that edge instead of stacking controls over the PDF.
final class ReaderControlStrip: UIScrollView {
    private let row = UIStackView()
    private var axisConstraints: [NSLayoutConstraint] = []
    init() {
        super.init(frame: .zero)
        backgroundColor = UIColor(white: 0.96, alpha: 1)
        showsHorizontalScrollIndicator = false; showsVerticalScrollIndicator = false
        row.alignment = .center; row.spacing = 0
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: contentLayoutGuide.leadingAnchor, constant: 4),
            row.trailingAnchor.constraint(equalTo: contentLayoutGuide.trailingAnchor, constant: -4),
            row.topAnchor.constraint(equalTo: contentLayoutGuide.topAnchor, constant: 4),
            row.bottomAnchor.constraint(equalTo: contentLayoutGuide.bottomAnchor, constant: -4)
        ])
        setPosition(.bottom)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func setPosition(_ position: ReaderToolbarPosition) {
        NSLayoutConstraint.deactivate(axisConstraints)
        row.axis = position.isVertical ? .vertical : .horizontal
        axisConstraints = position.isVertical ? [
            widthAnchor.constraint(equalToConstant: 52),
            row.widthAnchor.constraint(equalTo: frameLayoutGuide.widthAnchor, constant: -8)
        ] : [
            heightAnchor.constraint(equalToConstant: 52),
            row.heightAnchor.constraint(equalTo: frameLayoutGuide.heightAnchor, constant: -8)
        ]
        NSLayoutConstraint.activate(axisConstraints)
        contentOffset = .zero
    }
    func setControls(_ controls: [UIView]) {
        row.arrangedSubviews.forEach { row.removeArrangedSubview($0); $0.removeFromSuperview() }
        for control in controls { row.addArrangedSubview(control) }
    }
}
