import AppKit

/// run_task's settings and model calls. tiller_mcp runs the task's loop and
/// sends its two kinds of model request here, `jev.decide` to TypeSafe's Jev
/// and `jev.text` to the text model, so the keys stay in the app's Keychain
/// and never reach the agent's process.
extension ProfileSettings {
    static let defaultJevModel = "jev-latest"
    static let defaultJevTextBaseURL = "https://openrouter.ai/api/v1"
    static let defaultJevTextModel = "inception/mercury-2.5"

    /// As typed. Empty means the default.
    var jevModelSetting: String {
        get { defaults.string(forKey: "jevModel") ?? "" }
        nonmutating set { defaults.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "jevModel") }
    }

    var jevTextBaseURLSetting: String {
        get { defaults.string(forKey: "jevTextBaseURL") ?? "" }
        nonmutating set { defaults.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "jevTextBaseURL") }
    }

    var jevTextModelSetting: String {
        get { defaults.string(forKey: "jevTextModel") ?? "" }
        nonmutating set { defaults.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "jevTextModel") }
    }

    var jevModel: String { jevModelSetting.isEmpty ? Self.defaultJevModel : jevModelSetting }
    var jevTextBaseURL: String { jevTextBaseURLSetting.isEmpty ? Self.defaultJevTextBaseURL : jevTextBaseURLSetting }
    var jevTextModel: String { jevTextModelSetting.isEmpty ? Self.defaultJevTextModel : jevTextModelSetting }

    /// Whether the text model may think before it answers. Off unless turned
    /// on: a field's value rarely needs it, and thinking is most of the wait.
    var jevTextReasoning: Bool {
        get { defaults.bool(forKey: "jevTextReasoning") }
        nonmutating set { defaults.set(newValue, forKey: "jevTextReasoning") }
    }
}

/// run_task's two keys, per profile, in the Keychain.
enum JevKey: String {
    case typesafe
    case text

    private static let service = "Tiller Jev"

    func read(profile: String) -> String? {
        AgentProviderKeychain.read("\(profile).\(rawValue)", service: Self.service).flatMap { $0.isEmpty ? nil : $0 }
    }

    enum Status: String {
        /// No TypeSafe key: run_task isn't offered.
        case off
        /// A TypeSafe key but no text model key: run_task can't type.
        case clickOnly = "click_only"
        case ready
    }

    /// Only checks which keys are saved, so it never makes macOS ask for
    /// the login password; the keys are read when run_task uses them.
    static func status(profile: String) -> Status {
        guard typesafe.exists(profile: profile) else { return .off }
        return text.exists(profile: profile) ? .ready : .clickOnly
    }

    func exists(profile: String) -> Bool {
        AgentProviderKeychain.exists("\(profile).\(rawValue)", service: Self.service)
    }

    /// An empty key removes it.
    func write(_ key: String, profile: String) {
        AgentProviderKeychain.write(key.trimmingCharacters(in: .whitespacesAndNewlines), for: "\(profile).\(rawValue)", service: Self.service)
    }
}

@MainActor
enum JevControl {
    static var decideURL: URL {
        #if DEBUG
        // For testing against a stand-in for TypeSafe.
        if let url = ProcessInfo.processInfo.environment["TILLER_JEV_DECIDE_URL"].flatMap(URL.init(string:)) { return url }
        #endif
        return URL(string: "https://api.typesafe.ai/v1/systemone")!
    }

    /// `jev.status` says which keys are set. `jev.decide` takes the request
    /// `body` for TypeSafe, without the model, and `jev.text` the `system` and
    /// `user` messages for the text model; both answer with the provider's JSON.
    static func control(_ method: String, params: [String: Any], profile: ProfileContext) throws -> Any {
        let settings = profile.settings
        switch method {
        case "jev.status":
            // Whether tiller_mcp offers run_task, and whether it can type.
            return ["status": JevKey.status(profile: profile.id).rawValue]
        case "jev.decide":
            guard let key = JevKey.typesafe.read(profile: profile.id) else {
                throw ControlError("run_task needs a TypeSafe API key; the user can add one in Tiller's Settings > Jev")
            }
            guard var body = params["body"] as? [String: Any] else { throw ControlError("jev.decide needs a body") }
            body["model"] = settings.jevModel
            return try post(decideURL, key: key, body: body)
        case "jev.text":
            guard let key = JevKey.text.read(profile: profile.id) else {
                throw ControlError("run_task needs a text model key to type; the user can add one in Tiller's Settings > Jev")
            }
            guard let system = params["system"] as? String, let user = params["user"] as? String else {
                throw ControlError("jev.text needs system and user messages")
            }
            var base = settings.jevTextBaseURL
            while base.hasSuffix("/") { base.removeLast() }
            guard let url = URL(string: base + "/chat/completions"), ["https", "http"].contains(url.scheme) else {
                throw ControlError("the text model URL in Settings > Jev isn't a web address: \(base)")
            }
            var body: [String: Any] = [
                "model": settings.jevTextModel,
                "max_tokens": 1024,
                "response_format": ["type": "json_object"],
                "messages": [["role": "system", "content": system], ["role": "user", "content": user]],
            ]
            // DeepSeek's own API turns thinking on and off its own way;
            // OpenRouter and most others take `reasoning`.
            if url.host?.hasSuffix("deepseek.com") == true {
                body["thinking"] = ["type": settings.jevTextReasoning ? "enabled" : "disabled"]
            } else {
                body["reasoning"] = settings.jevTextReasoning ? ["effort": "low"] : ["enabled": false]
            }
            return try post(url, key: key, body: body)
        default:
            throw ControlError("unknown method \(method)")
        }
    }

