import AppKit

/// Asks whether a site may use the camera or microphone: a glass card at the
/// top of the page naming the site, with Block, Allow Once and Always Allow.
/// Closing it denies the request this once. When macOS refuses Tiller the
/// devices instead, it says so and offers System Settings.
final class MediaPermissionBar: NSView {
    enum Answer {
        /// Denied, and denied from now on.
        case block
        case allowOnce
        /// Allowed, and allowed from now on.
        case allowAlways
        /// Closed: denied this once.
        case dismiss
    }

    enum Content: Equatable {
        case request(MediaRequest)
        /// macOS refuses Tiller these devices.
        case refused(Set<MediaDevice>)
    }

    var onAnswer: ((Answer) -> Void)?
    var onOpenSettings: (() -> Void)?
    private(set) var content: Content?

    private let glass = GlassView()
    private let icon = NSImageView()
    private let label = NSTextField(wrappingLabelWithString: "")
    let blockButton = NSButton(title: "Block", target: nil, action: nil)
    let allowOnceButton = NSButton(title: "Allow Once", target: nil, action: nil)
    let allowButton = NSButton(title: "Always Allow", target: nil, action: nil)
    let settingsButton = NSButton(title: "Open System Settings", target: nil, action: nil)
    private let closeButton = Theme.iconButton("xmark", label: "Close", size: Theme.Symbol.inline, frame: Theme.ButtonSize.inline)

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)

        icon.contentTintColor = Theme.danger
        icon.setContentHuggingPriority(.required, for: .horizontal)

        label.font = .systemFont(ofSize: Theme.FontSize.body)
        label.textColor = Theme.text
        label.isSelectable = false
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        closeButton.image = Theme.closeImage(size: 9, label: "Close")
        (closeButton as? HoverButton)?.plateRadius = Theme.ButtonSize.inline / 2
        closeButton.target = self
        closeButton.action = #selector(close(_:))

        for (button, action) in [
            (blockButton, #selector(block(_:))),
            (allowOnceButton, #selector(allowOnce(_:))),
            (allowButton, #selector(allowAlways(_:))),
            (settingsButton, #selector(openSettings(_:))),
        ] {
            button.target = self
            button.action = action
            button.bezelStyle = .push
            button.controlSize = .regular
        }
        // No Return key equivalent: a key typed into the page must never
        // answer for the user.

        let top = NSStackView(views: [icon, label, closeButton])
        top.alignment = .top
        top.spacing = 8
        let buttons = NSStackView(views: [NSView(), blockButton, allowOnceButton, allowButton, settingsButton])
        buttons.spacing = 8
        let column = NSStackView(views: [top, buttons])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 10
        column.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 10)
        NSLayoutConstraint.activate([
            top.widthAnchor.constraint(equalTo: column.widthAnchor, constant: -24),
            buttons.widthAnchor.constraint(equalTo: top.widthAnchor),
        ])

        glass.contentView = column
        glass.cornerRadius = Theme.Radius.plate
        // As the find bar's: still visible over a white page.
        glass.tintColor = Theme.background.dynamic(alpha: 0.85)
        glass.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glass)
        NSLayoutConstraint.activate([
            glass.topAnchor.constraint(equalTo: topAnchor),
            glass.bottomAnchor.constraint(equalTo: bottomAnchor),
            glass.leadingAnchor.constraint(equalTo: leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: trailingAnchor),
            glass.widthAnchor.constraint(greaterThanOrEqualToConstant: 300),
        ])
        // Narrows when the page is too narrow to hold it.
        let width = glass.widthAnchor.constraint(equalToConstant: 440)
        width.priority = .defaultHigh
        width.isActive = true
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(_ content: Content) {
        self.content = content
        let devices: Set<MediaDevice>
        let text: NSMutableAttributedString
        let font = NSFont.systemFont(ofSize: Theme.FontSize.body)
        let bold = NSFont.systemFont(ofSize: Theme.FontSize.body, weight: .semibold)
        switch content {
        case .request(let request):
            devices = request.devices
            text = NSMutableAttributedString(
                string: SitePermissions.displayName(request.origin), attributes: [.font: bold, .foregroundColor: Theme.text])
            text.append(NSAttributedString(
                string: " wants to use your \(MediaDevice.names(request.devices)).",
                attributes: [.font: font, .foregroundColor: Theme.text]))
        case .refused(let refused):
            devices = refused
            text = NSMutableAttributedString(
                string: "macOS isn't letting Tiller use your \(MediaDevice.names(refused)). "
                    + "Turn Tiller on in Privacy & Security, then reload the page.",
                attributes: [.font: font, .foregroundColor: Theme.text])
        }
        label.attributedStringValue = text
        setAccessibilityLabel(text.string)
        let symbol = devices.contains(.camera) ? "video.fill" : "mic.fill"
        icon.image = Theme.symbol(symbol, size: Theme.Symbol.bar, label: MediaDevice.names(devices))
        let asking = if case .request = content { true } else { false }
        for button in [blockButton, allowOnceButton, allowButton] { button.isHidden = !asking }
        settingsButton.isHidden = asking
    }

    @objc private func block(_ sender: Any?) { onAnswer?(.block) }
    @objc private func allowOnce(_ sender: Any?) { onAnswer?(.allowOnce) }
    @objc private func allowAlways(_ sender: Any?) { onAnswer?(.allowAlways) }
    @objc private func close(_ sender: Any?) { onAnswer?(.dismiss) }
    @objc private func openSettings(_ sender: Any?) { onOpenSettings?() }

    // Clicks on the card stay on it rather than reaching the page.
    override var mouseDownCanMoveWindow: Bool { false }
}
