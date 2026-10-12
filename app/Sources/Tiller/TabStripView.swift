import AppKit

@MainActor
protocol TabStripDelegate: AnyObject {
    func tabStrip(_ strip: TabStripView, select tab: Tab)
    func tabStrip(_ strip: TabStripView, close tab: Tab)
    /// The user dragged `tab` to `index`.
    func tabStrip(_ strip: TabStripView, move tab: Tab, to index: Int)
    func tabStripNewTab(_ strip: TabStripView)
    /// The menu for a right-click on `tab`.
    func tabStrip(_ strip: TabStripView, menuFor tab: Tab) -> NSMenu?
}

/// The tabs, as a row in the toolbar or a column in the sidebar. In a row,
/// tabs share the width equally up to a maximum, like Safari's compact tabs.
/// Crowded tabs drop their titles and show only the icon; past that the row
/// scrolls to keep the selected tab in view. In a column, each tab is a row
/// as wide as the sidebar, a New Tab row follows the last one, and the column
/// scrolls. Tabs can be dragged to reorder them.
final class TabStripView: NSView {
    enum Orientation {
        case horizontal
        case vertical
    }

    weak var delegate: TabStripDelegate?
    var orientation = Orientation.horizontal {
        didSet {
            guard orientation != oldValue else { return }
            drag = nil
            scrollOffset = 0
            frozenLength = nil
            userScrolled = false
            newTabRow.isHidden = !isVertical
            layoutItems(animated: false)
        }
    }

    private static let maxTabWidth: CGFloat = 240
    /// Below this, tabs show only their icon.
    private static let titleMinWidth: CGFloat = 104
    private static let minTabWidth: CGFloat = 34
    private static let rowHeight: CGFloat = 34
    private static let animationDuration = Theme.Duration.slide
    private static let edgeFadeLength: CGFloat = 16

    private var items: [TabItemView] = []
    private var selectedItem: TabItemView?
    /// How far the row is scrolled when the tabs don't fit.
    private var scrollOffset: CGFloat = 0
    /// Positions are along the row or column.
    private var drag: (item: TabItemView, start: CGFloat, origin: CGFloat, moved: Bool)?
    /// Follows the last tab of a column.
    private let newTabRow = NewTabRowView()
    /// The tab width held while tabs close under the mouse, so the next
    /// close button stays where the last one was, as in Safari. Let go when
    /// the mouse leaves the row.
    private var frozenLength: CGFloat?
    /// The user scrolled the row, so a layout doesn't scroll it back to the
    /// selected tab until the selection changes.
    private var userScrolled = false
    /// Fades the ends of a row that is scrolled past them.
    private let edgeFade = CAGradientLayer()

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        clipsToBounds = true
        wantsLayer = true
        edgeFade.startPoint = CGPoint(x: 0, y: 0.5)
        edgeFade.endPoint = CGPoint(x: 1, y: 0.5)
        // VoiceOver reads the tabs as one group, with each one's place in it.
        setAccessibilityElement(true)
        setAccessibilityRole(.tabGroup)
        setAccessibilityLabel("Tabs")
        newTabRow.isHidden = true
        newTabRow.onClick = { [weak self] in self.map { $0.delegate?.tabStripNewTab($0) } }
        addSubview(newTabRow)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Rebuilds the row for `tabs`, reusing item views for tabs already shown.
    /// Tabs that move slide to their new place, and new ones fade in.
    func update(tabs: [Tab], selected: Tab?) {
        // The row changed under a drag; the drag's order no longer holds.
        drag = nil
        let lengthBefore = tabLength
        let selectedBefore = selectedItem
        var existing = Dictionary(uniqueKeysWithValues: items.map { (ObjectIdentifier($0.tab), $0) })
        var added: [TabItemView] = []
        items = tabs.map { tab in
            if let item = existing.removeValue(forKey: ObjectIdentifier(tab)) { return item }
            let item = TabItemView(tab: tab)
            item.strip = self
            item.onSelect = { [weak self] in self.map { $0.delegate?.tabStrip($0, select: tab) } }
            item.onClose = { [weak self] in self.map { $0.delegate?.tabStrip($0, close: tab) } }
            addSubview(item)
            added.append(item)
            return item
        }
        existing.values.forEach { $0.removeFromSuperview() }
        selectedItem = items.first { $0.tab === selected }
        if selectedItem !== selectedBefore { userScrolled = false }
        if !added.isEmpty {
            frozenLength = nil
        } else if !existing.isEmpty, !isVertical, isMouseInside {
            frozenLength = frozenLength ?? lengthBefore
        }
        // Selection changes redraw the two tabs concerned on their own; a tab
        // whose title or icon changed came through `refresh(_:)` already.
        for item in items { item.isSelected = item === selectedItem }
        added.forEach { $0.refresh() }
        let animate = window != nil && !items.isEmpty && (added.count < items.count || !existing.isEmpty)
        layoutItems(animated: animate, fadeIn: animate ? added : [])
    }

