import AppKit

/// The row above the message field: a numbered button per open chat on the
/// left, followed by the new tab button, and new chat and history buttons on
/// the right. The chat's model and tools are in the field itself.
final class AgentTabBar: NSView {
    static let height: CGFloat = 26

    var onSelect: ((Int) -> Void)?
    var onClose: ((Int) -> Void)?
    var onNewTab: (() -> Void)?
    var onNewChat: (() -> Void)?
    /// Gets the history button, to show the list from.
    var onHistory: ((NSView) -> Void)?

    private let tabStack = NSStackView()
    /// Smaller than the bar's other buttons, since it sits with the tabs.
    private let newTabButton = Theme.iconButton("plus", label: "New Tab", size: Theme.Symbol.row)
    private let newChatButton = Theme.iconButton("square.and.pencil", label: "New Chat")
    private let historyButton = Theme.iconButton("clock.arrow.circlepath", label: "Chat History")

    override init(frame: NSRect) {
        super.init(frame: frame)
        tabStack.spacing = 6
        newTabButton.target = self
        newTabButton.action = #selector(newTab(_:))
        newChatButton.target = self
        newChatButton.action = #selector(newChat(_:))
        historyButton.target = self
        historyButton.action = #selector(history(_:))
        let buttons = NSStackView(views: [newChatButton, historyButton])
        buttons.spacing = 4
        // Only the buttons give way. The tabs hold the panel as wide as they
        // need, so none ends up under the buttons.
        buttons.setClippingResistancePriority(.defaultLow, for: .horizontal)
        for view in [tabStack, newTabButton, buttons] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            tabStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            tabStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            buttons.trailingAnchor.constraint(equalTo: trailingAnchor),
            buttons.centerYAnchor.constraint(equalTo: centerYAnchor),
            // Right after the last tab, where the next one will go.
            newTabButton.leadingAnchor.constraint(equalTo: tabStack.trailingAnchor, constant: 4),
            newTabButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            buttons.leadingAnchor.constraint(greaterThanOrEqualTo: newTabButton.trailingAnchor, constant: 8),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    /// The new tab button shows only while there is room for another tab.
    func update(tabs: [(title: String, busy: Bool)], selected: Int, canAddTab: Bool) {
        while tabStack.arrangedSubviews.count > tabs.count { tabStack.arrangedSubviews.last?.removeFromSuperview() }
        while tabStack.arrangedSubviews.count < tabs.count {
            let index = tabStack.arrangedSubviews.count
            let button = TabNumberButton(number: index + 1)
            button.onSelect = { [weak self] in self?.onSelect?(index) }
            button.onClose = { [weak self] in self?.onClose?(index) }
            tabStack.addArrangedSubview(button)
        }
        // Many tabs sit closer together, to leave the buttons room.
        tabStack.spacing = tabs.count > 5 ? 2 : 6
        for (index, (view, tab)) in zip(tabStack.arrangedSubviews, tabs).enumerated() {
            guard let button = view as? TabNumberButton else { continue }
            button.title = tab.title
            button.isBusy = tab.busy
            button.isSelected = index == selected
        }
        newTabButton.isHidden = !canAddTab
    }

    @objc private func newTab(_ sender: Any?) { onNewTab?() }
    @objc private func newChat(_ sender: Any?) { onNewChat?() }
    @objc private func history(_ sender: Any?) { onHistory?(historyButton) }

    #if DEBUG
    /// Clicks the history button for `ui.agentAction`, so what opens hangs
    /// off that button, as it does for a real click.
    func historyForTesting() { history(nil) }
    #endif
}

/// A tab's number in a rounded square, tinted with the accent color when
/// selected, with a dot while its agent works. The selected tab's number
/// gives way to a cross under the mouse, which closes it, unless its agent
/// is working; right-click closes any tab.
private final class TabNumberButton: NSView {
    var onSelect: (() -> Void)?
    var onClose: (() -> Void)?
    var title = "" {
        didSet {
            toolTip = title
            setAccessibilityLabel("Tab \(number): \(title)")
        }
    }
    var isSelected = false {
        didSet {
            guard isSelected != oldValue else { return }
            // A tab just selected under the mouse keeps its number until the
            // mouse comes back, so a double-click doesn't close it.
            closeArmed = false
            setAccessibilityValue(isSelected)
            setAccessibilitySelected(isSelected)
            updateLabel()
            needsDisplay = true
        }
    }
    var isBusy = false {
        didSet {
            busyDot.isHidden = !isBusy
            updateLabel()
        }
    }