    private static func post(_ url: URL, key: String, body: [String: Any]) throws -> ControlDeferred {
        let data = try JSONSerialization.data(withJSONObject: body)
        return ControlDeferred { reply in
            Task { @MainActor in
                switch await send(url, key: key, body: data) {
                case .success(let data):
                    guard let value = try? JSONSerialization.jsonObject(with: data) else {
                        return reply(.failure(ControlError("\(url.host ?? "the model") answered with something other than JSON")))
                    }
                    reply(.success(value))
                case .failure(let error):
                    reply(.failure(error))
                }
            }
        }
    }

    /// One POST, tried again twice after a short pause while the provider is
    /// busy (429, 503, 529). Nothing has acted on the page yet when it fails.
    nonisolated private static func send(_ url: URL, key: String, body: Data) async -> Result<Data, ControlError> {
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Tiller", forHTTPHeaderField: "X-Title")
        let host = url.host ?? "the model"
        for attempt in 0..<3 {
            let data: Data, response: URLResponse
            do {
                (data, response) = try await URLSession.shared.data(for: request)
            } catch {
                return .failure(ControlError("could not reach \(host): \(error.localizedDescription)"))
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if [429, 503, 529].contains(status), attempt < 2 {
                try? await Task.sleep(for: .milliseconds(500 << attempt))
                continue
            }
            guard (200..<300).contains(status) else {
                let detail = String(decoding: data.prefix(300), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                return .failure(ControlError("\(host) answered HTTP \(status)" + (detail.isEmpty ? "" : ": \(detail)")))
            }
            return .success(data)
        }
        return .failure(ControlError("\(host) stayed busy"))
    }
}

// MARK: Settings

/// Settings > Jev: the keys and models run_task uses.
final class JevSettingsPane: SettingsPane, NSTextFieldDelegate {
    private let typesafeKeyField = NSSecureTextField()
    private let modelField = NSTextField()
    private let textURLField = NSTextField()
    private let textModelField = NSTextField()
    private let textKeyField = NSSecureTextField()

    init(profile: ProfileContext) { super.init(title: "Jev", profile: profile) }

    required init?(coder: NSCoder) { fatalError() }

    override func buildRows() {
        let intro = Self.note(
            "Agents call run_task to hand a short task on one page, such as filling a search form, to TypeSafe's Jev, "
                + "which picks each click and field quickly. A small text model writes what goes in the fields."
        )
        intro.lineBreakMode = .byWordWrapping
        intro.maximumNumberOfLines = 3
        intro.preferredMaxLayoutWidth = Self.controlWidth
        grid.addRow(with: [NSGridCell.emptyContentView, intro]).bottomPadding = 8

        typesafeKeyField.stringValue = JevKey.typesafe.read(profile: profile.id) ?? ""
        typesafeKeyField.placeholderString = "Required for run_task"
        addRow("TypeSafe API key:", Self.fixWidth(typesafeKeyField))
        addNote(Self.note("From typesafe.ai. Kept in the Keychain."))

        modelField.stringValue = settings.jevModelSetting
        modelField.placeholderString = ProfileSettings.defaultJevModel
        addRow("Jev model:", Self.fixWidth(modelField))

        textURLField.stringValue = settings.jevTextBaseURLSetting
        textURLField.placeholderString = ProfileSettings.defaultJevTextBaseURL
        addRow("Text model URL:", Self.fixWidth(textURLField))
        addNote(Self.note("An OpenAI-compatible API; /chat/completions is added."))

        textModelField.stringValue = settings.jevTextModelSetting
        textModelField.placeholderString = ProfileSettings.defaultJevTextModel
        addRow("Text model:", Self.fixWidth(textModelField))

        textKeyField.stringValue = JevKey.text.read(profile: profile.id) ?? ""
        textKeyField.placeholderString = "Required to type into fields"
        addRow("Text model key:", Self.fixWidth(textKeyField))

        let reasoning = NSButton(
            checkboxWithTitle: "Let the text model think first", target: self, action: #selector(reasoningChanged(_:))
        )
        reasoning.state = settings.jevTextReasoning ? .on : .off
        Self.linkLabel(of: addRow("Reasoning:", reasoning), to: reasoning)
        addNote(Self.note("Slower, and rarely needed for a field's value."))

        let restart = Self.note("Agents get run_task from their next start: a new chat, or the next message after one stops.")
        restart.lineBreakMode = .byWordWrapping
        restart.maximumNumberOfLines = 2
        restart.preferredMaxLayoutWidth = Self.controlWidth
        grid.addRow(with: [NSGridCell.emptyContentView, restart]).topPadding = 8

        let privacy = Self.note(
            "run_task sends the goal and the visible text of the page it works on to TypeSafe, and to the text model when it types."
        )
        privacy.lineBreakMode = .byWordWrapping
        privacy.maximumNumberOfLines = 2
        privacy.preferredMaxLayoutWidth = Self.controlWidth
        grid.addRow(with: [NSGridCell.emptyContentView, privacy]).topPadding = 8

        for field in [typesafeKeyField, modelField, textURLField, textModelField, textKeyField] {
            field.delegate = self
        }
    }

    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        switch field {
        case typesafeKeyField: JevKey.typesafe.write(field.stringValue, profile: profile.id)
        case textKeyField: JevKey.text.write(field.stringValue, profile: profile.id)
        case modelField: settings.jevModelSetting = field.stringValue
        case textURLField: settings.jevTextBaseURLSetting = field.stringValue
        case textModelField: settings.jevTextModelSetting = field.stringValue
        default: break
        }
    }

    @objc private func reasoningChanged(_ sender: NSButton) {
        settings.jevTextReasoning = sender.state == .on
    }
}
