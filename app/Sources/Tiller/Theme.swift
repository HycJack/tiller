import AppKit

/// The values the chrome shares, so a hover, a corner or a caption reads the
/// same in the tab strip, the start page, the popovers and the agent panel.
/// Under Tiller's own theme, colors stay semantic system colors with an
/// alpha on top, so they follow light and dark mode on their own, and the
/// accent is the one chosen in Settings. Under Claude or Qoder they come from
/// that theme's `Palette`. Either way they are read each time they are drawn.
enum Theme {
    // MARK: Colors

    /// The window, and the sidebar, toolbar and agent panel on it.
    nonisolated static let chrome = themed(.windowBackgroundColor) { $0.chrome }
    /// The start page, and a page that hasn't painted yet.
    nonisolated static let background = themed(.windowBackgroundColor) { $0.background }
    /// The face of a field over the chrome, such as the message field.
    nonisolated static let surface = themed(.controlBackgroundColor) { $0.surface }
    nonisolated static let text = themed(.labelColor) { $0.text }
    nonisolated static let secondaryText = themed(.secondaryLabelColor) { $0.muted }
    nonisolated static let tertiaryText = themed(.tertiaryLabelColor) { $0.faint }
    nonisolated static let danger = themed(.systemRed) { $0.danger }
    nonisolated static let warning = themed(.systemOrange) { $0.warning }
    nonisolated static let success = themed(.systemGreen) { $0.success }
    /// A solid accent to fill a button, as Send, deeper than `accentColor`
    /// where white on that would be hard to read.
    nonisolated static let accentFill = themed(accentColor(alpha: 1)) { $0.fill }
    /// The glyph or text on `accentFill`.
    nonisolated static let accentFillText = themed(.white) { $0.fillText }

