import AppKit

/// The color of a profile's square on the rail and of its avatar in menus:
/// one picked from the square's context menu, else one from its place among
/// the profiles that took none, passing over those picked, so no two share
/// one until there are more than eight.
enum ProfileColor: String, CaseIterable, Sendable {
    case red, orange, yellow, green, teal, blue, purple, pink

    var title: String { rawValue.capitalized }

    var color: NSColor {
        switch self {
        case .red: .systemRed
        case .orange: .systemOrange
        case .yellow: .systemYellow
        case .green: .systemGreen
        case .teal: .systemTeal
        case .blue: .systemBlue
        case .purple: .systemPurple
        case .pink: .systemPink
        }
    }

    /// The order profiles without a color of their own take them in.
    private static let rotation: [ProfileColor] = [.blue, .orange, .green, .purple, .pink, .teal, .yellow, .red]

    /// Each profile's color, by id.
    static func of(_ profiles: [Profile]) -> [String: ProfileColor] {
        let picked = profiles.compactMap { $0.color.flatMap(ProfileColor.init) }
        var free = rotation.filter { !picked.contains($0) }
        if free.isEmpty { free = rotation }
        var automatic = 0
        let pairs = profiles.map { profile in
            if let color = profile.color.flatMap(ProfileColor.init) { return (profile.id, color) }
            defer { automatic += 1 }
            return (profile.id, free[automatic % free.count])
        }
        return Dictionary(pairs) { first, _ in first }
    }

    /// Initials on a square of this color: lighter on a dark ground and
    /// deeper on a light one, where yellow alone wouldn't read.
    var ink: NSColor {
        let base = color
        return NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            var ink = base
            appearance.performAsCurrentDrawingAppearance {
                let resolved = base.usingColorSpace(.sRGB) ?? base
                ink = resolved.blended(withFraction: dark ? 0.25 : 0.42, of: dark ? .white : .black) ?? resolved
            }
            return ink
        }
    }
}

/// A profile's avatar for menus and the toolbar: its initials on its color,
/// white, or dark on a color as light as yellow.
@MainActor
enum ProfileAvatar {
    static func image(initials: String, color: ProfileColor, size: CGFloat = 16) -> NSImage {
        let emoji = ProfileAvatar.isEmoji(initials)
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            let radius = size * 0.3
            let fill = color.color.usingColorSpace(.sRGB) ?? color.color
            fill.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            let luminance = 0.299 * fill.redComponent + 0.587 * fill.greenComponent + 0.114 * fill.blueComponent
            let ink = luminance > 0.7 ? NSColor.black.withAlphaComponent(0.75) : .white
            let scale: CGFloat = emoji ? (initials.count > 1 ? 0.36 : 0.62) : initials.count > 1 ? 0.46 : 0.56
            let font = NSFont.systemFont(ofSize: size * scale, weight: .bold).rounded
            let text = NSAttributedString(string: initials, attributes: [.font: font, .foregroundColor: ink])
            let textSize = text.size()
            text.draw(at: NSPoint(x: rect.midX - textSize.width / 2, y: rect.midY - textSize.height / 2))
            return true
        }
        image.accessibilityDescription = initials
        return image
    }

    /// Avatars for every profile, by id, their initials told apart as the
    /// rail tells them apart.
    static func images(for profiles: [Profile], size: CGFloat = 16) -> [String: NSImage] {
        let labels = labels(for: profiles)
        let colors = ProfileColor.of(profiles)
        var images: [String: NSImage] = [:]
        for profile in profiles {
            images[profile.id] = image(initials: labels[profile.id] ?? "?", color: colors[profile.id] ?? .blue, size: size)
        }
        return images
    }

    /// Whether a label has an emoji, which draws in its own colors and wants
    /// a size of its own.
    nonisolated static func isEmoji(_ label: String) -> Bool {
        label.unicodeScalars.contains { $0.properties.isEmojiPresentation || $0.value == 0xFE0F }
    }

    /// What each profile's square and avatar show, by id: its own label, else
    /// its initials, told apart from every profile's, open or not, so a
    /// profile shows the same two letters on the rail and in menus.
    static func labels(for profiles: [Profile]) -> [String: String] {
        let initials = ProfileRailView.initials(for: profiles.map(\.name))
        let pairs = profiles.enumerated().map { index, profile in (profile.id, profile.label ?? initials[index]) }
        return Dictionary(pairs) { first, _ in first }
    }
}

