import AppKit

/// Suggestions under the address bar, as in Chrome. While the user types,
/// the first row is what Return does: the best page from history, its
/// address completed in the field, when one starts with what was typed and
/// has been typed or visited before, else the text itself, as a search or a
/// site. Then come the search engine's suggestions, open tabs to switch to
/// and pages from history. A click in the field, Cmd+L or Down lists a link
/// on the clipboard and recent pages. Up and Down, or Tab and Shift-Tab,
/// move through the rows, wrapping round, and put each in the field; Return
/// opens it; Shift+Delete forgets a page; Escape goes back to what was typed
/// and then to the page's URL.
@MainActor
final class AddressSuggestions: NSObject, NSTextFieldDelegate {
    /// Opens a suggestion's URL, in the current tab or a new one. `typed` is
    /// true for an address rather than a search, which counts in history.
    var onOpen: ((String, OpenDisposition, Bool) -> Void)?
    /// Selects the open tab a suggestion stands for.
    var onSwitchTab: ((ObjectIdentifier) -> Void)?
    /// The window's tabs other than the selected one.
    var openTabs: (() -> [OpenTab])?

    /// A tab a suggestion can switch to.
    struct OpenTab {
        let id: ObjectIdentifier
        let url: String
        let title: String
        let favicon: NSImage?
    }

    private let addressBar: AddressBarView
    private let panel = SuggestionsPanel()
    private let list = NSStackView()
    /// One row per place in the list, built once and filled in again on each
    /// keystroke; the ones not needed are hidden.
    private var pool: [SuggestionRow] = []
    private var rows: [Suggestion] = []
    private var highlighted: Int?
    /// Bumped on every keystroke so a slow query can't show stale results.
    private var generation = 0
    /// Bumped on every show and hide, so a fade-out that a show overtook
    /// leaves the panel up.
    private var fadeGeneration = 0
    /// True while the panel fades out, still visible but on its way.
    private var isFadingOut = false

    /// What the user typed, without the completion shown after it.
    private var typed = ""
    /// The rest of the completed address, selected after `typed`.
    private var completion = ""
    /// Whether the last edit left the caret at the end without deleting,
    /// the only edit that completes the text: after Delete the field keeps
    /// what is left.
    private var completes = false
    /// Set by a delete command, for the text change that follows it.
    private var deleting = false
    /// Whether Up, Down or Tab has put a row in the field since the last
    /// keystroke, so the rows that arrive later leave it there.
    private var moved = false
    /// Whether the list is the one shown before typing, which nothing is
    /// highlighted in at first, so Return goes to what the field holds.
    private var isZeroSuggest = false
    /// The history pages and the engine's suggestions the rows show, kept
    /// for the next keystroke.
    private var shownPages: [HistoryPage] = []
    private var shownSearches: [String] = []

    private static let maxRows = 8
    private static let maxSearches = 3
    private static let maxTabs = 2
    private static let rowHeight = Theme.RowHeight.compact
    private static let inset: CGFloat = 6

    enum Suggestion {
        /// A search for the typed text, or the site it names.
        case input(String)
        case page(HistoryPage)
        /// A search the engine suggested.
        case search(String)
        case openTab(OpenTab)
        /// A link on the clipboard.
        case clipboard(String)

        func url(settings: ProfileSettings) -> String {
            switch self {
            case .input(let text): AddressInput.url(for: text, settings: settings)
            case .page(let page): page.url
            case .search(let text): settings.searchURL(for: text)
            case .openTab(let tab): tab.url
            case .clipboard(let url): url
            }
        }

        /// What Up and Down put in the field.
        var fieldText: String {
            switch self {
            case .input(let text), .search(let text): text
            case .page(let page): HistoryStore.bare(page.url)
            case .openTab(let tab): HistoryStore.bare(tab.url)
            case .clipboard(let url): url
            }
        }