    /// `system` under Tiller's theme, else `pick` of the palette, for the
    /// appearance it is drawn in.
    private nonisolated static func themed(_ system: NSColor, _ pick: @escaping @Sendable (Palette) -> NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            if let palette = Palette.current(for: appearance) { return pick(palette) }
            var color = system
            appearance.performAsCurrentDrawingAppearance { color = system.usingColorSpace(.sRGB) ?? system }
            return color
        }
    }

    // MARK: Fills

    /// Alphas of `labelColor` for a surface's resting, hovered, pressed and
    /// selected states.
    enum Fill {
        static let rest: CGFloat = 0.05
        static let hover: CGFloat = 0.08
        static let pressed: CGFloat = 0.12
        static let selected: CGFloat = 0.11
    }

    /// Alphas of `controlAccentColor` for tinted surfaces.
    enum Accent {
        /// A badge or a light wash.
        static let soft: CGFloat = 0.14
        /// The selected row of a list.
        static let selected: CGFloat = 0.18
        /// The selected row under the mouse.
        static let selectedHover: CGFloat = 0.26
        /// The user's message bubble.
        static let bubble: CGFloat = 0.2
        /// The outline of a selected surface.
        static let outline: CGFloat = 0.45
    }

    /// `text` at `alpha`, resolved whenever it is drawn. Made once for each
    /// alpha, as hovers ask for the same few all the time.
    @MainActor
    static func fill(_ alpha: CGFloat) -> NSColor {
        if let color = fills[alpha] { return color }
        let color = text.dynamic(alpha: alpha)
        fills[alpha] = color
        return color
    }

    @MainActor private static var fills: [CGFloat: NSColor] = [:]

    /// The fill for a row or tile in the given state, or clear at rest.
    @MainActor
    static func fill(hovered: Bool, pressed: Bool = false, selected: Bool = false) -> NSColor {
        if pressed { return fill(Fill.pressed) }
        if selected { return fill(Fill.selected) }
        if hovered { return fill(Fill.hover) }
        return .clear
    }

    /// The accent chosen in Settings, or the theme's own, resolved whenever
    /// it is drawn, so a color set once still follows a change. Nonisolated,
    /// so it can resolve wherever AppKit asks for it.
    nonisolated static let accentColor = accentColor(alpha: 1)

    /// The accent at `alpha`, made once for each alpha. It still follows a
    /// change of accent, being resolved whenever it is drawn.
    @MainActor
    static func accent(_ alpha: CGFloat) -> NSColor {
        if let color = accents[alpha] { return color }
        let color = accentColor(alpha: alpha)
        accents[alpha] = color
        return color
    }

    @MainActor private static var accents: [CGFloat: NSColor] = [:]

    private nonisolated static func accentColor(alpha: CGFloat) -> NSColor {
        NSColor(name: nil) { appearance in
            var color = NSColor.controlAccentColor
            if let palette = Palette.current(for: appearance) {
                color = palette.accent
            } else {
                appearance.performAsCurrentDrawingAppearance {
                    color = Settings.accentTheme.color.usingColorSpace(.sRGB) ?? color
                }
            }
            return alpha < 1 ? color.withAlphaComponent(alpha) : color
        }
    }

    /// The solid fill of a highlighted row: the system's, the chosen accent
    /// or the theme's button fill.
    static var selectionColor: NSColor {
        if Settings.theme != .tiller { return accentFill }
        return Settings.accentTheme == .system ? .selectedContentBackgroundColor : accentColor
    }

    /// Text on `selectionColor`.
    static var selectionText: NSColor {
        Settings.theme == .tiller ? .alternateSelectedControlTextColor : accentFillText
    }

    /// A one-point line between surfaces.
    nonisolated static let hairline = themed(.separatorColor) { $0.border }

    // MARK: Shape

    enum Radius {
        /// Tables, boxes and badges.
        static let small: CGFloat = 6
        /// Rows in lists, tool rows, code blocks and thumbnails.
        static let row: CGFloat = 8
        /// Cards: the page, error boxes.
        static let card: CGFloat = 10
        /// Floating plates, bubbles and chips.
        static let plate: CGFloat = 14
        /// The start page's site tiles.
        static let tile: CGFloat = 18
    }

    /// The address bar's and find bar's round-ended field.
    enum Capsule {
        static let height: CGFloat = 30
        static let radius: CGFloat = height / 2
    }

    static let hairlineWidth: CGFloat = 1

    // MARK: Type

    enum FontSize {
        /// Captions, counts and uppercase headers.
        static let caption: CGFloat = 11
        /// Secondary lines: URLs, dates, hints.
        static let secondary: CGFloat = 12
        /// Row titles and messages.
        static let body: CGFloat = 13
        /// Panel titles.
        static let title: CGFloat = 15
    }

    /// The uppercase header of a popover section, such as DOWNLOADS or CHATS.
    static func sectionHeader(_ text: String) -> NSAttributedString {
        NSAttributedString(string: text.uppercased(), attributes: [
            .font: NSFont.systemFont(ofSize: FontSize.caption, weight: .semibold),
            .foregroundColor: NSColor.secondaryLabelColor,
            .kern: 0.6,
        ])
    }

    // MARK: Icons

    /// SF Symbol point sizes.
    enum Symbol {
        /// Beside text in a field or a row.
        static let inline: CGFloat = 11
        /// A row's leading icon.
        static let row: CGFloat = 12
        /// A toolbar or bar button.
        static let bar: CGFloat = 14
        /// A panel's primary action, or an empty state.
        static let hero: CGFloat = 22
    }

    /// Square sizes of icon-only buttons.
    enum ButtonSize {
        /// Beside text, as in the find bar.
        static let inline: CGFloat = 22
        /// In a bar of buttons.
        static let bar: CGFloat = 26
    }

    /// An SF Symbol image at a shared size. Made once for each name, size,
    /// weight and label, as rows ask for the same few over and over; an
    /// image is shared, so it isn't changed after.
    @MainActor
    static func symbol(_ name: String, size: CGFloat, weight: NSFont.Weight = .medium, label: String? = nil) -> NSImage? {
        let key = SymbolKey(name: name, size: size, weight: weight.rawValue, label: label)
        if let image = symbolCache[key] { return image }
        let image = NSImage(systemSymbolName: name, accessibilityDescription: label)?
            .withSymbolConfiguration(.init(pointSize: size, weight: weight))
        symbolCache[key] = image
        return image
    }

    private struct SymbolKey: Hashable {
        let name: String
        let size: CGFloat
        let weight: CGFloat
        let label: String?
    }

    @MainActor private static var symbolCache: [SymbolKey: NSImage?] = [:]

    /// An icon-only button with no bezel, as in bars and rows. `label` is
    /// both the tooltip and what VoiceOver reads.
    @MainActor
    static func iconButton(_ name: String, label: String, size: CGFloat = Symbol.bar, frame: CGFloat = ButtonSize.bar) -> NSButton {
        let button = HoverButton()
        button.image = symbol(name, size: size, label: label)
        button.imagePosition = .imageOnly
        button.isBordered = false
        button.bezelStyle = .accessoryBarAction
        button.contentTintColor = .secondaryLabelColor
        button.toolTip = label
        button.setAccessibilityLabel(label)
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: frame),
            button.heightAnchor.constraint(equalToConstant: frame),
        ])
        return button
    }

    /// The one close glyph, for tabs, bars and chips.
    @MainActor
    static func closeImage(size: CGFloat = 9, label: String) -> NSImage? {
        symbol("xmark", size: size, weight: .bold, label: label)
    }

    // MARK: Layout

    enum RowHeight {
        /// A suggestion.
        static let compact: CGFloat = 30
        /// A tab in the sidebar, a closed tab on the start page.
        static let standard: CGFloat = 34
        /// Two lines: a download, a chat in history.
        static let twoLine: CGFloat = 48
    }

    enum Padding {
        static let tight: CGFloat = 8
        static let row: CGFloat = 10
        static let panel: CGFloat = 12
        static let section: CGFloat = 14
        static let sheet: CGFloat = 20
    }

    /// The width of popovers hanging off the toolbar and the agent bar.
    static let popoverWidth: CGFloat = 320
    /// The height a list keeps for an empty-state label.
    static let emptyListHeight: CGFloat = 56
    /// A busy indicator's dot.
    static let busyDot: CGFloat = 6

    // MARK: Motion

    enum Duration {
        /// A fill fading under the mouse.
        static let quick: TimeInterval = 0.12
        /// The default ease for layer changes.
        static let standard: TimeInterval = 0.15
        /// Tabs sliding to a new order.
        static let slide: TimeInterval = 0.2
        /// A panel opening or closing.
        static let panel: TimeInterval = 0.25
    }

    // MARK: Appearance

    /// Sets light or dark from Settings for the whole app, which Chromium
    /// passes on to pages as `prefers-color-scheme`.
    @MainActor
    static func applyAppearance() {
        NSApp.appearance = Settings.appearance.appearance
    }

    /// Redraws every window after the accent changes. Views pick their
    /// colors in `updateLayer` or `draw`, which a change of accent alone
    /// would not call again, unlike a change of appearance.
    @MainActor
    static func redrawAll() {
        func mark(_ view: NSView) {
            view.needsDisplay = true
            view.subviews.forEach(mark)
        }
        for window in NSApp.windows {
            if let frame = window.contentView?.superview { mark(frame) } else if let content = window.contentView { mark(content) }
        }
    }

    // MARK: Accessibility

    static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    static var increaseContrast: Bool { NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast }
    static var reduceTransparency: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency }

    /// The outline a filled selection gets under Increase Contrast, where a
    /// faint fill alone would not show.
    @MainActor
    static func selectionOutline(selected: Bool) -> NSColor {
        increaseContrast && selected ? fill(Accent.outline) : .clear
    }
}