    func refresh(_ tab: Tab) {
        items.first { $0.tab === tab }?.refresh()
    }

    override func layout() {
        super.layout()
        // A column, or a row the user scrolled, stays where it was put.
        layoutItems(animated: false, reveal: !isVertical && !userScrolled)
    }

    override func scrollWheel(with event: NSEvent) {
        var delta = event.scrollingDeltaY
        if !isVertical {
            guard overflows else { return super.scrollWheel(with: event) }
            // A trackpad swipes sideways; a plain mouse wheel only turns.
            if abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) { delta = event.scrollingDeltaX }
            userScrolled = true
        }
        scrollOffset -= delta * (event.hasPreciseScrollingDeltas ? 1 : 10)
        layoutItems(animated: false, reveal: false)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
    }

    override func mouseExited(with event: NSEvent) {
        guard frozenLength != nil else { return }
        frozenLength = nil
        layoutItems(animated: true, reveal: !userScrolled)
    }

    private var isMouseInside: Bool {
        guard let window else { return false }
        return bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil))
    }

    // MARK: Accessibility

    // In the order shown, which the subviews lose while a tab is dragged.
    override func accessibilityChildren() -> [Any]? {
        isVertical ? items as [NSView] + [newTabRow] : items
    }

    override func accessibilityTabs() -> [Any]? { items }

    // MARK: Layout

    private var isVertical: Bool { orientation == .vertical }
    private var spacing: CGFloat { isVertical ? 2 : 4 }
    /// The room along the row or column.
    private var extent: CGFloat { isVertical ? bounds.height : bounds.width }

    /// A tab's size along the row or column.
    private var tabLength: CGFloat {
        if isVertical { return Self.rowHeight }
        if let frozenLength { return frozenLength }
        let count = CGFloat(max(1, items.count))
        let fit = (bounds.width - spacing * (count - 1)) / count
        return min(Self.maxTabWidth, max(Self.minTabWidth, fit)).rounded(.down)
    }

    /// The tabs, and a column's New Tab row, take more room than there is.
    private var overflows: Bool {
        let slots = CGFloat(items.count + (isVertical ? 1 : 0))
        return slots * (tabLength + spacing) - spacing > extent
    }

    private func slot(_ index: Int, length: CGFloat) -> NSRect {
        let position = CGFloat(index) * (length + spacing) - scrollOffset
        return isVertical
            ? NSRect(x: 0, y: position, width: bounds.width, height: length)
            : NSRect(x: position, y: 0, width: length, height: bounds.height)
    }

    /// `reveal` scrolls the selected tab into view.
    private func layoutItems(animated: Bool, fadeIn: [TabItemView] = [], reveal: Bool = true) {
        guard !items.isEmpty else { return }
        // Under Reduce Motion tabs land in their new places at once.
        let animated = animated && !Theme.reduceMotion
        let length = tabLength
        let extent = extent
        let compact = (isVertical ? bounds.width : length) < Self.titleMinWidth
        let slots = items.count + (isVertical ? 1 : 0)
        let total = CGFloat(slots) * (length + spacing) - spacing
        if total <= extent {
            scrollOffset = 0
        } else {
            if reveal, let selectedItem, let index = items.firstIndex(of: selectedItem) {
                let start = CGFloat(index) * (length + spacing)
                scrollOffset = min(max(scrollOffset, start + length - extent), start)
            }
            scrollOffset = min(max(0, scrollOffset), total - extent)
        }
        updateEdgeFade(overflowing: total > extent, total: total)
        for item in fadeIn {
            item.frame = slot(items.firstIndex(of: item) ?? 0, length: length)
            item.alphaValue = 0
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = animated ? Self.animationDuration : 0
            context.allowsImplicitAnimation = animated
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            for (index, item) in items.enumerated() where item !== drag?.item {
                item.isCompact = compact
                item.closesOnTrailing = isVertical && !compact
                let frame = slot(index, length: length)
                if animated {
                    item.animator().frame = frame
                    item.animator().alphaValue = 1
                } else {
                    item.frame = frame
                    item.alphaValue = 1
                }
            }
            newTabRow.isCompact = compact
            let frame = slot(items.count, length: length)
            if animated {
                newTabRow.animator().frame = frame
            } else {
                newTabRow.frame = frame
            }
        }
    }

    /// Fades a row's leading end when tabs are scrolled past it and its
    /// trailing end when more follow, so clipped tabs show they are there.
    private func updateEdgeFade(overflowing: Bool, total: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        guard !isVertical, overflowing, bounds.width > 0 else {
            layer?.mask = nil
            return
        }
        let fade = min(Self.edgeFadeLength / bounds.width, 0.5)
        let opaque = CGColor(gray: 0, alpha: 1)
        let clear = CGColor(gray: 0, alpha: 0)
        edgeFade.colors = [
            scrollOffset > 0.5 ? clear : opaque, opaque, opaque,
            scrollOffset < total - extent - 0.5 ? clear : opaque,
        ]
        edgeFade.locations = [0, NSNumber(value: Double(fade)), NSNumber(value: Double(1 - fade)), 1]
        edgeFade.frame = bounds
        if layer?.mask !== edgeFade { layer?.mask = edgeFade }
    }

    // MARK: Dragging

    private func position(of event: NSEvent) -> CGFloat {
        let point = convert(event.locationInWindow, from: nil)
        return isVertical ? point.y : point.x
    }

    fileprivate func beginDrag(_ item: TabItemView, with event: NSEvent) {
        drag = (item, position(of: event), isVertical ? item.frame.minY : item.frame.minX, false)
    }

    fileprivate func continueDrag(with event: NSEvent) {
        guard var drag, let from = items.firstIndex(of: drag.item) else { return }
        let delta = position(of: event) - drag.start
        if !drag.moved {
            guard abs(delta) > 4, items.count > 1 else { return }
            drag.moved = true
            // Keep the dragged tab above its neighbours.
            addSubview(drag.item, positioned: .above, relativeTo: nil)
        }
        self.drag = drag
        let length = tabLength
        let last = CGFloat(items.count - 1) * (length + spacing) - scrollOffset
        let position = min(max(-scrollOffset, drag.origin + delta), last)
        if isVertical {
            drag.item.frame.origin.y = position
        } else {
            drag.item.frame.origin.x = position
        }
        let center = position + length / 2 + scrollOffset
        let to = min(items.count - 1, max(0, Int(center / (length + spacing))))
        if to != from {
            items.insert(items.remove(at: from), at: to)
            layoutItems(animated: true, reveal: false)
        }
    }

    fileprivate func endDrag() {
        guard let drag else { return }
        self.drag = nil
        guard drag.moved, let index = items.firstIndex(of: drag.item) else { return }
        layoutItems(animated: true, reveal: false)
        delegate?.tabStrip(self, move: drag.item.tab, to: index)
    }
}