extension Theme {
    /// The rail's ground: a shade off the chrome, as an activity bar is.
    nonisolated static let railGround = NSColor(name: nil) { appearance in
        let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        var ground = NSColor.windowBackgroundColor
        appearance.performAsCurrentDrawingAppearance {
            let chrome = Theme.chrome.usingColorSpace(.sRGB) ?? ground
            ground = chrome.blended(withFraction: dark ? 0.2 : 0.045, of: .black) ?? chrome
        }
        return ground
    }
}

/// The rail at the left of the window with Profile Tabs: a square for each
/// open profile, tinted in its color with its initials or label, the shown
/// one ringed and marked by a pill in its color along the rail's edge, which
/// grows a little under the mouse too. A dot in a square's corner pulses
/// while its agent works out of sight, and stays once it has finished until
/// the profile shows. After the squares, a plus button opens another
/// profile. Drag a square to reorder them, or drop a link on one to open it
/// in that profile; with more than fit, the rail scrolls.
@MainActor
final class ProfileRailView: NSView {
    struct Item: Equatable {
        let id: String
        let name: String
        /// Its own label, or its initials.
        let label: String
        let color: ProfileColor
        let shown: Bool
        let busy: Bool
        /// Its agent finished while it was out of sight, and it hasn't
        /// shown since.
        let finished: Bool
    }

    static let width: CGFloat = 52
    static let squareSize: CGFloat = 34
    /// A square's row, which takes the mouse across the rail's width.
    fileprivate static let pitch: CGFloat = 42
    private static let top: CGFloat = 6
    /// Between the last square and the separator, and the separator and
    /// the plus button.
    private static let gap: CGFloat = 4

    var onSelect: ((String) -> Void)?
    var onMove: ((String, Int) -> Void)?
    var menuFor: ((String) -> NSMenu?)?
    var addMenu: (() -> NSMenu)?
    /// A link dropped on a profile's square.
    var onDropURL: ((String, URL) -> Void)?
    /// The second line of a profile's tip, asked for as it shows: its tabs
    /// and the page in front.
    var detailFor: ((String) -> String?)?

    var items: [Item] = [] {
        didSet {
            guard items != oldValue else { return }
            rebuild(revealShown: items.firstIndex(where: \.shown) != oldValue.firstIndex(where: \.shown))
        }
    }