/// The colors of a theme other than Tiller's own, for a light or a dark
/// window. The values are Mayoi's Claude and Qoder themes.
struct Palette: Sendable {
    /// The window, and the sidebar, toolbar and agent panel on it.
    let chrome: NSColor
    /// The start page.
    let background: NSColor
    let border: NSColor
    let text: NSColor
    let muted: NSColor
    let faint: NSColor
    /// For marks on the chrome: selections, dots, links.
    let accent: NSColor
    /// The accent as a button's background, under `fillText`.
    let fill: NSColor
    let fillText: NSColor
    let danger: NSColor
    let warning: NSColor
    let success: NSColor
    /// The face of a field.
    let surface: NSColor

    /// The palette of the theme chosen in Settings, for `appearance`, or nil
    /// under Tiller's own theme.
    nonisolated static func current(for appearance: NSAppearance) -> Palette? {
        let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return of(Settings.theme, dark: dark)
    }

    nonisolated static func of(_ theme: ChromeTheme, dark: Bool) -> Palette? {
        switch theme {
        case .tiller: nil
        case .claude: dark ? claudeDark : claudeLight
        case .qoder: dark ? qoderDark : qoderLight
        }
    }

    /// Anthropic's ivory and near-black, with a deeper orange for marks on a
    /// light ground.
    static let claudeLight = Palette(
        chrome: hex(0xf0eee6), background: hex(0xfaf9f5), border: hex(0xe3dfd3),
        text: hex(0x141413), muted: hex(0x6b675f), faint: hex(0x938d82),
        accent: hex(0xc96442), fill: hex(0xb8573a), fillText: hex(0xffffff),
        danger: hex(0xbf4d3a), warning: hex(0xb5791f), success: hex(0x5e8a3a),
        surface: hex(0xffffff)
    )

