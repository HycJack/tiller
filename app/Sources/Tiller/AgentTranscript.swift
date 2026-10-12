import AppKit

/// A transcript row holding wrapping text, which needs to know the width it
/// gets to report its height.
@MainActor
protocol TranscriptRow: NSView {
    func fit(width: CGFloat)
}

/// The scrolling column of messages. Flipped so rows stack from the top.
final class TranscriptView: NSView {
    private let stack = NSStackView()
    /// The same as the composer's, so messages line up with it.
    private static let inset: CGFloat = 12
    private var lastWidth: CGFloat = 0
    /// The "Thinking…" row while the agent has nothing to show yet.
    private var thinking: ThinkingRowView?

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: Self.inset),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.inset),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.inset),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -Self.inset),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    var isEmpty: Bool { stack.arrangedSubviews.allSatisfy { $0 is ThinkingRowView } }

    /// The group taking tool calls until any other row, or `closeToolGroup()`.
    private var openGroup: ToolGroupView?

    /// Tool calls that follow one another go into one group; any other row
    /// ends the group.
    func add(_ row: NSView) {
        hideThinking()
        if let call = row as? ToolRowView {
            if let openGroup {
                openGroup.add(call)
                needsLayout = true
            } else {
                let group = ToolGroupView(first: call)
                add(group)
                openGroup = group
            }
            return
        }
        closeToolGroup()
        stack.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        if lastWidth > 0 { Self.fit(row, width: lastWidth) }
        needsLayout = true
    }

    /// Ends the current run of tool calls, folding them under their header.
    func closeToolGroup() {
        openGroup?.close()
        openGroup = nil
    }

    func clear() {
        for view in stack.arrangedSubviews { view.removeFromSuperview() }
        openGroup = nil
        thinking = nil
    }

    /// Puts a "Thinking…" row after the last row, until something else
    /// comes. It leaves a run of tool calls open: the next call joins it.
    func showThinking() {
        guard thinking == nil else { return }
        let row = ThinkingRowView()
        thinking = row
        stack.addArrangedSubview(row)
        needsLayout = true
    }

    func hideThinking() {
        thinking?.removeFromSuperview()
        thinking = nil
    }

    var isThinking: Bool { thinking != nil }

    /// Whether the bottom of the transcript is in view, give or take a line.
    /// The clip runs under the scroll view's bottom inset, which isn't text.
    func isNearBottom(of scrollView: NSScrollView) -> Bool {
        scrollView.contentView.bounds.maxY - scrollView.contentInsets.bottom >= frame.height - 40
    }

    /// Only a width change re-measures every row; new rows are measured as
    /// they are added.
    override func layout() {
        let width = bounds.width - 2 * Self.inset
        if width != lastWidth, width > 0 {
            lastWidth = width
            for row in stack.arrangedSubviews { Self.fit(row, width: width) }
        }
        super.layout()
    }

    private static func fit(_ row: NSView, width: CGFloat) {
        if let row = row as? TranscriptRow {
            row.fit(width: width)
        } else if let label = row as? NSTextField, label.preferredMaxLayoutWidth != width {
            label.preferredMaxLayoutWidth = width
        }
    }
}

// MARK: Rows

/// A user message: its images, then a tinted bubble with its text, on the right.
final class UserMessageView: NSView, TranscriptRow {
    private let bubble = NSView()
    private let label: NSTextField
    /// Room kept free to the bubble's left, so it reads as a reply side.
    private static let leftMargin: CGFloat = 36
    private static let padding = NSEdgeInsets(top: 7, left: 12, bottom: 7, right: 12)

    /// `onOpenImage` gets the index of a clicked image.
    init(text: String, images: [NSImage] = [], onOpenImage: ((Int) -> Void)? = nil) {
        label = NSTextField(wrappingLabelWithString: text)
        super.init(frame: .zero)
        label.font = .systemFont(ofSize: 13)
        label.textColor = .labelColor
        label.isSelectable = true
        bubble.wantsLayer = true
        bubble.layer?.cornerRadius = Theme.Radius.plate
        bubble.layer?.cornerCurve = .continuous
        let grid = ThumbnailGrid(side: 64, alignment: .trailing)
        grid.images = images
        grid.onOpen = onOpenImage
        for view in [grid, bubble, label] {
            view.translatesAutoresizingMaskIntoConstraints = false
        }
        addSubview(grid)
        addSubview(bubble)
        bubble.addSubview(label)
        bubble.isHidden = text.isEmpty
        let p = Self.padding
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: topAnchor),
            grid.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.leftMargin),
            grid.trailingAnchor.constraint(equalTo: trailingAnchor),
            text.isEmpty
                ? grid.bottomAnchor.constraint(equalTo: bottomAnchor)
                : bubble.topAnchor.constraint(equalTo: grid.bottomAnchor, constant: images.isEmpty ? 0 : 6),
            bubble.trailingAnchor.constraint(equalTo: trailingAnchor),
            bubble.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: Self.leftMargin),
            label.topAnchor.constraint(equalTo: bubble.topAnchor, constant: p.top),
            label.bottomAnchor.constraint(equalTo: bubble.bottomAnchor, constant: -p.bottom),
            label.leadingAnchor.constraint(equalTo: bubble.leadingAnchor, constant: p.left),
            label.trailingAnchor.constraint(equalTo: bubble.trailingAnchor, constant: -p.right),
        ])
        if !text.isEmpty { bubble.bottomAnchor.constraint(equalTo: bottomAnchor).isActive = true }
    }

    required init?(coder: NSCoder) { fatalError() }

    func fit(width: CGFloat) {
        label.preferredMaxLayoutWidth = width - Self.leftMargin - Self.padding.left - Self.padding.right
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        bubble.layer?.backgroundColor = Theme.accent(Theme.Accent.bubble).layerColor
    }
}

/// Square image thumbnails in rows that wrap to the grid's width. Clicking one
/// opens it; with `onRemove` set, each also gets a remove button.
final class ThumbnailGrid: NSView {
    enum Alignment { case leading, trailing }

    var onOpen: ((Int) -> Void)?
    var onRemove: ((Int) -> Void)?
    /// Only the thumbnails are kept; the images given are let go once they
    /// are drawn small.
    var images: [NSImage] {
        get { [] }
        set { rebuild(with: newValue) }
    }

    private let side: CGFloat
    private let alignment: Alignment
    private var thumbnails: [ThumbnailView] = []
    private static let spacing: CGFloat = 6

    override var isFlipped: Bool { true }

    init(side: CGFloat, alignment: Alignment) {
        self.side = side
        self.alignment = alignment
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    private func rebuild(with images: [NSImage]) {
        thumbnails.forEach { $0.removeFromSuperview() }
        thumbnails = images.enumerated().map { index, image in
            // VoiceOver tells the images apart by name, or else by place.
            let label = image.name() ?? "Image \(index + 1)"
            let thumbnail = ThumbnailView(image: image, label: label, removable: onRemove != nil)
            thumbnail.onOpen = { [weak self] in self?.onOpen?(index) }
            thumbnail.onRemove = { [weak self] in self?.onRemove?(index) }
            addSubview(thumbnail)
            return thumbnail
        }
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    /// Before the grid has a width, everything goes in one row.
    private var perRow: Int {
        guard bounds.width > 0 else { return max(1, thumbnails.count) }
        return max(1, Int((bounds.width + Self.spacing) / (side + Self.spacing)))
    }

    override var intrinsicContentSize: NSSize {
        let rows = (thumbnails.count + perRow - 1) / perRow
        return NSSize(width: NSView.noIntrinsicMetric, height: rows == 0 ? 0 : CGFloat(rows) * (side + Self.spacing) - Self.spacing)
    }

    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = newSize.width != frame.width
        super.setFrameSize(newSize)
        if widthChanged { invalidateIntrinsicContentSize() }
    }

    override func layout() {
        super.layout()
        let perRow = perRow
        for (index, thumbnail) in thumbnails.enumerated() {
            let column = CGFloat(index % perRow), row = CGFloat(index / perRow)
            let offset = column * (side + Self.spacing)
            let x = alignment == .leading ? offset : bounds.width - side - offset
            thumbnail.frame = NSRect(x: x, y: row * (side + Self.spacing), width: side, height: side)
        }
    }
}

/// One thumbnail: the image filling a rounded square, with an optional
/// remove button in its corner. The square shows a copy of the image shrunk
/// to its size: a screenshot's full bitmap would otherwise sit in the
/// layer for every thumbnail in a long chat.
private final class ThumbnailView: NSView {
    var onOpen: (() -> Void)?
    var onRemove: (() -> Void)?
    private let image: NSImage

    init(image: NSImage, label: String, removable: Bool) {
        self.image = Self.thumbnail(of: image, side: 128)
        super.init(frame: .zero)
        wantsLayer = true
        toolTip = "Click to preview"
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(label)
        guard removable else { return }
        let remove = ThumbnailRemoveButton()
        remove.isBordered = false
        remove.imagePosition = .imageOnly
        remove.toolTip = "Remove"
        remove.setAccessibilityLabel("Remove Image")
        remove.target = self
        remove.action = #selector(removeClicked(_:))
        remove.translatesAutoresizingMaskIntoConstraints = false
        addSubview(remove)
        NSLayoutConstraint.activate([
            remove.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            remove.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func removeClicked(_ sender: Any?) { onRemove?() }

    /// `image` cropped to a square from its middle and drawn `side` points
    /// wide, which is enough for a thumbnail on any screen.
    private static func thumbnail(of image: NSImage, side: CGFloat) -> NSImage {
        let size = image.size
        guard size.width > side || size.height > side, size.width > 0, size.height > 0 else { return image }
        let crop = min(size.width, size.height)
        let source = NSRect(x: (size.width - crop) / 2, y: (size.height - crop) / 2, width: crop, height: crop)
        let thumbnail = NSImage(size: NSSize(width: side, height: side))
        thumbnail.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: NSRect(x: 0, y: 0, width: side, height: side), from: source, operation: .copy, fraction: 1)
        thumbnail.unlockFocus()
        return thumbnail
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        guard let layer else { return }
        layer.contents = image.layerContents(forContentsScale: window?.backingScaleFactor ?? 2)
        layer.contentsGravity = .resizeAspectFill
        layer.masksToBounds = true
        layer.cornerRadius = Theme.Radius.row
        layer.cornerCurve = .continuous
        layer.borderWidth = 1
        layer.borderColor = Theme.hairline.layerColor
    }

    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onOpen?() }
    }

