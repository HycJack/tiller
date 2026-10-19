import AppKit

/// The rail at the left of the window with Profile Tabs: a square for each
/// open profile, with its initials, the shown one marked by a pill along the
/// rail's edge and the others by a dot while their agent works, then a plus
/// button that opens another profile. Drag a square to reorder them.
@MainActor
final class ProfileRailView: NSView {
    struct Item: Equatable {
        let id: String
        let name: String
        let initials: String
        let shown: Bool
        let busy: Bool
    }

    static let width: CGFloat = 52
    static let squareSize: CGFloat = 34
    private static let spacing: CGFloat = 8
    private static let top: CGFloat = 8

    var onSelect: ((String) -> Void)?
    var onMove: ((String, Int) -> Void)?
    var menuFor: ((String) -> NSMenu?)?
    var addMenu: (() -> NSMenu)?

    var items: [Item] = [] {
        didSet {
            guard items != oldValue else { return }
            rebuild()
        }
    }

    private var squares: [ProfileSquareView] = []
    private let addButton = NSButton()
    /// Marks the shown profile on the rail's edge, and slides to the next.
    private let pill = RailPillView()
    /// The square being dragged, and how far the mouse is from its top.
    private var dragging: (square: ProfileSquareView, offset: CGFloat)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        addButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "Open Profile")
        addButton.isBordered = false
        addButton.contentTintColor = Theme.secondaryText
        addButton.toolTip = "Open Profile"
        addButton.target = self
        addButton.action = #selector(showAddMenu(_:))
        addSubview(addButton)
        addSubview(pill)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Profiles")
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    private func rebuild() {
        while squares.count > items.count { squares.removeLast().removeFromSuperview() }
        while squares.count < items.count {
            let square = ProfileSquareView()
            square.rail = self
            addSubview(square)
            squares.append(square)
        }
        for (index, item) in items.enumerated() {
            squares[index].item = item
            squares[index].toolTip = index < 9 ? "\(item.name)\n⌃⌘\(index + 1)" : item.name
        }
        needsLayout = true
    }

    private func frame(at index: Int) -> NSRect {
        let size = Self.squareSize
        return NSRect(
            x: ((Self.width - size) / 2).rounded(), y: Self.top + CGFloat(index) * (size + Self.spacing),
            width: size, height: size
        )
    }

    override func layout() {
        super.layout()
        for (index, square) in squares.enumerated() where square !== dragging?.square {
            square.frame = frame(at: index)
        }
        addButton.frame = frame(at: squares.count)
        placePill()
    }

    /// Beside the shown square, sliding there from where it was.
    private func placePill() {
        guard let index = items.firstIndex(where: \.shown) else {
            pill.isHidden = true
            return
        }
        let square = frame(at: index)
        let height: CGFloat = 20
        let target = NSRect(x: 0, y: square.midY - height / 2, width: 3, height: height)
        guard pill.frame != target else { return }
        if pill.isHidden || Theme.reduceMotion {
            pill.frame = target
        } else {
            withEasing(Theme.Duration.slide) { pill.animator().frame = target }
        }
        pill.isHidden = false
    }

    @objc private func showAddMenu(_ sender: NSButton) {
        guard let menu = addMenu?() else { return }
        menu.popUp(positioning: nil, at: NSPoint(x: sender.bounds.maxX, y: sender.bounds.minY), in: sender)
    }

    // MARK: Dragging

    fileprivate func beginDrag(_ square: ProfileSquareView, at point: NSPoint) {
        dragging = (square, point.y - square.frame.minY)
        // Over the others while it moves.
        addSubview(square, positioned: .above, relativeTo: nil)
    }

    fileprivate func drag(to point: NSPoint) {
        guard let (square, offset) = dragging else { return }
        let maxY = frame(at: squares.count - 1).minY
        square.frame.origin.y = min(max(point.y - offset, Self.top), maxY)
        // The others make room where it would land.
        let target = index(for: square)
        var others = squares.filter { $0 !== square }
        others.insert(square, at: target)
        withEasing(Theme.Duration.quick) {
            for (index, other) in others.enumerated() where other !== square {
                other.animator().frame = frame(at: index)
            }
        }
    }

    fileprivate func endDrag() {
        guard let (square, _) = dragging else { return }
        dragging = nil
        let target = index(for: square)
        let from = squares.firstIndex { $0 === square } ?? target
        if target != from {
            squares.insert(squares.remove(at: from), at: target)
            items.insert(items.remove(at: from), at: target)
            onMove?(square.item?.id ?? "", target)
        }
        withEasing(Theme.Duration.quick) { square.animator().frame = frame(at: target) }
        needsLayout = true
    }

    private func index(for square: ProfileSquareView) -> Int {
        let pitch = Self.squareSize + Self.spacing
        let index = Int(((square.frame.minY - Self.top) / pitch).rounded())
        return min(max(index, 0), squares.count - 1)
    }

    fileprivate func select(_ square: ProfileSquareView) {
        guard let id = square.item?.id else { return }
        onSelect?(id)
    }

    fileprivate func menu(for square: ProfileSquareView) -> NSMenu? {
        square.item.flatMap { menuFor?($0.id) }
    }

    // MARK: Initials

    /// Two letters for each name: the first letters of its first two words,
    /// or a one-word name's first two. Names that would share them are told
    /// apart by the first letter that differs: Downloads and Documents show
    /// as "Dw" and "Dc".
    static func initials(for names: [String]) -> [String] {
        let letters = names.map { name in Array(name.filter { !$0.isWhitespace }) }
        let base = names.map(baseInitials)
        return names.indices.map { index in
            let others = names.indices.filter { $0 != index && base[$0] == base[index] }
            guard !others.isEmpty, let first = letters[index].first else { return base[index] }
            let own = letters[index]
            for position in 1..<max(own.count, 1) {
                let letter = own[position]
                let shared = others.contains { other in
                    letters[other].count > position && letters[other][position].lowercased() == letter.lowercased()
                }
                if !shared { return first.uppercased() + letter.lowercased() }
            }
            return base[index]
        }
    }

    private static func baseInitials(_ name: String) -> String {
        let words = name.split { $0.isWhitespace || $0 == "-" || $0 == "_" }
        guard let first = words.first?.first else { return "?" }
        if words.count > 1, let second = words[1].first {
            return first.uppercased() + second.uppercased()
        }
        let rest = words[0].dropFirst()
        return first.uppercased() + (rest.first.map { $0.lowercased() } ?? "")
    }
}

