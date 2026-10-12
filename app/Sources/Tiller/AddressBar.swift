import AppKit

/// A glass capsule holding a lock for secure pages, the address field
/// and, at the end, the zoom and a key button that fills a saved login. It
/// is a titlebar accessory under the tabs, or a toolbar item when the tabs
/// are in the sidebar. While a page loads, the capsule fills with a faint
/// tint from the left, as in Safari.
final class AddressBarView: NSView {
    let field = AddressField()
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

    private let statusIcon = NSImageView()
    /// The symbol `statusIcon` shows, so it is only made when it changes.
    private var statusSymbol = ""
    /// Whether the user is typing, when the icon says what Return would do.
    private var isEditing = false
    private let glass = GlassView()
    private let progressFill = ProgressTintView()
    /// The share of the capsule's width the load tint covers, kept so the
    /// tint follows the capsule when it resizes.
    private var progressFraction: CGFloat = 0
    private var capsuleLeading: NSLayoutConstraint!
    private var capsuleTrailing: NSLayoutConstraint!
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

        statusIcon.contentTintColor = .secondaryLabelColor
        statusIcon.imageScaling = .scaleNone

        keyButton.bezelStyle = .accessoryBarAction
        keyButton.isBordered = false
        keyButton.imagePosition = .imageOnly
        keyButton.image = Theme.symbol("key.fill", size: Theme.Symbol.inline, label: "Fill Password")
        keyButton.contentTintColor = .secondaryLabelColor
        keyButton.toolTip = "Fill Saved Password"
        keyButton.isHidden = true

        zoomButton.bezelStyle = .accessoryBarAction
        zoomButton.isBordered = false
        zoomButton.font = .monospacedDigitSystemFont(ofSize: Theme.FontSize.caption, weight: .medium)
        zoomButton.contentTintColor = .secondaryLabelColor
        zoomButton.toolTip = "Actual Size"
        zoomButton.isHidden = true

        // Hidden buttons give their room to the field.
        let buttons = NSStackView(views: [zoomButton, keyButton])
        buttons.spacing = 2
        buttons.setContentHuggingPriority(.required, for: .horizontal)

        let content = CapsuleContentView()
        content.layer?.cornerRadius = 15
        content.layer?.cornerCurve = .continuous
        content.layer?.masksToBounds = true
        progressFill.alphaValue = 0
        content.addSubview(progressFill)
        for view in [statusIcon, field, buttons] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        glass.contentView = content
        glass.cornerRadius = 15
        glass.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glass)

        capsuleLeading = glass.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset)
        capsuleTrailing = glass.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset)
        NSLayoutConstraint.activate([
            capsuleLeading,
            capsuleTrailing,
            glass.centerYAnchor.constraint(equalTo: centerYAnchor),
            glass.heightAnchor.constraint(equalToConstant: 30),

            statusIcon.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 10),
            statusIcon.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            statusIcon.widthAnchor.constraint(equalToConstant: 16),
            field.leadingAnchor.constraint(equalTo: statusIcon.trailingAnchor, constant: 6),
            field.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            field.trailingAnchor.constraint(equalTo: buttons.leadingAnchor, constant: -4),
            buttons.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -8),
            buttons.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            // Plates the size of the find bar's buttons in the same capsule.
            keyButton.widthAnchor.constraint(equalToConstant: Theme.ButtonSize.inline),
            keyButton.heightAnchor.constraint(equalToConstant: Theme.ButtonSize.inline),
            zoomButton.heightAnchor.constraint(equalToConstant: Theme.ButtonSize.inline),
        ])
        content.onResize = { [weak self] in self?.resizeProgress() }
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

    /// A lock for https, a warning for http, and a magnifying glass where
    /// there is no page yet or while typing, when Return searches or goes
    /// to what was typed rather than the page shown before.
    private func showStatus(of url: String) {
        let (symbol, description) = if isEditing {
            ("magnifyingglass", "Search")
        } else if url.hasPrefix("https://") {
            ("lock.fill", "Secure")
        } else if url.hasPrefix("http://") {
            ("exclamationmark.triangle", "Not Secure")
        } else if url.isEmpty || url == "about:blank" {
            ("magnifyingglass", "Search")
        } else {
            ("globe", "Page")
        }
        if statusSymbol != symbol {
            statusSymbol = symbol
            statusIcon.image = Theme.symbol(symbol, size: Theme.Symbol.inline, label: description)
        }
        statusIcon.toolTip = !isEditing && url.hasPrefix("http") ? description : nil
    }
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

/// The address field. At rest it shows the whole URL with everything but the
/// site dimmed; a click selects it all, so typing replaces it.
final class AddressField: NSTextField {
    var url = "" {
        didSet { if !isEditing { showURL() } }
    }

    /// Called with true when typing starts and false when it ends.
    var onEditingChanged: ((Bool) -> Void)?

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

    /// The first click selects the whole URL, as in Safari. Left to the
    /// field editor, it would put the caret where the click landed.
    override func mouseDown(with event: NSEvent) {
        guard isEditing else {
            window?.makeFirstResponder(self)
            // Becoming first responder on a click can hand the click to the
            // field editor, which puts the caret where it landed, so select
            // now and again once that has settled.
            currentEditor()?.selectAll(nil)
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { self?.currentEditor()?.selectAll(nil) }
            }
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

    private func showURL() {
        let shown = url == "about:blank" ? "" : url
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let text = NSMutableAttributedString(string: shown, attributes: [
            .font: font ?? .systemFont(ofSize: Theme.FontSize.body),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: paragraph,
        ])
        text.addAttribute(.foregroundColor, value: NSColor.labelColor, range: Self.siteRange(in: shown))
        attributedStringValue = text
        toolTip = shown.isEmpty ? nil : shown
    }

    /// The host and port of a URL with `://`, else all of it.
    static func siteRange(in url: String) -> NSRange {
        let whole = NSRange(url.startIndex..., in: url)
        guard let scheme = url.range(of: "://") else { return whole }
        let end = url[scheme.upperBound...].firstIndex { "/?#".contains($0) } ?? url.endIndex
        return NSRange(scheme.upperBound..<end, in: url)
    }
}

/// Turns address bar input into a URL: a URL if it looks like one, else a
/// search with the engine the profile's `settings` chose.
enum AddressInput {
    static func url(for input: String, settings: ProfileSettings) -> String {
        if input.contains("://") || input.hasPrefix("about:") || input.hasPrefix("data:") {
            return input
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
