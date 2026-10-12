import AppKit

/// History suggestions under the address bar while the user types. Up and
/// Down move through them, Return opens the highlighted one, Escape closes the
/// list. When the best match's address starts with what was typed, it is
/// highlighted from the start, so Return goes there instead of searching.
@MainActor
final class AddressSuggestions: NSObject, NSTextFieldDelegate {
    /// Opens a suggestion's URL, in the current tab or a new one.
    var onOpen: ((String, OpenDisposition) -> Void)?

    private let addressBar: AddressBarView
    private let panel = SuggestionsPanel()
    private let list = NSStackView()
    /// One row per place in the list, built once and filled in again on each
    /// keystroke; the ones not needed are hidden.
    private var pool: [SuggestionRow] = []
    /// What the rows open: a search for the text, then the history pages.
    private var rows: [Suggestion] = []
    private var highlighted: Int?
    /// Bumped on every keystroke so a slow query can't show stale results.
    private var generation = 0
    /// Bumped on every show and hide, so a fade-out that a show overtook
    /// leaves the panel up.
    private var fadeGeneration = 0
    /// True while the panel fades out, still visible but on its way.
    private var isFadingOut = false

    private static let limit = 7
    private static let rowHeight = Theme.RowHeight.compact
    private static let inset: CGFloat = 6

    enum Suggestion {
        /// A search for the typed text, or the site it names.
        case input(String)
        case page(HistoryPage)

        func url(settings: ProfileSettings) -> String {
            switch self {
            case .input(let text): AddressInput.url(for: text, settings: settings)
            case .page(let page): page.url
            }
        }
    }

    private let profile: ProfileContext