    /// Anthropic's warm near-black and cloud, with Claude's orange. White on
    /// that orange reads at 3:1, so buttons take a deeper one, at 4.6:1.
    static let claudeDark = Palette(
        chrome: hex(0x191918), background: hex(0x1f1e1d), border: hex(0x2e2c2a),
        text: hex(0xe8e6dc), muted: hex(0xa39e93), faint: hex(0x75716a),
        accent: hex(0xd97757), fill: hex(0xb8573a), fillText: hex(0xffffff),
        danger: hex(0xe8705f), warning: hex(0xe3b25f), success: hex(0x7ba05b),
        surface: hex(0x262523)
    )

    /// Qoder's Forest Light: white, grey with a hint of green, and the forest
    /// green of its buttons.
    static let qoderLight = Palette(
        chrome: hex(0xf2f4f2), background: hex(0xffffff), border: hex(0xe3e6e3),
        text: hex(0x141414), muted: hex(0x636261), faint: hex(0x838280),
        accent: hex(0x4b6f5a), fill: hex(0x4b6f5a), fillText: hex(0xfdfdfd),
        danger: hex(0xc9363e), warning: hex(0xb77a0a), success: hex(0x579b6e),
        surface: hex(0xffffff)
    )

    /// Qoder's Forest Dark: greys with a little green, a light green for
    /// marks, and a deeper one for buttons, with a near-black label at 5.9:1.
    static let qoderDark = Palette(
        chrome: hex(0x242624), background: hex(0x191b1a), border: hex(0x363c37),
        text: hex(0xd9dcd9), muted: hex(0x949d96), faint: hex(0x6b736d),
        accent: hex(0x8ee5a1), fill: hex(0x4d9c61), fillText: hex(0x080807),
        danger: hex(0xff6b70), warning: hex(0xfaad14), success: hex(0x73cd94),
        surface: hex(0x222523)
    )

    private static func hex(_ value: UInt32) -> NSColor {
        NSColor(
            srgbRed: CGFloat((value >> 16) & 0xff) / 255, green: CGFloat((value >> 8) & 0xff) / 255,
            blue: CGFloat(value & 0xff) / 255, alpha: 1
        )
    }
}

/// Runs `changes` to layer-backed views so their layers ease to the new
/// values over `duration`, instead of snapping as they do by default. Under
/// Reduce Motion the change lands at once.
@MainActor
func withEasing(_ duration: TimeInterval = Theme.Duration.standard, _ changes: () -> Void) {
    NSAnimationContext.runAnimationGroup { context in
        context.duration = Theme.reduceMotion ? 0 : duration
        context.allowsImplicitAnimation = true
        context.timingFunction = CAMediaTimingFunction(name: .easeOut)
        changes()
    }
}

/// Fades `view` to alpha 0 over `duration`, at once under Reduce Motion,
/// then runs `done`, which takes the view away. A caller that may show the
/// view again meanwhile checks in `done` that it is still meant to go.
@MainActor
func fadeOut(_ view: NSView, _ duration: TimeInterval = Theme.Duration.standard, then done: @escaping @MainActor () -> Void) {
    view.fadeAlpha(to: 0, duration: duration, then: done)
}

extension NSView {
    /// Shows or hides the view. Coming into view in a window it fades in to
    /// `alpha` rather than popping; it hides at once, so a view taking
    /// another's place never overlaps it, unless `fadesOut`. Already shown,
    /// it eases to a new `alpha`. Before the view is in a window, or under
    /// Reduce Motion, the change lands at once. Calling it again with the
    /// same state does nothing, so it is cheap on an update path.
    @MainActor
    func setShown(_ shown: Bool, alpha: CGFloat = 1, fadesOut: Bool = false, duration: TimeInterval = Theme.Duration.quick) {
        let animates = window != nil && !Theme.reduceMotion
        // Where a fade under way has got to.
        let current = layer?.presentation()?.opacity
        guard shown else {
            guard !isHidden else { return }
            guard fadesOut, animates else { isHidden = true; return }
            // Already fading out.
            guard alphaValue != 0 else { return }
            fadeAlpha(to: 0, from: current, duration: duration) { [weak self] in
                // Shown again meanwhile, it eased back to its alpha.
                guard let self, self.alphaValue == 0 else { return }
                self.isHidden = true
            }
            return
        }
        guard animates else {
            isHidden = false
            alphaValue = alpha
            return
        }
        let from: Float
        if isHidden {
            from = 0
            isHidden = false
        } else if alphaValue == alpha {
            return
        } else {
            from = current ?? Float(alphaValue)
        }
        fadeAlpha(to: alpha, from: from, duration: duration)
    }