    override func accessibilityPerformPress() -> Bool {
        onOpen?()
        return true
    }
}

/// The cross in a thumbnail's corner. It stays in view, since the image
/// under it can be any color, and its plate darkens under the mouse so it
/// reads as the thing a click will hit.
private final class ThumbnailRemoveButton: NSButton {
    private var isHovered = false {
        didSet { if isHovered != oldValue { updateImage() } }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        updateImage()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func updateImage() {
        let plate = NSColor.black.withAlphaComponent(isHovered ? 0.8 : 0.6)
        image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Remove Image")?
            .withSymbolConfiguration(.init(paletteColors: [.white, plate]))
    }

    /// Only this area is replaced, so the ones AppKit keeps for the tooltip stay.
    private var hoverArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }
}

/// One tool call: a spinner, then a check or a cross, beside the tool and
/// what it acted on. A running call shows a few lines of its arguments; a
/// finished one keeps a single line. A failed call adds the first line of
/// its error. With `disclosure`, the row is the clickable header of a
/// `ToolGroupView`, with a chevron for its state.
final class ToolRowView: NSView, TranscriptRow {
    enum Outcome { case running, done, failed, unfinished }

    /// The tool's name without the MCP server prefix.
    private(set) var tool: String
    private(set) var outcome = Outcome.running
    /// Called when the call finishes, whichever way.
    var onFinish: (() -> Void)?
    /// Called when a disclosure row is clicked.
    var onToggle: (() -> Void)?
    var isExpanded = false {
        didSet {
            chevron?.image = Self.chevronImage(expanded: isExpanded)
            if chevron != nil { setAccessibilityExpanded(isExpanded) }
        }
    }

    /// The icon column and the text column that the Thinking row and error
    /// boxes share, so their icons and text line up down the transcript.
    static let iconLeading: CGFloat = 9
    static let iconWidth: CGFloat = 14
    static let textLeading = iconLeading + iconWidth + 7

    private let spinner = NSProgressIndicator()
    private let icon = NSImageView()
    private let label = NSTextField(wrappingLabelWithString: "")
    private let chevron: NSImageView?
    private var heading: NSAttributedString

    /// `detail` is what `detail(_:)` made of the call's input.
    init(name: String, detail: String, disclosure: Bool = false) {
        tool = Self.tool(name)
        heading = Self.heading(tool: tool, detail: detail)
        chevron = disclosure ? NSImageView(image: Self.chevronImage(expanded: false)!) : nil
        super.init(frame: .zero)
        wantsLayer = true

        spinner.style = .spinning
        spinner.controlSize = .mini
        spinner.isDisplayedWhenStopped = false
        spinner.startAnimation(nil)
        icon.isHidden = true
        label.attributedStringValue = heading
        label.maximumNumberOfLines = disclosure ? 1 : 4
        label.lineBreakMode = .byTruncatingTail
        // Without this, a line cut by the limit ends at a word break with no
        // ellipsis when the text would have wrapped there.
        label.cell?.truncatesLastVisibleLine = true
        for view in [spinner, icon, label] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.iconLeading),
            icon.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            icon.widthAnchor.constraint(equalToConstant: Self.iconWidth),
            icon.heightAnchor.constraint(equalToConstant: Self.iconWidth),
            spinner.centerXAnchor.constraint(equalTo: icon.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: icon.centerYAnchor),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.textLeading),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5),
        ])
        if let chevron {
            chevron.contentTintColor = .tertiaryLabelColor
            chevron.translatesAutoresizingMaskIntoConstraints = false
            addSubview(chevron)
            NSLayoutConstraint.activate([
                chevron.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -9),
                chevron.centerYAnchor.constraint(equalTo: icon.centerYAnchor),
                chevron.widthAnchor.constraint(equalToConstant: 12),
                label.trailingAnchor.constraint(equalTo: chevron.leadingAnchor, constant: -6),
            ])
            label.isSelectable = false
            // VoiceOver reads the row as one disclosure control, not its parts.
            setAccessibilityElement(true)
            label.setAccessibilityElement(false)
            setAccessibilityRole(.disclosureTriangle)
        } else {
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -9).isActive = true
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    func fit(width: CGFloat) {
        label.preferredMaxLayoutWidth = width - 39 - (chevron == nil ? 0 : 18)
    }

    /// Changes what the row says. A group header counts its calls as they come.
    func update(name: String, detail: String) {
        tool = Self.tool(name)
        heading = Self.heading(tool: tool, detail: detail)
        label.attributedStringValue = heading
        setAccessibilityLabel(heading.string)
    }

    /// A group header spins only while one of its calls runs; between
    /// calls it shows an empty circle.
    func setRunning(_ running: Bool) {
        guard outcome == .running else { return }
        if running {
            icon.isHidden = true
            spinner.startAnimation(nil)
        } else {
            spinner.stopAnimation(nil)
            icon.image = NSImage(systemSymbolName: "circle.dashed", accessibilityDescription: "Waiting")?
                .withSymbolConfiguration(.init(pointSize: Theme.Symbol.row, weight: .medium))
            icon.contentTintColor = .tertiaryLabelColor
            icon.isHidden = false
        }
    }

    /// A nil `isError` means the call never finished: the agent stopped first.
    func finish(isError: Bool?, summary: String) {
        spinner.stopAnimation(nil)
        icon.isHidden = false
        isHovered = false
        // Only a failure gets a color: a long run would otherwise be a
        // column of green.
        let (symbol, description, color): (String, String, NSColor) = switch isError {
        case true?: ("xmark.circle.fill", "Failed", .systemRed)
        case false?: ("checkmark.circle.fill", "Done", .tertiaryLabelColor)
        case nil: ("minus.circle.fill", "Didn't finish", .tertiaryLabelColor)
        }
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: description)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .medium))
        icon.contentTintColor = color
        outcome = switch isError {
        case true?: .failed
        case false?: .done
        case nil: .unfinished
        }
        label.maximumNumberOfLines = 1
        if isError == true, !summary.isEmpty {
            let text = NSMutableAttributedString(attributedString: heading)
            text.append(NSAttributedString(string: "\n" + summary, attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor.systemRed,
            ]))
            label.attributedStringValue = text
            label.maximumNumberOfLines = 3
        }
        onFinish?()
    }

    // Clicks anywhere on a disclosure row toggle it, the label included.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return chevron != nil && hit != nil ? self : hit
    }

    override func mouseDown(with event: NSEvent) {
        if chevron != nil { isPressed = true }
    }

    override func mouseDragged(with event: NSEvent) {
        if chevron != nil { isPressed = bounds.contains(convert(event.locationInWindow, from: nil)) }
    }

    override func mouseUp(with event: NSEvent) {
        isPressed = false
        if chevron != nil, bounds.contains(convert(event.locationInWindow, from: nil)) { onToggle?() }
    }

    override func accessibilityPerformPress() -> Bool {
        guard chevron != nil else { return false }
        onToggle?()
        return true
    }

    // A disclosure row takes keyboard focus, and Space or Return toggles it.
    // Only under Full Keyboard Access, as a button does: otherwise a click
    // on the row would take the keyboard from the message field.
    override var acceptsFirstResponder: Bool { chevron != nil && NSApp.isFullKeyboardAccessEnabled }

    override func keyDown(with event: NSEvent) {
        // Space, Return and the keypad's Enter.
        if chevron != nil, [49, 36, 76].contains(event.keyCode) {
            onToggle?()
        } else {
            super.keyDown(with: event)
        }
    }

    override var focusRingMaskBounds: NSRect { bounds }

    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: bounds, xRadius: Theme.Radius.row, yRadius: Theme.Radius.row).fill()
    }

    override var wantsUpdateLayer: Bool { true }

    /// A clickable header darkens a little under the mouse, and more while pressed.
    private var isHovered = false {
        didSet { if isHovered != oldValue { needsDisplay = true } }
    }

    private var isPressed = false {
        didSet { if isPressed != oldValue { needsDisplay = true } }
    }

    override func updateLayer() {
        layer?.cornerRadius = Theme.Radius.row
        layer?.cornerCurve = .continuous
        let alpha = chevron == nil ? Theme.Fill.rest
            : isPressed ? Theme.Fill.pressed : isHovered ? Theme.Fill.hover : Theme.Fill.rest
        withEasing { layer?.backgroundColor = Theme.fill(alpha).layerColor }
        // A fill this faint goes with Increase Contrast; an edge stays.
        layer?.borderWidth = Theme.increaseContrast ? 1 : 0
        layer?.borderColor = Theme.hairline.layerColor
    }

    /// Only this area is replaced, so the ones AppKit keeps for the tooltip stay.
    private var hoverArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        hoverArea = nil
        guard chevron != nil else { return }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    private static func tool(_ name: String) -> String {
        // Chats saved before the rename from Mini carry the old server name.
        let prefix = ["mcp__tiller__", "mcp__mini__"].first { name.hasPrefix($0) }
        return prefix.map { String(name.dropFirst($0.count)) } ?? name
    }

    /// What a tool is called in the transcript: Tiller's and the CLIs'
    /// built-in tools by what they do, anything else as named.
    static func displayName(of tool: String) -> String {
        switch tool {
        case "read_page": "Read page"
        case "click": "Click"
        case "type": "Type"
        case "navigate": "Open page"
        case "new_tab": "New tab"
        case "select_tab": "Select tab"
        case "close_tab": "Close tab"
        case "list_tabs": "List tabs"
        case "screenshot": "Screenshot"
        case "eval_js": "Run script"
        case "list_skills": "List skills"
        case "read_skill": "Read skill"
        case "save_skill": "Save skill"
        case "list_schedules": "List schedules"
        case "save_schedule": "Save schedule"
        case "delete_schedule": "Delete schedule"
        case "run_schedule": "Run schedule"
        case "Read": "Read file"
        case "Write": "Write file"
        case "Edit", "MultiEdit": "Edit file"
        case "Bash", "run_command", "run_terminal_command": "Run command"
        case "view_file", "read_file": "Read file"
        case "write_to_file", "write": "Write file"
        case "replace_file_content", "multi_replace_file_content", "search_replace": "Edit file"
        case "grep_search", "find_by_name", "list_dir", "grep": "Search files"
        case "read_url_content": "Fetch"
        case "search_web": "Search the web"
        case "Grep", "Glob": "Search files"
        case "WebFetch": "Fetch"
        case "WebSearch": "Search the web"
        case "TodoWrite": "Plan"
        case "Task": "Subtask"
        default: tool
        }
    }

    private static func heading(tool: String, detail: String) -> NSAttributedString {
        let text = NSMutableAttributedString(string: displayName(of: tool), attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.labelColor,
        ])
        if !detail.isEmpty {
            text.append(NSAttributedString(string: "  " + detail, attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]))
        }
        return text
    }

    private static func chevronImage(expanded: Bool) -> NSImage? {
        NSImage(systemSymbolName: expanded ? "chevron.down" : "chevron.right", accessibilityDescription: expanded ? "Hide steps" : "Show steps")?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .semibold))
    }

    /// The arguments worth showing: where it acts, and what it types or runs.
    /// URLs lose their scheme and scripts their line breaks, so a row's one
    /// line holds what matters.
    static func detail(_ input: [String: Any]) -> String {
        var parts: [String] = []
        if let url = input["url"] {
            var address = "\(url)"
            for scheme in ["https://", "http://"] where address.hasPrefix(scheme) { address.removeFirst(scheme.count) }
            parts.append(address)
        }
        if let ref = input["ref"] { parts.append("ref \(ref)") } else if let selector = input["selector"] { parts.append("\(selector)") }
        if let text = input["text"] { parts.append("\"\(text)\"") }
        if let expression = input["expression"] { parts.append("\(expression)") }
        if let command = input["command"] { parts.append("\(command)") }
        if let pattern = input["pattern"] { parts.append("\(pattern)") }
        if let path = input["file_path"] ?? input["path"] { parts.append("\(path)") }
        if parts.isEmpty, let tab = input["tab_id"] { parts.append("tab \(tab)") }
        // A skill or schedule by name.
        if parts.isEmpty, let name = input["name"] { parts.append("\(name)") }
        let string = parts.joined(separator: " ").split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return string.count > 80 ? String(string.prefix(80)) + "…" : string
    }
}

