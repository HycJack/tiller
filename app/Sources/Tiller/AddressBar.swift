import AppKit

/// A glass capsule holding the site's button, which says whether the
/// connection is secure and opens the site's settings, the address field
/// and, at the end, the zoom and a key button that fills a saved login. It
/// is a titlebar accessory under the tabs, or a toolbar item when the tabs
/// are in the sidebar. While a page loads, the capsule fills with a faint
/// tint from the left, as in Safari.
final class AddressBarView: NSView {
    let field = AddressField()
    /// Shows whether the page's connection is secure, and opens the site's
    /// information when clicked.
    let siteButton: NSButton = HoverButton()
    let keyButton: NSButton = HoverButton()
    /// The page's zoom, when it isn't 100%. Clicking it resets.
    let zoomButton: NSButton = HoverButton()
    /// Room left at each end of the capsule.
    var inset: CGFloat = 12 {
        didSet {
            capsuleLeading.constant = inset
            capsuleTrailing.constant = -inset
        }
    }

    /// The symbol `siteButton` shows, so it is only made when it changes.
    private var statusSymbol = ""
    /// The URL the status was last shown for.
    private var statusURL = ""
    /// Whether the user is typing, when the icon says what Return would do.
    private var isEditing = false
    private let glass = GlassView()
    private let progressFill = ProgressTintView()
    /// The share of the capsule's width the load tint covers, kept so the
    /// tint follows the capsule when it resizes.
    private var progressFraction: CGFloat = 0
    private var capsuleLeading: NSLayoutConstraint!
    private var capsuleTrailing: NSLayoutConstraint!
    /// Room between the site button and the field, more when the button
    /// has words.
    private var fieldLeading: NSLayoutConstraint!
    /// Whether the tint is tracking a load, as opposed to finishing or hidden.
    private var showsLoad = false
    /// The capsule, for placing the suggestion list under it.
    var capsule: NSView { glass }

    override init(frame: NSRect) {
        super.init(frame: frame)

        field.placeholderString = "Search or enter website"
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: Theme.FontSize.body)
        field.lineBreakMode = .byTruncatingTail
        field.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        // Only Return navigates. Leaving the field must not load what it shows.
        field.cell?.sendsActionOnEndEditing = false

        siteButton.bezelStyle = .accessoryBarAction
        siteButton.isBordered = false
        siteButton.imagePosition = .imageLeading
        siteButton.imageHugsTitle = true
        siteButton.font = .systemFont(ofSize: Theme.FontSize.secondary, weight: .medium)
        siteButton.contentTintColor = Theme.secondaryText
        (siteButton as? HoverButton)?.plateRadius = Theme.ButtonSize.inline / 2
        siteButton.setContentHuggingPriority(.required, for: .horizontal)
        siteButton.setContentCompressionResistancePriority(.required, for: .horizontal)

        keyButton.bezelStyle = .accessoryBarAction
        keyButton.isBordered = false
        keyButton.imagePosition = .imageOnly
        keyButton.image = Theme.symbol("key.fill", size: Theme.Symbol.inline, label: "Fill Password")
        keyButton.contentTintColor = Theme.secondaryText
        keyButton.toolTip = "Fill Saved Password"
        keyButton.isHidden = true

        zoomButton.bezelStyle = .accessoryBarAction
        zoomButton.isBordered = false
        zoomButton.font = .monospacedDigitSystemFont(ofSize: Theme.FontSize.caption, weight: .medium)
        zoomButton.contentTintColor = Theme.secondaryText
        zoomButton.toolTip = "Actual Size"
        zoomButton.isHidden = true

        // Hidden buttons give their room to the field.
        let buttons = NSStackView(views: [zoomButton, keyButton])
        buttons.spacing = 2
        buttons.setContentHuggingPriority(.required, for: .horizontal)

