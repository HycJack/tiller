import AppKit

/// A profile's history, downloads, settings, site choices, saved logins and
/// Chrome import, for the `tiller` CLI. Each does what its Settings pane or
/// menu does; the tab-bound ones (filling a login, reopening a closed tab)
/// are the window's, in `BrowserWindowController.control`.
@MainActor
enum ProfileControl {
    private static let prefixes = ["history.", "downloads.", "settings.", "sites.", "passwords.", "import."]

    static func handles(_ method: String) -> Bool {
        prefixes.contains(where: method.hasPrefix)
    }

    static func control(_ method: String, params: [String: Any], profile: ProfileContext) throws -> Any {
        switch method {
        case _ where method.hasPrefix("history."): return try history(method, params: params, profile: profile)
        case _ where method.hasPrefix("downloads."): return try downloads(method, params: params, profile: profile)
        case _ where method.hasPrefix("settings."): return try settings(method, params: params, profile: profile)
        case _ where method.hasPrefix("sites."): return try sites(method, params: params, profile: profile)
        case _ where method.hasPrefix("passwords."): return try passwords(method, params: params, profile: profile)
        default: return try chromeImport(method, params: params, profile: profile)
        }
    }

    // MARK: History

    private static func history(_ method: String, params: [String: Any], profile: ProfileContext) throws -> Any {
        let store = profile.history
        let limit = min(max((params["limit"] as? NSNumber)?.intValue ?? 25, 1), 1000)
        let dates = ISO8601DateFormatter()
        let describe = { (pages: [HistoryPage]) -> [[String: Any]] in
            pages.map { page in
                ["url": page.url, "title": page.displayTitle, "visits": page.visitCount, "typed": page.typedCount,
                 "last_visit": dates.string(from: page.lastVisit)]
            }
        }
        /// Answers with what `finish` makes of what the store's queue found.
        func answer<T: Sendable>(
            _ query: @escaping (@escaping @Sendable (T) -> Void) -> Void, _ finish: @escaping (T) -> Any
        ) -> ControlDeferred {
            ControlDeferred { reply in
                Task { @MainActor in
                    let found = await withCheckedContinuation { continuation in query { continuation.resume(returning: $0) } }
                    reply(.success(finish(found)))
                }
            }
        }
        switch method {
        case "history.search":
            guard let query = params["query"] as? String, !query.isEmpty else { throw ControlError("search needs some text") }
            return answer({ store.search(query, limit: limit, replaceable: false, completion: $0) }) { ["pages": describe($0)] }
        case "history.recent":
            return answer({ store.recent(limit: limit, completion: $0) }) { ["pages": describe($0)] }
        case "history.top":
            return answer({ store.frequentSites(limit: limit, completion: $0) }) { sites in
                ["sites": sites.map { ["host": $0.host, "url": $0.url, "title": $0.title] }]
            }
        case "history.remove":
            guard let url = params["url"] as? String, !url.isEmpty else { throw ControlError("remove needs the page's URL") }
            store.remove(url: url)
            return ["removed": url]
        case "history.clear":
            profile.window?.clearHistoryNow() ?? {
                store.clear()
                profile.session.clearClosedTabs()
            }()
            return ["cleared": true]
        default:
            throw ControlError("unknown method \(method)")
        }
    }

    // MARK: Downloads