    init(addressBar: AddressBarView, profile: ProfileContext) {
        self.addressBar = addressBar
        self.profile = profile
        super.init()
        list.orientation = .vertical
        list.spacing = 0
        list.alignment = .width
        list.setAccessibilityRole(.list)
        list.setAccessibilityLabel("Suggestions")
        pool = (0...Self.limit).map { index in
            let row = SuggestionRow()
            row.heightAnchor.constraint(equalToConstant: Self.rowHeight).isActive = true
            row.onHover = { [weak self] in self?.highlight(index) }
            row.onClick = { [weak self] disposition in self?.open(index, disposition) }
            row.isHidden = true
            list.addArrangedSubview(row)
            return row
        }
        let background = SuggestionsBackground()
        background.material = .popover
        // Blurs what is behind the panel, the page and the toolbar, and stays
        // lit though the panel is never key.
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = Theme.Radius.plate
        background.layer?.cornerCurve = .continuous
        background.layer?.masksToBounds = true
        list.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(list)
        NSLayoutConstraint.activate([
            list.topAnchor.constraint(equalTo: background.topAnchor, constant: Self.inset),
            list.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: Self.inset),
            list.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -Self.inset),
        ])
        panel.contentView = background
        addressBar.field.delegate = self
    }

    var isShown: Bool { panel.isVisible && !isFadingOut }

    /// Fades the list out, or takes it away at once when `animated` is
    /// false, as when a suggestion opens, so it doesn't linger over the
    /// page that follows.
    func hide(animated: Bool = true) {
        generation += 1
        highlighted = nil
        shownPages = []
        guard panel.isVisible else { return }
        fadeGeneration += 1
        guard animated else { return close() }
        guard !isFadingOut else { return }
        isFadingOut = true
        let fade = fadeGeneration
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Theme.reduceMotion ? 0 : Theme.Duration.quick
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.fadeGeneration == fade else { return }
                self.close()
            }
        }
    }

    private func close() {
        isFadingOut = false
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        panel.alphaValue = 1
    }

    // MARK: NSTextFieldDelegate

    func controlTextDidChange(_ notification: Notification) {
        let text = addressBar.field.stringValue.trimmingCharacters(in: .whitespaces)
        generation += 1
        guard !text.isEmpty else { return hide() }
        let generation = generation
        // The row for the text itself follows every keystroke, over the
        // pages found for the last one; the ones for this come after.
        show(shownPages, for: text)
        profile.history.search(text, limit: Self.limit) { [weak self] pages in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.generation == generation, self.addressBar.field.currentEditor() != nil else { return }
                    self.show(pages, for: text)
                }
            }
        }
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        hide()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard isShown else {
            // Escape with no list up puts the page's URL back, as in Safari.
            guard selector == #selector(NSResponder.cancelOperation(_:)) else { return false }
            addressBar.field.revert()
            return true
        }
        switch selector {
        case #selector(NSResponder.moveDown(_:)):
            highlight(min(rows.count - 1, (highlighted ?? 0) + 1), announce: true)
        case #selector(NSResponder.moveUp(_:)):
            highlight(max(0, (highlighted ?? 0) - 1), announce: true)
        case #selector(NSResponder.cancelOperation(_:)):
            hide()
        case #selector(NSResponder.insertNewline(_:)):
            guard let index = highlighted, rows.indices.contains(index) else {
                hide(animated: false)
                return false
            }
            open(index, .returnKey(OpenDisposition.currentFlags))
        default:
            return false
        }
        return true
    }

    // MARK: List

    /// The first row is the text itself, as a search or a site, and starts
    /// highlighted, so Return does what the address bar would anyway. When
    /// the best match's address starts with the text, that row is
    /// highlighted instead, as Safari does.
    /// The history pages the rows show, kept for the next keystroke.
    private var shownPages: [HistoryPage] = []

    private func show(_ pages: [HistoryPage], for text: String) {
        shownPages = pages
        // A page the text's own row already opens, give or take scheme and
        // "www.", is left out.
        let typedAddress = HistoryStore.bare(AddressInput.url(for: text, settings: profile.settings)).lowercased()
        let pages = pages.filter { HistoryStore.bare($0.url).lowercased() != typedAddress }
        rows = [.input(text)] + pages.map(Suggestion.page)
        guard let window = addressBar.window else { return hide() }
        for (index, row) in pool.enumerated() {
            if rows.indices.contains(index) {
                row.configure(rows[index], typed: text, settings: profile.settings)
                row.isHidden = false
            } else {
                row.isHidden = true
            }
        }
        let host = pages.first.map { HistoryStore.bare($0.url).lowercased() } ?? ""
        highlight(!host.isEmpty && host.hasPrefix(text.lowercased()) ? 1 : 0)

        let capsule = addressBar.capsule
        let frame = window.convertToScreen(capsule.convert(capsule.bounds, to: nil))
        let height = CGFloat(rows.count) * Self.rowHeight + 2 * Self.inset
        panel.setFrame(NSRect(x: frame.minX, y: frame.minY - 6 - height, width: frame.width, height: height), display: true)
        fadeGeneration += 1
        let appearing = !panel.isVisible
        if appearing { panel.alphaValue = 0 }
        if panel.parent == nil { window.addChildWindow(panel, ordered: .above) }
        panel.orderFront(nil)
        // Eases in when it first comes up, or back from a fade-out.
        if appearing || isFadingOut {
            isFadingOut = false
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Theme.reduceMotion ? 0 : Theme.Duration.quick
                panel.animator().alphaValue = 1
            }
        }
    }

    /// With `announce`, as when Up or Down moves the highlight, VoiceOver
    /// reads the new row, since focus stays in the address field.
    private func highlight(_ index: Int?, announce: Bool = false) {
        let changed = index != highlighted
        highlighted = index
        for (offset, row) in pool.enumerated() {
            row.isHighlighted = offset == index
        }
        guard announce, changed, NSWorkspace.shared.isVoiceOverEnabled,
              let index, pool.indices.contains(index) else { return }
        NSAccessibility.post(element: addressBar.field, notification: .announcementRequested, userInfo: [
            .announcement: pool[index].accessibilityLabel() ?? "",
            .priority: NSAccessibilityPriorityLevel.high.rawValue,
        ])
    }

    private func open(_ index: Int, _ disposition: OpenDisposition) {
        guard rows.indices.contains(index) else { return }
        let url = rows[index].url(settings: profile.settings)
        hide(animated: false)
        onOpen?(url, disposition)
    }
}

