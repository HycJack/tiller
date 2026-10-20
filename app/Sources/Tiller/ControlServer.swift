import AppKit
import CTillerCore

struct ControlError: Error {
    let message: String
    init(_ message: String) { self.message = message }
}

/// A result that comes later: `start` is given the function to call with
/// the result, or a `ControlError`, once it is known.
final class ControlDeferred {
    let start: (@escaping (Result<Any, ControlError>) -> Void) -> Void
    init(_ start: @escaping (@escaping (Result<Any, ControlError>) -> Void) -> Void) { self.start = start }
}

/// Answers tiller_mcp's and the `tiller` CLI's requests for one profile, on
/// its control socket: tabs (`tabs.*`), skills, schedules, run_task's model
/// requests (`jev.*`), the agent panel (`agent.*`), history, downloads,
/// settings, sites and passwords, and requests about Tiller as a whole
/// (`app.*`, in `AppControl`), which any open profile's socket takes.
/// DevTools calls on the same socket never reach Swift; the core sends them
/// to the profile's tab directly. `app.open` opens a profile, for a second
/// launch of Tiller to pass on what it was asked.
///
/// A request from an agent's chat carries the chat's id in `chat`, from
/// TILLER_CHAT. Such requests may use the browser tools, skills and
/// schedules, but not the requests that manage Tiller (see `isManagement`).
@MainActor
final class ControlServer {
    private weak var profile: ProfileContext?
    private let socketPath: String

    init(profile: ProfileContext) {
        self.profile = profile
        socketPath = profile.socketPath
    }

    /// The server object lives for the rest of the process once started,
    /// since a request may still be on its way after `stop`.
    func start() -> Bool {
        guard let profile else { return false }
        let ctx = Unmanaged.passRetained(self).toOpaque()
        return tiller_ipc_start(socketPath, profile.context, ctx) { ctx, request, token in
            guard let ctx, let request else { return }
            ControlServer.from(ctx).handle(String(cString: request), token: token)
        }
    }

    /// Stops the socket, for the profile closing.
    func stop() {
        tiller_ipc_stop(socketPath)
    }

    nonisolated private static func from(_ ctx: UnsafeMutableRawPointer) -> ControlServer {
        Unmanaged<ControlServer>.fromOpaque(ctx).takeUnretainedValue()
    }

    nonisolated private func handle(_ json: String, token: UInt64) {
        MainActor.assumeIsolated {
            let result: Any
            do {
                guard let request = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
                    let method = request["method"] as? String
                else { throw ControlError("request needs a method") }
                var params = request["params"] as? [String: Any] ?? [:]
                let chat = (request["chat"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                if chat != nil, Self.isManagement(method) {
                    throw ControlError("\(method) manages Tiller, which an agent's chat can't do. Ask the user to run it from Terminal or do it in Tiller.")
                }
                // The person at a terminal may give a schedule any tools.
                if method.hasPrefix("schedules."), chat == nil, request["user"] as? Bool == true, params["chat"] == nil {
                    params["user"] = true
                }
                if method == "app.open" {
                    result = try Self.openProfile(params)
                } else if method.hasPrefix("app.") || method.hasPrefix("extensions.") || method.hasPrefix("jobs.") {
                    result = try AppControl.control(method, params: params, profile: profile)
                } else {
                    guard let profile else { throw ControlError("the profile was closed") }
                    if method.hasPrefix("skills.") {
                        result = try AgentSkillCatalog.control(method, params: params, profile: profile)
                    } else if method.hasPrefix("schedules.") {
                        result = try AgentScheduleControl.control(method, params: params, profile: profile)
                    } else if method.hasPrefix("jev.") {
                        result = try JevControl.control(method, params: params, profile: profile)
                    } else if ProfileControl.handles(method) {
                        result = try ProfileControl.control(method, params: params, profile: profile)
                    } else {
                        guard let browser = profile.window else { throw ControlError("no browser window is open") }
                        result = try browser.control(method, params: params)
                    }
                }
            } catch let error as ControlError {
                return Self.send(["error": error.message], token: token)
            } catch {
                return Self.send(["error": "\(error)"], token: token)
            }
            // A result that waits on the page answers when it is ready.
            if let deferred = result as? ControlDeferred {
                deferred.start { outcome in
                    switch outcome {
                    case .success(let value): Self.send(["result": value], token: token)
                    case .failure(let error): Self.send(["error": error.message], token: token)
                    }
                }
            } else {
                Self.send(["result": result], token: token)
            }
        }
    }

    /// Requests an agent's chat may not make: those that change Tiller's
    /// profiles, settings, passwords, sites, extensions, history or
    /// downloads, import data, change the skill library outside save_skill,
    /// or start and stop agents. Reading tabs, pages, skills, schedules and
    /// history stays open to agents, as do the per-chat limits on schedules.
    static func isManagement(_ method: String) -> Bool {
        let open: Set<String> = [
            "app.status", "app.profiles", "jobs.wait", "history.search", "history.recent", "history.top",
            "downloads.list", "settings.get", "agent.chats", "agent.transcript", "agent.status",
        ]
        if open.contains(method) { return false }
        let managed = ["app.", "extensions.", "history.", "downloads.", "settings.", "sites.", "passwords.", "import.", "agent.", "window."]
        if managed.contains(where: method.hasPrefix) { return true }
        return ["skills.toggle", "skills.remove", "skills.add", "tabs.fill_password"].contains(method)
    }

    /// Opens the profile `profile` names by id or name, or the one used
    /// last, with `urls` in new tabs.
    private static func openProfile(_ params: [String: Any]) throws -> Any {
        var id = Profiles.lastUsed.id
        if let wanted = params["profile"] as? String {
            guard let profile = Profiles.find(wanted) else { throw ControlError("no profile named \(wanted)") }
            id = profile.id
        }
        ProfileContext.open(id, urls: params["urls"] as? [String] ?? [])
        return ["profile": id]
    }

    private static func send(_ reply: [String: Any], token: UInt64) {
        var data = (try? JSONSerialization.data(withJSONObject: reply)) ?? Data(#"{"error":"could not encode reply"}"#.utf8)
        // Passed as is, NUL-terminated, rather than through a String, which
        // would copy and check every byte of a large reply on the main
        // thread. The core checks the text on the connection's thread, and
        // JSON escapes any NUL inside it.
        data.append(0)
        data.withUnsafeBytes { tiller_ipc_reply(token, $0.bindMemory(to: CChar.self).baseAddress) }
    }
}