/// A run of tool calls between messages, under a header that counts them.
/// The calls show while the run is under way and fold under the header when
/// it ends; clicking the header shows them again. A run of one call is just
/// that call, with no header.
final class ToolGroupView: NSView, TranscriptRow {
    private let header = ToolRowView(name: "", detail: "", disclosure: true)
    private let stack = NSStackView()
    private let rows = NSStackView()
    private var calls: [ToolRowView] = []
    private(set) var isOpen = true
    /// Set once the user clicked the header: closing then leaves their choice alone.
    private var toggled = false
    private var width: CGFloat = 0
    /// How far the calls sit in from the header. None when there is no header.
    private var indent: CGFloat { calls.count > 1 ? 12 : 0 }
    private var rowsLeading: NSLayoutConstraint!
    private var rowsWidth: NSLayoutConstraint!

    init(first: ToolRowView) {
        super.init(frame: .zero)
        for list in [stack, rows] {
            list.orientation = .vertical
            list.alignment = .leading
            list.spacing = 4
            list.translatesAutoresizingMaskIntoConstraints = false
        }
        addSubview(stack)
        stack.addArrangedSubview(header)
        stack.addArrangedSubview(rows)
        header.onToggle = { [weak self] in
            guard let self else { return }
            toggled = true
            setExpanded(!header.isExpanded)
        }
        header.isExpanded = true
        rowsLeading = rows.leadingAnchor.constraint(equalTo: stack.leadingAnchor)
        rowsWidth = rows.widthAnchor.constraint(equalTo: stack.widthAnchor)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            header.widthAnchor.constraint(equalTo: stack.widthAnchor),
            rowsLeading, rowsWidth,
        ])
        add(first)
    }

    required init?(coder: NSCoder) { fatalError() }

    func add(_ call: ToolRowView) {
        calls.append(call)
        call.translatesAutoresizingMaskIntoConstraints = false
        rows.addArrangedSubview(call)
        call.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
        call.onFinish = { [weak self] in self?.updateHeader() }
        rowsLeading.constant = indent
        rowsWidth.constant = -indent
        if width > 0 { fit(width: width) }
        updateHeader()
    }

    /// The run ended: the header takes its outcome and the calls fold away.
    func close() {
        guard isOpen else { return }
        isOpen = false
        if !toggled { setExpanded(false) }
        updateHeader()
    }

    func fit(width: CGFloat) {
        self.width = width
        header.fit(width: width)
        for call in calls { call.fit(width: width - indent) }
    }

    private func setExpanded(_ expanded: Bool) {
        header.isExpanded = expanded
        header.toolTip = expanded ? "Hide steps" : "Show steps"
        updateHeader()
    }

    private func updateHeader() {
        // One call has no header to reopen it from, so it stays in view.
        header.isHidden = calls.count < 2
        let hideRows = !header.isExpanded && calls.count > 1
        if rows.isHidden && !hideRows {
            // Shown again from the header, the calls fade in rather than pop.
            rows.alphaValue = 0
            rows.isHidden = false
            withEasing(Theme.Duration.quick) { rows.animator().alphaValue = 1 }
        } else if hideRows && !rows.isHidden && window != nil && !Theme.reduceMotion {
            // And fade out before they fold, as when a turn ends.
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Theme.Duration.quick
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                rows.animator().alphaValue = 0
            } completionHandler: { [weak self] in
                MainActor.assumeIsolated {
                    // Unless they were opened again meanwhile.
                    guard let self, !self.header.isExpanded else { return }
                    self.rows.isHidden = true
                    self.rows.alphaValue = 1
                }
            }
        } else {
            rows.isHidden = hideRows
            rows.alphaValue = 1
        }
        var names: [String] = []
        for call in calls {
            let name = ToolRowView.displayName(of: call.tool).lowercased()
            if !names.contains(name) { names.append(name) }
        }
        let failed = calls.filter { $0.outcome == .failed }.count
        header.update(
            name: "\(calls.count) steps" + (failed > 0 ? " · \(failed) failed" : ""),
            detail: names.joined(separator: ", ")
        )
        guard !isOpen else {
            header.setRunning(calls.contains { $0.outcome == .running })
            return
        }
        let settled = calls.allSatisfy { $0.outcome == .done || $0.outcome == .failed }
        header.finish(isError: failed > 0 ? true : settled ? false : nil, summary: "")
    }
}

/// What shows between sending a message and the agent's first words or
/// step: a small bobbing boat and a sailing phrase, where the answer will
/// start.
final class ThinkingRowView: NSView {
    private static let phrases = [
        "Setting sail…", "Reading the wind…", "Charting a course…", "Trimming the sails…",
        "Holding the tiller…", "Tacking…", "Scanning the horizon…", "Riding the swell…",
    ]
    private static let phraseInterval: TimeInterval = 3

    private let label: NSTextField
    private var phrase: Int
    private var timer: Timer?

    init() {
        phrase = Int.random(in: 0..<Self.phrases.count)
        label = NSTextField(labelWithString: Self.phrases[phrase])
        super.init(frame: .zero)
        let boat = BoatView()
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        for view in [boat, label] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        // The boat and text sit in a tool row's columns, so the boat stays
        // put when the next step's row takes this one's place.
        NSLayoutConstraint.activate([
            boat.centerXAnchor.constraint(equalTo: leadingAnchor, constant: ToolRowView.iconLeading + ToolRowView.iconWidth / 2),
            boat.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            boat.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
            boat.widthAnchor.constraint(equalToConstant: 16),
            boat.heightAnchor.constraint(equalToConstant: 16),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: ToolRowView.textLeading),
            label.centerYAnchor.constraint(equalTo: boat.centerYAnchor),
        ])
        // The phrases are decoration; VoiceOver hears one plain word.
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel("Working")
        label.setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// The phrase changes only while the row is on screen: in a window, and
    /// not in a hidden chat or panel, which a turn can run on in.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateTimer()
    }

    override func viewDidHide() {
        super.viewDidHide()
        updateTimer()
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        updateTimer()
    }

    private func updateTimer() {
        let visible = window != nil && !isHiddenOrHasHiddenAncestor
        guard visible != (timer != nil) else { return }
        timer?.invalidate()
        timer = nil
        guard visible else { return }
        timer = Timer.scheduledTimer(withTimeInterval: Self.phraseInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.nextPhrase() }
        }
    }

    private func nextPhrase() {
        phrase = (phrase + 1 + Int.random(in: 0..<Self.phrases.count - 1)) % Self.phrases.count
        let text = Self.phrases[phrase]
        guard !Theme.reduceMotion else { label.stringValue = text; return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            label.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.label.stringValue = text
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.15
                    self.label.animator().alphaValue = 1
                }
            }
        }
    }
}