        let content = CapsuleContentView()
        content.layer?.cornerRadius = Theme.Capsule.radius
        content.layer?.cornerCurve = .continuous
        content.layer?.masksToBounds = true
        progressFill.alphaValue = 0
        content.addSubview(progressFill)
        for view in [siteButton, field, buttons] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        glass.contentView = content
        glass.cornerRadius = Theme.Capsule.radius
        glass.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glass)

        capsuleLeading = glass.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset)
        capsuleTrailing = glass.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset)
        fieldLeading = field.leadingAnchor.constraint(equalTo: siteButton.trailingAnchor, constant: 0)
        NSLayoutConstraint.activate([
            capsuleLeading,
            capsuleTrailing,
            glass.centerYAnchor.constraint(equalTo: centerYAnchor),
            glass.heightAnchor.constraint(equalToConstant: Theme.Capsule.height),

            // The button's icon sits where a 16-point icon 10 from the edge
            // would, with the text 6 after it, where the suggestions line up.
            siteButton.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 4),
            siteButton.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            siteButton.heightAnchor.constraint(equalToConstant: Theme.ButtonSize.inline),
            siteButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 28),
            fieldLeading,
            field.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            field.trailingAnchor.constraint(equalTo: buttons.leadingAnchor, constant: -4),
            buttons.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -8),
            buttons.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            // Plates the size of the find bar's buttons in the same capsule.
            keyButton.widthAnchor.constraint(equalToConstant: Theme.ButtonSize.inline),
            keyButton.heightAnchor.constraint(equalToConstant: Theme.ButtonSize.inline),
            zoomButton.heightAnchor.constraint(equalToConstant: Theme.ButtonSize.inline),
        ])
        content.onResize = { [weak self] in
            guard let self else { return }
            self.resizeProgress()
            self.showStatus(of: self.statusURL, force: true)
        }
        field.onEditingChanged = { [weak self, weak content] editing in
            guard let self else { return }
            self.isEditing = editing
            content?.isFocused = editing
            self.showStatus(of: self.field.url)
        }
        showStatus(of: "")
    }

    /// Shows the zoom badge for `factor`, or hides it at 100%.
    func showZoom(_ factor: Double) {
        let percent = Int((factor * 100).rounded())
        if percent != 100 { zoomButton.title = "\(percent)%" }
        zoomButton.isHidden = percent == 100
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Moves the load tint to `progress` (0 to 1). When `loading` turns false
    /// the tint runs to the end and fades out. Without `animated`, as when
    /// switching tabs, it jumps straight to the new state.
    func setProgress(_ progress: Double, loading: Bool, animated: Bool = true) {
        // Under Reduce Motion the tint jumps to each state instead of sweeping.
        let animated = animated && !Theme.reduceMotion
        let fraction = min(1, max(0.08, progress))
        let started = loading && !showsLoad
        showsLoad = loading
        if !animated {
            progressFraction = fraction
            progressFill.frame = progressFrame(fraction)
            progressFill.alphaValue = loading ? 1 : 0
        } else if loading {
            if started {
                // A new load starts from the left edge.
                progressFraction = 0
                progressFill.frame = progressFrame(0)
                progressFill.alphaValue = 1
            }
            guard fraction > progressFraction else { return }
            progressFraction = fraction
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Theme.Duration.panel
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                progressFill.animator().frame = progressFrame(fraction)
            }
        } else if progressFill.alphaValue > 0 {
            progressFraction = 1
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Theme.Duration.slide
                progressFill.animator().frame = progressFrame(1)
            } completionHandler: { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, !self.showsLoad else { return }
                    NSAnimationContext.runAnimationGroup { context in
                        context.duration = Theme.Duration.panel
                        self.progressFill.animator().alphaValue = 0
                    }
                }
            }
        }
    }

    /// The load tint's frame at `fraction` of the capsule's current width.
    private func progressFrame(_ fraction: CGFloat) -> NSRect {
        let bounds = progressFill.superview?.bounds ?? .zero
        return NSRect(x: 0, y: 0, width: bounds.width * fraction, height: bounds.height)
    }

    /// Fits the tint to a resized capsule at once, so it neither lags behind
    /// a wider capsule nor gets stuck at the size it had before layout.
    private func resizeProgress() {
        guard progressFill.alphaValue > 0 else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            context.allowsImplicitAnimation = false
            progressFill.frame = progressFrame(progressFraction)
        }
    }

    /// Shows `url` unless the user is typing. Blank pages show the placeholder.
    func show(_ url: String) {
        field.url = url
        showStatus(of: url)
    }

    /// As in Chrome: sliders for https, which open the site's settings, a
    /// warning with "Not Secure" for http, the text left out when the bar
    /// is narrow, and a magnifying glass where there is no page yet or
    /// while typing, when Return searches or goes to what was typed rather
    /// than the page shown before. Only a web page's button can be clicked.
    private func showStatus(of url: String, force: Bool = false) {
        statusURL = url
        let web = !isEditing && (url.hasPrefix("https://") || url.hasPrefix("http://"))
        let (symbol, description) = if isEditing || url.isEmpty || url == "about:blank" {
            ("magnifyingglass", "Search")
        } else if url.hasPrefix("https://") {
            ("slider.horizontal.3", "View Site Information")
        } else if url.hasPrefix("http://") {
            ("exclamationmark.triangle", "Not Secure")
        } else {
            ("info.circle", "Page")
        }
        let notSecure = web && url.hasPrefix("http://")
        let title = notSecure && glass.bounds.width >= Self.chipMinWidth ? "Not Secure" : ""
        guard force || statusSymbol != symbol || siteButton.title != title || siteButton.isEnabled != web else { return }
        if statusSymbol != symbol {
            statusSymbol = symbol
            siteButton.image = Theme.symbol(symbol, size: Theme.Symbol.inline, label: description)
        }
        siteButton.title = title
        fieldLeading.constant = title.isEmpty ? 0 : 4
        siteButton.contentTintColor = notSecure ? Theme.danger : Theme.secondaryText
        siteButton.isEnabled = web
        siteButton.toolTip = web ? (notSecure ? "Not Secure: View Site Information" : description) : nil
        siteButton.setAccessibilityLabel(web ? (notSecure ? "Not Secure, View Site Information" : description) : description)
    }

    /// Below this width the capsule shows the warning without its words.
    private static let chipMinWidth: CGFloat = 420
}

