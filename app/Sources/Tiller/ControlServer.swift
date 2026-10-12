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

/// Answers tiller_mcp's tab requests (list, open, select, navigate, close) and
/// skill requests (list, read, save) and schedule requests (list, save,
/// delete, run) for one profile, on its control socket. DevTools calls on the
/// same socket never reach Swift; the core sends them to the profile's tab
/// directly. `app.open` opens a profile, for a second launch of Tiller to
/// pass on what it was asked.
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
                let params = request["params"] as? [String: Any] ?? [:]
                if method == "app.open" {
                    result = try Self.openProfile(params)
                } else {
                    guard let profile else { throw ControlError("the profile was closed") }
                    if method.hasPrefix("skills.") {
                        result = try AgentSkillCatalog.control(method, params: params, profile: profile)
                    } else if method.hasPrefix("schedules.") {
                        result = try AgentScheduleControl.control(method, params: params, profile: profile)
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