/// One tab: favicon or spinner, title, and a close button that replaces the
/// icon on hover, or sits at the end of a sidebar's tab.
final class TabItemView: NSView {
    let tab: Tab
    fileprivate weak var strip: TabStripView?
    var onSelect: (() -> Void)?
    var onClose: (() -> Void)?
    var isSelected = false {
        didSet {
            guard isSelected != oldValue else { return }
            titleLabel.font = .systemFont(ofSize: Theme.FontSize.secondary, weight: isSelected ? .medium : .regular)
            setAccessibilityValue(isSelected)
            setAccessibilitySelected(isSelected)
            updateAppearance()
        }
    }
    /// Too narrow for a title: the icon sits in the middle.
    var isCompact = false {
        didSet {
            guard isCompact != oldValue else { return }
            titleLabel.isHidden = isCompact
            // Off before on, so the two never hold at once.
            (isCompact ? iconLeading : iconCentered).isActive = false
            (isCompact ? iconCentered : iconLeading).isActive = true
            updateAppearance()
        }
    }

    /// The close button sits at the end, on the selected tab too, and the
    /// icon stays.
    var closesOnTrailing = false {
        didSet {
            guard closesOnTrailing != oldValue else { return }
            // Off before on, so the two never hold at once.
            (closesOnTrailing ? closeOverIcon : closeTrailing).isActive = false
            (closesOnTrailing ? closeTrailing : closeOverIcon).isActive = true
            updateAppearance()
        }
    }