    /// Sets `alphaValue` to `to` and eases the layer there from `from`, or
    /// from wherever it shows now, with an animation of its own: AppKit's
    /// animator doesn't fade a view without a layer of its own, such as one
    /// in the toolbar or the sidebar. Before the view is in a window, or
    /// under Reduce Motion, it lands at once. `done` runs once it is there.
    @MainActor
    func fadeAlpha(
        to: CGFloat, from: Float? = nil, duration: TimeInterval = Theme.Duration.quick,
        then done: (@MainActor () -> Void)? = nil
    ) {
        let start = from ?? layer?.presentation()?.opacity ?? Float(alphaValue)
        guard window != nil, !Theme.reduceMotion else {
            alphaValue = to
            done?()
            return
        }
        wantsLayer = true
        alphaValue = to
        guard let layer else { done?(); return }
        CATransaction.begin()
        if let done { CATransaction.setCompletionBlock { MainActor.assumeIsolated { done() } } }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = start
        fade.toValue = Float(to)
        fade.duration = duration
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(fade, forKey: "fade")
        CATransaction.commit()
    }

    /// Fades the view's layer up from `opacity` to full, after `delay`,
    /// without touching `alphaValue`, so nothing that sets that meanwhile
    /// cuts it short. Nothing under Reduce Motion.
    @MainActor
    func fadeUp(from opacity: Float = 0, delay: TimeInterval = 0, duration: TimeInterval = Theme.Duration.panel) {
        guard !Theme.reduceMotion, window != nil else { return }
        wantsLayer = true
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = opacity
        fade.toValue = 1
        fade.beginTime = CACurrentMediaTime() + delay
        fade.duration = duration
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        fade.fillMode = .backwards
        layer?.add(fade, forKey: "fadeUp")
    }

    /// A small pop as the view's layer appears or changes to mark a moment,
    /// such as a check after Copy: it scales up from `from` with a little
    /// overshoot. Nothing under Reduce Motion.
    @MainActor
    func pop(from scale: CGFloat = 0.6, duration: TimeInterval = Theme.Duration.slide) {
        guard !Theme.reduceMotion, window != nil, let layer else { return }
        // Scale about the middle, without moving the view: AppKit puts the
        // anchor at the corner and owns the layer's position.
        let bounds = layer.bounds
        let animation = CAKeyframeAnimation(keyPath: "transform")
        let center = CATransform3DMakeTranslation(bounds.midX, bounds.midY, 0)
        func scaled(_ s: CGFloat) -> NSValue {
            var t = CATransform3DScale(center, s, s, 1)
            t = CATransform3DTranslate(t, -bounds.midX, -bounds.midY, 0)
            return NSValue(caTransform3D: t)
        }
        animation.values = [scaled(scale), scaled(1.08), scaled(1)]
        animation.keyTimes = [0, 0.6, 1]
        animation.timingFunctions = [CAMediaTimingFunction(name: .easeOut), CAMediaTimingFunction(name: .easeInEaseOut)]
        animation.duration = duration
        layer.add(animation, forKey: "pop")
    }
}

extension NSView {
    /// Adds an area that reports the mouse entering and leaving the view, if
    /// it has none yet. With `.inVisibleRect` it follows the visible part on
    /// its own, so it needn't be made again on every scroll step, and the
    /// areas AppKit keeps, such as the tooltip's, are left alone. Call it
    /// from `updateTrackingAreas`.
    @MainActor
    func addHoverArea(_ options: NSTrackingArea.Options) {
        guard !trackingAreas.contains(where: { $0.userInfo?[Self.hoverAreaKey] != nil }) else { return }
        addTrackingArea(NSTrackingArea(
            rect: .zero, options: options.union([.mouseEnteredAndExited, .inVisibleRect]), owner: self,
            userInfo: [Self.hoverAreaKey: true]))
    }

