import AppKit
import CTillerCore

/// What an import can bring over.
enum ImportKind: CaseIterable, Sendable {
    case cookies
    case passwords
    case history
    case settings
    case extensions

    var title: String {
        switch self {
        case .cookies: "Cookies"
        case .passwords: "Saved passwords"
        case .history: "History"
        case .settings: "Search engine and homepage"
        case .extensions: "Extensions"
        }
    }

    var needsChromeKey: Bool { self == .cookies || self == .passwords }
}

/// One line of an import's result.
struct ImportResult: Sendable {
    let title: String
    let detail: String
    let error: Error?
}

/// Reads a Chrome profile and brings the chosen data into Tiller.
@MainActor
enum ChromeImporter {
    /// Everything read from Chrome, gathered off the main thread.
    private struct Loaded: Sendable {
        var cookies: Result<(cookies: [ImportedCookie], skipped: Int), Error>?
        var logins: Result<(logins: [SavedLogin], skipped: Int), Error>?
        var history: Result<[HistoryPage], Error>?
        var preferences: Result<ChromePreferences, Error>?
        var extensions: Result<(extensions: [ChromeExtension], skipped: Int), Error>?
    }

    /// Brings the data into the Tiller profile `target`. Reads from
    /// `dataDirectory` instead of Chrome's real folder when set — the
    /// Finder-made copy used when security software blocks direct reads.
    static func run(
        profile: ChromeProfile, into target: ProfileContext, kinds: Set<ImportKind>, dataDirectory: String? = nil
    ) async -> [ImportResult] {
        let loaded = await Task.detached {
            load(ChromeReader(profile: profile, dataDirectory: dataDirectory ?? ChromeReader.defaultDataDirectory), kinds)
        }.value
        var results: [ImportResult] = []

        if let preferences = loaded.preferences {
            switch preferences {
            case .success(let prefs): results += applySettings(prefs, to: target.settings)
            case .failure(let error): results.append(ImportResult(title: "Search engine and homepage", detail: "", error: error))
            }
        }

        if let history = loaded.history {
            let result: Result<Int, Error>
            switch history {
            case .success(let pages):
                result = await withCheckedContinuation { continuation in
                    target.history.importPages(pages) { continuation.resume(returning: $0) }
                }
            case .failure(let error):
                result = .failure(error)
            }
            results.append(line("History", result.map { "\($0.formatted()) pages imported" }))
        }

        if let logins = loaded.logins {
            var result: Result<String, Error>
            do {
                let (logins, skipped) = try logins.get()
                let saved = try await target.passwords.merge(logins)
                result = .success("\(saved.formatted()) imported" + skippedNote(skipped, "never-saved, non-web or unreadable"))
            } catch {
                result = .failure(error)
            }
            results.append(line("Passwords", result))
        }

        if let extensions = loaded.extensions {
            var result: Result<String, Error>
            do {
                let (found, left) = try extensions.get()
                let (imported, skipped) = await ExtensionStore.shared.importFromChrome(found)
                result = .success(
                    "\(imported.formatted()) imported, loading at next launch"
                        + skippedNote(left + skipped, "Chrome's own, installed by policy, apps, themes or unreadable"))
            } catch {
                result = .failure(error)
            }
            results.append(line("Extensions", result))
        }

        if let cookies = loaded.cookies {
            var result: Result<String, Error>
            do {
                let (cookies, skipped) = try cookies.get()
                let (imported, failed) = await setCookies(cookies, context: target.context)
                var detail = "\(imported.formatted()) imported" + skippedNote(skipped, "partitioned, expired or unreadable")
                if failed > 0 { detail += ", \(failed.formatted()) rejected by Chromium" }
                result = .success(detail)
            } catch {
                result = .failure(error)
            }
            results.append(line("Cookies", result))
        }
        return results
    }

    nonisolated private static func load(_ reader: ChromeReader, _ kinds: Set<ImportKind>) -> Loaded {
        var loaded = Loaded()
        if kinds.contains(.settings) { loaded.preferences = Result { try reader.preferences() } }
        if kinds.contains(.history) { loaded.history = Result { try reader.history() } }
        if kinds.contains(.extensions) { loaded.extensions = Result { try reader.extensions() } }
        guard kinds.contains(where: \.needsChromeKey) else { return loaded }
        // One keychain prompt covers both.
        let key = Result { try ChromeReader.safeStorageKey() }
        if kinds.contains(.passwords) { loaded.logins = Result { try reader.logins(key: key.get()) } }
        if kinds.contains(.cookies) { loaded.cookies = Result { try reader.cookies(key: key.get()) } }
        return loaded
    }