/// Tiller's boat, drawn small and in one color: a hull and sail that bob and
/// rock above a wave line while the agent works, and sit still when the
/// system asks for less motion.
private final class BoatView: NSView {
    private let boat = CAShapeLayer()
    private let wave = CAShapeLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.addSublayer(wave)
        layer?.addSublayer(boat)
        wave.fillColor = nil
        wave.lineWidth = 1.2
        wave.lineCap = .round
    }

    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        boat.fillColor = NSColor.secondaryLabelColor.cgColor
        wave.strokeColor = NSColor.tertiaryLabelColor.cgColor
    }

    override func layout() {
        super.layout()
        let size = bounds.size
        guard size.width > 0, boat.frame.size != size else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        wave.frame = bounds
        wave.path = Self.wavePath(width: size.width)
        // The boat rocks about the middle of its hull.
        boat.bounds = bounds
        boat.anchorPoint = CGPoint(x: 0.5, y: 4.5 / size.height)
        boat.position = CGPoint(x: size.width / 2, y: 4.5)
        boat.path = Self.boatPath()
        CATransaction.commit()
        startAnimating()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        startAnimating()
    }

    override func viewDidHide() {
        super.viewDidHide()
        boat.removeAllAnimations()
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        startAnimating()
    }

    private func startAnimating() {
        boat.removeAllAnimations()
        guard window != nil, !isHiddenOrHasHiddenAncestor, !Theme.reduceMotion else { return }
        let bob = CABasicAnimation(keyPath: "position.y")
        bob.fromValue = boat.position.y - 0.75
        bob.toValue = boat.position.y + 0.75
        bob.duration = 0.8
        let rock = CABasicAnimation(keyPath: "transform.rotation.z")
        rock.fromValue = -6 * CGFloat.pi / 180
        rock.toValue = 6 * CGFloat.pi / 180
        // Rocking at a different pace than bobbing keeps it from looking
        // mechanical.
        rock.duration = 1.1
        for (animation, key) in [(bob, "bob"), (rock, "rock")] {
            animation.autoreverses = true
            animation.repeatCount = .infinity
            animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            boat.add(animation, forKey: key)
        }
    }

    /// A hull, mast and sail in a 16-point box, origin at the bottom left.
    private static func boatPath() -> CGPath {
        let path = CGMutablePath()
        // Hull: a wide deck tapering to a narrower keel.
        path.move(to: CGPoint(x: 2, y: 6.5))
        path.addLine(to: CGPoint(x: 14, y: 6.5))
        path.addLine(to: CGPoint(x: 11.5, y: 3))
        path.addLine(to: CGPoint(x: 4.5, y: 3))
        path.closeSubpath()
        // Mast.
        path.addRect(CGRect(x: 7.4, y: 6.5, width: 1.2, height: 8.5))
        // Sail, leaning off the mast toward the bow.
        path.move(to: CGPoint(x: 9, y: 14.5))
        path.addLine(to: CGPoint(x: 13.5, y: 7.5))
        path.addLine(to: CGPoint(x: 9, y: 7.5))
        path.closeSubpath()
        return path
    }

    /// One gentle wave along the bottom.
    private static func wavePath(width: CGFloat) -> CGPath {
        let path = CGMutablePath()
        let y: CGFloat = 1.5
        path.move(to: CGPoint(x: 0.5, y: y))
        let step = (width - 1) / 4
        for i in 0..<4 {
            let x = 0.5 + CGFloat(i) * step
            path.addQuadCurve(to: CGPoint(x: x + step, y: y), control: CGPoint(x: x + step / 2, y: i.isMultiple(of: 2) ? y + 1.2 : y - 1.2))
        }
        return path
    }
}

/// A quiet line in the middle, such as "Stopped".
final class NoteView: NSView {
    init(text: String) {
        super.init(frame: .zero)
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: Theme.FontSize.caption, weight: .medium)
        label.textColor = .secondaryLabelColor
        // A long one, such as a scheduled run's name, loses its middle and
        // keeps the whole text in its tooltip.
        label.alignment = .center
        label.lineBreakMode = .byTruncatingMiddle
        label.toolTip = text
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            label.topAnchor.constraint(equalTo: topAnchor),
            label.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }
}

/// An error from the agent or its process, in a red-tinted box.
final class ErrorMessageView: NSView, TranscriptRow {
    private let label: NSTextField
    private let action: (() -> Void)?