    private let icon = FaviconView()
    private let spinner = NSProgressIndicator()
    private let titleLabel = NSTextField(labelWithString: "")
    private let closeButton = HoverButton()
    private var isHovered = false { didSet { if isHovered != oldValue { updateAppearance() } } }
    private var isPressed = false { didSet { updateAppearance() } }
    private var iconLeading: NSLayoutConstraint!
    private var iconCentered: NSLayoutConstraint!
    private var closeOverIcon: NSLayoutConstraint!
    private var closeTrailing: NSLayoutConstraint!
    private var titleToClose: NSLayoutConstraint!

    private static let globe = NSImage(systemSymbolName: "globe", accessibilityDescription: nil)
    private static let closeImage = Theme.closeImage(size: 9, label: "Close Tab")
    private static let closeSize: CGFloat = 18

    init(tab: Tab) {
        self.tab = tab
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = Theme.Radius.row
        layer?.cornerCurve = .continuous
        // VoiceOver reads a tab as one of a group of radio buttons, as it
        // does the tabs of a tab view.
        setAccessibilityElement(true)
        setAccessibilityRole(.radioButton)
        setAccessibilityValue(false)
        setAccessibilitySelected(false)
        setAccessibilityCustomActions([
            NSAccessibilityCustomAction(name: "Close Tab", target: self, selector: #selector(closeFromAccessibility)),
        ])

        icon.imageScaling = .scaleProportionallyDown
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false

        titleLabel.font = .systemFont(ofSize: Theme.FontSize.secondary)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.cell?.truncatesLastVisibleLine = true
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        closeButton.image = Self.closeImage
        closeButton.isBordered = false
        closeButton.bezelStyle = .accessoryBarAction
        closeButton.contentTintColor = .secondaryLabelColor
        closeButton.target = self
        closeButton.action = #selector(closeClicked)
        closeButton.toolTip = "Close Tab"
        // A round plate under the mouse, as in Safari.
        closeButton.plateRadius = Self.closeSize / 2

        for view in [icon, spinner, titleLabel, closeButton] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        iconLeading = icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10)
        iconCentered = icon.centerXAnchor.constraint(equalTo: centerXAnchor)
        // On hover the close button takes the icon's place, as in Safari.
        closeOverIcon = closeButton.centerXAnchor.constraint(equalTo: icon.centerXAnchor)
        closeTrailing = closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6)
        titleToClose = titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: closeButton.leadingAnchor, constant: -2)
        // Gives way in a compact tab, which has no room after a centered icon.
        let titleLeading = titleLabel.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 7)
        titleLeading.priority = .defaultHigh
        NSLayoutConstraint.activate([
            iconLeading,
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),
            spinner.centerXAnchor.constraint(equalTo: icon.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: icon.centerYAnchor),
            closeOverIcon,
            closeButton.centerYAnchor.constraint(equalTo: icon.centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: Self.closeSize),
            closeButton.heightAnchor.constraint(equalToConstant: Self.closeSize),

            titleLeading,
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        refresh()
    }

    required init?(coder: NSCoder) { fatalError() }

    func refresh() {
        let title = tab.displayTitle
        if titleLabel.stringValue != title {
            titleLabel.stringValue = title
            toolTip = title
            setAccessibilityLabel(title)
        }
        icon.image = tab.favicon ?? Self.globe
        icon.contentTintColor = .secondaryLabelColor
        updateAppearance()
    }

    private func updateAppearance() {
        let fill = Theme.fill(hovered: isHovered, pressed: isPressed, selected: isSelected)
        // The fill eases between rest, hover and selected rather than snapping.
        withEasing { layer?.backgroundColor = fill.layerColor }
        // Under Increase Contrast the selected tab gets an outline too.
        layer?.borderWidth = Theme.hairlineWidth
        layer?.borderColor = Theme.selectionOutline(selected: isSelected).layerColor
        // Unselected titles in secondary gray read as disabled; the weight
        // alone marks the selected one. A tab whose page isn't loaded,
        // restored at launch or unloaded to save memory, is dimmed for that.
        let dimmed = !tab.isStarted && !isSelected
        titleLabel.textColor = dimmed ? .secondaryLabelColor : .labelColor
        icon.alphaValue = dimmed ? 0.5 : 1
        // A compact tab only offers to close when it is the selected one, so a
        // pass of the mouse along a crowded row can't hit a close button.
        let showsClose = closesOnTrailing ? isHovered || isSelected : isHovered && (!isCompact || isSelected)
        closeButton.isHidden = !showsClose
        titleToClose.isActive = closesOnTrailing && showsClose
        let coversIcon = showsClose && !closesOnTrailing
        icon.isHidden = coversIcon || tab.isLoading
        if tab.isLoading && !coversIcon {
            spinner.startAnimation(nil)
        } else {
            spinner.stopAnimation(nil)
        }
    }

    override func updateLayer() {
        super.updateLayer()
        updateAppearance() // layer colors don't follow light/dark changes on their own
    }

    override var wantsUpdateLayer: Bool { true }

    // MARK: Mouse

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
        // A tab that slides under a still mouse, or out from under it, gets
        // no enter or exit event.
        if let window, NSApp.isActive {
            isHovered = bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil))
        }
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        isPressed = false
    }

    override func mouseDown(with event: NSEvent) {
        isPressed = true
        onSelect?()
        strip?.beginDrag(self, with: event)
    }

    override func mouseDragged(with event: NSEvent) { strip?.continueDrag(with: event) }

    override func mouseUp(with event: NSEvent) {
        isPressed = false
        strip?.endDrag()
    }

    // Middle click closes, as in other browsers.
    override func otherMouseUp(with event: NSEvent) {
        if event.buttonNumber == 2 { onClose?() }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let strip else { return nil }
        return strip.delegate?.tabStrip(strip, menuFor: tab)
    }

    // Clicks in the tab select it instead of dragging the window.
    override var mouseDownCanMoveWindow: Bool { false }

    @objc private func closeClicked() { onClose?() }

    // MARK: Accessibility

    override func accessibilityPerformPress() -> Bool {
        onSelect?()
        return true
    }

    @objc private func closeFromAccessibility() -> Bool {
        onClose?()
        return true
    }
}

