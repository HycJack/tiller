import AppKit

/// What the address bar's site button opens, as Chrome's page info does:
/// the site, whether its connection is secure, and its camera and microphone
/// choices, each of which can be changed or put back to asking.
@MainActor
final class SiteInfoController: NSViewController {
    private let url: String
    private let origin: String
    private let permissions: SitePermissions
    private var popUps: [MediaDevice: NSPopUpButton] = [:]

    /// The choices a device's pop-up offers, in order. Nil is Ask.
    private static let choices: [(SitePermission?, String)] = [(nil, "Ask"), (.allow, "Allow"), (.block, "Block")]

    init(url: String, permissions: SitePermissions) {
        self.url = url
        origin = SitePermissions.origin(url)
        self.permissions = permissions
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let secure = url.hasPrefix("https://")
        let site = NSTextField(labelWithString: HistoryStore.host(of: url) ?? SitePermissions.displayName(origin))
        site.font = .systemFont(ofSize: Theme.FontSize.title, weight: .semibold)
        site.lineBreakMode = .byTruncatingMiddle

        let icon = NSImageView()
        icon.image = Theme.symbol(
            secure ? "lock.fill" : "exclamationmark.triangle.fill", size: Theme.Symbol.bar,
            label: secure ? "Secure" : "Not Secure")
        icon.contentTintColor = secure ? Theme.secondaryText : Theme.danger
        icon.setContentHuggingPriority(.required, for: .horizontal)
        let status = NSTextField(labelWithString: secure ? "Connection is secure" : "Connection is not secure")
        status.font = .systemFont(ofSize: Theme.FontSize.body, weight: .medium)
        let note = NSTextField(wrappingLabelWithString: secure
            ? "Information you send to this site, such as passwords, is private."
            : "Don't enter passwords or other sensitive information on this site: others on the network could see it.")
        note.font = .systemFont(ofSize: Theme.FontSize.secondary)
        note.textColor = Theme.secondaryText
        let statusText = NSStackView(views: [status, note])
        statusText.orientation = .vertical
        statusText.alignment = .leading
        statusText.spacing = 2
        let statusRow = NSStackView(views: [icon, statusText])
        statusRow.alignment = .top
        statusRow.spacing = 10

        let header = NSTextField(labelWithString: "")
        header.attributedStringValue = Theme.sectionHeader("Permissions")
        let grid = NSGridView(numberOfColumns: 2, rows: 0)
        grid.rowSpacing = 6
        grid.columnSpacing = 10
        let saved = permissions.permissions(for: origin)
        for device in MediaDevice.allCases {
            let label = NSTextField(labelWithString: device == .camera ? "Camera" : "Microphone")
            label.font = .systemFont(ofSize: Theme.FontSize.body)
            let popUp = NSPopUpButton()
            popUp.controlSize = .small
            popUp.font = .systemFont(ofSize: Theme.FontSize.secondary)
            for (_, title) in Self.choices { popUp.addItem(withTitle: title) }
            popUp.selectItem(at: Self.choices.firstIndex { $0.0 == saved[device] } ?? 0)
            popUp.target = self
            popUp.action = #selector(permissionChanged(_:))
            popUp.setAccessibilityLabel(label.stringValue)
            popUps[device] = popUp
            grid.addRow(with: [label, popUp])
        }
        grid.column(at: 0).xPlacement = .leading
        grid.column(at: 1).xPlacement = .trailing

        let stack = NSStackView(views: [site, statusRow, header, grid])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.setCustomSpacing(16, after: statusRow)
        stack.setCustomSpacing(8, after: header)
        stack.edgeInsets = NSEdgeInsets(
            top: Theme.Padding.section, left: Theme.Padding.section, bottom: Theme.Padding.section,
            right: Theme.Padding.section)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let view = NSView()
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            view.widthAnchor.constraint(equalToConstant: Theme.popoverWidth),
            stack.topAnchor.constraint(equalTo: view.topAnchor),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            grid.trailingAnchor.constraint(equalTo: stack.trailingAnchor, constant: -Theme.Padding.section),
            note.widthAnchor.constraint(lessThanOrEqualToConstant: Theme.popoverWidth - 2 * Theme.Padding.section - 30),
        ])
        self.view = view
    }

    @objc private func permissionChanged(_ sender: NSPopUpButton) {
        guard let device = popUps.first(where: { $0.value === sender })?.key,
              Self.choices.indices.contains(sender.indexOfSelectedItem) else { return }
        permissions.set(Self.choices[sender.indexOfSelectedItem].0, for: [device], origin: origin)
    }
}