    private static func downloads(_ method: String, params: [String: Any], profile: ProfileContext) throws -> Any {
        let store = DownloadStore.shared
        // Downloads are numbered per request context, so each profile's apart.
        let own = store.downloads.filter { $0.context == profile.context }
        func find() throws -> Download {
            guard let id = (params["id"] as? NSNumber)?.uint32Value, let download = own.first(where: { $0.id == id }) else {
                throw ControlError("no download with id \(params["id"] ?? ""). Run `tiller downloads` for the list.")
            }
            return download
        }
        switch method {
        case "downloads.list":
            return ["downloads": own.map(describe)]
        case "downloads.cancel":
            let download = try find()
            guard download.state == .inProgress else { throw ControlError("\(download.name) isn't downloading") }
            store.cancel(download)
            return describe(download)
        case "downloads.open", "downloads.reveal":
            let download = try find()
            guard download.state == .complete, FileManager.default.fileExists(atPath: download.path) else {
                throw ControlError("\(download.name) hasn't finished downloading, or was moved")
            }
            let url = URL(fileURLWithPath: download.path)
            if method == "downloads.open" {
                NSWorkspace.shared.open(url)
            } else {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
            return describe(download)
        case "downloads.clear":
            store.clearFinished()
            return ["cleared": true]
        default:
            throw ControlError("unknown method \(method)")
        }
    }

    private static func describe(_ download: Download) -> [String: Any] {
        let state = switch download.state {
        case .inProgress: "downloading"
        case .complete: "done"
        case .canceled: "canceled"
        case .failed: "failed"
        }
        var result: [String: Any] = [
            "id": download.id, "name": download.name, "path": download.path, "url": download.url,
            "received": download.received, "state": state,
        ]
        if download.total >= 0 { result["total"] = download.total }
        return result
    }

    // MARK: Settings

    /// One setting `tiller settings` can read and change. `values` lists
    /// what it takes when that is a fixed set.
    private struct Setting {
        let key: String
        let summary: String
        var shared = false
        var values: [String]? = nil
        let get: () -> Any
        let set: (String) throws -> Void
    }

    private static func settingsTable(_ profile: ProfileContext) -> [Setting] {
        let settings = profile.settings
        let providers = profile.providers
        func choice<T: RawRepresentable & CaseIterable>(_ type: T.Type, _ value: String, key: String) throws -> T where T.RawValue == String {
            guard let found = T(rawValue: value) else {
                throw ControlError("\(key) is one of \(T.allCases.map(\.rawValue).joined(separator: ", "))")
            }
            return found
        }
        func flag(_ value: String, key: String) throws -> Bool {
            switch value.lowercased() {
            case "on", "true", "yes", "1": return true
            case "off", "false", "no", "0": return false
            default: throw ControlError("\(key) is on or off")
            }
        }
        let onOff = ["on", "off"]
        var table: [Setting] = [
            Setting(key: "homepage", summary: "Homepage, empty for Google's", get: { settings.homepage }, set: { settings.homepage = $0 }),
            Setting(key: "launch_tabs", summary: "What a launch opens", values: LaunchTabs.allCases.map(\.rawValue),
                    get: { settings.launchTabs.rawValue }, set: { settings.launchTabs = try choice(LaunchTabs.self, $0, key: "launch_tabs") }),
            Setting(key: "new_tab_page", summary: "What new tabs open with", values: NewTabPage.allCases.map(\.rawValue),
                    get: { settings.newTabPage.rawValue }, set: { settings.newTabPage = try choice(NewTabPage.self, $0, key: "new_tab_page") }),
            Setting(key: "tab_layout", summary: "Tabs along the top (horizontal) or in a sidebar (vertical)", values: TabLayout.allCases.map(\.rawValue),
                    get: { settings.tabLayout.rawValue }, set: { settings.tabLayout = try choice(TabLayout.self, $0, key: "tab_layout") }),
            Setting(key: "sidebar_collapsed", summary: "The tab sidebar shows only icons", values: onOff,
                    get: { settings.sidebarCollapsed }, set: { value in
                        let on = try flag(value, key: "sidebar_collapsed")
                        if let window = profile.window { window.setSidebarCollapsed(on) } else { settings.sidebarCollapsed = on }
                    }),
            Setting(key: "unload_inactive_tabs", summary: "Unload background tabs to save memory", values: onOff,
                    get: { settings.unloadsInactiveTabs }, set: { settings.unloadsInactiveTabs = try flag($0, key: "unload_inactive_tabs") }),
            Setting(key: "unload_after", summary: "How long a background tab waits before it unloads", values: TabUnloadDelay.allCases.map(\.rawValue),
                    get: { settings.tabUnloadDelay.rawValue }, set: { settings.tabUnloadDelay = try choice(TabUnloadDelay.self, $0, key: "unload_after") }),
            Setting(key: "search_engine", summary: "Search engine", values: SearchEngine.allCases.map(\.rawValue),
                    get: { settings.searchEngine.rawValue }, set: { settings.searchEngine = try choice(SearchEngine.self, $0, key: "search_engine") }),
            Setting(key: "search_url", summary: "The custom search engine's URL, with %s for the query", get: { settings.searchTemplate }, set: { value in
                guard value.isEmpty || Settings.isValidSearchTemplate(value) else {
                    throw ControlError("search_url is an http(s) URL with %s where the query goes")
                }
                settings.searchTemplate = value
            }),
            Setting(key: "search_suggestions", summary: "The address bar asks the search engine for suggestions", values: onOff,
                    get: { settings.searchSuggestions }, set: { settings.searchSuggestions = try flag($0, key: "search_suggestions") }),
            Setting(key: "full_urls", summary: "The address bar always shows full URLs", values: onOff,
                    get: { settings.showsFullURLs }, set: { settings.showsFullURLs = try flag($0, key: "full_urls") }),
            Setting(key: "agent", summary: "The agent new chats use", values: providers.all.map(\.rawValue),
                    get: { providers.current.rawValue }, set: { value in
                        guard let picked = AgentChoice(rawValue: value), providers.exists(picked) else {
                            throw ControlError("agent is one of \(providers.all.map(\.rawValue).joined(separator: ", "))")
                        }
                        providers.current = picked
                    }),
            Setting(key: "agent_tabs", summary: "How many chats the agent panel keeps open, 1 to 9",
                    get: { settings.agentTabs }, set: { value in
                        guard let count = Int(value), Settings.agentTabsRange.contains(count) else { throw ControlError("agent_tabs is 1 to 9") }
                        settings.agentTabs = count
                    }),
            Setting(key: "agent_tools", summary: "Built-in tools new chats get: any of read, write and shell, comma-separated, or none",
                    get: { settings.agentTools.map(\.rawValue).joined(separator: ",") }, set: { value in
                        let names = value == "none" ? [] : value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                        let tools = try names.map { name in
                            guard let tool = AgentTool(rawValue: name) else { throw ControlError("agent_tools are any of read, write and shell, or none") }
                            return tool
                        }
                        for tool in AgentTool.allCases { settings.setAgentTool(tool, enabled: tools.contains(tool)) }
                    }),
            Setting(key: "agent_instructions", summary: "Extra instructions after Tiller's system prompt",
                    get: { settings.agentInstructions }, set: { settings.agentInstructions = $0 }),
            Setting(key: "agent_folder", summary: "The folder agents work in, empty for Tiller's own",
                    get: { settings.agentFolder }, set: { settings.agentFolder = $0 }),
            Setting(key: "jev_model", summary: "run_task's Jev model, empty for \(ProfileSettings.defaultJevModel)",
                    get: { settings.jevModelSetting }, set: { settings.jevModelSetting = $0 }),
            Setting(key: "jev_text_url", summary: "run_task's text model URL, empty for \(ProfileSettings.defaultJevTextBaseURL)",
                    get: { settings.jevTextBaseURLSetting }, set: { settings.jevTextBaseURLSetting = $0 }),
            Setting(key: "jev_text_model", summary: "run_task's text model, empty for \(ProfileSettings.defaultJevTextModel)",
                    get: { settings.jevTextModelSetting }, set: { settings.jevTextModelSetting = $0 }),
            Setting(key: "jev_text_reasoning", summary: "run_task's text model may think before answering", values: onOff,
                    get: { settings.jevTextReasoning }, set: { settings.jevTextReasoning = try flag($0, key: "jev_text_reasoning") }),
        ]
        for kind in AgentKind.allCases {
            table.append(Setting(key: "agent_command.\(kind.rawValue)", summary: "The file to run \(kind.displayName) from, empty to look it up",
                                 get: { settings.agentPath(for: kind) ?? "" }, set: { settings.setAgentPath($0, for: kind) }))
        }
        for agent in providers.all {
            let name = providers.displayName(agent)
            func options(_ change: (inout AgentModelOptions) -> Void) throws {
                var options = settings.agentModelOptions(for: agent)
                change(&options)
                settings.setAgentModelOptions(options.supported(by: agent), for: agent)
            }
            table.append(Setting(key: "agent_model.\(agent.rawValue)", summary: "\(name)'s model for new chats, empty for the CLI's own",
                                 get: { settings.agentModelOptions(for: agent).model ?? "" },
                                 set: { value in try options { $0.model = value.isEmpty ? nil : value } }))
            let efforts = agent.effortLevels(model: settings.agentModelOptions(for: agent).model)
            if !efforts.isEmpty {
                table.append(Setting(key: "agent_effort.\(agent.rawValue)", summary: "\(name)'s thinking effort for new chats, empty for its own",
                                     values: efforts, get: { settings.agentModelOptions(for: agent).effort ?? "" }, set: { value in
                                         guard value.isEmpty || efforts.contains(value) else {
                                             throw ControlError("effort for \(name) is one of \(efforts.joined(separator: ", ")), or empty")
                                         }
                                         try options { $0.effort = value.isEmpty ? nil : value }
                                     }))
            }
            let sizes = agent.contextSizes.map(\.value)
            if !sizes.isEmpty {
                table.append(Setting(key: "agent_context.\(agent.rawValue)", summary: "\(name)'s context window for new chats, empty for its own",
                                     values: sizes, get: { settings.agentModelOptions(for: agent).context ?? "" }, set: { value in
                                         guard value.isEmpty || sizes.contains(value) else {
                                             throw ControlError("context for \(name) is one of \(sizes.joined(separator: ", ")), or empty")
                                         }
                                         try options { $0.context = value.isEmpty ? nil : value }
                                     }))
            }
            if agent.fastTier(model: settings.agentModelOptions(for: agent).model) != nil {
                table.append(Setting(key: "agent_fast.\(agent.rawValue)", summary: "\(name)'s fast mode for new chats", values: onOff,
                                     get: { settings.agentModelOptions(for: agent).fast }, set: { value in
                                         let on = try flag(value, key: "agent_fast")
                                         try options { $0.fast = on }
                                     }))
            }
        }
        table += [
            Setting(key: "theme", summary: "Tiller's theme, for every profile", shared: true, values: ChromeTheme.allCases.map(\.rawValue),
                    get: { Settings.theme.rawValue }, set: { Settings.theme = try choice(ChromeTheme.self, $0, key: "theme") }),
            Setting(key: "appearance", summary: "Light or dark, for every profile", shared: true, values: Appearance.allCases.map(\.rawValue),
                    get: { Settings.appearance.rawValue }, set: { Settings.appearance = try choice(Appearance.self, $0, key: "appearance") }),
            Setting(key: "accent", summary: "Accent color with the Tiller theme, for every profile", shared: true, values: AccentTheme.allCases.map(\.rawValue),
                    get: { Settings.accentTheme.rawValue }, set: { Settings.accentTheme = try choice(AccentTheme.self, $0, key: "accent") }),
            Setting(key: "profile_tabs", summary: "Every open profile in one window, with a rail", shared: true, values: onOff,
                    get: { Settings.profileTabs }, set: { Settings.profileTabs = try flag($0, key: "profile_tabs") }),
            Setting(key: "remote_debugging", summary: "Chromium's DevTools protocol on 127.0.0.1:9222, from the next launch", shared: true, values: onOff,
                    get: { Settings.remoteDebuggingEnabled }, set: { Settings.remoteDebuggingEnabled = try flag($0, key: "remote_debugging") }),
        ]
        if Updater.isAvailable {
            table += [
                Setting(key: "update_automatically", summary: "Check for updates automatically", shared: true, values: onOff,
                        get: { Updater.shared.automaticallyChecks }, set: { Updater.shared.automaticallyChecks = try flag($0, key: "update_automatically") }),
                Setting(key: "update_betas", summary: "Updates include beta versions", shared: true, values: onOff,
                        get: { Updater.includesBetas }, set: { Updater.includesBetas = try flag($0, key: "update_betas") }),
            ]
        }
        return table
    }

    private static func settings(_ method: String, params: [String: Any], profile: ProfileContext) throws -> Any {
        let table = settingsTable(profile)
        func describe(_ setting: Setting) -> [String: Any] {
            var result: [String: Any] = ["key": setting.key, "value": setting.get(), "summary": setting.summary, "shared": setting.shared]
            if let values = setting.values { result["values"] = values }
            return result
        }
        func find(_ key: String) throws -> Setting {
            guard let setting = table.first(where: { $0.key == key }) else {
                throw ControlError("no setting \(key). Run `tiller settings` for the list.")
            }
            return setting
        }
        switch method {
        case "settings.get":
            if let key = params["key"] as? String, !key.isEmpty { return describe(try find(key)) }
            return ["settings": table.map(describe), "profile": profile.id]
        case "settings.set":
            guard let key = params["key"] as? String, !key.isEmpty else { throw ControlError("set needs a key") }
            let setting = try find(key)
            let value = (params["value"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            try setting.set(value)
            // The new value shows in Settings when its pane is next shown.
            return describe(try find(key))
        default:
            throw ControlError("unknown method \(method)")
        }
    }

    // MARK: Sites

    private static func sites(_ method: String, params: [String: Any], profile: ProfileContext) throws -> Any {
        let permissions = profile.settings.sitePermissions
        func origin() throws -> String {
            guard let site = params["site"] as? String, !site.isEmpty else { throw ControlError("name the site, as https://meet.google.com") }
            return SitePermissions.origin(site.contains("://") ? site : "https://" + site)
        }
        switch method {
        case "sites.list":
            let sites = permissions.all.keys.sorted().map { origin -> [String: Any] in
                var site: [String: Any] = ["site": origin]
                for (device, choice) in permissions.permissions(for: origin) { site[device.rawValue] = choice.rawValue }
                return site
            }
            return ["sites": sites]
        case "sites.set":
            let origin = try origin()
            var changed = false
            for device in MediaDevice.allCases {
                guard let value = params[device.rawValue] as? String else { continue }
                let choice: SitePermission?
                switch value {
                case "ask": choice = nil
                case "allow": choice = .allow
                case "block": choice = .block
                default: throw ControlError("\(device.rawValue) is ask, allow or block")
                }
                permissions.set(choice, for: [device], origin: origin)
                changed = true
            }
            guard changed else { throw ControlError("give --camera or --microphone, each ask, allow or block") }
            var site: [String: Any] = ["site": origin]
            for (device, choice) in permissions.permissions(for: origin) { site[device.rawValue] = choice.rawValue }
            return site
        case "sites.remove":
            let origin = try origin()
            guard permissions.all[origin] != nil else { throw ControlError("\(origin) has no saved choices") }
            permissions.remove([origin])
            return ["removed": origin]
        default:
            throw ControlError("unknown method \(method)")
        }
    }

    // MARK: Saved passwords

    /// Lists and removes saved logins. Passwords themselves never leave the
    /// app this way: `tiller password fill` fills one into a page instead.
    private static func passwords(_ method: String, params: [String: Any], profile: ProfileContext) throws -> Any {
        let store = profile.passwords
        let dates = ISO8601DateFormatter()
        switch method {
        case "passwords.list":
            let query = (params["query"] as? String ?? "").lowercased()
            let logins = store.entries.filter {
                query.isEmpty || $0.origin.lowercased().contains(query) || $0.username.lowercased().contains(query)
            }
            return ["logins": logins.map { ["site": $0.origin, "username": $0.username, "created": dates.string(from: $0.created)] }]
        case "passwords.remove":
            guard let site = params["site"] as? String, !site.isEmpty else { throw ControlError("name the login's site") }
            let origin = SavedLogin.origin(of: site.contains("://") ? site : "https://" + site) ?? site
            let username = params["username"] as? String
            let matches = store.entries.filter { $0.origin == origin && (username == nil || $0.username == username) }
            guard !matches.isEmpty else { throw ControlError("no saved login for \(origin)\(username.map { " with username \($0)" } ?? "")") }
            if username == nil, matches.count > 1, params["all"] as? Bool != true {
                throw ControlError("\(origin) has \(matches.count) logins: \(matches.map(\.username).joined(separator: ", ")). Give --username, or --all to remove them all.")
            }
            do {
                try store.remove(Set(matches.map(\.id)))
            } catch {
                throw ControlError(error.localizedDescription)
            }
            return ["removed": matches.map { ["site": $0.origin, "username": $0.username] }]
        default:
            throw ControlError("unknown method \(method)")
        }
    }

    // MARK: Import from Chrome

    private static func chromeImport(_ method: String, params: [String: Any], profile: ProfileContext) throws -> Any {
        switch method {
        case "import.chrome_profiles":
            do {
                let (profiles, lastUsed) = try ChromeReader.profiles()
                return ["profiles": profiles.map { ["directory": $0.directory, "name": $0.name, "last_used": $0.directory == lastUsed] }]
            } catch {
                throw ControlError(error.localizedDescription)
            }
        case "import.chrome":
            let (profiles, lastUsed): ([ChromeProfile], String?)
            do {
                (profiles, lastUsed) = try ChromeReader.profiles()
            } catch {
                throw ControlError(error.localizedDescription)
            }
            let wanted = params["chrome_profile"] as? String
            let source = wanted.map { wanted in
                profiles.first { $0.directory == wanted } ?? profiles.first { $0.name.localizedCaseInsensitiveCompare(wanted) == .orderedSame }
            } ?? profiles.first { $0.directory == lastUsed } ?? profiles.first
            guard let source else {
                throw ControlError("Chrome has no profile \(wanted ?? ""). Profiles: \(profiles.map(\.name).joined(separator: ", "))")
            }
            var kinds = Set(ImportKind.allCases)
            if let names = params["kinds"] as? [String], !names.isEmpty {
                kinds = try Set(names.map { name in
                    guard let kind = ImportKind.allCases.first(where: { "\($0)" == name }) else {
                        throw ControlError("kinds are any of \(ImportKind.allCases.map { "\($0)" }.joined(separator: ", "))")
                    }
                    return kind
                })
            }
            // Reading Chrome's key makes macOS ask for the login password,
            // which can take longer than a reply may.
            let job = ControlJobs.start { finish in
                if kinds.contains(where: \.needsChromeKey) { NSApp.activate() }
                Task { @MainActor in
                    let results = await ChromeImporter.run(profile: source, into: profile, kinds: kinds)
                    finish(.success([
                        "chrome_profile": source.name,
                        "results": results.map { result -> [String: Any] in
                            var line: [String: Any] = ["title": result.title, "detail": result.detail]
                            if let error = result.error { line["error"] = error.localizedDescription }
                            return line
                        },
                    ]))
                }
            }
            return ["job": job]
        default:
            throw ControlError("unknown method \(method)")
        }
    }
}