/// The list's plate: a popover's material with a hairline around it, like
/// the glass of the address bar it hangs from.
private final class SuggestionsBackground: NSVisualEffectView {
    // A material view need not call updateLayer, so the border is set here
    // and again when the appearance changes the separator's color.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateBorder()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateBorder()
    }

    private func updateBorder() {
        guard let layer else { return }
        layer.borderWidth = Theme.hairlineWidth
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer.borderColor = Theme.hairline.layerColor
        }
    }
}

/// A borderless panel that never takes key status, so the address field keeps
/// the keyboard while the list is up.
private final class SuggestionsPanel: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// One suggestion: for a page, its site's favicon, or a clock without one,
/// the page's title with the typed text in bold where it matches, then its
/// address in grey; for the typed text, a magnifying glass or globe and
/// what Return would do with it. The highlighted row takes the system's
/// selection colors, so it follows the accent color and contrast settings.
private final class SuggestionRow: NSView {
    var onHover: (() -> Void)?
    var onClick: ((OpenDisposition) -> Void)?

    var isHighlighted = false {
        didSet {
            guard isHighlighted != oldValue else { return }
            needsDisplay = true
            setAccessibilitySelected(isHighlighted)
            updateColors()
        }
    }

    private var isPressed = false {
        didSet { if isPressed != oldValue { needsDisplay = true } }
    }

    private let icon = FaviconView()
    private var showsFavicon = false
    private let title = NSTextField(labelWithString: "")
    private let url = NSTextField(labelWithString: "")
    private var titleText = ""
    private var typed = ""
    /// What the icon shows, so it is only made again when that changes.
    private var iconKey = ""

    /// Decoded favicons by site, so typing doesn't decode the same icon
    /// again on every keystroke.
    private static let favicons = NSCache<NSString, NSImage>()

    private static func symbol(_ name: String, _ description: String) -> NSImage? {
        Theme.symbol(name, size: Theme.Symbol.row, weight: .regular, label: description)
    }