    private static func applySettings(_ prefs: ChromePreferences, to settings: ProfileSettings) -> [ImportResult] {
        var results: [ImportResult] = []
        if let url = prefs.searchURL {
            if let (engine, template) = searchSetting(for: url) {
                settings.searchEngine = engine
                if let template { settings.searchTemplate = template }
                results.append(ImportResult(title: "Search engine", detail: "Set to \(template ?? engine.displayName)", error: nil))
            } else {
                results.append(ImportResult(title: "Search engine", detail: "Chrome's engine (\(url)) can't be used; left unchanged", error: nil))
            }
        } else {
            results.append(ImportResult(title: "Search engine", detail: "Chrome uses its default; left unchanged", error: nil))
        }
        if let homepage = prefs.homepage {
            settings.homepage = homepage
            results.append(ImportResult(title: "Homepage", detail: "Set to \(homepage)", error: nil))
        } else {
            results.append(ImportResult(title: "Homepage", detail: "Chrome opens its New Tab page; left unchanged", error: nil))
        }
        return results
    }

    /// Tiller's engine for Chrome's search URL, with a template for a custom
    /// one. Chrome's URLs use `{searchTerms}` and other `{…}` parameters.
    static func searchSetting(for url: String) -> (SearchEngine, String?)? {
        let host = URL(string: url)?.host()?.lowercased() ?? ""
        if url.hasPrefix("{google:baseURL}") || host.hasPrefix("www.google.") || host.hasPrefix("google.") {
            return (.google, nil)
        }
        if host.hasSuffix("bing.com") { return (.bing, nil) }
        if host.hasSuffix("duckduckgo.com") { return (.duckduckgo, nil) }
        let template = url.replacingOccurrences(of: "{searchTerms}", with: "%s")
            .replacingOccurrences(of: #"\{[^}]*\}"#, with: "", options: .regularExpression)
        return Settings.isValidSearchTemplate(template) ? (.custom, template) : nil
    }

    private static func line(_ title: String, _ result: Result<String, Error>) -> ImportResult {
        switch result {
        case .success(let detail): ImportResult(title: title, detail: detail, error: nil)
        case .failure(let error): ImportResult(title: title, detail: "", error: error)
        }
    }

    private static func skippedNote(_ count: Int, _ reason: String) -> String {
        count > 0 ? ", \(count.formatted()) skipped (\(reason))" : ""
    }

    /// Hands the cookies to the core, which sets them through Chromium's
    /// cookie manager and flushes them to disk.
    private static func setCookies(_ cookies: [ImportedCookie], context: Int32) async -> (imported: Int, failed: Int) {
        guard let data = try? JSONEncoder().encode(cookies) else { return (0, cookies.count) }
        let json = String(decoding: data, as: UTF8.self)
        return await withCheckedContinuation { continuation in
            let ctx = Unmanaged.passRetained(CookieCompletion { continuation.resume(returning: ($0, $1)) }).toOpaque()
            tiller_cookies_import(context, json, ctx) { ctx, imported, failed in
                guard let ctx else { return }
                Unmanaged<CookieCompletion>.fromOpaque(ctx).takeRetainedValue().done(Int(imported), Int(failed))
            }
        }
    }

    private final class CookieCompletion {
        let done: (Int, Int) -> Void
        init(_ done: @escaping (Int, Int) -> Void) { self.done = done }
    }
}

/// Tiller > Import from Chrome…, shown as a sheet on the browser window.
@MainActor
final class ChromeImportController: NSWindowController {
    private let target: ProfileContext
    private let profilePopUp = NSPopUpButton()
    private var checkboxes: [(ImportKind, NSButton)] = []
    private let status = NSTextField(wrappingLabelWithString: "")
    private let spinner = NSProgressIndicator()
    private let privacyButton = NSButton(title: "Open Privacy Settings", target: nil, action: nil)
    private let finderButton = NSButton(title: "Copy via Finder", target: nil, action: nil)
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    private let importButton = NSButton(title: "Import", target: nil, action: nil)
    private var profiles: [ChromeProfile] = []
    /// Temp folder holding a Finder-made copy of Chrome's data, used when
    /// security software blocks Tiller from reading the real folder.
    private var copyRoot: URL?
    private var finished = false
    private var onEnd: (() -> Void)?