/// The shown profile's mark on the rail's edge.
@MainActor
private final class RailPillView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.cornerRadius = 1.5
        layer?.backgroundColor = Theme.text.layerColor
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// One profile's square on the rail.
@MainActor
private final class ProfileSquareView: NSView {
    weak var rail: ProfileRailView?
    var item: ProfileRailView.Item? {
        didSet {
            label.stringValue = item?.initials ?? ""
            setAccessibilityLabel(item.map { $0.busy ? "\($0.name) (agent working)" : $0.name })
            setAccessibilitySelected(item?.shown ?? false)
            needsDisplay = true
        }
    }

    private let label = NSTextField(labelWithString: "")
    private let badge = CALayer()
    private var hovered = false {
        didSet { needsDisplay = true }
    }
    private var pressed = false {
        didSet { needsDisplay = true }
    }
    /// Where a press began, until it moves far enough to be a drag.
    private var pressPoint: NSPoint?
    private var isDragging = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        // The busy dot sits over the square's corner.
        clipsToBounds = false
        layer?.masksToBounds = false
        label.font = .systemFont(ofSize: Theme.FontSize.body, weight: .semibold)
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -4),
        ])
        layer?.addSublayer(badge)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        guard let layer, let item else { return }
        layer.cornerRadius = Theme.Radius.row
        layer.cornerCurve = .continuous
        let fill: NSColor = item.shown
            ? Theme.accentColor.dynamic(alpha: Theme.Accent.selected)
            : Theme.text.dynamic(alpha: pressed ? Theme.Fill.pressed : hovered ? Theme.Fill.hover : Theme.Fill.rest)
        layer.backgroundColor = fill.layerColor
        layer.borderWidth = item.shown && Theme.increaseContrast ? Theme.hairlineWidth : 0
        layer.borderColor = Theme.accentColor.dynamic(alpha: Theme.Accent.outline).layerColor
        label.textColor = item.shown ? Theme.text : Theme.secondaryText

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let dot = Theme.busyDot + 2
        badge.frame = NSRect(x: bounds.width - dot + 2, y: bounds.height - dot + 2, width: dot, height: dot)
        badge.cornerRadius = dot / 2
        badge.backgroundColor = Theme.accentColor.layerColor
        badge.borderWidth = 1.5
        badge.borderColor = Theme.chrome.layerColor
        badge.isHidden = !item.busy
        CATransaction.commit()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }

    override func mouseDown(with event: NSEvent) {
        pressed = true
        pressPoint = event.locationInWindow
        isDragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let rail, let start = pressPoint else { return }
        let point = rail.convert(event.locationInWindow, from: nil)
        if !isDragging {
            guard hypot(event.locationInWindow.x - start.x, event.locationInWindow.y - start.y) > 4 else { return }
            isDragging = true
            rail.beginDrag(self, at: rail.convert(start, from: nil))
        }
        rail.drag(to: point)
    }

    override func mouseUp(with event: NSEvent) {
        pressed = false
        pressPoint = nil
        if isDragging {
            isDragging = false
            rail?.endDrag()
        } else if bounds.contains(convert(event.locationInWindow, from: nil)) {
            rail?.select(self)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        rail?.menu(for: self)
    }

    override func accessibilityPerformPress() -> Bool {
        rail?.select(self)
        return true
    }
}
