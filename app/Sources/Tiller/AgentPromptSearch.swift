import AppKit

/// The list Ctrl+R opens above the message field: a search field over the
/// messages sent before, in any chat, newest first. Typing filters them,
/// the arrow keys or Ctrl+R move the selection, and Return or a click puts
/// one in the message field. Escape, or clicking elsewhere, closes it. It
/// sits on the same material as the skill picker.
final class PromptSearch: NSVisualEffectView, NSSearchFieldDelegate {
    /// Called with the message picked.
    var onPick: ((String) -> Void)?
    /// Called once it has closed without a pick.
    var onCancel: (() -> Void)?

    private let field = NSSearchField()
    private let stack = NSStackView()
    private let emptyLabel = NSTextField(labelWithString: "No matching messages")
    private var rows: [PromptSearchRow] = []
    /// Newest first.
    private var prompts: [String] = []
    private var matches: [String] = []
    private var selected = 0
    private static let maxRows = 8

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        material = .popover
        blendingMode = .withinWindow
        state = .active
        isHidden = true

        field.placeholderString = "Search sent messages"
        field.font = .systemFont(ofSize: Theme.FontSize.body)
        field.focusRingType = .none
        field.sendsSearchStringImmediately = true
        field.delegate = self
        field.setAccessibilityLabel("Search Sent Messages")

        emptyLabel.font = .systemFont(ofSize: Theme.FontSize.secondary)
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.isHidden = true

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        let content = NSStackView(views: [field, stack, emptyLabel])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 4
        content.setCustomSpacing(6, after: field)
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            field.widthAnchor.constraint(equalTo: content.widthAnchor),
            stack.widthAnchor.constraint(equalTo: content.widthAnchor),
        ])
        emptyLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 8).isActive = true
        setAccessibilityRole(.list)
        setAccessibilityLabel("Sent Messages")
    }

    required init?(coder: NSCoder) { fatalError() }

    var isShown: Bool { !isHidden }

    /// Opens with `prompts`, newest first, and takes the keyboard.
    func show(_ prompts: [String]) {
        self.prompts = prompts
        field.stringValue = ""
        filter()
        if Theme.reduceMotion {
            alphaValue = 1
            isHidden = false
        } else {
            alphaValue = 0
            isHidden = false
            withEasing(Theme.Duration.quick) { animator().alphaValue = 1 }
        }
        window?.makeFirstResponder(field)
    }

    /// Closes without a pick, handing the keyboard back through `onCancel`.
    func cancel() {
        guard isShown else { return }
        isHidden = true
        onCancel?()
    }

    /// Moves to the next older match, as Ctrl+R does again in a shell.
    func selectOlder() {
        moveSelection(by: 1)
    }

    private func filter() {
        let query = field.stringValue.trimmingCharacters(in: .whitespaces)
        let found = query.isEmpty ? prompts : prompts.filter { $0.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        matches = Array(found.prefix(Self.maxRows))
        rows.forEach { $0.removeFromSuperview() }
        rows = matches.enumerated().map { index, prompt in
            let row = PromptSearchRow(text: prompt)
            row.onHover = { [weak self] in self?.select(index) }
            row.onClick = { [weak self] in self?.pick(index) }
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            return row
        }
        stack.isHidden = matches.isEmpty
        emptyLabel.isHidden = !matches.isEmpty
        select(0)
    }

    private func moveSelection(by offset: Int) {
        guard !matches.isEmpty else { return }
        select((selected + offset + matches.count) % matches.count)
        // The keyboard stays in the search field, so VoiceOver is told
        // which message Return would now pick.
        NSAccessibility.post(element: self, notification: .announcementRequested, userInfo: [
            .announcement: matches[selected],
            .priority: NSAccessibilityPriorityLevel.medium.rawValue,
        ])
    }

    private func select(_ index: Int) {
        selected = index
        for (i, row) in rows.enumerated() {
            row.isSelected = i == index
            row.setAccessibilitySelected(i == index)
        }
        setAccessibilitySelectedChildren(rows.indices.contains(index) ? [rows[index]] : [])
    }

    private func pick(_ index: Int) {
        guard matches.indices.contains(index) else { return }
        isHidden = true
        onPick?(matches[index])
    }

    // MARK: Search field

    func controlTextDidChange(_ notification: Notification) {
        filter()
    }

    /// Clicking elsewhere closes it.
    func controlTextDidEndEditing(_ notification: Notification) {
        guard isShown else { return }
        isHidden = true
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveUp(_:)):
            // The list runs newest at the top, so Up goes to a newer one.
            moveSelection(by: -1)
        case #selector(NSResponder.moveDown(_:)):
            moveSelection(by: 1)
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertTab(_:)):
            if matches.isEmpty { NSSound.beep() } else { pick(selected) }
        case #selector(NSResponder.cancelOperation(_:)):
            cancel()
        default:
            return false
        }
        return true
    }

    /// Ctrl+R again moves on to an older match. Control keys reach views
    /// here before the search field's own key handling.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isShown, Self.isSearchKey(event) else { return super.performKeyEquivalent(with: event) }
        selectOlder()
        return true
    }

    /// Ctrl+R, which opens the search and moves through it.
    static func isSearchKey(_ event: NSEvent) -> Bool {
        event.type == .keyDown
            && event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .control
            && event.charactersIgnoringModifiers?.lowercased() == "r"
    }

    // A material view doesn't reliably call `updateLayer`, so the plate's
    // shape and border are set when it joins a window and when the
    // appearance changes, as the skill picker does.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        shapePlate()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        shapePlate()
    }

    private func shapePlate() {
        guard let layer else { return }
        layer.cornerRadius = Theme.Radius.plate
        layer.cornerCurve = .continuous
        layer.masksToBounds = true
        layer.borderWidth = Theme.hairlineWidth
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer.borderColor = Theme.hairline.layerColor
        }
    }
}