/// The load tint inside the capsule. Its color is set in `updateLayer`, so it
/// follows light and dark mode and the accent color, which a layer color set
/// once would not.
private final class ProgressTintView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = Theme.accent(Theme.Accent.soft).layerColor
    }
}

/// The capsule's content. While the field is being edited it takes a thin
/// accent outline, set in `updateLayer` so it follows the appearance and the
/// accent color. It reports a change of size so the load tint can follow.
private final class CapsuleContentView: NSView {
    var isFocused = false {
        didSet { if isFocused != oldValue { needsDisplay = true } }
    }
    var onResize: (() -> Void)?
    private var laidOutSize = NSSize.zero

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        // Light glass over a light titlebar all but disappears, so at rest
        // the capsule keeps a faint fill and edge to show where to type.
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let width = isFocused || !dark ? Theme.hairlineWidth : 0
        let color = isFocused ? Theme.accent(Theme.Accent.outline) : Theme.fill(0.07)
        let fill = dark || isFocused ? NSColor.clear : Theme.fill(0.03)
        withEasing {
            layer?.borderWidth = width
            layer?.borderColor = color.layerColor
            layer?.backgroundColor = fill.layerColor
        }
    }

    override func layout() {
        super.layout()
        guard bounds.size != laidOutSize else { return }
        laidOutSize = bounds.size
        onResize?()
    }
}

/// The address field. At rest it shows the URL with everything but the site
/// dimmed and, unless `showsFullURL`, without `https://`, `www.` and a lone
/// trailing slash, as Chrome does. Editing shows all of it. A click selects
/// it all, so typing replaces it; a drag selects part of it.
final class AddressField: NSTextField {
    var url = "" {
        // Tabs report the same URL with every title or loading change, and
        // building the text again for it would be wasted. Editing's end
        // shows the URL on its own.
        didSet { if url != oldValue, !isEditing { showURL() } }
    }

    var showsFullURL = false {
        didSet { if showsFullURL != oldValue, !isEditing { showURL() } }
    }

    /// Called with true when typing starts and false when it ends.
    var onEditingChanged: ((Bool) -> Void)?
    /// Called when a click puts the field in editing, after it is selected.
    var onClickFocus: (() -> Void)?
    /// Paste and Go: called with what was on the clipboard.
    var onPasteAndGo: ((String) -> Void)?
    /// Always Show Full URLs was chosen from the menu.
    var onToggleFullURLs: (() -> Void)?