    private let scrollView = NSScrollView()
    private let content = RailContentView()
    private let edge = FillView(Theme.hairline)
    private let separator = FillView(Theme.hairline)
    private let addButton = RailAddButton()
    private var rows: [ProfileSquareView] = []
    /// The row being dragged, and how far the mouse is from its top.
    private var dragging: (row: ProfileSquareView, offset: CGFloat)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.verticalScrollElasticity = .none
        scrollView.horizontalScrollElasticity = .none
        scrollView.documentView = content
        addSubview(scrollView)
        addSubview(edge)
        content.addSubview(separator)
        addButton.onClick = { [weak self] in self?.showAddMenu() }
        content.addSubview(addButton)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Profiles")
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = Theme.railGround.cgColor
    }

    override func viewDidHide() {
        super.viewDidHide()
        RailTip.shared.hide()
    }

    private func rebuild(revealShown: Bool) {
        while rows.count > items.count { rows.removeLast().removeFromSuperview() }
        while rows.count < items.count {
            let row = ProfileSquareView()
            row.rail = self
            content.addSubview(row, positioned: .below, relativeTo: separator)
            rows.append(row)
        }
        for (index, item) in items.enumerated() {
            rows[index].shortcut = index < 9 ? "⌃⌘\(index + 1)" : nil
            rows[index].item = item
        }
        needsLayout = true
        if revealShown, let index = items.firstIndex(where: \.shown) {
            layoutSubtreeIfNeeded()
            content.scrollToVisible(frame(at: index))
        }
    }

    private func frame(at index: Int) -> NSRect {
        NSRect(x: 0, y: Self.top + CGFloat(index) * Self.pitch, width: Self.width, height: Self.pitch)
    }

    override func layout() {
        super.layout()
        scrollView.frame = bounds
        edge.frame = NSRect(x: bounds.maxX - Theme.hairlineWidth, y: 0, width: Theme.hairlineWidth, height: bounds.height)
        let separatorY = frame(at: rows.count).minY + Self.gap
        let addFrame = NSRect(x: 0, y: separatorY + 1 + Self.gap, width: Self.width, height: Self.pitch)
        let height = max(addFrame.maxY + Self.top, scrollView.contentSize.height)
        content.frame = NSRect(x: 0, y: 0, width: Self.width, height: height)
        for (index, row) in rows.enumerated() where row !== dragging?.row {
            row.frame = frame(at: index)
        }
        separator.frame = NSRect(x: ((Self.width - 20) / 2).rounded(), y: separatorY, width: 20, height: 1)
        addButton.frame = addFrame
    }

    private func showAddMenu() {
        guard let menu = addMenu?() else { return }
        RailTip.shared.hide()
        let square = addButton.squareFrame
        menu.popUp(positioning: nil, at: NSPoint(x: square.maxX + 6, y: square.maxY), in: addButton)
    }

    // MARK: Dragging

    fileprivate func beginDrag(_ row: ProfileSquareView, at point: NSPoint) {
        dragging = (row, point.y - row.frame.minY)
        RailTip.shared.hide()
        // Over the others while it moves.
        content.addSubview(row, positioned: .above, relativeTo: nil)
    }

    fileprivate func drag(to point: NSPoint) {
        guard let (row, offset) = dragging else { return }
        let maxY = frame(at: rows.count - 1).minY
        row.frame.origin.y = min(max(point.y - offset, Self.top), maxY)
        // The others make room where it would land.
        let target = index(for: row)
        var others = rows.filter { $0 !== row }
        others.insert(row, at: target)
        withEasing(Theme.Duration.quick) {
            for (index, other) in others.enumerated() where other !== row {
                other.animator().frame = frame(at: index)
            }
        }
    }

    fileprivate func endDrag() {
        guard let (row, _) = dragging else { return }
        dragging = nil
        let target = index(for: row)
        let from = rows.firstIndex { $0 === row } ?? target
        // Back under the separator and the plus button.
        content.addSubview(row, positioned: .below, relativeTo: separator)
        if target != from {
            rows.insert(rows.remove(at: from), at: target)
            items.insert(items.remove(at: from), at: target)
            onMove?(row.item?.id ?? "", target)
        }
        withEasing(Theme.Duration.quick) { row.animator().frame = frame(at: target) }
        needsLayout = true
    }

    private func index(for row: ProfileSquareView) -> Int {
        let index = Int(((row.frame.minY - Self.top) / Self.pitch).rounded())
        return min(max(index, 0), rows.count - 1)
    }

    fileprivate func select(_ row: ProfileSquareView) {
        guard let id = row.item?.id else { return }
        onSelect?(id)
    }

    fileprivate func drop(_ url: URL, on row: ProfileSquareView) {
        guard let id = row.item?.id else { return }
        onDropURL?(id, url)
    }

    fileprivate func detail(for row: ProfileSquareView) -> String? {
        row.item.flatMap { detailFor?($0.id) }
    }

    fileprivate func menu(for row: ProfileSquareView) -> NSMenu? {
        RailTip.shared.hide()
        return row.item.flatMap { menuFor?($0.id) }
    }

    fileprivate func convertFromWindow(_ point: NSPoint) -> NSPoint {
        content.convert(point, from: nil)
    }

    /// Scrolls the rail as a drag nears its top or bottom.
    fileprivate func scrollAlong(with event: NSEvent) {
        content.autoscroll(with: event)
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

/// What the rail scrolls: its rows, the separator and the plus button.
@MainActor
private final class RailContentView: NSView {
    override var isFlipped: Bool { true }
}

/// A flat color that takes no clicks: a hairline, or the separator.
@MainActor
private final class FillView: NSView {
    private let color: NSColor

    init(_ color: NSColor) {
        self.color = color
        super.init(frame: .zero)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = color.cgColor
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// One profile's row on the rail: its square, the pill on the rail's edge
/// beside it, and the agent's dot in the square's corner. The whole row
/// takes the mouse, and a link dragged over it.
@MainActor
private final class ProfileSquareView: NSView {
    weak var rail: ProfileRailView?
    /// The keys that show it, for its tip.
    var shortcut: String?
    var item: ProfileRailView.Item? {
        didSet {
            guard item != oldValue else { return }
            if let item {
                var label = item.name
                if item.busy { label += " (agent working)" } else if item.finished { label += " (agent finished)" }
                setAccessibilityLabel(label)
                setAccessibilitySelected(item.shown)
            }
            if hovered, let item { RailTip.shared.update(for: self, tip: tip(for: item)) }
            updateLook(animated: oldValue?.id == item?.id)
        }
    }

    private let pill = CALayer()
    private let tile = CALayer()
    private let text = CATextLayer()
    private let badge = CALayer()
    private static let font = NSFont.systemFont(ofSize: 12.5, weight: .semibold).rounded

    private var hovered = false {
        didSet { if hovered != oldValue { updateLook(animated: true) } }
    }
    private var pressed = false {
        didSet { if pressed != oldValue { updateLook(animated: true) } }
    }
    /// Where a press began, until it moves far enough to be a drag.
    private var pressPoint: NSPoint?
    private var isDragging = false {
        didSet { if isDragging != oldValue { updateLook(animated: true) } }
    }
    /// A link is dragged over it, which a drop opens in its profile.
    private var isDropTarget = false {
        didSet { if isDropTarget != oldValue { updateLook(animated: true) } }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
        tile.cornerRadius = 9
        tile.cornerCurve = .continuous
        tile.shadowOffset = CGSize(width: 0, height: -2)
        tile.shadowRadius = 6
        tile.shadowColor = NSColor.black.cgColor
        text.font = Self.font
        text.fontSize = Self.font.pointSize
        text.alignmentMode = .center
        text.truncationMode = .none
        tile.addSublayer(text)
        pill.cornerRadius = 2.5
        badge.borderWidth = 2
        for sublayer in [pill, tile, badge] { layer?.addSublayer(sublayer) }
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        registerForDraggedTypes([.URL])
    }

    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }

    /// Colors resolve here for the window's appearance and accent; a change
    /// of either marks every view for display.
    override func updateLayer() {
        updateLook(animated: false)
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        text.contentsScale = window?.backingScaleFactor ?? 2
    }

    override func layout() {
        super.layout()
        let size = ProfileRailView.squareSize
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // Centered in what the hairline on the rail's edge leaves.
        tile.bounds = CGRect(x: 0, y: 0, width: size, height: size)
        tile.position = CGPoint(x: ((bounds.width - Theme.hairlineWidth) / 2).rounded(), y: bounds.midY)
        layoutText()
        let dot: CGFloat = 11
        badge.bounds = CGRect(x: 0, y: 0, width: dot, height: dot)
        badge.cornerRadius = dot / 2
        badge.position = CGPoint(x: tile.position.x + size / 2 - 2, y: bounds.midY + size / 2 - 2)
        CATransaction.commit()
        updateLook(animated: false)
    }

    /// The text's line, centered in the square for its size.
    private func layoutText() {
        let size = ProfileRailView.squareSize
        let font = Self.font.withSize(text.fontSize)
        let lineHeight = ceil(font.ascender - font.descender)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        text.frame = CGRect(x: 0, y: ((size - lineHeight) / 2).rounded(), width: size, height: lineHeight)
        text.contentsScale = window?.backingScaleFactor ?? 2
        CATransaction.commit()
    }

    /// Eases the square, the pill and the dot to the row's state.
    private func updateLook(animated: Bool) {
        guard let item else { return }
        let color = item.color.color
        let shown = item.shown
        CATransaction.begin()
        CATransaction.setAnimationDuration(Theme.Duration.slide)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        CATransaction.setDisableActions(!animated || Theme.reduceMotion)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let hot = hovered || isDropTarget
            let fill: CGFloat = shown || isDropTarget ? 0.3 : pressed || hovered ? 0.22 : 0.14
            tile.backgroundColor = color.withAlphaComponent(fill).cgColor
            tile.borderColor = color.withAlphaComponent(Theme.increaseContrast ? 1 : 0.75).cgColor
            tile.borderWidth = isDropTarget ? 2 : shown ? 1.25 : 0
            let ink = item.color.ink
            text.foregroundColor = (shown || hot ? ink : ink.blended(withFraction: 0.3, of: .secondaryLabelColor) ?? ink).cgColor
            if text.string as? String != item.label {
                // Emoji draw in their own colors, and at a size that fills
                // the square as two letters do.
                text.string = item.label
                let emoji = ProfileAvatar.isEmoji(item.label)
                text.fontSize = emoji ? (item.label.count > 1 ? 13 : 17) : Self.font.pointSize
                layoutText()
            }

            // Along the rail's edge: the shown profile's in its color, and
            // a stub under the mouse.
            let pillHeight: CGFloat = shown ? 20 : hot && !isDragging ? 8 : 0
            pill.bounds = CGRect(x: 0, y: 0, width: 5, height: pillHeight)
            pill.position = CGPoint(x: 0.5, y: bounds.midY)
            pill.backgroundColor = (shown ? item.color.ink : Theme.secondaryText).cgColor
            pill.opacity = pillHeight > 0 ? 1 : 0

            badge.backgroundColor = Theme.accentColor.cgColor
            badge.borderColor = Theme.railGround.cgColor
            badge.opacity = item.busy || item.finished ? 1 : 0
        }
        let scale: CGFloat = isDragging || isDropTarget ? 1.08 : pressed ? 0.92 : 1
        tile.transform = CATransform3DMakeScale(scale, scale, 1)
        tile.shadowOpacity = isDragging ? 0.3 : 0
        CATransaction.commit()
        pulse(item.busy && !Theme.reduceMotion)
    }

    /// The busy dot's slow breathing.
    private func pulse(_ on: Bool) {
        let key = "pulse"
        guard on != (badge.animation(forKey: key) != nil) else { return }
        guard on else { return badge.removeAnimation(forKey: key) }
        let animation = CABasicAnimation(keyPath: "transform.scale")
        animation.fromValue = 1
        animation.toValue = 0.7
        animation.duration = 0.8
        animation.autoreverses = true
        animation.repeatCount = .infinity
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        badge.add(animation, forKey: key)
    }

    // An animation stops when its layer leaves the window.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        badge.removeAnimation(forKey: "pulse")
        if let item { pulse(item.busy && !Theme.reduceMotion) }
    }

    private func tip(for item: ProfileRailView.Item) -> RailTip.Content {
        let note = item.busy ? "Agent working" : item.finished ? "Agent finished" : nil
        return RailTip.Content(title: item.name, keys: shortcut, detail: rail?.detail(for: self), note: note)
    }

    // MARK: Dropping a link

    /// The web or file address a drag carries, if any.
    private func link(in info: NSDraggingInfo) -> URL? {
        let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self]) as? [URL]
        return urls?.first { ["http", "https", "file"].contains($0.scheme?.lowercased() ?? "") }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard link(in: sender) != nil else { return [] }
        isDropTarget = true
        RailTip.shared.hide()
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        isDropTarget ? .copy : []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        isDropTarget = false
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        isDropTarget = false
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        isDropTarget = false
        guard let url = link(in: sender) else { return false }
        rail?.drop(url, on: self)
        return true
    }

    // MARK: Mouse

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        hovered = true
        if let item, pressPoint == nil { RailTip.shared.show(for: self, tip: tip(for: item)) }
    }

    override func mouseExited(with event: NSEvent) {
        hovered = false
        RailTip.shared.hide(from: self)
    }

    override func viewDidHide() {
        super.viewDidHide()
        hovered = false
        pressed = false
    }

    override func mouseDown(with event: NSEvent) {
        pressed = true
        pressPoint = event.locationInWindow
        isDragging = false
        RailTip.shared.hide()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let rail, let start = pressPoint else { return }
        if !isDragging {
            guard hypot(event.locationInWindow.x - start.x, event.locationInWindow.y - start.y) > 4 else { return }
            isDragging = true
            pressed = false
            rail.beginDrag(self, at: rail.convertFromWindow(start))
        }
        rail.scrollAlong(with: event)
        rail.drag(to: rail.convertFromWindow(event.locationInWindow))
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

/// The plus button after the squares: a dashed square that fills with the
/// accent under the mouse.
@MainActor
private final class RailAddButton: NSView {
    var onClick: (() -> Void)?

    private let square = CAShapeLayer()
    private let plus = NSImageView()
    private var hovered = false {
        didSet { if hovered != oldValue { updateLook(animated: true) } }
    }
    private var pressed = false {
        didSet { if pressed != oldValue { updateLook(animated: true) } }
    }

    var squareFrame: NSRect {
        let size = ProfileRailView.squareSize
        let x = ((bounds.width - Theme.hairlineWidth) / 2).rounded() - size / 2
        return NSRect(x: x, y: ((bounds.height - size) / 2).rounded(), width: size, height: size)
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        square.lineWidth = 1
        square.lineDashPattern = [3, 2.5]
        layer?.addSublayer(square)
        plus.image = Theme.symbol("plus", size: Theme.Symbol.bar, weight: .medium, label: "Open Profile")
        plus.imageScaling = .scaleNone
        addSubview(plus)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Open Profile")
    }

    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        updateLook(animated: false)
    }

    override func layout() {
        super.layout()
        let frame = squareFrame
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        square.frame = frame
        let path = CGPath(
            roundedRect: CGRect(origin: .zero, size: frame.size).insetBy(dx: 0.5, dy: 0.5),
            cornerWidth: 9, cornerHeight: 9, transform: nil
        )
        square.path = path
        CATransaction.commit()
        plus.frame = frame
        updateLook(animated: false)
    }

    private func updateLook(animated: Bool) {
        let hot = hovered || pressed
        CATransaction.begin()
        CATransaction.setAnimationDuration(Theme.Duration.quick)
        CATransaction.setDisableActions(!animated || Theme.reduceMotion)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            square.fillColor = hot ? Theme.accentColor.withAlphaComponent(pressed ? 0.22 : 0.14).cgColor : NSColor.clear.cgColor
            square.strokeColor = (hot ? Theme.accentColor : Theme.tertiaryText).cgColor
        }
        CATransaction.commit()
        plus.contentTintColor = hot ? Theme.accentColor : Theme.secondaryText
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        hovered = true
        RailTip.shared.show(for: self, tip: RailTip.Content(title: "Open Profile", keys: nil, detail: nil, note: nil))
    }

    override func mouseExited(with event: NSEvent) {
        hovered = false
        RailTip.shared.hide(from: self)
    }

    override func mouseDown(with event: NSEvent) {
        pressed = true
        RailTip.shared.hide()
    }

    override func mouseUp(with event: NSEvent) {
        pressed = false
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }

    override func accessibilityPerformPress() -> Bool {
        onClick?()
        return true
    }
}