    /// `action` adds a button under the text, such as Try Again.
    init(text: String, action: (title: String, run: () -> Void)? = nil) {
        label = NSTextField(wrappingLabelWithString: text)
        self.action = action?.run
        super.init(frame: .zero)
        wantsLayer = true
        label.font = .systemFont(ofSize: 13)
        label.textColor = .labelColor
        label.isSelectable = true
        let icon = NSImageView(image: NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: "Error")!
            .withSymbolConfiguration(.init(pointSize: 12, weight: .medium))!)
        icon.contentTintColor = .systemRed
        for view in [icon, label] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: ToolRowView.iconLeading),
            icon.topAnchor.constraint(equalTo: topAnchor, constant: 9),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: ToolRowView.textLeading),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 8),
        ])
        guard let action else {
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8).isActive = true
            return
        }
        let button = NSButton(title: action.title, target: self, action: #selector(run(_:)))
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.font = .systemFont(ofSize: 11, weight: .medium)
        button.translatesAutoresizingMaskIntoConstraints = false
        addSubview(button)
        NSLayoutConstraint.activate([
            button.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 6),
            button.leadingAnchor.constraint(equalTo: label.leadingAnchor),
            button.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func run(_ sender: Any?) { action?() }

    func fit(width: CGFloat) {
        label.preferredMaxLayoutWidth = width - ToolRowView.textLeading - 10
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.cornerRadius = Theme.Radius.card
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = NSColor.systemRed.dynamic(alpha: 0.1).layerColor
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.systemRed.dynamic(alpha: 0.25).layerColor
    }
}

// MARK: Markdown

/// Renders the agent's markdown: headings, lists, quotes and fenced code by
/// line, bold, italics, code and links within a line, and pipe tables as
/// grids. Other block syntax stays as typed.
@MainActor
enum AgentMarkdown {
    private static let bodySize: CGFloat = 13
    private static let listIndent: CGFloat = 16

    /// A pipe table, its cells as written. They are rendered when drawn, so a
    /// table still streaming in renders only the cells it gained.
    struct Table {
        /// The lines it was parsed from, to tell whether it changed.
        let source: String
        let header: [String]
        let rows: [[String]]
        let alignments: [NSTextAlignment]

        /// The cell's text rendered for its column, from a cache.
        @MainActor
        func cell(_ text: String, header: Bool, column: Int) -> NSAttributedString {
            AgentMarkdown.cell(text, header: header, alignment: alignments[min(column, alignments.count - 1)])
        }
    }

    /// The pieces of a message. Text and quotes stay as written and are
    /// rendered when a view takes them, so a block a streamed answer isn't
    /// adding to any more costs nothing on the next render.
    enum Block {
        case text(String)
        case table(Table)
        /// A fenced code block, with the language named after the opening fence.
        case code(language: String, text: String)
        /// Lines quoted with `>`, without the markers.
        case quote(String)
        /// A horizontal rule.
        case rule
    }

    static func label(_ text: String) -> MarkdownMessageView {
        let view = MarkdownMessageView()
        view.text = text
        return view
    }

    /// The message as runs of text with the code blocks, tables, quotes and
    /// rules between them. A fence still open at the end, as while an answer
    /// streams, is a code block too.
    static func blocks(_ text: String) -> [Block] {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var blocks: [Block] = []
        var pending: [String] = []
        func flush() {
            defer { pending.removeAll() }
            guard pending.contains(where: { !$0.allSatisfy(\.isWhitespace) }) else { return }
            blocks.append(.text(pending.joined(separator: "\n")))
        }
        var index = 0
        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                flush()
                let language = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces)
                var end = index + 1
                while end < lines.count, !lines[end].trimmingCharacters(in: .whitespaces).hasPrefix("```") { end += 1 }
                blocks.append(.code(language: language, text: lines[(index + 1)..<end].joined(separator: "\n")))
                index = end + 1
                continue
            }
            if let (table, end) = table(in: lines, at: index) {
                flush()
                blocks.append(.table(table))
                index = end
                continue
            }
            if trimmed.hasPrefix(">") {
                flush()
                var end = index
                var quoted: [String] = []
                while end < lines.count {
                    let inner = lines[end].trimmingCharacters(in: .whitespaces)
                    guard inner.hasPrefix(">") else { break }
                    var content = inner.dropFirst()
                    if content.hasPrefix(" ") { content = content.dropFirst() }
                    quoted.append(String(content))
                    end += 1
                }
                blocks.append(.quote(quoted.joined(separator: "\n")))
                index = end
                continue
            }
            // A line of dashes under a paragraph underlines a heading; on its
            // own, like a line of stars or underscores, it is a rule.
            if let last = pending.last, !last.trimmingCharacters(in: .whitespaces).isEmpty, !isBlockStart(last),
                let level = setextLevel(trimmed)
            {
                // The whole paragraph is the heading, not just its last line.
                var start = pending.count - 1
                while start > 0, !pending[start - 1].trimmingCharacters(in: .whitespaces).isEmpty, !isBlockStart(pending[start - 1]) {
                    start -= 1
                }
                let heading = pending[start...].map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
                pending.replaceSubrange(start..., with: [String(repeating: "#", count: level) + " " + heading])
                index += 1
                continue
            }
            if isRule(trimmed) {
                flush()
                blocks.append(.rule)
                index += 1
                continue
            }
            // A long run of text ends at a paragraph break, so a streamed
            // answer only renders and lays out its last few paragraphs on
            // each tick rather than everything since the last table or
            // fence. Shorter runs stay whole, so they select as one.
            if trimmed.isEmpty, pending.count(where: { !$0.allSatisfy(\.isWhitespace) }) >= longTextRun {
                flush()
                index += 1
                continue
            }
            pending.append(line)
            index += 1
        }
        flush()
        return blocks
    }

    /// The lines of text past which a run is split at its next blank line.
    private static let longTextRun = 12

    /// Three or more of the same of `-`, `*` or `_`, spaces allowed between.
    private static func isRule(_ line: String) -> Bool {
        let marks = line.filter { $0 != " " }
        guard marks.count >= 3, let first = marks.first, "-*_".contains(first) else { return false }
        return marks.allSatisfy { $0 == first }
    }

    /// 1 for a line of `=`, 2 for a line of `-`, else nil.
    private static func setextLevel(_ line: String) -> Int? {
        guard line.count >= 3, let first = line.first, "=-".contains(first), line.allSatisfy({ $0 == first }) else { return nil }
        return first == "=" ? 1 : 2
    }

    /// Whether a line already starts a heading or list item, which a line of
    /// dashes after it doesn't turn into a heading.
    private static func isBlockStart(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("#") || trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ") { return true }
        return trimmed.first?.isNumber == true && trimmed.contains(". ")
    }

    /// The table whose header is the line at `start`, and the line after its
    /// last row. A table is a header, a line of dashes, then rows.
    private static func table(in lines: [String], at start: Int) -> (Table, Int)? {
        guard start + 1 < lines.count, lines[start].contains("|") else { return nil }
        let header = cells(lines[start])
        let delimiter = cells(lines[start + 1])
        guard !delimiter.isEmpty, delimiter.count == header.count, lines[start + 1].contains("-"),
            delimiter.allSatisfy({ cell in
                var dashes = Substring(cell)
                if dashes.hasPrefix(":") { dashes = dashes.dropFirst() }
                if dashes.hasSuffix(":") { dashes = dashes.dropLast() }
                return !dashes.isEmpty && dashes.allSatisfy { $0 == "-" }
            })
        else { return nil }
        let alignments: [NSTextAlignment] = delimiter.map { cell in
            if cell.hasSuffix(":") { return cell.hasPrefix(":") ? .center : .right }
            return .left
        }
        var end = start + 2
        var rows: [[String]] = []
        while end < lines.count {
            let trimmed = lines[end].trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, trimmed.contains("|"), !trimmed.hasPrefix("```") else { break }
            var row = Array(cells(trimmed).prefix(header.count))
            row += Array(repeating: "", count: header.count - row.count)
            rows.append(row)
            end += 1
        }
        let table = Table(source: lines[start..<end].joined(separator: "\n"), header: header, rows: rows, alignments: alignments)
        return (table, end)
    }

    /// Cells rendered before, by alignment, weight and text. Streaming
    /// renders a table again with every row it gains, and all but the last
    /// row's cells are as they were.
    private static var renderedCells: [String: NSAttributedString] = [:]

    fileprivate static func cell(_ text: String, header: Bool, alignment: NSTextAlignment) -> NSAttributedString {
        let key = "\(header ? "H" : "B")\(alignment.rawValue)" + text
        if let cached = renderedCells[key] { return cached }
        let rendered = inline(text, font: header ? .systemFont(ofSize: bodySize, weight: .semibold) : body)
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 1
        style.alignment = alignment
        rendered.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: rendered.length))
        if renderedCells.count >= renderedLinesLimit { renderedCells.removeAll(keepingCapacity: true) }
        renderedCells[key] = rendered
        return rendered
    }

    /// A quote's lines, rendered and dimmed.
    static func renderQuote(_ source: String) -> NSAttributedString {
        let text = NSMutableAttributedString(attributedString: render(source))
        text.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: NSRange(location: 0, length: text.length))
        return text
    }

    /// A table line's cells. A pipe after a backslash or inside backticks
    /// does not end a cell.
    private static func cells(_ line: String) -> [String] {
        let characters = Array(line.trimmingCharacters(in: .whitespaces))
        var cells: [String] = []
        var current = ""
        var inCode = false
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if character == "\\", index + 1 < characters.count, characters[index + 1] == "|" {
                current.append("|")
                index += 2
                continue
            }
            if character == "`" { inCode.toggle() }
            if character == "|" && !inCode {
                cells.append(current)
                current = ""
            } else {
                current.append(character)
            }
            index += 1
        }
        cells.append(current)
        // The pipes at either end of the line border the table.
        if cells.first?.trimmingCharacters(in: .whitespaces).isEmpty == true { cells.removeFirst() }
        if cells.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { cells.removeLast() }
        return cells.map { $0.trimmingCharacters(in: .whitespaces) }
    }

    static func render(_ text: String) -> NSAttributedString {
        let result = NSMutableAttributedString()
        var inFence = false
        var previousBlank = false
        for (index, rawLine) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let line = String(rawLine)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                inFence.toggle()
                continue
            }
            // Runs of blank lines collapse into paragraph spacing.
            if !inFence && trimmed.isEmpty {
                previousBlank = true
                continue
            }
            if index > 0 && result.length > 0 {
                result.append(NSAttributedString(string: "\n", attributes: [.font: body]))
            }
            let start = result.length
            result.append(rendered(line, trimmed: trimmed, inFence: inFence))
            if previousBlank, start > 0 {
                // A gap before the paragraph that followed a blank line.
                let range = NSRange(location: start, length: result.length - start)
                result.enumerateAttribute(.paragraphStyle, in: range) { value, subrange, _ in
                    let style = ((value as? NSParagraphStyle) ?? NSParagraphStyle.default).mutableCopy() as! NSMutableParagraphStyle
                    style.paragraphSpacingBefore = 6
                    result.addAttribute(.paragraphStyle, value: style, range: subrange)
                }
            }
            previousBlank = false
        }
        return result
    }

    /// Lines rendered before, by their text after an F in a fence or a B
    /// outside. A streamed answer renders again with every few words, and
    /// all but its last line are the same each time.
    private static var renderedLines: [String: NSAttributedString] = [:]
    private static let renderedLinesLimit = 4000

    private static func rendered(_ line: String, trimmed: String, inFence: Bool) -> NSAttributedString {
        let key = (inFence ? "F" : "B") + line
        if let cached = renderedLines[key] { return cached }
        let text = inFence ? code(line) : block(line, trimmed: trimmed)
        if renderedLines.count >= renderedLinesLimit { renderedLines.removeAll(keepingCapacity: true) }
        renderedLines[key] = text
        return text
    }

    private static let body = NSFont.systemFont(ofSize: bodySize)

    private static func paragraph(indent: CGFloat = 0, firstLineIndent: CGFloat? = nil) -> NSMutableParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 2
        style.paragraphSpacing = 2
        style.headIndent = indent
        style.firstLineHeadIndent = firstLineIndent ?? indent
        if indent > 0 { style.tabStops = [NSTextTab(textAlignment: .left, location: indent)] }
        return style
    }

    private static func block(_ line: String, trimmed: String) -> NSAttributedString {
        // Headings: "# Title" to "###### Title".
        if let hashes = trimmed.firstIndex(where: { $0 != "#" }), trimmed.hasPrefix("#"),
            trimmed.distance(from: trimmed.startIndex, to: hashes) <= 6, trimmed[hashes] == " " {
            let level = trimmed.distance(from: trimmed.startIndex, to: hashes)
            let size: CGFloat = level == 1 ? 16 : level == 2 ? 15 : 14
            let text = inline(String(trimmed[hashes...]).trimmingCharacters(in: .whitespaces),
                              font: .systemFont(ofSize: size, weight: .semibold))
            let style = paragraph()
            style.paragraphSpacingBefore = 4
            text.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: text.length))
            return text
        }
        // Nested lists indent by two spaces a level.
        let depth = CGFloat((line.prefix(while: { $0 == " " }).count) / 2)
        let indent = listIndent * (depth + 1)
        for marker in ["- ", "* ", "+ "] where trimmed.hasPrefix(marker) {
            let text = inline("•\t" + trimmed.dropFirst(2), font: body)
            text.addAttribute(.paragraphStyle, value: paragraph(indent: indent, firstLineIndent: indent - listIndent),
                              range: NSRange(location: 0, length: text.length))
            return text
        }
        if let dot = trimmed.firstIndex(of: "."), trimmed[..<dot].allSatisfy(\.isNumber), !trimmed[..<dot].isEmpty,
            trimmed[dot...].hasPrefix(". ") {
            let number = trimmed[..<dot]
            let text = inline("\(number).\t" + trimmed[dot...].dropFirst(2), font: body)
            text.addAttribute(.paragraphStyle, value: paragraph(indent: indent + 4, firstLineIndent: indent - listIndent),
                              range: NSRange(location: 0, length: text.length))
            return text
        }
        if trimmed.hasPrefix(">") {
            let text = inline(trimmed.dropFirst().trimmingCharacters(in: .whitespaces), font: body)
            let range = NSRange(location: 0, length: text.length)
            text.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: range)
            text.addAttribute(.paragraphStyle, value: paragraph(indent: 10), range: range)
            return text
        }
        let text = inline(line, font: body)
        text.addAttribute(.paragraphStyle, value: paragraph(), range: NSRange(location: 0, length: text.length))
        return text
    }

    private static func code(_ line: String) -> NSAttributedString {
        let style = paragraph(indent: 10)
        style.lineSpacing = 1
        return NSAttributedString(string: line.isEmpty ? " " : line, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: Theme.FontSize.secondary, weight: .regular),
            .foregroundColor: NSColor.labelColor,
            .backgroundColor: Theme.fill(Theme.Fill.rest),
            .paragraphStyle: style,
        ])
    }

    /// Bold, italics, inline code and links in one line.
    private static func inline<S: StringProtocol>(_ text: S, font: NSFont) -> NSMutableAttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        let parsed = (try? AttributedString(markdown: String(text), options: options)) ?? AttributedString(String(text))
        let result = NSMutableAttributedString(parsed)
        let whole = NSRange(location: 0, length: result.length)
        result.addAttribute(.font, value: font, range: whole)
        result.addAttribute(.foregroundColor, value: NSColor.labelColor, range: whole)
        result.enumerateAttribute(.inlinePresentationIntent, in: whole) { value, range, _ in
            guard let raw = value as? UInt else { return }
            let intent = InlinePresentationIntent(rawValue: raw)
            if intent.contains(.code) {
                result.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: font.pointSize - 1, weight: .regular), range: range)
                result.addAttribute(.backgroundColor, value: Theme.fill(Theme.Fill.rest), range: range)
            } else {
                var traits: NSFontDescriptor.SymbolicTraits = []
                if intent.contains(.stronglyEmphasized) { traits.insert(.bold) }
                if intent.contains(.emphasized) { traits.insert(.italic) }
                if !traits.isEmpty {
                    let descriptor = font.fontDescriptor.withSymbolicTraits(font.fontDescriptor.symbolicTraits.union(traits))
                    result.addAttribute(.font, value: NSFont(descriptor: descriptor, size: font.pointSize) ?? font, range: range)
                }
            }
        }
        result.enumerateAttribute(.link, in: whole) { value, range, _ in
            guard value != nil else { return }
            result.addAttribute(.foregroundColor, value: NSColor.linkColor, range: range)
        }
        return result
    }
}