    var isEditing: Bool { currentEditor() != nil }

    override func becomeFirstResponder() -> Bool {
        stringValue = url == "about:blank" ? "" : url
        guard super.becomeFirstResponder() else {
            showURL()
            return false
        }
        currentEditor()?.selectAll(nil)
        onEditingChanged?(true)
        return true
    }

    /// The first click selects the whole URL, as in Chrome and Safari, but
    /// a drag from it selects what it covers. Left to the field editor, a
    /// click would put the caret where it landed.
    override func mouseDown(with event: NSEvent) {
        guard isEditing else {
            window?.makeFirstResponder(self)
            guard let editor = currentEditor() else { return }
            // Tracks the mouse until it goes up, selecting what a drag covers.
            editor.mouseDown(with: event)
            if editor.selectedRange.length == 0 { editor.selectAll(nil) }
            // Becoming first responder on a click can hand the click to the
            // field editor again once things settle, which would put the
            // caret where it landed.
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let editor = self?.currentEditor(), editor.selectedRange.length == 0 else { return }
                    editor.selectAll(nil)
                }
            }
            onClickFocus?()
            return
        }
        super.mouseDown(with: event)
    }

    override func textDidEndEditing(_ notification: Notification) {
        super.textDidEndEditing(notification)
        // Return on input that goes nowhere ends editing only to start it
        // again, so check once things settle.
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.isEditing else { return }
                self.showURL()
                self.onEditingChanged?(false)
            }
        }
    }

    /// Escape: back to the page's URL, still editing.
    func revert() {
        stringValue = url == "about:blank" ? "" : url
        currentEditor()?.selectAll(nil)
    }

    /// While editing, shows `typed` followed by `completion`, which is
    /// selected, so typing on replaces it and Delete takes it away.
    func show(typed: String, completion: String) {
        guard let editor = currentEditor() as? NSTextView else { return }
        editor.string = typed + completion
        editor.setSelectedRange(NSRange(location: typed.utf16.count, length: completion.utf16.count))
    }

    /// While editing, shows `text` with the caret at its end, as when Up and
    /// Down put a suggestion in the field.
    func show(text: String) {
        guard let editor = currentEditor() as? NSTextView else { return }
        editor.string = text
        editor.setSelectedRange(NSRange(location: text.utf16.count, length: 0))
    }

    private func showURL() {
        let shown = url == "about:blank" ? "" : url
        let (text, site) = Self.display(shown, full: showsFullURL)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let attributed = NSMutableAttributedString(string: text, attributes: [
            .font: font ?? .systemFont(ofSize: Theme.FontSize.body),
            .foregroundColor: Theme.secondaryText,
            .paragraphStyle: paragraph,
        ])
        attributed.addAttribute(.foregroundColor, value: Theme.text, range: site)
        attributedStringValue = attributed
        toolTip = shown.isEmpty ? nil : shown
    }

    /// What the field shows at rest for `url`, and the range of its site in
    /// that. Unless `full`, a web page's address leaves out its scheme, a
    /// leading "www." and a trailing slash with nothing after it.
    static func display(_ url: String, full: Bool) -> (text: String, site: NSRange) {
        guard !full, url.hasPrefix("https://") || url.hasPrefix("http://") else { return (url, siteRange(in: url)) }
        var text = HistoryStore.bare(url)
        if text.hasSuffix("/"), text.firstIndex(of: "/") == text.index(before: text.endIndex) { text.removeLast() }
        let end = text.firstIndex { "/?#".contains($0) } ?? text.endIndex
        return (text, NSRange(text.startIndex..<end, in: text))
    }

    /// The host and port of a URL with `://`, else all of it.
    static func siteRange(in url: String) -> NSRange {
        let whole = NSRange(url.startIndex..., in: url)
        guard let scheme = url.range(of: "://") else { return whole }
        let end = url[scheme.upperBound...].firstIndex { "/?#".contains($0) } ?? url.endIndex
        return NSRange(scheme.upperBound..<end, in: url)
    }

    // MARK: Menu

    /// The field editor's menu while editing, with Paste and Go after Paste
    /// and the full URLs choice at the end. The field is its delegate.
    @objc(textView:menu:forEvent:atIndex:)
    func textView(_ textView: NSTextView, menu: NSMenu, for event: NSEvent, at charIndex: Int) -> NSMenu? {
        let paste = menu.items.firstIndex { $0.action == #selector(NSText.paste(_:)) }
        menu.insertItem(pasteAndGoItem(), at: paste.map { $0 + 1 } ?? menu.items.count)
        menu.addItem(.separator())
        menu.addItem(fullURLsItem())
        return menu
    }

    /// At rest, a right-click gets Copy, Paste and Go and the full URLs choice.
    override func menu(for event: NSEvent) -> NSMenu? {
        guard !isEditing else { return super.menu(for: event) }
        let menu = NSMenu()
        let copy = NSMenuItem(title: "Copy", action: #selector(copyURL(_:)), keyEquivalent: "")
        copy.target = self
        copy.isEnabled = !url.isEmpty && url != "about:blank"
        menu.autoenablesItems = false
        menu.addItem(copy)
        menu.addItem(pasteAndGoItem())
        menu.addItem(.separator())
        menu.addItem(fullURLsItem())
        return menu
    }

    private func pasteAndGoItem() -> NSMenuItem {
        // Only the clipboard's types are checked here: reading what is on
        // it would ask for permission on every right-click.
        let item = NSMenuItem(title: "Paste and Go", action: #selector(pasteAndGo(_:)), keyEquivalent: "")
        item.target = self
        item.isEnabled = NSPasteboard.general.availableType(from: [.string, .URL]) != nil
        return item
    }

    private func fullURLsItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Always Show Full URLs", action: #selector(toggleFullURLs(_:)), keyEquivalent: "")
        item.target = self
        item.state = showsFullURL ? .on : .off
        return item
    }

    @objc private func copyURL(_ sender: Any?) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url, forType: .string)
    }

    @objc private func pasteAndGo(_ sender: Any?) {
        let pasteboard = NSPasteboard.general
        let text = (pasteboard.string(forType: .string) ?? pasteboard.string(forType: .URL) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        onPasteAndGo?(text)
    }

    @objc private func toggleFullURLs(_ sender: Any?) {
        onToggleFullURLs?()
    }
}

