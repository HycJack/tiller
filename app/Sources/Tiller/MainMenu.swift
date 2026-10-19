import AppKit

/// The menu bar, built in code so the app needs no xib and no ibtool.
enum MainMenu {
    /// Shortcuts from this menu go to the page first. See `Tab`'s key handling.
    static let editTitle = "Edit"
    /// Edit > Find, whose shortcuts go before the page's all the same.
    static let findTitle = "Find"

    @MainActor
    static func build() -> NSMenu {
        let main = NSMenu()

        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Tiller", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        if Updater.isAvailable {
            let update = appMenu.addItem(withTitle: "Check for Updates…", action: #selector(Updater.checkForUpdates(_:)), keyEquivalent: "")
            update.target = Updater.shared
        }
        appMenu.addItem(.separator())
        // Reaches the AppDelegate at the end of the responder chain.
        appMenu.addItem(withTitle: "Settings…", action: #selector(AppDelegate.showSettings(_:)), keyEquivalent: ",")
        appMenu.addItem(withTitle: "Install Command Line Tool…", action: #selector(AppDelegate.installCommandLineTool(_:)), keyEquivalent: "")
        // Goes to the key window's BrowserWindowController, like File's items.
        appMenu.addItem(withTitle: "Import from Chrome…", action: #selector(BrowserWindowController.importFromChrome(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        let services = NSMenu(title: "Services")
        add(services, titled: "Services", to: appMenu)
        NSApp.servicesMenu = services
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Tiller", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Tiller", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        add(appMenu, titled: "Tiller", to: main)

        // Browser actions have no target, so they go to the key window's
        // BrowserWindowController through the responder chain.
        let file = NSMenu(title: "File")
        file.addItem(withTitle: "New Tab", action: #selector(BrowserWindowController.newTab(_:)), keyEquivalent: "t")
        file.addItem(withTitle: "Open Location…", action: #selector(BrowserWindowController.openLocation(_:)), keyEquivalent: "l")
        file.addItem(.separator())
        file.addItem(withTitle: "Print…", action: #selector(BrowserWindowController.printPage(_:)), keyEquivalent: "p")
        file.addItem(.separator())
        file.addItem(withTitle: "Close Tab", action: #selector(BrowserWindowController.closeTab(_:)), keyEquivalent: "w")
        file.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "W")
        file.addItem(withTitle: "Reopen Closed Tab", action: #selector(BrowserWindowController.reopenClosedTab(_:)), keyEquivalent: "T")
        add(file, titled: "File", to: main)

        let edit = NSMenu(title: editTitle)
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        let pasteMatching = edit.addItem(withTitle: "Paste and Match Style", action: #selector(NSTextView.pasteAsPlainText(_:)), keyEquivalent: "V")
        pasteMatching.keyEquivalentModifierMask = [.command, .option, .shift]
        edit.addItem(withTitle: "Delete", action: #selector(NSText.delete(_:)), keyEquivalent: "")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.addItem(.separator())
        let find = NSMenu(title: findTitle)
        find.addItem(withTitle: "Find…", action: #selector(BrowserWindowController.showFindBar(_:)), keyEquivalent: "f")
        find.addItem(withTitle: "Find Next", action: #selector(BrowserWindowController.findNext(_:)), keyEquivalent: "g")
        find.addItem(withTitle: "Find Previous", action: #selector(BrowserWindowController.findPrevious(_:)), keyEquivalent: "G")
        add(find, titled: findTitle, to: edit)
        edit.addItem(withTitle: "Fill Saved Password", action: #selector(BrowserWindowController.fillPassword(_:)), keyEquivalent: "")
        add(edit, titled: editTitle, to: main)

        let view = NSMenu(title: "View")
        view.addItem(withTitle: "Reload Page", action: #selector(BrowserWindowController.reloadPage(_:)), keyEquivalent: "r")
        view.addItem(withTitle: "Stop", action: #selector(BrowserWindowController.stopLoading(_:)), keyEquivalent: ".")
        view.addItem(.separator())
        view.addItem(withTitle: "Actual Size", action: #selector(BrowserWindowController.actualSize(_:)), keyEquivalent: "0")
        view.addItem(withTitle: "Zoom In", action: #selector(BrowserWindowController.zoomIn(_:)), keyEquivalent: "=")
        // Cmd+Plus (Shift+=) zooms in too, as in other browsers.
        hidden(view, "Zoom In", #selector(BrowserWindowController.zoomIn(_:)), "+", [.command])
        view.addItem(withTitle: "Zoom Out", action: #selector(BrowserWindowController.zoomOut(_:)), keyEquivalent: "-")
        view.addItem(.separator())
        agentItem = view.addItem(withTitle: "Show Agent", action: #selector(BrowserWindowController.toggleAgentPanel(_:)), keyEquivalent: "")
        applyAgentShortcut()
        view.addItem(withTitle: "Show Tab Sidebar", action: #selector(BrowserWindowController.toggleTabSidebar(_:)), keyEquivalent: "L")
        let collapse = view.addItem(withTitle: "Collapse Tab Sidebar", action: #selector(BrowserWindowController.toggleSidebarCollapsed(_:)), keyEquivalent: "s")
        collapse.keyEquivalentModifierMask = [.command, .control]
        view.addItem(withTitle: "Profile Tabs", action: #selector(AppDelegate.toggleProfileTabs(_:)), keyEquivalent: "")
        view.addItem(.separator())
        let source = view.addItem(withTitle: "View Page Source", action: #selector(BrowserWindowController.viewPageSource(_:)), keyEquivalent: "u")
        source.keyEquivalentModifierMask = [.command, .option]
        // Cmd+Shift+U shows the source too.
        hidden(view, "View Page Source", #selector(BrowserWindowController.viewPageSource(_:)), "u", [.command, .shift])
        let devTools = view.addItem(withTitle: "Developer Tools", action: #selector(BrowserWindowController.showDevTools(_:)), keyEquivalent: "i")
        devTools.keyEquivalentModifierMask = [.command, .option]
        view.addItem(.separator())
        let fullScreen = view.addItem(withTitle: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        fullScreen.keyEquivalentModifierMask = [.command, .control]
        add(view, titled: "View", to: main)

        let history = NSMenu(title: "History")
        history.addItem(withTitle: "Back", action: #selector(BrowserWindowController.goBack(_:)), keyEquivalent: "[")
        history.addItem(withTitle: "Forward", action: #selector(BrowserWindowController.goForward(_:)), keyEquivalent: "]")
        history.addItem(.separator())
        history.addItem(withTitle: "Clear History…", action: #selector(BrowserWindowController.clearHistory(_:)), keyEquivalent: "")
        history.delegate = historyMenu
        add(history, titled: "History", to: main)

        // Filled each time it opens, since another Tiller may change the profiles.
        profiles.delegate = profilesMenu
        add(profiles, titled: "Profiles", to: main)

        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        window.addItem(.separator())
        window.addItem(withTitle: "Show Previous Tab", action: #selector(BrowserWindowController.selectPreviousTab(_:)), keyEquivalent: "{")
        window.addItem(withTitle: "Show Next Tab", action: #selector(BrowserWindowController.selectNextTab(_:)), keyEquivalent: "}")
        // Ctrl+Tab and Ctrl+Shift+Tab, Cmd+Option+Right and Cmd+Option+Left, and
        // Cmd+1 to Cmd+9, work but stay out of sight.
        hidden(window, "Show Next Tab", #selector(BrowserWindowController.selectNextTab(_:)), "\t", [.control])
        hidden(window, "Show Previous Tab", #selector(BrowserWindowController.selectPreviousTab(_:)), "\t", [.control, .shift])
        hidden(window, "Show Next Tab", #selector(BrowserWindowController.selectNextTab(_:)), arrowKey(NSRightArrowFunctionKey), [.command, .option])
        hidden(window, "Show Previous Tab", #selector(BrowserWindowController.selectPreviousTab(_:)), arrowKey(NSLeftArrowFunctionKey), [.command, .option])
        for number in 1...9 {
            let item = hidden(window, "Select Tab \(number)", #selector(BrowserWindowController.selectTabByNumber(_:)), "\(number)", [.command])
            item.tag = number
        }
        window.addItem(.separator())
        let previousProfile = window.addItem(withTitle: "Show Previous Profile", action: #selector(AppDelegate.showPreviousProfile(_:)), keyEquivalent: "[")
        previousProfile.keyEquivalentModifierMask = [.control, .command]
        let nextProfile = window.addItem(withTitle: "Show Next Profile", action: #selector(AppDelegate.showNextProfile(_:)), keyEquivalent: "]")
        nextProfile.keyEquivalentModifierMask = [.control, .command]
        // Ctrl+Cmd+1 to Ctrl+Cmd+9 work but stay out of sight.
        for number in 1...9 {
            let item = hidden(window, "Show Profile \(number)", #selector(AppDelegate.showProfileByNumber(_:)), "\(number)", [.control, .command])
            item.tag = number
        }
        window.addItem(.separator())
        window.addItem(withTitle: "Downloads", action: #selector(BrowserWindowController.showDownloads(_:)), keyEquivalent: "J")
        window.addItem(.separator())
        window.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        window.addItem(.separator())
        add(window, titled: "Window", to: main)
        NSApp.windowsMenu = window

        let help = NSMenu(title: "Help")
        help.addItem(withTitle: "Tiller Help", action: #selector(AppDelegate.openHelp(_:)), keyEquivalent: "?")
        help.addItem(withTitle: "Tiller on GitHub", action: #selector(AppDelegate.openGitHub(_:)), keyEquivalent: "")
        add(help, titled: "Help", to: main)
        NSApp.helpMenu = help

        return main
    }

    @MainActor private static let historyMenu = HistoryMenuDelegate()
    @MainActor fileprivate static var historyDelegate: HistoryMenuDelegate? { historyMenu }
    @MainActor private static let profilesMenu = ProfilesMenuDelegate()

    /// The Profiles menu, which the toolbar's profile button shows too.
    @MainActor static let profiles = NSMenu(title: "Profiles")

    /// View > Show Agent, whose shortcut Settings can change.
    @MainActor private static var agentItem: NSMenuItem?

    /// Gives Show Agent the shortcut in Settings.
    @MainActor
    static func applyAgentShortcut() {
        let shortcut = Settings.agentShortcut
        agentItem?.keyEquivalent = shortcut?.key ?? ""
        agentItem?.keyEquivalentModifierMask = shortcut?.modifiers ?? []
    }

    /// The title of another menu item that already uses `shortcut`, hidden ones included.
    @MainActor
    static func conflict(with shortcut: Shortcut) -> String? {
        func search(_ menu: NSMenu) -> String? {
            for item in menu.items {
                if item !== agentItem, Shortcut(menuItem: item) == shortcut { return item.title }
                if let submenu = item.submenu, let title = search(submenu) { return title }
            }
            return nil
        }
        return NSApp.mainMenu.flatMap(search)
    }

    /// The key equivalent for an arrow key, from its `NS…ArrowFunctionKey` code.
    private static func arrowKey(_ code: Int) -> String {
        UnicodeScalar(code).map { String(Character($0)) } ?? ""
    }

    @MainActor
    @discardableResult
    private static func hidden(
        _ menu: NSMenu, _ title: String, _ action: Selector, _ key: String, _ modifiers: NSEvent.ModifierFlags
    ) -> NSMenuItem {
        let item = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.isHidden = true
        item.allowsKeyEquivalentWhenHidden = true
        return item
    }

    @MainActor
    private static func add(_ submenu: NSMenu, titled title: String, to menu: NSMenu) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        menu.addItem(item)
    }
}

/// Fills the History menu with the front window's profile's recently visited
/// pages each time it opens, between Back/Forward and Clear History.
@MainActor
private final class HistoryMenuDelegate: NSObject, NSMenuDelegate {
    private static let recentTag = 1001
    private static let limit = 15
    /// The pages shown last time, and the history they came from. The menu
    /// opens with these rather than waiting on the database, which an
    /// import or a search may be holding, and asks for fresh ones.
    private var pages: [HistoryPage] = []
    /// The pages' favicons by URL, decoded once when fresh pages arrive
    /// rather than each time the menu opens.
    private var icons: [String: NSImage] = [:]
    private var pagesVersion = -1
    /// The history `pages` came from.
    private weak var pagesStore: HistoryStore?
    /// The menu, for filling once fresh pages arrive.
    private weak var menu: NSMenu?

    func menuNeedsUpdate(_ menu: NSMenu) {
        // AppKit also asks while it looks for a shortcut's menu item, on every
        // Command and Control key press. Only the fixed items have shortcuts.
        if let event = NSApp.currentEvent, event.type == .keyDown,
            !event.modifierFlags.intersection([.command, .control]).isEmpty
        {
            return
        }
        self.menu = menu
        guard let store = ProfileContext.active?.history else { return }
        if store !== pagesStore {
            // Another profile's pages mustn't show while this one's load.
            pages = []
            icons = [:]
            pagesVersion = -1
            pagesStore = store
        }
        if store.version != pagesVersion {
            let version = store.version
            store.recentWithIcons(limit: Self.limit) { [weak store] pages in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self = MainMenu.historyDelegate, let store, store === self.pagesStore else { return }
                        self.pages = pages
                        self.icons = [:]
                        for page in pages {
                            guard let data = page.icon, let image = NSImage(data: data) else { continue }
                            image.size = NSSize(width: 16, height: 16)
                            self.icons[page.url] = image
                        }
                        self.pagesVersion = version
                        // Usually back before the menu has drawn; else the
                        // items change under the mouse, which is fine.
                        if let menu = self.menu { self.fill(menu) }
                    }
                }
            }
        }
        fill(menu)
    }

    private func fill(_ menu: NSMenu) {
        for item in menu.items where item.tag == Self.recentTag {
            menu.removeItem(item)
        }
        // After Back, Forward and the separator.
        var index = 3
        for page in pages {
            var title = page.displayTitle
            if title.count > 60 { title = title.prefix(59) + "…" }
            let item = NSMenuItem(title: title, action: #selector(BrowserWindowController.openHistoryItem(_:)), keyEquivalent: "")
            item.representedObject = page.url
            item.toolTip = page.url
            // A globe for a site with no saved favicon, so the titles line up.
            item.image = icons[page.url] ?? Theme.symbol("globe", size: Theme.Symbol.row, weight: .regular)
            item.tag = Self.recentTag
            menu.insertItem(item, at: index)
            index += 1
        }
        if index > 3 {
            let separator = NSMenuItem.separator()
            separator.tag = Self.recentTag
            menu.insertItem(separator, at: index)
        }
    }
}

/// Fills the Profiles menu each time it opens: every profile, the front
/// window's checked and the other open ones marked, then New Profile and
/// Manage Profiles.
@MainActor
private final class ProfilesMenuDelegate: NSObject, NSMenuDelegate {
    /// No item has a shortcut, which spares reading the profiles from disk
    /// on every Command and Control key press.
    func menuHasKeyEquivalent(
        _ menu: NSMenu, for event: NSEvent, target: AutoreleasingUnsafeMutablePointer<AnyObject?>,
        action: UnsafeMutablePointer<Selector?>
    ) -> Bool {
        false
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let active = ProfileContext.active?.id
        for profile in Profiles.all {
            let item = NSMenuItem(title: profile.name, action: #selector(AppDelegate.openProfile(_:)), keyEquivalent: "")
            item.representedObject = profile.id
            item.state = profile.id == active ? .on : ProfileContext.opened(profile.id) != nil ? .mixed : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "New Profile…", action: #selector(AppDelegate.newProfile(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Manage Profiles…", action: #selector(AppDelegate.manageProfiles(_:)), keyEquivalent: "")
    }
}