    private static let hoverAreaKey = "TillerHoverArea"
}

extension NSMenu {
    /// Pops the menu up with its bottom edge just above `view`, as for a
    /// control along the window's bottom, where a menu below it would be
    /// pushed up to cover it.
    @MainActor
    func popUp(above view: NSView) {
        let height = size.height
        let y = view.isFlipped ? view.bounds.minY - 4 - height : view.bounds.maxY + 4 + height
        popUp(positioning: nil, at: NSPoint(x: 0, y: y), in: view)
    }
}

/// A borderless button that shows a faint plate under the mouse and a darker
/// one while pressed, as rows and tabs do, so a small icon target still
/// answers the pointer. The button's cell draws over the plate as usual.
class HoverButton: NSButton {
    /// The plate's corner radius; half the side makes it round.
    var plateRadius = Theme.Radius.small {
        didSet { layer?.cornerRadius = plateRadius }
    }

    /// The `labelColor` alpha of the plate at rest, for a button with a
    /// title that should read as one before the mouse reaches it. Clear by default.
    var restFill: CGFloat = 0 {
        didSet { updatePlate() }
    }

    private var isHovered = false {
        didSet { if isHovered != oldValue { updatePlate() } }
    }
    private var isPressed = false {
        didSet { if isPressed != oldValue { updatePlate() } }
    }

    override var isEnabled: Bool {
        didSet { updatePlate() }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = plateRadius
        layer?.cornerCurve = .continuous
    }

    required init?(coder: NSCoder) { fatalError() }

    private func updatePlate() {
        let fill: NSColor
        if !isEnabled {
            fill = .clear
        } else if isHovered || isPressed {
            fill = Theme.fill(hovered: isHovered, pressed: isPressed)
        } else {
            fill = restFill > 0 ? Theme.fill(restFill) : .clear
        }
        withEasing(Theme.Duration.quick) { layer?.backgroundColor = fill.layerColor }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updatePlate()
    }

    private var hoverArea: NSTrackingArea?

    // Only its own area is replaced: the others are AppKit's, such as the
    // tooltip's.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(
            rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self)
        addTrackingArea(area)
        hoverArea = area
    }

    // Its own area's events stop here. Passed on, they would reach the row
    // or tab the button sits in, which would take the exit for its own and
    // drop its hover with the mouse still inside it.
    override func mouseEntered(with event: NSEvent) {
        guard event.trackingArea === hoverArea else { return super.mouseEntered(with: event) }
        isHovered = true
    }

    override func mouseExited(with event: NSEvent) {
        guard event.trackingArea === hoverArea else { return super.mouseExited(with: event) }
        isHovered = false
    }

    // `super.mouseDown` tracks the click until the mouse goes up.
    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return super.mouseDown(with: event) }
        isPressed = true
        super.mouseDown(with: event)
        isPressed = false
        isHovered = isMouseInside
    }

    // A hidden view gets no exit event, so the plate is dropped on hiding and
    // put back on showing only if the mouse is still there.
    override func viewDidHide() {
        super.viewDidHide()
        isHovered = false
        isPressed = false
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        isHovered = isMouseInside
    }

    private var isMouseInside: Bool {
        guard let window else { return false }
        return bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil))
    }
}

extension NSColor {
    /// This color at `alpha`, still following light and dark.
    /// `withAlphaComponent` fixes a system color to whichever appearance is
    /// current when it is called, which a forced light or dark then misses.
    func dynamic(alpha: CGFloat) -> NSColor {
        NSColor(name: nil) { appearance in
            var color = self
            appearance.performAsCurrentDrawingAppearance { color = self.withAlphaComponent(alpha) }
            return color
        }
    }

    /// The color for a layer, resolved for the app's appearance. A plain
    /// `cgColor` resolves for whichever appearance is current, and outside
    /// `updateLayer` and `draw` that is the system's, which differs from the
    /// windows' while Settings forces light or dark: a hover or selection
    /// fill set from a mouse event would come out in the wrong shade.
    @MainActor var layerColor: CGColor {
        var color: CGColor?
        NSApp.effectiveAppearance.performAsCurrentDrawingAppearance { color = self.cgColor }
        return color ?? cgColor
    }
}

extension NSFont {
    /// The same font in the rounded design, where the system has one.
    var rounded: NSFont {
        fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: pointSize) } ?? self
    }
}