/// An agent message: its text, with each table drawn as a grid.
final class MarkdownMessageView: NSView, TranscriptRow {
    private let stack = NSStackView()
    private var width: CGFloat = 0
    private lazy var stackBottom = stack.bottomAnchor.constraint(equalTo: bottomAnchor)
    /// Copy and the time, under a turn's last text once the turn has ended.
    private var actions: ResponseActionsView?
    /// Keeps the actions in view without the mouse, for the newest response.
    var isPinned = false {
        didSet { actions?.isPinned = isPinned }
    }
    private var isHovered = false {
        didSet { actions?.isHovered = isHovered }
    }

    var text = "" {
        didSet { if text != oldValue { rebuild() } }
    }

    init() {
        super.init(frame: .zero)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stackBottom,
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Adds the row with Copy and `date` under the text, once. A response
    /// saved before responses had times has none.
    func showActions(date: Date?) {
        guard actions == nil else { return }
        let actions = ResponseActionsView(date: date) { [weak self] in self?.text ?? "" }
        actions.translatesAutoresizingMaskIntoConstraints = false
        actions.isPinned = isPinned
        actions.isHovered = isHovered
        addSubview(actions)
        stackBottom.isActive = false
        NSLayoutConstraint.activate([
            actions.topAnchor.constraint(equalTo: stack.bottomAnchor, constant: 4),
            // Lines the copy glyph up with the text rather than the button's edge.
            actions.leadingAnchor.constraint(equalTo: leadingAnchor, constant: -4),
            actions.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            actions.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        self.actions = actions
        updateTrackingAreas()
    }

    func fit(width: CGFloat) {
        guard width != self.width else { return }
        self.width = width
        for view in stack.arrangedSubviews { fit(view) }
    }

    /// Only a response with actions tracks the mouse, to show them.
    private var hoverArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        hoverArea = nil
        guard actions != nil else { return }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    private func fit(_ view: NSView) {
        guard width > 0 else { return }
        if let row = view as? TranscriptRow {
            row.fit(width: width)
        } else if let label = view as? NSTextField {
            label.preferredMaxLayoutWidth = width
        }
    }

    /// Keeps the views whose kind of block is unchanged, and the text of
    /// those whose source is unchanged, so a streamed answer only renders
    /// and lays out the block it is still adding to.
    private func rebuild() {
        let blocks = AgentMarkdown.blocks(text)
        for (index, block) in blocks.enumerated() {
            let existing = index < stack.arrangedSubviews.count ? stack.arrangedSubviews[index] : nil
            switch block {
            case .text(let source):
                if let label = existing as? TranscriptLinkLabel {
                    label.show(source)
                } else {
                    let label = TranscriptLinkLabel(wrappingLabelWithString: "")
                    label.isSelectable = true
                    // Lets links in the text be clicked.
                    label.allowsEditingTextAttributes = true
                    label.show(source)
                    place(label, at: index, replacing: existing)
                }
            case .table(let table):
                if let view = existing as? MarkdownTableView {
                    view.table = table
                } else {
                    let view = MarkdownTableView()
                    view.table = table
                    place(view, at: index, replacing: existing)
                }
            case .code(let language, let code):
                if let view = existing as? MarkdownCodeView {
                    view.set(language: language, code: code)
                } else {
                    let view = MarkdownCodeView()
                    view.set(language: language, code: code)
                    place(view, at: index, replacing: existing)
                }
            case .quote(let source):
                if let view = existing as? MarkdownQuoteView {
                    view.source = source
                } else {
                    let view = MarkdownQuoteView()
                    view.source = source
                    place(view, at: index, replacing: existing)
                }
            case .rule:
                if !(existing is MarkdownRuleView) { place(MarkdownRuleView(), at: index, replacing: existing) }
            }
        }
        for view in stack.arrangedSubviews.dropFirst(blocks.count) { view.removeFromSuperview() }
    }

    private func place(_ view: NSView, at index: Int, replacing existing: NSView?) {
        existing?.removeFromSuperview()
        stack.insertArrangedSubview(view, at: index)
        view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        fit(view)
    }
}

/// Under an agent's response: a button that copies its text, and when it came.
private final class ResponseActionsView: NSView {
    private let copyButton = CopyButton(name: "Copy Response")
    private let timeLabel = NSTextField(labelWithString: "")
    var isPinned = false { didSet { updateVisibility() } }
    var isHovered = false { didSet { updateVisibility() } }
    private var isCopyFocused = false { didSet { updateVisibility() } }

    init(date: Date?, text: @escaping () -> String) {
        super.init(frame: .zero)
        copyButton.string = text
        copyButton.onCopiedChange = { [weak self] in self?.updateVisibility() }
        // Tabbing to the button shows the row, so it isn't focused unseen.
        copyButton.onFocusChange = { [weak self] focused in self?.isCopyFocused = focused }
        timeLabel.font = .systemFont(ofSize: Theme.FontSize.caption)
        timeLabel.textColor = .secondaryLabelColor
        if let date {
            timeLabel.stringValue = Self.timeText(date)
            timeLabel.toolTip = date.formatted(date: .complete, time: .shortened)
        }
        timeLabel.isHidden = date == nil
        for view in [copyButton, timeLabel] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 20),
            copyButton.leadingAnchor.constraint(equalTo: leadingAnchor),
            copyButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            copyButton.widthAnchor.constraint(equalToConstant: 22),
            copyButton.heightAnchor.constraint(equalToConstant: 20),
            timeLabel.leadingAnchor.constraint(equalTo: copyButton.trailingAnchor, constant: 4),
            timeLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            timeLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
        ])
        alphaValue = 0
    }

    required init?(coder: NSCoder) { fatalError() }

    /// The time today, then the date and time, with the year if not this one.
    static func timeText(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return date.formatted(date: .omitted, time: .shortened) }
        if calendar.isDate(date, equalTo: Date(), toGranularity: .year) {
            return date.formatted(.dateTime.month(.abbreviated).day().hour().minute())
        }
        return date.formatted(.dateTime.year().month(.abbreviated).day().hour().minute())
    }

    /// Shown for the newest response, under the mouse, with keyboard focus,
    /// and while it says "Copied".
    private func updateVisibility() {
        let shown = isPinned || isHovered || isCopyFocused || copyButton.isShowingCopied
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Theme.reduceMotion ? 0 : Theme.Duration.quick
            animator().alphaValue = shown ? 1 : 0
        }
    }
}

private final class TranscriptHorizontalScrollView: NSScrollView {
    override func scrollWheel(with event: NSEvent) {
        let contentWidth = documentView?.frame.width ?? 0
        let overflowsHorizontally = contentWidth - contentView.bounds.width > 1
        let scrollsHorizontally = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY)
        guard overflowsHorizontally && scrollsHorizontally else {
            if let enclosingScrollView {
                enclosingScrollView.scrollWheel(with: event)
            } else {
                super.scrollWheel(with: event)
            }
            return
        }
        super.scrollWheel(with: event)
    }
}

/// A markdown table: a bold header, a rule between rows, and cells that wrap
/// to the transcript's width. One whose columns can't wrap that narrow and
/// stay readable keeps them wider and scrolls sideways instead.
final class MarkdownTableView: NSView, TranscriptRow {
    private let scroll = TranscriptHorizontalScrollView()
    private let content = MarkdownTableContentView()
    private var width: CGFloat = 0
    private lazy var height = heightAnchor.constraint(equalToConstant: 0)