    private let number: Int
    private let label: NSTextField
    /// Stands in for the number while a click would close the tab.
    private let closeIcon = NSImageView()
    private let busyDot = NSView()
    private var isHovered = false {
        didSet {
            updateLabel()
            needsDisplay = true
        }
    }
    private var isPressed = false { didSet { needsDisplay = true } }
    /// Whether the mouse came onto the tab while it was already selected.
    private var closeArmed = false

    /// Whether a click closes the tab rather than selecting it. Not while
    /// its agent works: closing would end the turn, so that takes the menu.
    private var offersClose: Bool { isSelected && isHovered && closeArmed && !isBusy }

    private func updateLabel() {
        label.isHidden = offersClose
        closeIcon.isHidden = !offersClose
        toolTip = offersClose ? "Close Tab" : title
    }

    init(number: Int) {
        self.number = number
        label = NSTextField(labelWithString: "\(number)")
        super.init(frame: .zero)
        wantsLayer = true
        label.font = .monospacedDigitSystemFont(ofSize: Theme.FontSize.secondary, weight: .medium)
        label.alignment = .center
        closeIcon.image = Theme.closeImage(size: 9, label: "Close Chat")
        closeIcon.contentTintColor = Theme.text
        closeIcon.isHidden = true
        busyDot.wantsLayer = true
        busyDot.layer?.cornerRadius = Theme.busyDot / 2
        busyDot.layer?.backgroundColor = Theme.accentColor.layerColor
        busyDot.isHidden = true
        for view in [label, closeIcon, busyDot] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: AgentTabBar.height),
            heightAnchor.constraint(equalToConstant: AgentTabBar.height),
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeIcon.centerXAnchor.constraint(equalTo: centerXAnchor),
            closeIcon.centerYAnchor.constraint(equalTo: centerYAnchor),
            busyDot.widthAnchor.constraint(equalToConstant: Theme.busyDot),
            busyDot.heightAnchor.constraint(equalToConstant: Theme.busyDot),
            busyDot.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            busyDot.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -3),
        ])
        // One of a set, like the tab strip's tabs, so VoiceOver says which
        // chat is showing; closing is an action rather than a hover.
        setAccessibilityElement(true)
        setAccessibilityRole(.radioButton)
        setAccessibilityValue(false)
        setAccessibilitySelected(false)
        setAccessibilityCustomActions([
            NSAccessibilityCustomAction(name: "Close Chat", target: self, selector: #selector(accessibilityClose)),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.cornerRadius = Theme.Radius.row
        layer?.cornerCurve = .continuous
        let fill: NSColor = isSelected
            ? Theme.accent(isHovered || isPressed ? Theme.Accent.selectedHover : Theme.Accent.selected)
            : Theme.fill(isPressed ? Theme.Fill.pressed : isHovered ? Theme.Fill.hover : Theme.Fill.rest)
        withEasing(Theme.Duration.quick) { layer?.backgroundColor = fill.layerColor }
        // The selected tab always has its accent edge; under Increase
        // Contrast the others get a hairline, as a faint fill alone won't show.
        layer?.borderWidth = isSelected || Theme.increaseContrast ? Theme.hairlineWidth : 0
        layer?.borderColor = (isSelected ? Theme.accent(Theme.Accent.outline) : Theme.hairline).layerColor
        label.textColor = isSelected ? Theme.text : Theme.secondaryText
        busyDot.layer?.backgroundColor = Theme.accentColor.layerColor
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        closeArmed = isSelected
        isHovered = true
    }

    override func mouseExited(with event: NSEvent) {
        closeArmed = false
        isHovered = false
        isPressed = false
    }

    override func mouseDown(with event: NSEvent) { isPressed = true }

    override func mouseUp(with event: NSEvent) {
        isPressed = false
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        if offersClose { onClose?() } else { onSelect?() }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        menu.addItem(withTitle: "Close Tab", action: #selector(close(_:)), keyEquivalent: "").target = self
        return menu
    }

    @objc private func close(_ sender: Any?) { onClose?() }

    override func accessibilityPerformPress() -> Bool {
        onSelect?()
        return true
    }

    @objc private func accessibilityClose() -> Bool {
        onClose?()
        return true
    }
}

// MARK: History

/// The list of saved chats, newest first, that the history button shows.
/// A chat open in a tab says which; the selected tab's is marked. Right-click
/// a chat to delete it.
final class AgentHistoryController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    struct Item {
        let conversation: AgentConversation
        /// The tab it is open in.
        let tab: Int?
        /// The agent's name, a provider's included.
        let agentName: String
    }

    var onOpen: ((String) -> Void)?
    var onDelete: ((String) -> Void)?

    private var items: [Item]
    /// The selected tab's chat.
    private let current: String
    private let table = HistoryTableView()
    private let emptyLabel = NSTextField(labelWithString: "No Chats")
    private var scrollHeight: NSLayoutConstraint!
    private static let rowHeight = Theme.RowHeight.twoLine
    /// How far the rows sit in from the popover's edges, as in Downloads.
    private static let inset: CGFloat = 6

    init(items: [Item], current: String) {
        self.items = items
        self.current = current
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let header = NSTextField(labelWithString: "")
        header.attributedStringValue = Theme.sectionHeader("Chats")

        table.addTableColumn(NSTableColumn(identifier: .init("chat")))
        table.headerView = nil
        table.style = .plain
        table.rowHeight = Self.rowHeight
        table.intercellSpacing = .zero
        table.backgroundColor = .clear
        table.selectionHighlightStyle = .none
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(rowClicked(_:))
        // Arrow keys move the selection, Return opens it and Delete removes it.
        table.onReturn = { [weak self] in self?.openSelected() }
        table.onDelete = { [weak self] in self?.deleteSelected() }
        let menu = NSMenu()
        menu.addItem(withTitle: "Delete", action: #selector(deleteClicked(_:)), keyEquivalent: "").target = self
        table.menu = menu

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false

        emptyLabel.font = .systemFont(ofSize: Theme.FontSize.secondary)
        emptyLabel.textColor = Theme.secondaryText

        let view = NSView()
        for subview in [header, scroll, emptyLabel] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(subview)
        }
        scrollHeight = scroll.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            view.widthAnchor.constraint(equalToConstant: Theme.popoverWidth),
            header.topAnchor.constraint(equalTo: view.topAnchor, constant: 10),
            header.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: Theme.Padding.section),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: Self.inset),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -Self.inset),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -Self.inset),
            scrollHeight,
            emptyLabel.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
        ])
        self.view = view
        reload(items)
    }

    /// The keyboard goes to the list, so the arrow keys work at once.
    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(table)
    }

    /// Up to about seven chats show before the list scrolls.
    func reload(_ items: [Item]) {
        self.items = items
        table.reloadData()
        emptyLabel.isHidden = !items.isEmpty
        scrollHeight.constant = items.isEmpty ? Theme.emptyListHeight : min(CGFloat(items.count), 7.5) * Self.rowHeight
        preferredContentSize = view.fittingSize
    }

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let view = HistoryRowView()
        view.isCurrent = items[row].conversation.id == current
        return view
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let item = items[row]
        let isCurrent = item.conversation.id == current
        let subtitle = item.tab.map { "Open in tab \($0 + 1)" } ?? Self.dateText(item.conversation.updated)
        return HistoryCellView(
            title: item.conversation.title,
            subtitle: subtitle + " · " + item.agentName
                + (item.conversation.scheduleID == nil ? "" : " · Scheduled"),
            logo: item.conversation.kind.logo(size: 18),
            isCurrent: isCurrent
        )
    }

    @objc private func rowClicked(_ sender: Any?) {
        let row = table.clickedRow
        guard items.indices.contains(row) else { return }
        onOpen?(items[row].conversation.id)
    }

    @objc private func deleteClicked(_ sender: Any?) {
        let row = table.clickedRow
        guard items.indices.contains(row) else { return }
        onDelete?(items[row].conversation.id)
    }

    private func openSelected() {
        let row = table.selectedRow
        guard items.indices.contains(row) else { return }
        onOpen?(items[row].conversation.id)
    }

    private func deleteSelected() {
        let row = table.selectedRow
        guard items.indices.contains(row) else { return }
        onDelete?(items[row].conversation.id)
        // Keep a row under the keyboard.
        if !items.isEmpty { table.selectRowIndexes([min(row, items.count - 1)], byExtendingSelection: false) }
    }

    /// The time today, "Yesterday", then the date, with the year if not this one.
    private static func dateText(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return date.formatted(date: .omitted, time: .shortened) }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        if calendar.isDate(date, equalTo: Date(), toGranularity: .year) {
            return date.formatted(.dateTime.month(.abbreviated).day())
        }
        return date.formatted(.dateTime.year().month(.abbreviated).day())
    }
}