/// The row after the last tab of a sidebar, which opens a new tab.
final class NewTabRowView: NSView {
    var onClick: (() -> Void)?
    /// Too narrow for a title: the plus sits in the middle.
    var isCompact = false {
        didSet {
            guard isCompact != oldValue else { return }
            titleLabel.isHidden = isCompact
            // Off before on, so the two never hold at once.
            (isCompact ? iconLeading : iconCentered).isActive = false
            (isCompact ? iconCentered : iconLeading).isActive = true
        }
    }

    private let icon = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "New Tab")
    private var isHovered = false { didSet { needsDisplay = true } }
    private var isPressed = false { didSet { needsDisplay = true } }
    private var iconLeading: NSLayoutConstraint!
    private var iconCentered: NSLayoutConstraint!

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = Theme.Radius.row
        layer?.cornerCurve = .continuous
        toolTip = "New Tab"
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("New Tab")

        icon.image = Theme.symbol("plus", size: Theme.Symbol.row, label: "New Tab")
        icon.contentTintColor = .secondaryLabelColor
        titleLabel.font = .systemFont(ofSize: Theme.FontSize.secondary)
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        for view in [icon, titleLabel] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        iconLeading = icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10)
        iconCentered = icon.centerXAnchor.constraint(equalTo: centerXAnchor)
        // Gives way in a compact tab, which has no room after a centered icon.
        let titleLeading = titleLabel.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 7)
        titleLeading.priority = .defaultHigh
        NSLayoutConstraint.activate([
            iconLeading,
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            titleLeading,
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        super.updateLayer()
        let fill = Theme.fill(hovered: isHovered, pressed: isPressed)
        withEasing { layer?.backgroundColor = fill.layerColor }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        isPressed = false
    }

    override func mouseDown(with event: NSEvent) { isPressed = true }

    override func mouseUp(with event: NSEvent) {
        isPressed = false
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }

    override func accessibilityPerformPress() -> Bool {
        onClick?()
        return true
    }

    override var mouseDownCanMoveWindow: Bool { false }
}