/// One sent message in the search: its first line, with the whole of it
/// in the tooltip.
private final class PromptSearchRow: NSView {
    var onHover: (() -> Void)?
    var onClick: (() -> Void)?
    var isSelected = false { didSet { if isSelected != oldValue { needsDisplay = true } } }
    private var isPressed = false { didSet { if isPressed != oldValue { needsDisplay = true } } }

    init(text: String) {
        super.init(frame: .zero)
        wantsLayer = true
        let lines = text.split(whereSeparator: \.isNewline).filter { !$0.allSatisfy(\.isWhitespace) }
        let label = NSTextField(labelWithString: lines.first.map(String.init) ?? "")
        label.font = .systemFont(ofSize: Theme.FontSize.body)
        label.lineBreakMode = .byTruncatingTail
        label.cell?.truncatesLastVisibleLine = true
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let more = NSTextField(labelWithString: lines.count > 1 ? "+\(lines.count - 1) lines" : "")
        more.font = .systemFont(ofSize: Theme.FontSize.caption)
        more.textColor = .secondaryLabelColor
        more.isHidden = lines.count < 2
        let stack = NSStackView(views: [label, NSView(), more])
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
        ])
        toolTip = text
        setAccessibilityRole(.button)
        setAccessibilityLabel(text)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }

    /// Tinted like the skill picker's rows.
    override func updateLayer() {
        layer?.cornerRadius = Theme.Radius.row
        layer?.cornerCurve = .continuous
        let fill: NSColor = isSelected
            ? Theme.accent(isPressed ? Theme.Accent.selectedHover : Theme.Accent.selected)
            : Theme.fill(hovered: false, pressed: isPressed)
        withEasing(Theme.Duration.quick) { layer?.backgroundColor = fill.layerColor }
        layer?.borderWidth = Theme.hairlineWidth
        layer?.borderColor = Theme.selectionOutline(selected: isSelected).layerColor
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { onHover?() }
    override func mouseExited(with event: NSEvent) { isPressed = false }
    override func mouseDown(with event: NSEvent) { isPressed = true }

    override func mouseUp(with event: NSEvent) {
        isPressed = false
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }

    override func accessibilityPerformPress() -> Bool {
        onClick?()
        return true
    }
}