/// The list of chats, which answers Return and Delete for the row selected
/// with the arrow keys.
private final class HistoryTableView: NSTableView {
    var onReturn: (() -> Void)?
    var onDelete: (() -> Void)?

    /// The table tracks the click itself, so the row under it is told it
    /// is pressed until the mouse comes up.
    override func mouseDown(with event: NSEvent) {
        let row = self.row(at: convert(event.locationInWindow, from: nil))
        let pressed = row >= 0 ? rowView(atRow: row, makeIfNecessary: false) as? HistoryRowView : nil
        pressed?.isPressed = true
        super.mouseDown(with: event)
        pressed?.isPressed = false
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76: onReturn?()  // Return, Enter
        case 51, 117: onDelete?()  // Delete, forward delete
        default: super.keyDown(with: event)
        }
    }
}

/// A row of the history list, a rounded plate like a download's: filled on
/// hover, when pressed or when selected with the keyboard, and tinted with
/// the accent color for the selected tab's chat.
private final class HistoryRowView: NSTableRowView {
    var isCurrent = false { didSet { updateFill() } }
    var isPressed = false { didSet { updateFill() } }
    private var isHovered = false { didSet { updateFill() } }
    /// A layer of its own under the cell, so the fill can ease.
    private let fill = NSView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        fill.wantsLayer = true
        fill.layer?.cornerRadius = Theme.Radius.row
        fill.layer?.cornerCurve = .continuous
        fill.frame = bounds
        fill.autoresizingMask = [.width, .height]
        addSubview(fill)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isSelected: Bool {
        didSet { updateFill() }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateFill(animated: false)
    }

