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

    static func status(profile: String) -> Status {
        guard typesafe.read(profile: profile) != nil else { return .off }
        return text.read(profile: profile) == nil ? .clickOnly : .ready
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
        case "jev.progress":
            // How a run is going, for the window to show; answers whether
            // the user pressed Stop.
            guard let window = profile.window else { return ["stop": false] }
            return try window.control(method, params: params)
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
            let url = try textURL(settings)
            return try post(url, key: key, body: textBody(settings, url: url, system: system, user: user))
        default:
            throw ControlError("unknown method \(method)")
        }
    }

    /// The text model's chat completions address, from Settings > Jev.
    nonisolated private static func textURL(_ settings: ProfileSettings) throws -> URL {
        var base = settings.jevTextBaseURL
        while base.hasSuffix("/") { base.removeLast() }
        guard let url = URL(string: base + "/chat/completions"), ["https", "http"].contains(url.scheme) else {
            throw ControlError("the text model URL in Settings > Jev isn't a web address: \(base)")
        }
        return url
    }

    nonisolated private static func textBody(_ settings: ProfileSettings, url: URL, system: String, user: String, maxTokens: Int = 1024) -> [String: Any] {
        var body: [String: Any] = [
            "model": settings.jevTextModel,
            "max_tokens": maxTokens,
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
        return body
    }

    /// How a check of one key went: the round trip, or why it failed.
    typealias CheckResult = Result<Duration, ControlError>

    /// Settings > Jev's Check Keys: one small request to each model whose
    /// key is set, sent together. Nil for a key that isn't set.
    static func check(profile: ProfileContext) async -> (typesafe: CheckResult?, text: CheckResult?) {
        let settings = profile.settings
        let (url, model) = (decideURL, settings.jevModel)
        let (typesafeKey, textKey) = (JevKey.typesafe.read(profile: profile.id), JevKey.text.read(profile: profile.id))
        async let typesafe = checkTypeSafe(key: typesafeKey, url: url, model: model)
        async let text = checkText(key: textKey, settings: settings)
        return await (typesafe, text)
    }

    /// One operation question with two choices, on a page with nothing on it.
    nonisolated private static func checkTypeSafe(key: String?, url: URL, model: String) async -> CheckResult? {
        guard let key else { return nil }
        let body: [String: Any] = [
            "model": model,
            "state": [
                "page": ["url": "about:blank", "title": "Tiller", "text": "Tiller is checking its connection."],
                "elements": [Any](),
                "recent_actions": [Any](),
            ],
            "questions": ["operation": [
                "type": "choice",
                "criteria": ["DONE": "Every requirement is visibly satisfied.", "BLOCKED": "No supported operation can progress."],
                "instructions": ["goal": "Check that the connection works."],
            ]],
        ]
        return await timed(url, key: key, body: body)
    }

    nonisolated private static func checkText(key: String?, settings: ProfileSettings) async -> CheckResult? {
        guard let key else { return nil }
        do {
            let url = try textURL(settings)
            let body = textBody(settings, url: url, system: "Return the JSON object {\"text\": \"ok\"}.", user: "Check", maxTokens: 16)
            return await timed(url, key: key, body: body)
        } catch {
            return .failure(error as? ControlError ?? ControlError(error.localizedDescription))
        }
    }

    nonisolated private static func timed(_ url: URL, key: String, body: [String: Any]) async -> CheckResult {
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return .failure(ControlError("couldn't write the request")) }
        let clock = ContinuousClock()
        let start = clock.now
        return await send(url, key: key, body: data).map { _ in clock.now - start }
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

/// Settings > Jev: the keys and models run_task uses, whether agents get
/// it, and a check that the keys work.
final class JevSettingsPane: SettingsPane, NSTextFieldDelegate {
    private let typesafeKeyField = NSSecureTextField()
    private let modelField = NSTextField()
    private let textURLField = NSTextField()
    private let textModelField = NSTextField()
    private let textKeyField = NSSecureTextField()
    private let statusDot = NSView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let statusNote = SettingsPane.note()
    private let checkButton = NSButton(title: "Check Keys", target: nil, action: nil)
    private let checkResult = SettingsPane.note()
    private var checking: Task<Void, Never>?

    init(profile: ProfileContext) { super.init(title: "Jev", profile: profile) }

    required init?(coder: NSCoder) { fatalError() }

    override func buildRows() {
        let intro = Self.wrapping(Self.note(
            "Agents call run_task to hand a short task on one page, such as filling a search form, to TypeSafe's Jev, "
                + "which picks each click and field in a few hundred milliseconds. A small text model writes what goes in the fields."
        ), lines: 3)
        grid.addRow(with: [NSGridCell.emptyContentView, intro]).bottomPadding = 8

        statusDot.wantsLayer = true
        statusDot.layer?.cornerRadius = 4
        statusDot.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            statusDot.widthAnchor.constraint(equalToConstant: 8),
            statusDot.heightAnchor.constraint(equalToConstant: 8),
        ])
        statusLabel.font = .systemFont(ofSize: Theme.FontSize.body, weight: .semibold)
        let status = NSStackView(views: [statusDot, statusLabel])
        status.spacing = 6
        status.alignment = .centerY
        addRow("Status:", status)
        addNote(Self.wrapping(statusNote, lines: 2))

        typesafeKeyField.stringValue = JevKey.typesafe.read(profile: profile.id) ?? ""
        typesafeKeyField.placeholderString = "Required for run_task"
        addRow("TypeSafe API key:", Self.fixWidth(typesafeKeyField))
        addLinkNote(Self.noteWithLink("Kept in the Keychain.", link: "Get a key", url: "https://typesafe.ai", target: self))

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
        addLinkNote(Self.noteWithLink("Kept in the Keychain.", link: "OpenRouter keys", url: "https://openrouter.ai/settings/keys", target: self))

        let reasoning = NSButton(
            checkboxWithTitle: "Let the text model think first", target: self, action: #selector(reasoningChanged(_:))
        )
        reasoning.state = settings.jevTextReasoning ? .on : .off
        Self.linkLabel(of: addRow("Reasoning:", reasoning), to: reasoning)
        addNote(Self.note("Slower, and rarely needed for a field's value."))

        checkButton.target = self
        checkButton.action = #selector(checkKeys(_:))
        checkButton.bezelStyle = .push
        checkButton.controlSize = .regular
        checkResult.lineBreakMode = .byTruncatingTail
        let check = NSStackView(views: [checkButton, checkResult])
        check.spacing = 8
        check.alignment = .firstBaseline
        check.widthAnchor.constraint(equalToConstant: Self.controlWidth).isActive = true
        grid.addRow(with: [NSGridCell.emptyContentView, check]).topPadding = 4

        let restart = Self.wrapping(Self.note(
            "Agents get run_task from their next start: a new chat, or the next message after one stops. "
                + "While it works, the page shows each step, with a Stop button."
        ), lines: 3)
        grid.addRow(with: [NSGridCell.emptyContentView, restart]).topPadding = 12

        let privacy = Self.wrapping(Self.note(
            "run_task sends the goal and the visible text of the page it works on to TypeSafe, and to the text model when it types."
        ), lines: 2)
        grid.addRow(with: [NSGridCell.emptyContentView, privacy]).topPadding = 6

        for field in [typesafeKeyField, modelField, textURLField, textModelField, textKeyField] {
            field.delegate = self
        }
        updateStatus()
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        checking?.cancel()
    }

    /// `addNote` for a note with a link in it.
    private func addLinkNote(_ view: NSView) {
        let row = grid.addRow(with: [NSGridCell.emptyContentView, view])
        row.topPadding = -4
        row.bottomPadding = 6
    }

    private static func milliseconds(_ duration: Duration) -> Int {
        let (seconds, attoseconds) = duration.components
        return Int(seconds) * 1000 + Int(attoseconds / 1_000_000_000_000_000)
    }

    private static func wrapping(_ label: NSTextField, lines: Int) -> NSTextField {
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = lines
        label.preferredMaxLayoutWidth = controlWidth
        return label
    }

    /// A note with a link after it that opens `url` in the browser.
    private static func noteWithLink(_ text: String, link: String, url: String, target: JevSettingsPane) -> NSView {
        let button = NSButton(title: link, target: target, action: #selector(openLink(_:)))
        button.isBordered = false
        button.attributedTitle = NSAttributedString(string: link + " \u{2197}", attributes: [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.linkColor,
        ])
        button.toolTip = url
        button.identifier = NSUserInterfaceItemIdentifier(url)
        let row = NSStackView(views: [note(text), button])
        row.spacing = 4
        row.alignment = .firstBaseline
        return row
    }

    @objc private func openLink(_ sender: NSButton) {
        guard let string = sender.identifier?.rawValue, let url = URL(string: string) else { return }
        NSWorkspace.shared.open(url)
    }

    /// Whether agents get run_task, and what is missing.
    private func updateStatus() {
        let (title, note, color): (String, String, NSColor) = switch JevKey.status(profile: profile.id) {
        case .ready: ("Ready", "Agents can hand tasks on a page to Jev, typing included.", .systemGreen)
        case .clickOnly: ("Clicks only", "Add a text model key so Jev can type into fields.", .systemOrange)
        case .off: ("Off", "Add a TypeSafe API key to give agents run_task.", .tertiaryLabelColor)
        }
        statusLabel.stringValue = title
        statusNote.stringValue = note
        statusDot.layer?.backgroundColor = color.layerColor
        statusDot.setAccessibilityElement(false)
        checkButton.isEnabled = JevKey.status(profile: profile.id) != .off
        if !checkButton.isEnabled { Self.show("", in: checkResult) }
    }

    @objc private func checkKeys(_ sender: Any?) {
        checking?.cancel()
        checkButton.isEnabled = false
        Self.show("Checking\u{2026}", in: checkResult)
        checking = Task { [weak self, profile] in
            let (typesafe, text) = await JevControl.check(profile: profile)
            guard let self, !Task.isCancelled else { return }
            checkButton.isEnabled = true
            let parts = [("TypeSafe", typesafe), ("Text model", text)].compactMap { name, result in
                result.map { (name, $0) }
            }
            let failed = parts.filter { if case .failure = $0.1 { true } else { false } }
            if let (name, result) = failed.first, case .failure(let error) = result {
                Self.show("\(name): \(error.message)", in: checkResult, warning: true)
            } else {
                let times: [String] = parts.map { name, result in
                    let ms = (try? result.get()).map(Self.milliseconds) ?? 0
                    return "\(name) \(ms) ms"
                }
                Self.show("\u{2713} " + times.joined(separator: " \u{00B7} "), in: checkResult)
            }
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
        if field === typesafeKeyField || field === textKeyField { updateStatus() }
        // An earlier check said nothing about the keys as they are now.
        if !checkResult.stringValue.isEmpty, checking != nil {
            checking?.cancel()
            checking = nil
            Self.show("", in: checkResult)
            checkButton.isEnabled = JevKey.status(profile: profile.id) != .off
        }
    }

    @objc private func reasoningChanged(_ sender: NSButton) {
        settings.jevTextReasoning = sender.state == .on
    }
}