/// Turns address bar input into a URL: a URL if it looks like one, a file
/// URL for a path on this Mac, else a search with the engine the profile's
/// `settings` chose.
enum AddressInput {
    static func url(for input: String, settings: ProfileSettings) -> String {
        if input.contains("://") || input.hasPrefix("about:") || input.hasPrefix("data:") {
            return input
        }
        // A path may hold spaces, so it is a file whether or not it exists.
        if input.hasPrefix("/") || input.hasPrefix("~/") {
            return URL(fileURLWithPath: (input as NSString).expandingTildeInPath).absoluteString
        }
        let host = input.split(separator: "/", maxSplits: 1).first.map(String.init) ?? input
        // A colon only belongs to a host when a port follows it, so search
        // operators such as `site:example.com` stay searches.
        var name = Substring(host)
        var hasPort = false
        if !host.hasPrefix("["), let colon = host.lastIndex(of: ":") {
            let port = host[host.index(after: colon)...]
            hasPort = !port.isEmpty && port.allSatisfy(\.isASCII) && port.allSatisfy(\.isNumber)
            name = host[..<colon]
        }
        let looksLikeHost = !input.contains(" ") && !name.isEmpty
            && (host.hasPrefix("[") || hasPort || name.contains(".") || name.hasPrefix("localhost"))
        if looksLikeHost {
            let scheme = isLocal(name) ? "http" : "https"
            return "\(scheme)://\(input)"
        }
        return settings.searchURL(for: input)
    }

    /// Localhost and private IPv4 addresses, which seldom serve https.
    private static func isLocal(_ name: Substring) -> Bool {
        if name.hasPrefix("localhost") { return true }
        let parts = name.split(separator: ".", omittingEmptySubsequences: false)
        let octets = parts.compactMap { UInt8($0) }
        guard parts.count == 4, octets.count == 4 else { return false }
        switch (octets[0], octets[1]) {
        case (10, _), (127, _), (192, 168), (172, 16...31): return true
        default: return false
        }
    }
}