    /// Hover and the keyboard's selection share a fill, as before.
    private func updateFill(animated: Bool = true) {
        let lit = isHovered || isSelected
        let color = isCurrent
            ? Theme.accent(lit || isPressed ? Theme.Accent.selectedHover : Theme.Accent.selected)
            : Theme.fill(hovered: lit, pressed: isPressed)
        let filled = isCurrent || lit || isPressed
        let apply = { [fill] in
            // Resolved here, so the colors follow light and dark mode.
            fill.effectiveAppearance.performAsCurrentDrawingAppearance {
                fill.layer?.backgroundColor = color.layerColor
                fill.layer?.borderColor = Theme.selectionOutline(selected: filled).layerColor
            }
            fill.layer?.borderWidth = Theme.hairlineWidth
        }
        if animated { withEasing(Theme.Duration.quick, apply) } else { apply() }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        isPressed = false
    }
}

/// The agent's logo, or a chat bubble icon without one, beside the chat's
/// title and where or when it was.
private final class HistoryCellView: NSView {
    init(title: String, subtitle: String, logo: NSImage?, isCurrent: Bool) {
        super.init(frame: .zero)
        let icon = NSImageView(image: logo ?? NSImage(systemSymbolName: "bubble.left", accessibilityDescription: nil)!
            .withSymbolConfiguration(.init(pointSize: 14, weight: .regular))!)
        if logo == nil { icon.contentTintColor = isCurrent ? Theme.accentColor : Theme.secondaryText }
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: Theme.FontSize.body, weight: .medium)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let subtitleLabel = NSTextField(labelWithString: subtitle)
        subtitleLabel.font = .systemFont(ofSize: Theme.FontSize.caption)
        subtitleLabel.textColor = Theme.secondaryText
        subtitleLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for view in [icon, titleLabel, subtitleLabel] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            // With the row's inset, the icon lines up under the header.
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.Padding.tight),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 18),
            titleLabel.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -Theme.Padding.tight),
            titleLabel.bottomAnchor.constraint(equalTo: centerYAnchor, constant: 1),
            subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            subtitleLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -Theme.Padding.tight),
            subtitleLabel.topAnchor.constraint(equalTo: centerYAnchor, constant: 3),
        ])
        toolTip = title
    }

    required init?(coder: NSCoder) { fatalError() }
}