/// The tip beside a square of the rail: the profile's name, the keys that
/// show it, its tabs and the page in front, and what its agent is doing. It comes after a moment under the
/// mouse, then at once while moving along the rail.
@MainActor
private final class RailTip {
    struct Content: Equatable {
        let title: String
        let keys: String?
        /// Under the title: the profile's tabs and the page in front.
        let detail: String?
        let note: String?
    }

    static let shared = RailTip()

    private let panel: NSPanel
    private let plate = TipPlateView()
    private let title = NSTextField(labelWithString: "")
    private let keys = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private let note = NSTextField(labelWithString: "")
    private let dot = FillView(Theme.accentColor)
    private let noteRow: NSStackView
    private weak var anchor: NSView?
    private var timer: Timer?
    /// When the tip last went away, so the next square's comes at once.
    private var hiddenAt = Date.distantPast

    private init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 30),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        title.font = .systemFont(ofSize: Theme.FontSize.secondary + 0.5, weight: .semibold)
        title.textColor = Theme.text
        title.lineBreakMode = .byTruncatingTail
        keys.font = .systemFont(ofSize: Theme.FontSize.secondary)
        keys.textColor = Theme.tertiaryText
        detail.font = .systemFont(ofSize: Theme.FontSize.caption + 0.5)
        detail.textColor = Theme.secondaryText
        detail.lineBreakMode = .byTruncatingTail
        note.font = .systemFont(ofSize: Theme.FontSize.caption + 0.5)
        note.textColor = Theme.secondaryText
        dot.layer?.cornerRadius = 3
        dot.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([dot.widthAnchor.constraint(equalToConstant: 6), dot.heightAnchor.constraint(equalToConstant: 6)])
        let titleRow = NSStackView(views: [title, keys])
        titleRow.spacing = 10
        titleRow.alignment = .firstBaseline
        noteRow = NSStackView(views: [dot, note])
        noteRow.spacing = 6
        noteRow.alignment = .centerY
        let stack = NSStackView(views: [titleRow, detail, noteRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 3
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 7, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        plate.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: plate.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: plate.trailingAnchor),
            stack.topAnchor.constraint(equalTo: plate.topAnchor),
            stack.bottomAnchor.constraint(equalTo: plate.bottomAnchor),
            title.widthAnchor.constraint(lessThanOrEqualToConstant: 240),
            detail.widthAnchor.constraint(lessThanOrEqualToConstant: 280),
        ])
        for label in [title, keys, note] {
            label.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        title.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        detail.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        panel.contentView = plate
        // The squares hear no exit while Tiller is in the background.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { RailTip.shared.hide() }
        }
    }

    /// Shows the tip of `view`, after a moment unless a tip was up just now.
    func show(for view: NSView, tip: Content) {
        timer?.invalidate()
        anchor = view
        let quick = panel.isVisible || Date().timeIntervalSince(hiddenAt) < 0.3
        if quick { return present(tip) }
        timer = Timer.scheduledTimer(withTimeInterval: 0.45, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.present(tip) }
        }
    }

    /// The tip of `view` changed while it is up.
    func update(for view: NSView, tip: Content) {
        guard anchor === view, panel.isVisible else { return }
        present(tip)
    }

    /// Hides the tip if it is `view`'s.
    func hide(from view: NSView) {
        guard anchor === view else { return }
        hide()
    }

    func hide() {
        timer?.invalidate()
        timer = nil
        anchor = nil
        guard panel.isVisible else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        hiddenAt = Date()
    }

    private func present(_ tip: Content) {
        guard NSApp.isActive, let anchor, let window = anchor.window, window.isVisible, !anchor.isHiddenOrHasHiddenAncestor
        else { return }
        title.stringValue = tip.title
        keys.stringValue = tip.keys ?? ""
        keys.isHidden = tip.keys == nil
        detail.stringValue = tip.detail ?? ""
        detail.isHidden = tip.detail == nil
        note.stringValue = tip.note ?? ""
        noteRow.isHidden = tip.note == nil
        panel.appearance = window.effectiveAppearance
        plate.layoutSubtreeIfNeeded()
        let fitting = plate.fittingSize
        let size = NSSize(width: ceil(fitting.width), height: ceil(fitting.height))
        // Right of the rail, level with the square.
        let rect = window.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        let origin = NSPoint(x: rect.minX + ProfileRailView.width + 4, y: (rect.midY - size.height / 2).rounded())
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        if panel.parent !== window {
            panel.parent?.removeChildWindow(panel)
            window.addChildWindow(panel, ordered: .above)
        }
        panel.orderFront(nil)
    }
}

/// The tip's rounded plate, on the face fields have, with a hairline round it.
@MainActor
private final class TipPlateView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = Theme.Radius.row
        layer?.cornerCurve = .continuous
        layer?.borderWidth = Theme.hairlineWidth
    }

    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = Theme.surface.cgColor
        layer?.borderColor = Theme.hairline.cgColor
    }
}
