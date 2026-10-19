import AppKit

/// A browser window. It holds one profile's browser, or with Profile Tabs
/// every open profile's, which a rail on its left chooses among. Only the
/// shown profile's toolbar and address bar are up. The others' views stay
/// in the window, hidden, so their tabs can still start and an agent can
/// wake one, and the window's menu actions reach the shown one, which is
/// the host's next responder.
@MainActor
final class BrowserWindowHost: NSWindowController, NSWindowDelegate {
    /// The open browser windows.
    private(set) static var all: [BrowserWindowHost] = []

    /// The window that holds every profile, while Profile Tabs is on.
    static var railHost: BrowserWindowHost? { all.first { $0.hasRail } }

    /// In the rail's order, which is the order of `ProfileContext.all`.
    private(set) var browsers: [BrowserWindowController] = []
    private(set) var shown: BrowserWindowController?
    /// Whether this window holds every profile, with the rail.
    private(set) var hasRail: Bool
    /// Set once the close button or Close Window closes every profile in a
    /// window with the rail, so they all open again at the next launch.
    private(set) var isClosingAll = false

    private let rail = ProfileRailView()
    /// Holds the browsers' views, the shown one on top.
    private let area = NSView()
    private lazy var railWidth = rail.widthAnchor.constraint(equalToConstant: 0)

    private static let railFrameName = "TillerProfileTabsWindow"

    init(rail hasRail: Bool, profile: ProfileContext) {
        self.hasRail = hasRail
        let window = BrowserWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Tiller"
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 520, height: 360)
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.toolbarStyle = .unified
        super.init(window: window)
        window.delegate = self
        window.onGoBack = { [weak self] in self?.shown?.goBack(nil) }
        window.onGoForward = { [weak self] in self?.shown?.goForward(nil) }