    init() {
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        icon.widthAnchor.constraint(equalToConstant: 16).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 16).isActive = true
        icon.setContentHuggingPriority(.required, for: .horizontal)
        // One line each: a long title or address is cut short, never wrapped
        // over the rows around it.
        clipsToBounds = true
        for label in [title, url] {
            label.lineBreakMode = .byTruncatingTail
            label.maximumNumberOfLines = 1
            label.usesSingleLineMode = true
        }
        // The title keeps the room it needs; the address gives way first and
        // never takes more than two fifths of the row.
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        url.font = .systemFont(ofSize: Theme.FontSize.secondary)
        url.setContentCompressionResistancePriority(.defaultLow - 1, for: .horizontal)
        let stack = NSStackView(views: [icon, title, url])
        stack.spacing = 8
        // The icon and title sit right under the address field's icon and
        // text: the list is inset 6 from the capsule's edge, the field's icon
        // 10, with its text 6 after the icon.
        stack.setCustomSpacing(6, after: icon)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            // Only once the address is in the row: the two need a common ancestor.
            url.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, multiplier: 0.4),
        ])
    }

    /// Shows `suggestion`, with `typed` in bold where the title matches it.
    func configure(_ suggestion: AddressSuggestions.Suggestion, typed: String, settings: ProfileSettings) {
        self.typed = typed
        var address = ""
        var tip = ""
        switch suggestion {
        case .page(let page):
            titleText = page.displayTitle
            address = HistoryStore.bare(page.url)
            tip = page.url
            let site = address.split(separator: "/", maxSplits: 1).first.map(String.init) ?? address
            if let favicon = Self.favicon(page.icon, site: site) {
                showFavicon(favicon, key: "page:" + site)
            } else {
                showSymbol("clock", "History")
            }
        case .input(let text):
            let url = AddressInput.url(for: text, settings: settings)
            let isSearch = url == settings.searchURL(for: text)
            titleText = text
            let engine = settings.searchEngine
            address = isSearch ? (engine == .custom ? "Search" : "Search \(engine.displayName)") : HistoryStore.bare(url)
            if isSearch { showSymbol("magnifyingglass", "Search") } else { showSymbol("globe", "Website") }
            tip = url
        }
        toolTip = tip
        setAccessibilityLabel(address.isEmpty ? titleText : "\(titleText), \(address)")
        url.stringValue = address
        updateColors()
    }

    /// The favicon decoded from `data`, from the cache when this site's
    /// has been decoded before.
    private static func favicon(_ data: Data?, site: String) -> NSImage? {
        guard let data else { return nil }
        if let cached = favicons.object(forKey: site as NSString) { return cached }
        guard let favicon = NSImage(data: data) else { return nil }
        favicon.size = NSSize(width: 16, height: 16)
        favicons.setObject(favicon, forKey: site as NSString)
        return favicon
    }

    private func showFavicon(_ favicon: NSImage, key: String) {
        guard key != iconKey else { return }
        iconKey = key
        showsFavicon = true
        icon.contentTintColor = nil
        icon.image = favicon
    }

    private func showSymbol(_ name: String, _ description: String) {
        guard name != iconKey else { return }
        iconKey = name
        showsFavicon = false
        icon.image = Self.symbol(name, description)
    }

    private func updateColors() {
        title.attributedStringValue = Self.highlighting(titleText, typed, color: isHighlighted ? .alternateSelectedControlTextColor : .labelColor)
        url.textColor = isHighlighted ? NSColor.alternateSelectedControlTextColor.dynamic(alpha: 0.75) : .secondaryLabelColor
        if !showsFavicon { icon.contentTintColor = isHighlighted ? .alternateSelectedControlTextColor : .secondaryLabelColor }
    }

    required init?(coder: NSCoder) { fatalError() }

    /// `text` with the first run matching `typed` in bold, case aside.
    private static func highlighting(_ text: String, _ typed: String, color: NSColor) -> NSAttributedString {
        // Without a paragraph style of its own the text would wrap, whatever
        // the label's line break mode.
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let result = NSMutableAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: Theme.FontSize.body), .foregroundColor: color,
            .paragraphStyle: paragraph,
        ])
        if !typed.isEmpty, let range = text.range(of: typed, options: [.caseInsensitive, .diacriticInsensitive]) {
            result.addAttribute(.font, value: NSFont.systemFont(ofSize: Theme.FontSize.body, weight: .semibold), range: NSRange(range, in: text))
        }
        return result
    }

    // The row draws its own selection, so its text stays in plain colors
    // over the material rather than blending into it, as white on the
    // accent fill would.
    override var allowsVibrancy: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        guard isHighlighted else { return }
        let path = NSBezierPath(roundedRect: bounds, xRadius: Theme.Radius.row, yRadius: Theme.Radius.row)
        Theme.selectionColor.setFill()
        path.fill()
        // A press shades the highlight, as it does a tile or a row elsewhere.
        if isPressed {
            Theme.fill(Theme.Fill.pressed).setFill()
            path.fill()
        }
    }

    private var hoverArea: NSTrackingArea?

    // Only its own area is replaced, leaving AppKit's, such as the tooltip's.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) { onHover?() }
    override func mouseExited(with event: NSEvent) { isPressed = false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { isPressed = true }

    // On release, as buttons do, so a slip of the mouse can be taken back.
    override func mouseUp(with event: NSEvent) {
        isPressed = false
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?(.click(event.modifierFlags)) }
    }

    override func otherMouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?(.backgroundTab) }
    }

    override func accessibilityPerformPress() -> Bool {
        onClick?(.currentTab)
        return true
    }
}
