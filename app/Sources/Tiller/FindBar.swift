import AppKit

/// Find in page: a glass capsule at the top right of the page with the search
/// text, the match count, previous/next buttons and a close button. Return
/// goes to the next match, Shift+Return the previous one, Escape closes.
final class FindBar: NSView, NSTextFieldDelegate {
    /// The search text changed. Empty text ends the search.
    var onChange: ((String) -> Void)?
    /// Go to the next match (true) or the previous one (false).
    var onStep: ((Bool) -> Void)?
    var onClose: (() -> Void)?

    let field = NSTextField()
    private let glass = GlassView()
    private let countLabel = NSTextField(labelWithString: "")
    private let previousButton = FindBar.button("chevron.up", "Previous Match (Shift+Return)")
    private let nextButton = FindBar.button("chevron.down", "Next Match (Return)")
    /// Reads the count out to VoiceOver once typing pauses.
    private var announcement: Task<Void, Never>?

    var text: String { field.stringValue }

    override init(frame: NSRect) {
        super.init(frame: frame)

        let icon = NSImageView(image: Theme.symbol("magnifyingglass", size: Theme.Symbol.inline) ?? NSImage())
        icon.contentTintColor = Theme.secondaryText

        field.placeholderString = "Find in page"
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: Theme.FontSize.body)
        field.usesSingleLineMode = true
        field.lineBreakMode = .byTruncatingTail
        field.cell?.isScrollable = true
        field.delegate = self
        field.setAccessibilityLabel("Find in Page")
        // In a narrow page the field gives up its room before the count and
        // the buttons do.
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        countLabel.font = .monospacedDigitSystemFont(ofSize: Theme.FontSize.caption, weight: .regular)
        countLabel.textColor = Theme.secondaryText
        countLabel.alignment = .right
        countLabel.setContentHuggingPriority(.required, for: .horizontal)
        countLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        // The same close glyph as a tab's.
        let closeButton = Self.button("xmark", "Done (Escape)")
        closeButton.image = Theme.closeImage(size: 9, label: "Done (Escape)")
        // And the same round plate.
        (closeButton as? HoverButton)?.plateRadius = Theme.ButtonSize.inline / 2
        for (button, action) in [
            (previousButton, #selector(previous(_:))),
            (nextButton, #selector(next(_:))),
            (closeButton, #selector(close(_:))),
        ] {
            button.target = self
            button.action = action
        }

        let row = NSStackView(views: [icon, field, countLabel, previousButton, nextButton, closeButton])
        row.spacing = 4
        row.setCustomSpacing(6, after: icon)
        row.setCustomSpacing(8, after: countLabel)
        row.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 8)
        glass.contentView = row
        // As tall and as round as the address bar.
        glass.cornerRadius = Theme.Capsule.radius
        // A wash of the window color, as the camera bar has, so the capsule
        // shows on a white page, where clear glass all but disappears, and
        // the page's own text doesn't read through the field.
        glass.tintColor = Theme.background.dynamic(alpha: 0.85)
        glass.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glass)
        NSLayoutConstraint.activate([
            glass.topAnchor.constraint(equalTo: topAnchor),
            glass.bottomAnchor.constraint(equalTo: bottomAnchor),
            glass.leadingAnchor.constraint(equalTo: leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: trailingAnchor),
            glass.heightAnchor.constraint(equalToConstant: Theme.Capsule.height),
            glass.widthAnchor.constraint(greaterThanOrEqualToConstant: 200),
        ])
        // Narrows when the page is too narrow to hold it. Below the split
        // view's holding priorities, so it never widens the page and pushes
        // the sidebar or the agent panel aside.
        let width = glass.widthAnchor.constraint(equalToConstant: 340)
        width.priority = .init(255)
        width.isActive = true
        showCount(nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    private static func button(_ symbol: String, _ label: String) -> NSButton {
        Theme.iconButton(symbol, label: label, size: Theme.Symbol.inline, frame: Theme.ButtonSize.inline)
    }

    /// Shows "3 of 12" or "No matches", or nothing while there's no search.
    func showCount(_ result: (count: Int, active: Int)?) {
        let hasText = !field.stringValue.isEmpty
        let shown = countLabel.stringValue
        switch result {
        case let (count, active)? where count > 0:
            // Chromium counts before it picks a match.
            countLabel.stringValue = active > 0 ? "\(active) of \(count)" : count == 1 ? "1 match" : "\(count) matches"
            countLabel.textColor = Theme.secondaryText
        case _? where hasText:
            countLabel.stringValue = "No matches"
            countLabel.textColor = Theme.danger
        default:
            countLabel.stringValue = ""
        }
        let canStep = hasText && (result?.count ?? 0) > 0
        previousButton.isEnabled = canStep
        nextButton.isEnabled = canStep
        if countLabel.stringValue != shown, !countLabel.stringValue.isEmpty { announce(countLabel.stringValue) }
    }

    /// Posts `text` to VoiceOver after a short pause, so each keystroke
    /// doesn't cut off the count read for the one before.
    private func announce(_ text: String) {
        announcement?.cancel()
        announcement = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled, let self else { return }
            NSAccessibility.post(element: self.field, notification: .announcementRequested, userInfo: [
                .announcement: text,
                .priority: NSAccessibilityPriorityLevel.high.rawValue,
            ])
        }
    }

    // MARK: NSTextFieldDelegate

    func controlTextDidChange(_ notification: Notification) {
        onChange?(field.stringValue)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            let backward = NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false
            onStep?(!backward)
        case #selector(NSResponder.cancelOperation(_:)):
            onClose?()
        default:
            return false
        }
        return true
    }

    @objc private func previous(_ sender: Any?) { onStep?(false) }
    @objc private func next(_ sender: Any?) { onStep?(true) }
    @objc private func close(_ sender: Any?) { onClose?() }
}