    var table: AgentMarkdown.Table? {
        didSet {
            content.table = table
            relayout()
        }
    }

    init() {
        super.init(frame: .zero)
        scroll.hasHorizontalScroller = true
        scroll.hasVerticalScroller = false
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.drawsBackground = false
        scroll.verticalScrollElasticity = .none
        scroll.documentView = content
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.wantsLayer = true
        addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            height,
        ])
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(scrolled(_:)), name: NSView.boundsDidChangeNotification, object: scroll.contentView)
    }

    required init?(coder: NSCoder) { fatalError() }

    func fit(width: CGFloat) {
        guard width != self.width else { return }
        self.width = width
        relayout()
    }

    private func relayout() {
        guard width > 0 else { return }
        content.arrange(width: width)
        content.frame = NSRect(origin: .zero, size: content.tableSize)
        if height.constant != content.tableSize.height { height.constant = content.tableSize.height }
        updateFade()
    }

    @objc private func scrolled(_ notification: Notification) {
        updateFade()
    }

    /// Fades the edges where more of the table lies, so a clipped table reads
    /// as one that scrolls.
    private func updateFade() {
        let visible = scroll.contentView.bounds
        let hiddenLeft = visible.minX > 1
        let hiddenRight = content.tableSize.width - visible.maxX > 1
        guard hiddenLeft || hiddenRight else {
            scroll.layer?.mask = nil
            return
        }
        let mask = (scroll.layer?.mask as? CAGradientLayer) ?? CAGradientLayer()
        mask.startPoint = CGPoint(x: 0, y: 0.5)
        mask.endPoint = CGPoint(x: 1, y: 0.5)
        let fade = min(0.2, 28 / max(1, visible.width))
        let clear = NSColor.clear.layerColor, opaque = NSColor.black.layerColor
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        mask.frame = scroll.bounds
        mask.colors = [hiddenLeft ? clear : opaque, opaque, opaque, hiddenRight ? clear : opaque]
        mask.locations = [0, NSNumber(value: fade), NSNumber(value: 1 - fade), 1]
        scroll.layer?.mask = mask
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        updateFade()
    }
}

/// The table itself, laid out for a width and drawn at its own size.
final class MarkdownTableContentView: NSView {
    private static let padding = NSSize(width: 8, height: 5)
    /// Narrower than this, a column's words would break mid-word.
    private static let minimumColumn: CGFloat = 72

    private var labels: [[TranscriptLinkLabel]] = []
    /// Each label's width when its text is on one line, measured once.
    private var naturalWidths: [ObjectIdentifier: CGFloat] = [:]
    /// Each label's height at the column width it was last measured for, so
    /// a row streaming in doesn't measure every row above it again.
    private var heights: [ObjectIdentifier: (width: CGFloat, height: CGFloat)] = [:]
    private var width: CGFloat = 0
    private(set) var tableSize = NSSize.zero
    /// Where each row starts, and the bottom of the last.
    private var rowEdges: [CGFloat] = []

    /// Cells whose text and alignment are as before keep their labels, so a
    /// table streaming in only renders the row it gained.
    var table: AgentMarkdown.Table? {
        didSet {
            guard let table, table.source != oldValue?.source else { return }
            let rows = [table.header] + table.rows
            let before = oldValue.map { [$0.header] + $0.rows } ?? []
            let sameAlignments = oldValue?.alignments == table.alignments
            for (r, row) in rows.enumerated() {
                if r >= labels.count { labels.append([]) }
                for (c, text) in row.enumerated() {
                    let kept = sameAlignments && c < labels[r].count && r < before.count && c < before[r].count && before[r][c] == text
                    if kept { continue }
                    let rendered = table.cell(text, header: r == 0, column: c)
                    if c < labels[r].count {
                        let label = labels[r][c]
                        label.attributedStringValue = rendered
                        naturalWidths[ObjectIdentifier(label)] = nil
                        heights[ObjectIdentifier(label)] = nil
                    } else {
                        let label = TranscriptLinkLabel(wrappingLabelWithString: "")
                        label.isSelectable = true
                        label.allowsEditingTextAttributes = true
                        label.attributedStringValue = rendered
                        addSubview(label)
                        labels[r].append(label)
                    }
                }
                while labels[r].count > row.count { remove(labels[r].removeLast()) }
            }
            while labels.count > rows.count { labels.removeLast().forEach(remove) }
            if width > 0 { arrange(width: width) }
        }
    }

    private func remove(_ label: TranscriptLinkLabel) {
        naturalWidths[ObjectIdentifier(label)] = nil
        heights[ObjectIdentifier(label)] = nil
        label.removeFromSuperview()
    }

    override var isFlipped: Bool { true }

    /// Lays the cells out for `width`: narrow columns keep their natural
    /// width, the wide ones share what is left, and none goes under the
    /// minimum, so `tableSize` may come out wider than asked.
    func arrange(width: CGFloat) {
        self.width = width
        arrange()
    }

    private func measure(_ label: NSTextField, width: CGFloat) -> NSSize {
        let bounds = NSRect(x: 0, y: 0, width: width, height: .greatestFiniteMagnitude)
        let size = label.cell?.cellSize(forBounds: bounds) ?? .zero
        return NSSize(width: ceil(size.width), height: ceil(size.height))
    }

    private func naturalWidth(of label: TranscriptLinkLabel) -> CGFloat {
        let key = ObjectIdentifier(label)
        if let width = naturalWidths[key] { return width }
        let width = measure(label, width: .greatestFiniteMagnitude).width
        naturalWidths[key] = width
        return width
    }

    private func height(of label: TranscriptLinkLabel, width: CGFloat) -> CGFloat {
        let key = ObjectIdentifier(label)
        if let cached = heights[key], cached.width == width { return cached.height }
        let height = measure(label, width: width).height
        heights[key] = (width, height)
        return height
    }

    private func arrange() {
        guard width > 0, let columns = labels.first?.count, columns > 0 else { return }
        let padding = Self.padding
        let natural = (0..<columns).map { column in
            labels.compactMap { column < $0.count ? naturalWidth(of: $0[column]) : nil }.max() ?? 0
        }
        // Narrow columns keep their width; the wide ones share what is left.
        let available = max(width - CGFloat(columns) * 2 * padding.width, CGFloat(columns) * Self.minimumColumn)
        var widths = natural
        if natural.reduce(0, +) > available {
            var remaining = available
            var left = columns
            var cap: CGFloat?
            for column in (0..<columns).sorted(by: { natural[$0] < natural[$1] }) {
                if cap == nil, natural[column] > remaining / CGFloat(left) {
                    cap = max(floor(remaining / CGFloat(left)), Self.minimumColumn)
                }
                if let cap {
                    widths[column] = cap
                } else {
                    remaining -= natural[column]
                    left -= 1
                }
            }
        }
        var y: CGFloat = 0
        rowEdges = [0]
        for row in labels {
            let heights = row.enumerated().map { self.height(of: $1, width: widths[min($0, columns - 1)]) }
            let height = heights.max() ?? 0
            var x: CGFloat = 0
            for (column, label) in row.enumerated() where column < columns {
                label.frame = NSRect(x: x + padding.width, y: y + padding.height, width: widths[column], height: heights[column])
                x += widths[column] + 2 * padding.width
            }
            y += height + 2 * padding.height
            rowEdges.append(y)
        }
        tableSize = NSSize(width: widths.reduce(0, +) + CGFloat(columns) * 2 * padding.width, height: y)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard rowEdges.count > 1 else { return }
        let frame = NSRect(origin: .zero, size: tableSize).insetBy(dx: 0.5, dy: 0.5)
        let outline = NSBezierPath(roundedRect: frame, xRadius: Theme.Radius.small, yRadius: Theme.Radius.small)
        NSGraphicsContext.saveGraphicsState()
        outline.addClip()
        Theme.fill(Theme.Fill.rest).setFill()
        NSRect(x: 0, y: 0, width: tableSize.width, height: rowEdges[1]).fill()
        Theme.hairline.setFill()
        for edge in rowEdges.dropFirst().dropLast() {
            NSRect(x: 0, y: edge - 0.5, width: tableSize.width, height: 1).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        Theme.hairline.setStroke()
        outline.lineWidth = 1
        outline.stroke()
    }
}

/// A fenced code block: a header strip naming the language, with a copy
/// button that shows under the mouse, over monospaced text on a rounded
/// plate. Long lines don't wrap; the text scrolls sideways under a fade at
/// the edge where more of it lies, as tables do.
final class MarkdownCodeView: NSView, TranscriptRow {
    private let header = NSView()
    private let languageLabel = NSTextField(labelWithString: "")
    private let copyButton = CopyButton(name: "Copy Code")
    private let rule = NSView()
    private let scroll = TranscriptHorizontalScrollView()
    /// Holds the text with the padding around it, at the text's own width.
    private let document = NSView()
    private let label = NSTextField(labelWithString: "")
    private var code = ""
    /// The text's size, measured when it changes: it doesn't wrap, so a new
    /// width leaves it as it was.
    private var textSize = NSSize.zero
    private var width: CGFloat = 0
    private lazy var height = heightAnchor.constraint(equalToConstant: 0)
    private var isHovered = false { didSet { updateButtons() } }
    private var isCopyFocused = false { didSet { updateButtons() } }

    private static let headerHeight: CGFloat = 24
    private static let padding = NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
    /// A borderless text field's cell still insets its text 2pt on each side.
    private static let cellInset: CGFloat = 4
    private static let font = NSFont.monospacedSystemFont(ofSize: Theme.FontSize.secondary, weight: .regular)

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        label.font = Self.font
        label.isSelectable = true
        label.lineBreakMode = .byClipping
        label.cell?.wraps = false
        label.cell?.isScrollable = false
        label.maximumNumberOfLines = 0