        let content = NSView()
        rail.translatesAutoresizingMaskIntoConstraints = false
        area.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(rail)
        content.addSubview(area)
        NSLayoutConstraint.activate([
            rail.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            rail.topAnchor.constraint(equalTo: content.topAnchor),
            rail.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            railWidth,
            area.leadingAnchor.constraint(equalTo: rail.trailingAnchor),
            area.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            area.topAnchor.constraint(equalTo: content.topAnchor),
            area.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        window.contentView = content
        rail.onSelect = { [weak self] id in
            guard let self, let browser = self.browsers.first(where: { $0.profile.id == id }) else { return }
            self.show(browser)
        }
        rail.onMove = { [weak self] id, index in
            ProfileContext.move(id, to: index)
            self?.sortBrowsers()
        }
        rail.menuFor = { [weak self] id in self?.menu(for: id) }
        rail.addMenu = { Self.addMenu() }
        updateRail()

        let name = hasRail ? Self.railFrameName : Self.frameName(for: profile)
        window.setFrameAutosaveName(name)
        // Turning Profile Tabs on for the first time keeps the profile's
        // own window's place.
        if !window.setFrameUsingName(name), !(hasRail && window.setFrameUsingName(Self.frameName(for: profile))) {
            // A profile's first window steps down from another one's.
            if let other = Self.all.compactMap(\.window).last(where: { $0.isVisible }) {
                window.setFrameTopLeftPoint(window.cascadeTopLeft(from: NSPoint(x: other.frame.minX, y: other.frame.maxY)))
            } else {
                window.center()
            }
        }
        Self.all.append(self)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// The default profile keeps the name from before profiles shared a
    /// process; the others get their own, so their windows keep their places.
    private static func frameName(for profile: ProfileContext) -> String {
        profile.id == Profiles.defaultID ? "TillerBrowserWindow" : "TillerBrowserWindow." + profile.id
    }

    /// The window a newly opened profile goes in: the one with the rail
    /// while Profile Tabs is on, else a new one.
    static func forOpening(_ profile: ProfileContext) -> BrowserWindowHost {
        if Settings.profileTabs, let railHost { return railHost }
        return BrowserWindowHost(rail: Settings.profileTabs, profile: profile)
    }

    // MARK: Browsers

    /// Puts `browser`'s views in the window, shown when `show` is set or
    /// nothing is shown yet, else hidden behind the shown one.
    func add(_ browser: BrowserWindowController, show: Bool) {
        guard !browsers.contains(where: { $0 === browser }) else { return }
        isClosingAll = false
        window?.layoutIfNeeded()
        let view = browser.rootView
        view.isHidden = true
        view.frame = area.bounds
        view.autoresizingMask = [.width, .height]
        area.addSubview(view, positioned: .below, relativeTo: nil)
        browsers.append(browser)
        browser.host = self
        sortBrowsers()
        if show || shown == nil { self.show(browser) } else { updateRail() }
    }

    /// Takes `browser` out of the window, showing the next one if it was
    /// shown. The window closes with its last browser.
    func remove(_ browser: BrowserWindowController) {
        guard let index = browsers.firstIndex(where: { $0 === browser }) else { return }
        browsers.remove(at: index)
        if shown === browser {
            if let window {
                browser.uninstall(from: window)
                // A toolbar is in one window at a time, and the browser may go
                // to another.
                window.toolbar = nil
            }
            shown = nil
            nextResponder = nil
        }
        browser.rootView.removeFromSuperview()
        browser.host = nil
        if shown == nil, !browsers.isEmpty { show(browsers[min(index, browsers.count - 1)]) }
        updateRail()
        if browsers.isEmpty { window?.close() }
    }

    /// Brings `browser` to the front of the window: its views, toolbar and
    /// address bar, and the keyboard.
    func show(_ browser: BrowserWindowController) {
        guard let window, browser.host === self, browser !== shown else { return }
        // A page with the whole screen keeps it until it gives it back.
        guard shown?.hasFullscreenPage != true else { return NSSound.beep() }
        isClosingAll = false
        let old = shown
        let view = browser.rootView
        // Views are moved only while hidden: Chromium counts a page that
        // moved while visible as visible again.
        view.isHidden = true
        area.addSubview(view, positioned: .above, relativeTo: nil)
        if let old { old.uninstall(from: window) }
        shown = browser
        nextResponder = browser
        view.isHidden = false
        browser.install(in: window)
        // An agent working in the profile left keeps its page drawing.
        if let old { old.rootView.isHidden = !old.isAwake }
        if window.isKeyWindow { Profiles.markUsed(browser.profile.id) }
        updateRail()
        browser.didShow()
    }

    /// A browser's last tab closed: the profile closes with it.
    func browserDidClose(_ browser: BrowserWindowController) {
        browser.shutDown()
        remove(browser)
    }

    /// A hidden browser's tabs an agent woke must draw, so its views show,
    /// under the shown one, while any is awake.
    func awakeChanged(_ browser: BrowserWindowController) {
        guard browser !== shown, browsers.contains(where: { $0 === browser }) else { return }
        let view = browser.rootView
        guard view.isHidden == browser.isAwake else { return }
        if browser.isAwake, let shown {
            area.addSubview(view, positioned: .below, relativeTo: shown.rootView)
        }
        view.isHidden = !browser.isAwake
    }

    /// In the order of `ProfileContext.all`, which the rail and the next
    /// launch keep.
    func sortBrowsers() {
        let order = ProfileContext.all.map(\.id)
        browsers.sort { (order.firstIndex(of: $0.profile.id) ?? .max) < (order.firstIndex(of: $1.profile.id) ?? .max) }
        updateRail()
    }

    // MARK: Profile Tabs

    /// Turns the rail on or off for this window. Each browser's toolbar
    /// names its profile only without the rail.
    private func setRail(_ on: Bool) {
        guard on != hasRail, let window, let profile = shown?.profile ?? browsers.first?.profile else { return }
        hasRail = on
        window.setFrameAutosaveName(on ? Self.railFrameName : Self.frameName(for: profile))
        updateRail()
        browsers.forEach { $0.updateProfileButton() }
    }

    /// Gathers every profile into the front window when Profile Tabs turns
    /// on, and gives each its own window again when it turns off.
    static func applyProfileTabs() {
        if Settings.profileTabs {
            guard let target = ProfileContext.active?.window?.host ?? all.first else { return }
            target.setRail(true)
            for host in all where host !== target {
                for browser in host.browsers {
                    host.remove(browser)
                    target.add(browser, show: false)
                }
            }
            target.showWindow(nil)
        } else {
            for host in all where host.hasRail {
                host.setRail(false)
                for browser in host.browsers where browser !== host.shown {
                    host.remove(browser)
                    let other = BrowserWindowHost(rail: false, profile: browser.profile)
                    other.add(browser, show: true)
                    other.showWindow(nil)
                }
                host.window?.makeKeyAndOrderFront(nil)
            }
        }
    }

    // MARK: Rail

    /// Shows the rail while the window has it and no page has the screen,
    /// and fills it with the open profiles.
    func updateRail() {
        let visible = hasRail && shown?.hasFullscreenPage != true
        rail.isHidden = !visible
        railWidth.constant = visible ? ProfileRailView.width : 0
        guard hasRail else { return }
        let names = browsers.map(\.profile.name)
        let initials = ProfileRailView.initials(for: names)
        rail.items = browsers.enumerated().map { index, browser in
            ProfileRailView.Item(
                id: browser.profile.id, name: names[index], initials: initials[index],
                shown: browser === shown, busy: browser !== shown && browser.isAgentBusy
            )
        }
    }

    private func menu(for id: String) -> NSMenu? {
        guard let browser = browsers.first(where: { $0.profile.id == id }) else { return nil }
        let profile = browser.profile
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(MenuActionItem(title: "Rename…") { [weak self] in
            ProfileNamePrompt.run("Rename \(profile.name)", button: "Rename", initial: profile.name, on: self?.window) { name in
                try Profiles.rename(profile.id, to: name)
            }
        })
        menu.addItem(.separator())
        menu.addItem(MenuActionItem(title: "Close Profile") { browser.closeAllTabs() })
        let others = MenuActionItem(title: "Close Other Profiles") { [weak self] in
            self?.browsers.filter { $0 !== browser }.forEach { $0.closeAllTabs() }
        }
        others.isEnabled = browsers.count > 1
        menu.addItem(others)
        return menu
    }

    /// The rail's plus button: the profiles that aren't open, and a new one.
    private static func addMenu() -> NSMenu {
        let menu = NSMenu()
        for profile in Profiles.all where ProfileContext.opened(profile.id) == nil {
            menu.addItem(MenuActionItem(title: profile.name) { ProfileContext.open(profile.id) })
        }
        if !menu.items.isEmpty { menu.addItem(.separator()) }
        menu.addItem(withTitle: "New Profile…", action: #selector(AppDelegate.newProfile(_:)), keyEquivalent: "")
        return menu
    }

    // MARK: NSWindowDelegate

    /// Closes every tab of every profile first. Each page's beforeunload may
    /// still cancel its own close. The window closes with its last profile.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard !browsers.isEmpty else { return true }
        if hasRail {
            isClosingAll = true
            Profiles.setOpen(ProfileContext.all.map(\.id))
        }
        browsers.forEach { $0.closeAllTabs() }
        return false
    }

    func windowWillClose(_ notification: Notification) {
        for browser in browsers {
            browser.shutDown()
            browser.host = nil
        }
        browsers = []
        shown = nil
        nextResponder = nil
        Self.all.removeAll { $0 === self }
    }

    /// The profile in front is the one a plain launch, links from other apps
    /// and the CLI pick.
    func windowDidBecomeKey(_ notification: Notification) {
        if let shown { Profiles.markUsed(shown.profile.id) }
    }

    func windowDidResize(_ notification: Notification) {
        shown?.windowDidResize()
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        shown?.windowDidEndLiveResize()
    }

    func windowWillEnterFullScreen(_ notification: Notification) {
        browsers.forEach { $0.windowWillEnterFullScreen() }
    }

    func windowDidEnterFullScreen(_ notification: Notification) {
        browsers.forEach { $0.windowDidEnterFullScreen() }
    }

    func windowDidFailToEnterFullScreen(_ window: NSWindow) {
        browsers.forEach { $0.windowDidFailToEnterFullScreen() }
    }

    func windowWillExitFullScreen(_ notification: Notification) {
        browsers.forEach { $0.windowWillExitFullScreen() }
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        browsers.forEach { $0.windowDidExitFullScreen() }
    }

    func window(_ window: NSWindow, willUseFullScreenPresentationOptions proposedOptions: NSApplication.PresentationOptions) -> NSApplication.PresentationOptions {
        shown?.fullScreenPresentationOptions(proposedOptions) ?? proposedOptions
    }
}