    init(profile: ProfileContext) {
        target = profile
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 300), styleMask: [.titled], backing: .buffered, defer: true)
        super.init(window: window)
        buildContent()
        loadProfiles()
    }

    required init?(coder: NSCoder) { fatalError() }

    func begin(on parent: NSWindow, onEnd: @escaping () -> Void) {
        guard let window else { return }
        self.onEnd = onEnd
        parent.beginSheet(window)
    }

    private func buildContent() {
        let heading = NSTextField(labelWithString: "Import from Google Chrome")
        heading.font = .systemFont(ofSize: Theme.FontSize.body, weight: .semibold)

        let grid = NSGridView()
        grid.rowSpacing = 6
        grid.columnSpacing = 8
        grid.rowAlignment = .firstBaseline
        grid.addRow(with: [NSTextField(labelWithString: "Profile:"), profilePopUp])
        for (index, kind) in ImportKind.allCases.enumerated() {
            let box = NSButton(checkboxWithTitle: kind.title, target: self, action: #selector(checkboxChanged(_:)))
            box.state = .on
            checkboxes.append((kind, box))
            grid.addRow(with: [index == 0 ? NSTextField(labelWithString: "Import:") : NSGridCell.emptyContentView, box])
        }
        grid.column(at: 0).xPlacement = .trailing
        // Otherwise the grid stretches to fill the sheet and one row or column takes the slack.
        grid.setContentHuggingPriority(.required, for: .horizontal)
        grid.setContentHuggingPriority(.required, for: .vertical)

        let note = SettingsPane.note("For cookies and passwords, macOS asks for your login password so Tiller can read Chrome's key. Imported cookies replace Tiller's for the same site. Extensions load at the next launch.")
        note.lineBreakMode = .byWordWrapping
        note.maximumNumberOfLines = 0
        note.preferredMaxLayoutWidth = 420

        status.preferredMaxLayoutWidth = 420
        status.isSelectable = true
        status.isHidden = true
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false

        privacyButton.target = self
        privacyButton.action = #selector(openPrivacySettings(_:))
        privacyButton.isHidden = true
        finderButton.target = self
        finderButton.action = #selector(copyViaFinder(_:))
        finderButton.isHidden = true
        cancelButton.target = self
        cancelButton.action = #selector(cancel(_:))
        cancelButton.keyEquivalent = "\u{1b}"
        importButton.target = self
        importButton.action = #selector(importOrClose(_:))
        importButton.keyEquivalent = "\r"
        let buttons = NSStackView(views: [spinner, privacyButton, finderButton, NSView(), cancelButton, importButton])
        buttons.spacing = 8
        buttons.setHuggingPriority(.defaultLow, for: .horizontal)

        let stack = NSStackView(views: [heading, grid, note, status, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        let inset = Theme.Padding.sheet
        stack.edgeInsets = NSEdgeInsets(top: inset, left: inset, bottom: inset, right: inset)
        stack.setCustomSpacing(10, after: heading)
        buttons.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -2 * inset).isActive = true
        stack.widthAnchor.constraint(equalToConstant: 460).isActive = true
        window?.contentView = stack
        window?.setContentSize(stack.fittingSize)
    }

    private func loadProfiles() {
        do {
            let (profiles, lastUsed) = try ChromeReader.profiles()
            self.profiles = profiles
            for profile in profiles {
                profilePopUp.addItem(withTitle: profile.name == profile.directory ? profile.name : "\(profile.name) (\(profile.directory))")
            }
            profilePopUp.selectItem(at: profiles.firstIndex { $0.directory == lastUsed } ?? 0)
        } catch {
            profilePopUp.addItem(withTitle: "None found")
            setControlsEnabled(false)
            show([ImportResult(title: "Chrome", detail: "", error: error)])
            finderButton.isHidden = !Self.isNoAccess(error)
        }
    }

    /// Fallback for when security software blocks Tiller from Chrome's folder:
    /// have Finder make a readable copy and import from that instead.
    @objc private func copyViaFinder(_ sender: Any?) {
        guard copyRoot == nil else { return }
        let needsProfiles = profiles.isEmpty
        finderButton.isEnabled = false
        spinner.startAnimation(nil)
        showStatus("Asking Finder to copy Chrome's data…")
        Task {
            let result = await Task.detached { () -> Result<(root: URL, profiles: [ChromeProfile], lastUsed: String?), Error> in
                Result {
                    let root = try FinderChromeCopy.makeTempRoot()
                    if needsProfiles {
                        try FinderChromeCopy.copyLocalState(to: root)
                        let (profiles, lastUsed) = try ChromeReader.profiles(in: root.path)
                        return (root, profiles, lastUsed)
                    }
                    return (root, [], nil)
                }
            }.value
            spinner.stopAnimation(nil)
            finderButton.isEnabled = true
            switch result {
            case .failure(let error):
                show([ImportResult(title: "Finder copy", detail: "", error: error)])
            case .success(let (root, copiedProfiles, lastUsed)):
                copyRoot = root
                finderButton.isHidden = true
                if needsProfiles {
                    profiles = copiedProfiles
                    profilePopUp.removeAllItems()
                    for profile in copiedProfiles {
                        profilePopUp.addItem(withTitle: profile.name == profile.directory ? profile.name : "\(profile.name) (\(profile.directory))")
                    }
                    profilePopUp.selectItem(at: copiedProfiles.firstIndex { $0.directory == lastUsed } ?? 0)
                }
                setControlsEnabled(true)
                showStatus("Copied. Tiller will import from Finder's copy — click Import.")
            }
        }
    }

    private func showStatus(_ text: String) {
        status.stringValue = text
        status.textColor = .secondaryLabelColor
        status.isHidden = false
        window?.layoutIfNeeded()
    }

    @objc private func checkboxChanged(_ sender: NSButton) {
        importButton.isEnabled = !selectedKinds.isEmpty
    }

    private var selectedKinds: Set<ImportKind> {
        Set(checkboxes.filter { $0.1.state == .on }.map(\.0))
    }

    private func setControlsEnabled(_ enabled: Bool) {
        profilePopUp.isEnabled = enabled
        checkboxes.forEach { $0.1.isEnabled = enabled }
        importButton.isEnabled = enabled && !selectedKinds.isEmpty
    }

    @objc private func importOrClose(_ sender: Any?) {
        if finished { return dismiss() }
        guard profiles.indices.contains(profilePopUp.indexOfSelectedItem) else { return }
        let profile = profiles[profilePopUp.indexOfSelectedItem]
        setControlsEnabled(false)
        cancelButton.isEnabled = false
        privacyButton.isHidden = true
        finderButton.isHidden = true
        spinner.startAnimation(nil)
        status.isHidden = false
        status.textColor = .secondaryLabelColor
        status.stringValue = copyRoot == nil ? "Importing…" : "Copying via Finder…"
        Task {
            var results: [ImportResult]?
            if let copyRoot {
                // The copy is made per import: the user may have picked another
                // profile since the last attempt, and it keeps plaintext data
                // on disk only for as long as this import runs.
                let extensions = selectedKinds.contains(.extensions)
                let copied = await Task.detached {
                    Result { try FinderChromeCopy.copyProfile(profile.directory, to: copyRoot, extensions: extensions) }
                }.value
                if case .failure(let error) = copied {
                    results = [ImportResult(title: "Finder copy", detail: "", error: error)]
                }
            }
            if results == nil {
                status.stringValue = "Importing…"
                results = await ChromeImporter.run(profile: profile, into: target, kinds: selectedKinds, dataDirectory: copyRoot?.path)
            }
            let usedCopy = copyRoot != nil
            if let copyRoot {
                try? FileManager.default.removeItem(at: copyRoot)
                self.copyRoot = nil
            }
            spinner.stopAnimation(nil)
            show(results!)
            if !usedCopy && results!.contains(where: { Self.isNoAccess($0.error) }) {
                // Direct reads are blocked — offer the Finder-copy retry.
                finderButton.isHidden = false
                setControlsEnabled(true)
                cancelButton.isEnabled = true
            } else {
                finished = true
                cancelButton.isHidden = true
                importButton.title = "Done"
                importButton.isEnabled = true
            }
        }
    }

    private static func isNoAccess(_ error: Error?) -> Bool {
        if case ChromeImportError.noAccess? = error { return true }
        return false
    }

    private func show(_ results: [ImportResult]) {
        let text = NSMutableAttributedString()
        let body: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: Theme.FontSize.secondary), .foregroundColor: NSColor.labelColor]
        for (index, result) in results.enumerated() {
            if index > 0 { text.append(NSAttributedString(string: "\n", attributes: body)) }
            var bold = body
            bold[.font] = NSFont.systemFont(ofSize: Theme.FontSize.secondary, weight: .semibold)
            text.append(NSAttributedString(string: result.title + ": ", attributes: bold))
            var detail = body
            if result.error != nil { detail[.foregroundColor] = NSColor.systemRed }
            text.append(NSAttributedString(string: result.error?.localizedDescription ?? result.detail, attributes: detail))
        }
        status.attributedStringValue = text
        status.isHidden = false
        privacyButton.isHidden = !results.contains {
            if case ChromeImportError.noAccess? = $0.error { true } else { false }
        }
        window?.layoutIfNeeded()
    }

    @objc private func openPrivacySettings(_ sender: Any?) {
        NSWorkspace.shared.open(ChromeImportError.privacySettingsURL)
    }

    @objc private func cancel(_ sender: Any?) {
        dismiss()
    }

    private func dismiss() {
        guard let window else { return }
        if let copyRoot { try? FileManager.default.removeItem(at: copyRoot) }
        window.sheetParent?.endSheet(window)
        onEnd?()
        onEnd = nil
    }
}