        var isRemovable: Bool {
            if case .page = self { true } else { false }
        }
    }

    private let profile: ProfileContext
    private lazy var searchSuggest = SearchSuggest(settings: profile.settings)

    init(addressBar: AddressBarView, profile: ProfileContext) {
        self.addressBar = addressBar
        self.profile = profile
        super.init()
        list.orientation = .vertical
        list.spacing = 0
        list.alignment = .width
        list.setAccessibilityRole(.list)
        list.setAccessibilityLabel("Suggestions")
        pool = (0..<Self.maxRows).map { index in
            let row = SuggestionRow()
            row.heightAnchor.constraint(equalToConstant: Self.rowHeight).isActive = true
            row.onHover = { [weak self] in self?.highlight(index) }
            row.onClick = { [weak self] disposition in self?.open(index, disposition) }
            row.onRemove = { [weak self] in self?.remove(index) }
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
        searchSuggest.cancel()
        highlighted = nil
        shownPages = []
        shownSearches = []
        typed = ""
        completion = ""
        moved = false
        isZeroSuggest = false
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

    /// Lists a link on the clipboard and recent pages, before anything is
    /// typed. Only when the user asked for the field, by a click, Cmd+L or
    /// Down: a new tab, which takes the field on its own, keeps its start
    /// page clear.
    func showOnFocus() {
        guard addressBar.field.isEditing else { return }
        generation += 1
        let generation = generation
        let current = HistoryStore.bare(addressBar.field.url).lowercased()
        let link = Self.copiedLink().flatMap { HistoryStore.bare($0).lowercased() == current ? nil : $0 }
        profile.history.recentWithIcons(limit: Self.maxRows + 1) { [weak self] pages in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.generation == generation, self.addressBar.field.isEditing else { return }
                    var seen: Set<String> = [current]
                    if let link { seen.insert(HistoryStore.bare(link).lowercased()) }
                    let recent = pages.filter { seen.insert(HistoryStore.bare($0.url).lowercased()).inserted }
                    let rows = (link.map { [Suggestion.clipboard($0)] } ?? []) + recent.map(Suggestion.page)
                    guard !rows.isEmpty else { return }
                    self.isZeroSuggest = true
                    self.typed = ""
                    self.completion = ""
                    self.moved = false
                    self.present(Array(rows.prefix(Self.maxRows)), typed: "", highlight: nil)
                }
            }
        }
    }

    /// The URL on the clipboard, when there is one and reading it won't ask
    /// the user's permission.
    private static func copiedLink() -> String? {
        let pasteboard = NSPasteboard.general
        if #available(macOS 15.4, *), pasteboard.accessBehavior != .alwaysAllow { return nil }
        guard pasteboard.availableType(from: [.string]) != nil,
              let text = pasteboard.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
              text.count < 2048, !text.contains(where: \.isWhitespace),
              text.hasPrefix("https://") || text.hasPrefix("http://"),
              let url = URL(string: text), url.host() != nil else { return nil }
        return text
    }

    // MARK: NSTextFieldDelegate

