import AppKit

/// Work a request starts that may outlast the core's 60 seconds per reply,
/// such as an agent's turn, a Chrome import or a Git clone. The request
/// answers at once with the job's id, and `jobs.wait` answers once the job
/// ends, or after `timeout_ms` with it still running, so the caller asks again.
@MainActor
enum ControlJobs {
    private enum State {
        case running
        case finished(Result<Any, ControlError>)
    }

    private final class Job {
        var state = State.running
        var waiters: [(Result<Any, ControlError>?) -> Void] = []
        let started = Date()
    }

    private static var jobs: [String: Job] = [:]

    /// Starts `work`, which calls its argument once with the outcome, and
    /// returns the job's id. Finished jobs are forgotten after ten minutes.
    static func start(_ work: (@escaping (Result<Any, ControlError>) -> Void) -> Void) -> String {
        let id = String(UUID().uuidString.lowercased().prefix(8))
        let job = Job()
        jobs[id] = job
        work { outcome in
            guard case .running = job.state else { return }
            job.state = .finished(outcome)
            let waiters = job.waiters
            job.waiters = []
            waiters.forEach { $0(outcome) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 600) {
                MainActor.assumeIsolated { _ = jobs.removeValue(forKey: id) }
            }
        }
        return id
    }

    /// Like `start`, for work that can fail before it gets going: its error
    /// is thrown, and no job is left behind.
    static func startThrowing(_ work: (@escaping (Result<Any, ControlError>) -> Void) throws -> Void) throws -> String {
        var failure: Error?
        let id = start { finish in
            do {
                try work(finish)
            } catch {
                failure = error
            }
        }
        if let failure {
            jobs[id] = nil
            throw failure as? ControlError ?? ControlError(failure.localizedDescription)
        }
        return id
    }

    /// `jobs.wait`: `{"status": "done", "result": …}` or `{"status": "failed",
    /// "error": …}` once the job ends, else `{"status": "running"}` after
    /// `timeout_ms`, at most 50 seconds.
    static func wait(_ params: [String: Any]) throws -> Any {
        guard let id = params["id"] as? String, let job = jobs[id] else {
            throw ControlError("no job with id \(params["id"] ?? ""), or it ended more than ten minutes ago")
        }
        let timeout = min((params["timeout_ms"] as? Double ?? 50_000) / 1000, 50)
        func reply(_ outcome: Result<Any, ControlError>?) -> [String: Any] {
            let seconds = Date().timeIntervalSince(job.started)
            switch outcome {
            case .success(let value): return ["status": "done", "result": value, "seconds": seconds]
            case .failure(let error): return ["status": "failed", "error": error.message, "seconds": seconds]
            case nil: return ["status": "running", "seconds": seconds]
            }
        }
        if case .finished(let outcome) = job.state { return reply(outcome) }
        return ControlDeferred { send in
            var answered = false
            let answer = { (outcome: Result<Any, ControlError>?) in
                guard !answered else { return }
                answered = true
                send(.success(reply(outcome)))
            }
            job.waiters.append(answer)
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
                MainActor.assumeIsolated { answer(nil) }
            }
        }
    }
}