        languageLabel.font = .systemFont(ofSize: Theme.FontSize.caption, weight: .medium)
        languageLabel.textColor = .secondaryLabelColor

        copyButton.string = { [weak self] in self?.code ?? "" }
        copyButton.onCopiedChange = { [weak self] in self?.updateButtons() }
        copyButton.alphaValue = 0
        // Tabbing to the button shows it, so it isn't focused unseen.
        copyButton.onFocusChange = { [weak self] focused in self?.isCopyFocused = focused }

        rule.wantsLayer = true

        scroll.hasHorizontalScroller = true
        scroll.hasVerticalScroller = false
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.drawsBackground = false
        scroll.verticalScrollElasticity = .none
        scroll.horizontalScrollElasticity = .automatic
        document.addSubview(label)
        scroll.documentView = document
        scroll.wantsLayer = true
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(scrolled(_:)), name: NSView.boundsDidChangeNotification, object: scroll.contentView)

        for view in [header, rule, scroll] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        for view in [languageLabel, copyButton] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            header.addSubview(view)
        }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor),
            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(equalTo: trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: Self.headerHeight),
            languageLabel.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: Self.padding.left),
            languageLabel.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            copyButton.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -3),
            copyButton.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            copyButton.widthAnchor.constraint(equalToConstant: 22),
            copyButton.heightAnchor.constraint(equalToConstant: 20),
            rule.topAnchor.constraint(equalTo: header.bottomAnchor),
            rule.leadingAnchor.constraint(equalTo: leadingAnchor),
            rule.trailingAnchor.constraint(equalTo: trailingAnchor),
            rule.heightAnchor.constraint(equalToConstant: 1),
            scroll.topAnchor.constraint(equalTo: rule.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            height,
        ])
        updateButtons()
    }

    required init?(coder: NSCoder) { fatalError() }

    func set(language: String, code: String) {
        if languageLabel.stringValue != language {
            languageLabel.stringValue = language.isEmpty ? "Code" : language
        }
        guard code != self.code else { return }
        self.code = code
        label.stringValue = code.isEmpty ? " " : code
        let measured = label.intrinsicContentSize
        // Rounded up, plus the cell's 2pt inset on each side: a fractional or
        // inset-less width clips the last glyph of the longest line.
        textSize = NSSize(width: ceil(measured.width) + Self.cellInset, height: ceil(measured.height))
        relayout()
    }

    func fit(width: CGFloat) {
        guard width != self.width else { return }
        self.width = width
        relayout()
    }

    /// The text sits at its own size inside the scrolling view, with the
    /// padding around it, and the block is as tall as the text.
    private func relayout() {
        let p = Self.padding
        let size = textSize
        let documentWidth = max(size.width + p.left + p.right, width)
        document.frame = NSRect(x: 0, y: 0, width: documentWidth, height: size.height + p.top + p.bottom)
        // The document isn't flipped, so the bottom padding is the origin.
        label.frame = NSRect(x: p.left, y: p.bottom, width: size.width, height: size.height)
        let total = Self.headerHeight + 1 + size.height + p.top + p.bottom
        if height.constant != total { height.constant = total }
        updateFade()
    }

    @objc private func scrolled(_ notification: Notification) {
        updateFade()
    }

    /// Fades the edges where more of the text lies.
    private func updateFade() {
        let visible = scroll.contentView.bounds
        let documentWidth = scroll.documentView?.frame.width ?? 0
        let hiddenLeft = visible.minX > 1
        let hiddenRight = documentWidth - visible.maxX > 1
        guard hiddenLeft || hiddenRight else {
            scroll.layer?.mask = nil
            return
        }
        let mask = (scroll.layer?.mask as? CAGradientLayer) ?? CAGradientLayer()
        mask.startPoint = CGPoint(x: 0, y: 0.5)
        mask.endPoint = CGPoint(x: 1, y: 0.5)
        let fade = min(0.2, 28 / max(1, visible.width))
        let clear = NSColor.clear.layerColor, opaque = NSColor.black.layerColor
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        mask.frame = scroll.bounds
        mask.colors = [hiddenLeft ? clear : opaque, opaque, opaque, hiddenRight ? clear : opaque]
        mask.locations = [0, NSNumber(value: fade), NSNumber(value: 1 - fade), 1]
        scroll.layer?.mask = mask
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        updateFade()
    }

    /// The copy button shows under the mouse, with keyboard focus, and
    /// while it says "Copied".
    private func updateButtons() {
        let shown = isHovered || isCopyFocused || copyButton.isShowingCopied
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Theme.reduceMotion ? 0 : Theme.Duration.quick
            copyButton.animator().alphaValue = shown ? 1 : 0
        }
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.cornerRadius = Theme.Radius.row
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = Theme.fill(Theme.Fill.rest).layerColor
        layer?.borderWidth = 1
        layer?.borderColor = Theme.hairline.layerColor
        rule.layer?.backgroundColor = Theme.hairline.layerColor
    }

    /// Only this area is replaced, so the ones AppKit keeps for tooltips stay.
    private var hoverArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }
}

/// A button that says when it gains or loses keyboard focus, for one that
/// hides until it is wanted.
private class FocusReportingButton: HoverButton {
    var onFocusChange: ((Bool) -> Void)?

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { onFocusChange?(true) }
        return became
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { onFocusChange?(false) }
        return resigned
    }
}

/// A borderless button that copies `string`, then shows a green checkmark
/// for a moment and tells VoiceOver it copied.
private final class CopyButton: FocusReportingButton {
    /// What to copy, read when clicked.
    var string: () -> String = { "" }
    /// Called when it starts and stops saying "Copied".
    var onCopiedChange: (() -> Void)?
    var isShowingCopied: Bool { copiedReset != nil }
    private let name: String
    private var copiedReset: DispatchWorkItem?

    private static let copiedImage = NSImage(systemSymbolName: "checkmark", accessibilityDescription: "Copied")?
        .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold))

    init(name: String) {
        self.name = name
        super.init(frame: .zero)
        isBordered = false
        bezelStyle = .accessoryBarAction
        imagePosition = .imageOnly
        setAccessibilityLabel(name)
        showCopy()
        target = self
        action = #selector(copyString(_:))
    }

    required init?(coder: NSCoder) { fatalError() }

    private func showCopy() {
        image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: name)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .medium))
        contentTintColor = .secondaryLabelColor
        toolTip = name
    }

    @objc private func copyString(_ sender: Any?) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string(), forType: .string)
        image = Self.copiedImage
        contentTintColor = .systemGreen
        toolTip = "Copied"
        NSAccessibility.post(element: self, notification: .announcementRequested, userInfo: [
            .announcement: "Copied",
            .priority: NSAccessibilityPriorityLevel.medium.rawValue,
        ])
        copiedReset?.cancel()
        let reset = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.showCopy()
                self.copiedReset = nil
                self.onCopiedChange?()
            }
        }
        copiedReset = reset
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: reset)
        onCopiedChange?()
    }
}

/// A block quote: dimmed text beside a bar as tall as the quote.
final class MarkdownQuoteView: NSView, TranscriptRow {
    private let bar = NSView()
    private let label = TranscriptLinkLabel(wrappingLabelWithString: "")
    private static let inset: CGFloat = 14

    /// The quoted lines, without their markers.
    var source = "" {
        didSet {
            guard source != oldValue else { return }
            label.attributedStringValue = AgentMarkdown.renderQuote(source)
        }
    }

    init() {
        super.init(frame: .zero)
        bar.wantsLayer = true
        bar.layer?.cornerRadius = 1.5
        bar.layer?.cornerCurve = .continuous
        label.isSelectable = true
        label.allowsEditingTextAttributes = true
        for view in [bar, label] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            bar.topAnchor.constraint(equalTo: topAnchor),
            bar.bottomAnchor.constraint(equalTo: bottomAnchor),
            bar.widthAnchor.constraint(equalToConstant: 3),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.inset),
            label.trailingAnchor.constraint(equalTo: trailingAnchor),
            label.topAnchor.constraint(equalTo: topAnchor),
            label.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func fit(width: CGFloat) {
        label.preferredMaxLayoutWidth = width - Self.inset
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        bar.layer?.backgroundColor = NSColor.tertiaryLabelColor.layerColor
    }
}

/// A horizontal rule.
final class MarkdownRuleView: NSView {
    init() {
        super.init(frame: .zero)
        wantsLayer = true
        heightAnchor.constraint(equalToConstant: 1).isActive = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = Theme.hairline.layerColor
    }
}

/// A transcript label whose web links open in Tiller tabs rather than the
/// default browser. A click opens and selects a tab, Cmd+click opens one
/// behind the current tab. Other links, such as mailto:, go to their apps.
final class TranscriptLinkLabel: NSTextField {
    /// The markdown the label shows, so the same text again isn't rendered
    /// or laid out again.
    private var source: String?

    func show(_ markdown: String) {
        guard markdown != source else { return }
        source = markdown
        attributedStringValue = AgentMarkdown.render(markdown)
    }

    /// The field editor's delegate is the label it edits, so it asks here.
    @objc func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        let url = (link as? URL) ?? (link as? String).flatMap { URL(string: $0) }
        guard let url, let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let app = NSApp.delegate as? AppDelegate else { return false }
        let background = OpenDisposition.click(OpenDisposition.currentFlags) == .backgroundTab
        // In the window the link is in, which has the chat's profile.
        let profile = (window?.windowController as? BrowserWindowController)?.profile
        app.openInNewTab(url.absoluteString, background: background, profile: profile)
        return true
    }
}