    func controlTextDidChange(_ notification: Notification) {
        let field = addressBar.field
        let text = field.stringValue
        let caretAtEnd = (field.currentEditor()?.selectedRange.location ?? 0) == text.utf16.count
        // Typing at the end completes; Delete, or an edit in the middle,
        // leaves the text as it is.
        completes = caretAtEnd && !deleting
        deleting = false
        typed = text
        completion = ""
        moved = false
        isZeroSuggest = false
        generation += 1
        let query = text.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else {
            searchSuggest.cancel()
            hide()
            return showOnFocus()
        }
        let generation = generation
        // The engine's suggestions for the last keystroke stay while they
        // still fit, until the ones for this arrive.
        shownSearches = shownSearches.filter { $0.lowercased().hasPrefix(query.lowercased()) }
        // The row for the text itself follows every keystroke, over the
        // pages found for the last one; the ones for this come after.
        show(for: query)
        profile.history.search(query, limit: Self.maxRows) { [weak self] pages in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.generation == generation, self.addressBar.field.isEditing else { return }
                    self.shownPages = pages
                    self.show(for: query)
                }
            }
        }
        searchSuggest.fetch(query, limit: Self.maxSearches + 1) { [weak self] searches in
            guard let self, self.generation == generation, self.addressBar.field.isEditing else { return }
            self.shownSearches = searches
            self.show(for: query)
        }
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        hide()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        let flags = OpenDisposition.currentFlags
        deleting = selector.description.hasPrefix("delete")
        // Ctrl+Return wraps a name in www. and .com, as in Chrome.
        if selector == #selector(NSResponder.insertLineBreak(_:))
            || (selector == #selector(NSResponder.insertNewline(_:)) && flags.contains(.control)) {
            let name = (isShown ? typed : addressBar.field.stringValue).trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, !name.contains("."), !name.contains(" "), !name.contains(":"), !name.contains("/") else {
                return false
            }
            hide(animated: false)
            onOpen?("https://www.\(name).com/", .returnKey(flags), true)
            return true
        }
        guard isShown else {
            switch selector {
            case #selector(NSResponder.cancelOperation(_:)):
                // Escape with no list up puts the page's URL back, as in Safari.
                addressBar.field.revert()
                return true
            case #selector(NSResponder.moveDown(_:)):
                showOnFocus()
                return true
            default:
                return false
            }
        }
        switch selector {
        case #selector(NSResponder.moveDown(_:)), #selector(NSResponder.insertTab(_:)):
            step(1)
        case #selector(NSResponder.moveUp(_:)), #selector(NSResponder.insertBacktab(_:)):
            step(-1)
        case #selector(NSResponder.cancelOperation(_:)):
            if moved && !isZeroSuggest {
                // Back to what was typed, then to the page's URL.
                moved = false
                restoreTyped()
                highlight(0, announce: true)
            } else {
                hide()
                addressBar.field.revert()
            }
        case #selector(NSResponder.deleteForward(_:)), #selector(NSResponder.deleteBackward(_:)):
            // Shift+Delete forgets the highlighted page, as in Chrome.
            guard flags.contains(.shift), moved, let index = highlighted, rows.indices.contains(index),
                  rows[index].isRemovable else { return false }
            // Nothing is deleted from the field.
            deleting = false
            remove(index)
        case #selector(NSResponder.insertNewline(_:)):
            guard let index = highlighted, rows.indices.contains(index) else {
                hide(animated: false)
                return false
            }
            open(index, .returnKey(flags))
        default:
            return false
        }
        return true
    }

    // MARK: List

    /// Builds the rows for `text` from the pages and searches found so far
    /// and completes the field from the first page when it can.
    private func show(for text: String) {
        let lower = text.lowercased()
        let settings = profile.settings
        let candidate = completes && typed == text ? Self.completionPage(for: lower, in: shownPages) : nil
        // A page the text's own row already opens, give or take scheme and
        // "www.", is left out.
        var seen: Set<String> = [HistoryStore.bare(AddressInput.url(for: text, settings: settings)).lowercased()]
        var rows: [Suggestion] = []
        if let candidate {
            rows.append(.page(candidate))
            seen.insert(HistoryStore.bare(candidate.url).lowercased())
        }
        rows.append(.input(text))
        var searches = Set([lower])
        rows += shownSearches.filter { searches.insert($0.lowercased()).inserted }.prefix(Self.maxSearches).map(Suggestion.search)
        // Open tabs whose title or address has the text, and history pages
        // that are open, offer to switch to their tab.
        let tabs = openTabs?() ?? []
        var tabsByAddress: [String: OpenTab] = [:]
        for tab in tabs { tabsByAddress[HistoryStore.bare(tab.url).lowercased(), default: tab] = tab }
        let matchingTabs = tabs.filter {
            $0.title.lowercased().contains(lower) || HistoryStore.bare($0.url).lowercased().contains(lower)
        }
        for tab in matchingTabs.prefix(Self.maxTabs) where seen.insert(HistoryStore.bare(tab.url).lowercased()).inserted {
            rows.append(.openTab(tab))
        }
        for page in shownPages {
            let address = HistoryStore.bare(page.url).lowercased()
            guard seen.insert(address).inserted else { continue }
            rows.append(tabsByAddress[address].map(Suggestion.openTab) ?? .page(page))
        }
        rows = Array(rows.prefix(Self.maxRows))

        // The completion follows the first row, as long as the user hasn't
        // moved off it.
        if !moved {
            let rest = candidate.map { Self.completion(of: $0, after: text) } ?? ""
            if rest != completion {
                completion = rest
                if rest.isEmpty { addressBar.field.show(text: typed) } else { addressBar.field.show(typed: typed, completion: rest) }
            }
        }
        let keep = moved ? highlighted.map { min($0, rows.count - 1) } : 0
        present(rows, typed: text, highlight: keep)
    }

    /// The first of `pages` whose address, without scheme and "www.",
    /// starts with `lower` and goes on past it, if it was typed before or
    /// visited more than once, so a page seen in passing isn't completed.
    static func completionPage(for lower: String, in pages: [HistoryPage]) -> HistoryPage? {
        guard !lower.isEmpty, !lower.contains(" ") else { return nil }
        return pages.first { page in
            let address = displayAddress(page.url).lowercased()
            return address.hasPrefix(lower) && address.count > lower.count && (page.typedCount > 0 || page.visitCount > 1)
        }
    }

    /// What follows `text` in `page`'s address.
    static func completion(of page: HistoryPage, after text: String) -> String {
        String(displayAddress(page.url).dropFirst(text.count))
    }

    /// `url` without scheme, "www." and a lone trailing slash.
    private static func displayAddress(_ url: String) -> String {
        var address = HistoryStore.bare(url)
        if address.hasSuffix("/"), address.firstIndex(of: "/") == address.index(before: address.endIndex) {
            address.removeLast()
        }
        return address
    }

    /// Fills the rows and puts the panel under the capsule.
    private func present(_ rows: [Suggestion], typed text: String, highlight index: Int?) {
        self.rows = rows
        guard let window = addressBar.window, !rows.isEmpty else { return hide() }
        for (offset, row) in pool.enumerated() {
            if rows.indices.contains(offset) {
                row.configure(rows[offset], typed: text, settings: profile.settings)
                row.isHidden = false
            } else {
                row.isHidden = true
            }
        }
        highlight(index)

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

    /// Moves the highlight by `offset`, wrapping round, and puts that row
    /// in the field, or what was typed back on the first row.
    private func step(_ offset: Int) {
        guard !rows.isEmpty else { return }
        let count = rows.count
        let next = highlighted.map { ($0 + offset + count) % count } ?? (offset > 0 ? 0 : count - 1)
        // Back on the first row counts as not moved, so Escape goes on to the
        // page's URL.
        moved = next != 0 || isZeroSuggest
        if next == 0 && !isZeroSuggest {
            restoreTyped()
        } else {
            addressBar.field.show(text: rows[next].fieldText)
        }
        highlight(next, announce: true)
    }

    /// What was typed, with its completion, back in the field.
    private func restoreTyped() {
        if completion.isEmpty { addressBar.field.show(text: typed) } else { addressBar.field.show(typed: typed, completion: completion) }
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
        let row = rows[index]
        hide(animated: false)
        if case .openTab(let tab) = row, disposition == .currentTab {
            onSwitchTab?(tab.id)
            return
        }
        let url = row.url(settings: profile.settings)
        let isSearch: Bool = switch row {
        case .search: true
        case .input(let text): url == profile.settings.searchURL(for: text)
        default: false
        }
        onOpen?(url, disposition, !isSearch)
    }

    /// Forgets a history page, from Shift+Delete or its row's remove button.
    private func remove(_ index: Int) {
        guard rows.indices.contains(index), case .page(let page) = rows[index] else { return }
        profile.history.remove(url: page.url)
        let address = HistoryStore.bare(page.url).lowercased()
        shownPages.removeAll { HistoryStore.bare($0.url).lowercased() == address }
        if isZeroSuggest {
            var rows = rows
            rows.remove(at: index)
            let next = rows.isEmpty ? nil : min(index, rows.count - 1)
            present(rows, typed: "", highlight: highlighted == nil ? nil : next)
            return
        }
        moved = false
        completion = ""
        addressBar.field.show(text: typed)
        show(for: typed.trimmingCharacters(in: .whitespaces))
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
/// what Return would do with it; for an open tab, its favicon and "Switch
/// to This Tab". The highlighted row takes the system's selection colors,
/// so it follows the accent color and contrast settings, and a page's
/// highlighted row has a button that forgets it.
private final class SuggestionRow: NSView {
    var onHover: (() -> Void)?
    var onClick: ((OpenDisposition) -> Void)?
    var onRemove: (() -> Void)?

    var isHighlighted = false {
        didSet {
            guard isHighlighted != oldValue else { return }
            needsDisplay = true
            setAccessibilitySelected(isHighlighted)
            updateColors()
        }
    }

    private let removeButton = HoverButton()
    private var isRemovable = false

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
        removeButton.bezelStyle = .accessoryBarAction
        removeButton.isBordered = false
        removeButton.imagePosition = .imageOnly
        removeButton.image = Theme.closeImage(label: "Remove from History")
        removeButton.toolTip = "Remove from History"
        removeButton.plateRadius = Theme.ButtonSize.inline / 2
        removeButton.target = self
        removeButton.action = #selector(removeClicked(_:))
        removeButton.isHidden = true
        removeButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(removeButton)
        NSLayoutConstraint.activate([
            removeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            removeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            removeButton.widthAnchor.constraint(equalToConstant: Theme.ButtonSize.inline),
            removeButton.heightAnchor.constraint(equalToConstant: Theme.ButtonSize.inline),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: removeButton.leadingAnchor, constant: -4),
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
        isRemovable = suggestion.isRemovable
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
        case .search(let text):
            titleText = text
            tip = settings.searchURL(for: text)
            showSymbol("magnifyingglass", "Search")
        case .openTab(let tab):
            titleText = tab.title.isEmpty ? HistoryStore.bare(tab.url) : tab.title
            address = "Switch to This Tab"
            tip = tab.url
            if let favicon = tab.favicon {
                showFavicon(favicon, key: "tab:" + tab.url)
            } else {
                showSymbol("square.on.square", "Open Tab")
            }
        case .clipboard(let link):
            titleText = "Link You Copied"
            address = HistoryStore.bare(link)
            tip = link
            showSymbol("doc.on.clipboard", "Clipboard")
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
        title.attributedStringValue = Self.highlighting(titleText, typed, color: isHighlighted ? Theme.selectionText : Theme.text)
        url.textColor = isHighlighted ? Theme.selectionText.dynamic(alpha: 0.75) : Theme.secondaryText
        if !showsFavicon { icon.contentTintColor = isHighlighted ? Theme.selectionText : Theme.secondaryText }
        removeButton.contentTintColor = isHighlighted ? Theme.selectionText : Theme.secondaryText
        removeButton.isHidden = !(isHighlighted && isRemovable)
    }

    @objc private func removeClicked(_ sender: Any?) {
        onRemove?()
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

    override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? {
        guard isRemovable else { return nil }
        return [NSAccessibilityCustomAction(name: "Remove from History") { [weak self] in
            self?.onRemove?()
            return true
        }]
    }
}