/// Requests about Tiller as a whole rather than one profile, which any open
/// profile's control socket answers: the profiles, Profile Tabs, the default
/// browser, updates, quitting, extensions (which every profile shares) and
/// waiting on jobs.
@MainActor
enum AppControl {
    static func control(_ method: String, params: [String: Any], profile: ProfileContext?) throws -> Any {
        switch method {
        case "jobs.wait":
            return try ControlJobs.wait(params)
        case "app.status":
            var status: [String: Any] = [
                "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
                "build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "",
                "app": Bundle.main.bundlePath,
                "data_folder": Profiles.root,
                "profiles": profiles(),
                "last_used": Profiles.lastUsed.id,
                "profile_tabs": Settings.profileTabs,
                "default_browser": DefaultBrowser.isDefault,
                "remote_debugging": Settings.remoteDebuggingEnabled,
                "updates": Updater.isAvailable,
            ]
            if let profile { status["profile"] = profile.id }
            return status
        case "app.profiles":
            return ["profiles": profiles()]
        case "app.profile.new":
            guard let name = params["name"] as? String else { throw ControlError("a new profile needs a name") }
            let created = try wrap { try Profiles.create(named: name) }
            if params["open"] as? Bool ?? true {
                ProfileContext.open(created.id, reveal: params["show"] as? Bool ?? true)
            }
            return describe(Profiles.profile(created.id) ?? created)
        case "app.profile.open", "app.profile.show":
            let found = try find(params)
            let urls = params["urls"] as? [String] ?? []
            if let open = ProfileContext.opened(found.id), params["show"] as? Bool == false {
                urls.forEach { open.window?.openInNewTab($0, background: true) }
            } else {
                ProfileContext.open(found.id, urls: urls, reveal: params["show"] as? Bool ?? true)
            }
            return describe(found)
        case "app.profile.close":
            let found = try find(params)
            guard let open = ProfileContext.opened(found.id) else { throw ControlError("\(found.name) isn't open") }
            // Answered first: closing this profile may close the socket the
            // request came on.
            DispatchQueue.main.async {
                MainActor.assumeIsolated { open.window?.closeAllTabs() }
            }
            return ["closing": found.id, "name": found.name]
        case "app.profile.rename":
            let found = try find(params)
            guard let name = params["name"] as? String else { throw ControlError("rename needs a name") }
            try wrap { try Profiles.rename(found.id, to: name) }
            return describe(Profiles.profile(found.id) ?? found)
        case "app.profile.color":
            let found = try find(params)
            let name = (params["color"] as? String ?? "").lowercased()
            let color: ProfileColor?
            if name.isEmpty || name == "auto" {
                color = nil
            } else {
                guard let picked = ProfileColor(rawValue: name) else {
                    throw ControlError("color is one of \(ProfileColor.allCases.map(\.rawValue).joined(separator: ", ")), or auto")
                }
                color = picked
            }
            Profiles.setColor(found.id, to: color)
            return describe(Profiles.profile(found.id) ?? found)
        case "app.profile.label":
            let found = try find(params)
            try wrap { try Profiles.setLabel(found.id, to: params["label"] as? String ?? "") }
            return describe(Profiles.profile(found.id) ?? found)
        case "app.profile.move":
            let found = try find(params)
            guard ProfileContext.opened(found.id) != nil else { throw ControlError("\(found.name) isn't open; only open profiles have a place on the rail") }
            guard let index = (params["index"] as? NSNumber)?.intValue else { throw ControlError("move needs an index, from 1") }
            ProfileContext.move(found.id, to: index - 1)
            BrowserWindowHost.all.forEach { $0.updateRail() }
            // The open ones, in their new order along the rail.
            return ["profiles": ProfileContext.all.compactMap { Profiles.profile($0.id) }.map(describe)]
        case "app.profile.delete":
            let found = try find(params)
            try wrap { try Profiles.delete(found.id) }
            return ["deleted": found.id, "name": found.name]
        case "app.profile_tabs":
            if let on = params["on"] as? Bool { Settings.profileTabs = on }
            return ["profile_tabs": Settings.profileTabs]
        case "app.default_browser":
            guard params["make"] as? Bool == true else { return ["default_browser": DefaultBrowser.isDefault] }
            guard DefaultBrowser.isAvailable else { throw ControlError("only a bundled Tiller.app can be the default browser") }
            if DefaultBrowser.isDefault { return ["default_browser": true] }
            // macOS asks the user to confirm, which may take longer than a reply.
            let job = ControlJobs.start { finish in
                NSApp.activate()
                DefaultBrowser.makeDefault { done in finish(.success(["default_browser": done])) }
            }
            return ["job": job]
        case "app.update":
            guard Updater.isAvailable else { throw ControlError("this build of Tiller doesn't update itself; only released builds do") }
            NSApp.activate()
            Updater.shared.checkForUpdates(nil)
            return ["checking": true]
        case "app.quit":
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                MainActor.assumeIsolated { NSApp.terminate(nil) }
            }
            return ["quitting": true]
        case _ where method.hasPrefix("extensions."):
            return try extensions(method, params: params, profile: profile)
        default:
            throw ControlError("unknown method \(method)")
        }
    }

    /// Every profile, in the order the Profiles menu lists them, with
    /// whether it is open and, if so, its tab count and agent activity.
    private static func profiles() -> [[String: Any]] {
        Profiles.all.map(describe)
    }

    private static func describe(_ profile: Profile) -> [String: Any] {
        let colors = ProfileColor.of(Profiles.all)
        var result: [String: Any] = [
            "id": profile.id, "name": profile.name, "color": colors[profile.id]?.rawValue ?? "",
            "open": ProfileContext.opened(profile.id) != nil, "last_used": Profiles.lastUsed.id == profile.id,
        ]
        if let label = profile.label { result["label"] = label }
        if let picked = profile.color { result["picked_color"] = picked }
        if let open = ProfileContext.opened(profile.id) {
            result["position"] = (ProfileContext.all.firstIndex { $0 === open } ?? 0) + 1
            if let window = open.window {
                result["tabs"] = window.tabCount
                result["agent_busy"] = window.isAgentBusy
                result["shown"] = window.isShown
            }
        }
        return result
    }

    /// The profile `profile` names by id or name.
    private static func find(_ params: [String: Any]) throws -> Profile {
        guard let wanted = params["profile"] as? String, !wanted.isEmpty else { throw ControlError("name a profile by its name or id") }
        guard let found = Profiles.find(wanted) else {
            throw ControlError("no profile named \(wanted). Profiles: \(Profiles.all.map(\.name).joined(separator: ", "))")
        }
        return found
    }

    /// Runs `body`, giving its error's description to the caller.
    @discardableResult
    private static func wrap<T>(_ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch let error as ControlError {
            throw error
        } catch {
            throw ControlError(error.localizedDescription)
        }
    }

    // MARK: Extensions

    private static func extensions(_ method: String, params: [String: Any], profile: ProfileContext?) throws -> Any {
        let store = ExtensionStore.shared
        func index() throws -> Int {
            guard let wanted = params["id"] as? String, !wanted.isEmpty else { throw ControlError("name the extension by its id or name") }
            let lower = wanted.lowercased()
            let matches = store.entries.indices.filter { index in
                guard case .success(let manifest) = store.manifest(for: store.entries[index]) else {
                    return store.entries[index].path == wanted
                }
                return manifest.id == wanted || manifest.name.lowercased() == lower
            }
            guard let first = matches.first else { throw ControlError("no extension \(wanted). Run `tiller extensions` for the list.") }
            guard matches.count == 1 else { throw ControlError("several extensions are called \(wanted); name it by its id") }
            return first
        }
        switch method {
        case "extensions.list":
            return [
                "extensions": store.entries.map { describe($0, store: store) },
                "needs_restart": store.needsRestart,
            ]
        case "extensions.add":
            guard let path = params["path"] as? String, !path.isEmpty else { throw ControlError("add needs a folder or a .crx file") }
            let full = NSString(string: path).expandingTildeInPath
            if full.hasSuffix(".crx") {
                let job = ControlJobs.start { finish in
                    Task { @MainActor in
                        do {
                            let manifest = try await store.addCRX(full)
                            finish(.success(["added": manifest.name, "id": manifest.id, "note": "It loads the next time Tiller opens."]))
                        } catch {
                            finish(.failure(ControlError(error.localizedDescription)))
                        }
                    }
                }
                return ["job": job]
            }
            let manifest = try wrap { try store.addFolder(full) }
            return ["added": manifest.name, "id": manifest.id, "note": "It loads the next time Tiller opens."]
        case "extensions.enable":
            let index = try index()
            store.setEnabled(params["on"] as? Bool ?? true, at: index)
            return describe(store.entries[index], store: store)
        case "extensions.pin":
            let index = try index()
            store.setPinned(params["on"] as? Bool ?? true, at: index)
            return describe(store.entries[index], store: store)
        case "extensions.remove":
            let index = try index()
            let removed = describe(store.entries[index], store: store)
            store.remove(at: IndexSet(integer: index))
            return ["removed": removed["name"] ?? "", "id": removed["id"] ?? ""]
        case "extensions.options":
            let index = try index()
            guard case .success(let manifest) = store.manifest(for: store.entries[index]) else {
                throw ControlError("the extension can't be read")
            }
            guard let url = manifest.optionsURL ?? manifest.popupURL else { throw ControlError("\(manifest.name) has no options page") }
            guard store.running.contains(where: { $0.id == manifest.id }) else {
                throw ControlError("\(manifest.name) isn't running, so its options page can't open")
            }
            guard let window = profile?.window else { throw ControlError("no browser window is open") }
            window.openInNewTab(url, background: params["background"] as? Bool ?? false)
            return ["opened": url]
        default:
            throw ControlError("unknown method \(method)")
        }
    }

    /// As Settings > Extensions shows it.
    private static func describe(_ entry: ExtensionStore.Entry, store: ExtensionStore) -> [String: Any] {
        var result: [String: Any] = ["path": entry.path, "source": entry.source.rawValue, "enabled": entry.enabled, "pinned": entry.pinned]
        let manifest = store.manifest(for: entry)
        switch manifest {
        case .success(let manifest):
            result["id"] = manifest.id
            result["name"] = manifest.name
            result["version"] = manifest.version
        case .failure(let error):
            result["name"] = (entry.path as NSString).lastPathComponent
            result["error"] = error.localizedDescription
        }
        let status: String
        if case .failure(let error) = manifest {
            if case ExtensionError.noManifest = error { status = "Folder missing" } else { status = "Can't be loaded" }
        } else if store.isLoaded(entry), let error = store.loadError(forFolder: entry.path) {
            status = "Failed to load"
            result["error"] = error
        } else {
            switch (store.isLoaded(entry), entry.enabled) {
            case (true, true): status = "Running"
            case (true, false): status = "Stops at next launch"
            case (false, true): status = "Starts at next launch"
            case (false, false): status = "Off"
            }
        }
        result["status"] = status
        return result
    }
}
