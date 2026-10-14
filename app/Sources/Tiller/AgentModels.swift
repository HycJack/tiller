import AppKit

/// The model, thinking effort, context size and fast mode an agent's CLI runs
/// with. Nil, or fast off, leaves the CLI's own choice, so no flag is passed
/// and the user's own CLI settings apply.
struct AgentModelOptions: Codable, Equatable {
    var model: String?
    var effort: String?
    /// Claude Code's `1m`, or Qoder CLI's window in tokens.
    var context: String?
    var fast = false

    init(model: String? = nil, effort: String? = nil, context: String? = nil, fast: Bool = false) {
        self.model = model
        self.effort = effort
        self.context = context
        self.fast = fast
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        model = try container.decodeIfPresent(String.self, forKey: .model)
        effort = try container.decodeIfPresent(String.self, forKey: .effort)
        context = try container.decodeIfPresent(String.self, forKey: .context)
        fast = try container.decodeIfPresent(Bool.self, forKey: .fast) ?? false
    }

    var isDefault: Bool { self == AgentModelOptions() }

    /// Only what `kind` can take: options left from another agent, or from a
    /// model without them, are dropped.
    @MainActor
    func supported(by kind: AgentChoice) -> AgentModelOptions {
        var options = self
        if let effort, !kind.effortLevels(model: model).contains(effort) { options.effort = nil }
        if let context, !kind.contextSizes.contains(where: { $0.value == context }) { options.context = nil }
        // Claude Code's 1M is a suffix on a model.
        if kind.kind == .claude, model == nil { options.context = nil }
        if fast, kind.fastTier(model: model) == nil { options.fast = false }
        return options
    }

    /// Like `opus · high · 1M · fast`, or `default` when nothing is set.
    @MainActor
    func summary(for kind: AgentChoice) -> String {
        var parts = [model.map { kind.modelName($0) } ?? "default model"]
        if let effort { parts.append(effort) }
        if let context, let size = kind.contextSizes.first(where: { $0.value == context }) { parts.append(size.title) }
        if fast { parts.append("fast") }
        return parts.joined(separator: " · ")
    }

    /// The model's name, and its effort when set, for the message field's
    /// model button: `Opus · high`. The CLI's own model goes by its name
    /// when the CLI has said which it is.
    @MainActor
    func shortTitle(for kind: AgentChoice) -> String {
        let fallback = kind.provider == nil && kind.kind == .codex ? AgentModelCatalog.codexModel(nil)?.name : nil
        var parts = [model.map { kind.modelName($0) } ?? fallback ?? "Default model"]
        if let effort { parts.append(effort) }
        if fast { parts.append("fast") }
        return parts.joined(separator: " · ")
    }
}

/// A model a CLI offers. Codex says which efforts and service tiers each
/// model has; the other CLIs only name them.
struct AgentModel: Codable, Equatable {
    var id: String
    var name: String
    var efforts: [String]?
    /// The service tier Codex calls Fast, if the model has one.
    var fastTier: String?
    var isDefault: Bool
}

extension AgentKind {
    /// What `--effort` and its kin take. Codex's depend on the model.
    @MainActor
    func effortLevels(model: String?) -> [String] {
        switch self {
        case .claude, .agy: ["low", "medium", "high", "xhigh", "max"]
        case .qodercli: ["none", "low", "medium", "high", "xhigh", "max", "ultracode"]
        case .grok: ["low", "medium", "high"]
        case .codex: AgentModelCatalog.codexModel(model)?.efforts ?? ["low", "medium", "high", "xhigh"]
        }
    }

    /// Context windows the CLI can be asked for. Claude Code's 1M is a
    /// suffix on the model, so it needs one picked.
    var contextSizes: [(value: String, title: String)] {
        switch self {
        case .claude: [("1m", "1M")]
        case .qodercli: [("200000", "200K"), ("400000", "400K"), ("1000000", "1M")]
        case .codex, .agy, .grok: []
        }
    }

    /// What fast mode passes: `fastMode` for Claude Code, a service tier for
    /// Codex models that have one. Nil when there is no fast mode.
    @MainActor
    func fastTier(model: String?) -> String? {
        switch self {
        case .claude: "fastMode"
        case .codex:
            // Until Codex has listed its models, take its tier's usual id.
            AgentModelCatalog.models(for: .codex).isEmpty ? "priority" : AgentModelCatalog.codexModel(model)?.fastTier
        case .qodercli, .agy, .grok: nil
        }
    }

    /// The model's name as the CLI lists it, or its id.
    @MainActor
    func modelName(_ id: String) -> String {
        AgentModelCatalog.models(for: self).first { $0.id == id }?.name ?? id
    }
}

/// The CLI's options, except that a provider has its own models and none of
/// the CLI's context sizes or fast mode, which are Anthropic's.
extension AgentChoice {
    @MainActor
    func effortLevels(model: String?) -> [String] { kind.effortLevels(model: model) }

    var contextSizes: [(value: String, title: String)] { provider == nil ? kind.contextSizes : [] }

    @MainActor
    func fastTier(model: String?) -> String? { provider == nil ? kind.fastTier(model: model) : nil }

    @MainActor
    func modelName(_ id: String) -> String { provider == nil ? kind.modelName(id) : id }
}

/// The models each CLI offers, asked of the CLI once per launch and kept in
/// the app's defaults, so a menu opened before the CLI answers shows last
/// time's. Every profile shares them.
/// Claude Code can't list its models, so it gets its aliases.
@MainActor
enum AgentModelCatalog {
    private static var cache: [AgentKind: [AgentModel]] = [:]
    private static var refreshed: Set<AgentKind> = []
    /// CLIs being asked right now.
    private(set) static var loading: Set<AgentKind> = []

    private static func defaultsKey(_ kind: AgentKind) -> String { "agentModels.\(kind.rawValue)" }

    static func models(for kind: AgentKind) -> [AgentModel] {
        if kind == .claude {
            return [("fable", "Fable"), ("opus", "Opus"), ("sonnet", "Sonnet"), ("haiku", "Haiku")].map {
                AgentModel(id: $0.0, name: $0.1, efforts: nil, fastTier: nil, isDefault: false)
            }
        }
        if let models = cache[kind] { return models }
        let data = Settings.defaults.data(forKey: defaultsKey(kind))
        let models = data.flatMap { try? JSONDecoder().decode([AgentModel].self, from: $0) } ?? []
        cache[kind] = models
        return models
    }

    /// Codex's entry for `model`, or its default model's for nil.
    static func codexModel(_ model: String?) -> AgentModel? {
        let models = models(for: .codex)
        return model.map { id in models.first { $0.id == id } } ?? models.first(where: \.isDefault)
    }

    /// Asks the CLI for its models in the background, once per launch, as
    /// `profile` runs it. Posts `agentModelsDidChange` when it answers, or
    /// fails to.
    static func refresh(_ kind: AgentKind, profile: ProfileContext) {
        guard kind != .claude, !refreshed.contains(kind) else { return }
        let path = profile.settings.agentPath(for: kind)
        // Codex needs Tiller's CODEX_HOME, which has the user's login.
        guard let environment = try? AgentEnvironment.environment(for: kind, chat: "", profile: profile) else { return }
        refreshed.insert(kind)
        loading.insert(kind)
        Task.detached(priority: .utility) {
            var models: [AgentModel]?
            if let executable = path ?? AgentEnvironment.detectedExecutable(for: kind),
                FileManager.default.isExecutableFile(atPath: executable) {
                models = list(kind, executable: executable, environment: environment)
            }
            await MainActor.run { [models] in
                loading.remove(kind)
                if let models, !models.isEmpty, models != self.models(for: kind) {
                    cache[kind] = models
                    Settings.defaults.set(try? JSONEncoder().encode(models), forKey: defaultsKey(kind))
                }
                NotificationCenter.default.post(name: .agentModelsDidChange, object: nil)
            }
        }
    }

    /// Asks every CLI, so the lists are there before a menu opens.
    static func refreshAll(profile: ProfileContext) {
        for kind in AgentKind.allCases { refresh(kind, profile: profile) }
    }

    /// Runs the CLI's own listing and reads it. Nil when it fails.
    nonisolated private static func list(_ kind: AgentKind, executable: String, environment: [String: String]) -> [AgentModel]? {
        switch kind {
        case .codex:
            return codexModels(executable: executable, environment: environment)
        case .qodercli:
            // A MODEL header, then a name a line.
            guard let output = run(executable, ["--list-models"], environment: environment) else { return nil }
            return output.split(whereSeparator: \.isNewline).dropFirst().compactMap { line in
                let name = line.components(separatedBy: "  ").first?.trimmingCharacters(in: .whitespaces) ?? ""
                return name.isEmpty ? nil : AgentModel(id: name, name: name, efforts: nil, fastTier: nil, isDefault: false)
            }
        case .agy:
            // `id<TAB>name` lines, after a line saying it is fetching.
            guard let output = run(executable, ["models"], environment: environment) else { return nil }
            return output.split(whereSeparator: \.isNewline).compactMap { line in
                let parts = line.split(separator: "\t", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                guard parts.count == 2, !parts[0].isEmpty else { return nil }
                return AgentModel(id: parts[0], name: parts[1], efforts: nil, fastTier: nil, isDefault: false)
            }
        case .grok:
            // `  * id (default)` and `  - id` lines. The image and video
            // models can't run an agent.
            guard let output = run(executable, ["models"], environment: environment) else { return nil }
            return output.split(whereSeparator: \.isNewline).compactMap { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("* ") || trimmed.hasPrefix("- ") else { return nil }
                let words = trimmed.dropFirst(2).split(separator: " ")
                guard let id = words.first.map(String.init), !id.contains("imagine") else { return nil }
                return AgentModel(id: id, name: id, efforts: nil, fastTier: nil, isDefault: trimmed.hasPrefix("*"))
            }
        case .claude:
            return nil
        }
    }

    /// The output of a listing command, or nil if it fails or takes over 30 seconds.
    nonisolated private static func run(_ executable: String, _ arguments: [String], environment: [String: String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = URL(fileURLWithPath: NSTemporaryDirectory())
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 30, execute: timeout)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        timeout.cancel()
        guard process.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// Codex lists its models over the app server's `model/list`.
    nonisolated private static func codexModels(executable: String, environment: [String: String]) -> [AgentModel]? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["app-server"]
        process.environment = environment
        process.currentDirectoryURL = URL(fileURLWithPath: NSTemporaryDirectory())
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        signal(SIGPIPE, SIG_IGN)
        guard (try? process.run()) != nil else { return nil }
        let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 30, execute: timeout)
        defer {
            timeout.cancel()
            try? input.fileHandleForWriting.close()
            if process.isRunning { process.terminate() }
        }
        let requests: [[String: Any]] = [
            ["id": 1, "method": "initialize", "params": ["clientInfo": ["name": "tiller", "title": "Tiller", "version": "0"]]],
            ["method": "initialized"],
            ["id": 2, "method": "model/list", "params": [String: Any]()],
        ]
        for request in requests {
            guard var data = try? JSONSerialization.data(withJSONObject: request) else { return nil }
            data.append(0x0A)
            guard (try? input.fileHandleForWriting.write(contentsOf: data)) != nil else { return nil }
        }
        let parser = JSONLineParser()
        while true {
            let data = output.fileHandleForReading.availableData
            if data.isEmpty { return nil }
            for message in parser.feed(data) where message.object["id"] as? Int == 2 {
                let entries = (message.object["result"] as? [String: Any])?["data"] as? [[String: Any]] ?? []
                return entries.compactMap { entry in
                    guard entry["hidden"] as? Bool != true, let id = entry["id"] as? String ?? entry["model"] as? String else { return nil }
                    let efforts = (entry["supportedReasoningEfforts"] as? [[String: Any]])?.compactMap { $0["reasoningEffort"] as? String }
                    let tiers = entry["serviceTiers"] as? [[String: Any]] ?? []
                    let fast = tiers.first { ($0["name"] as? String)?.lowercased() == "fast" }?["id"] as? String
                    return AgentModel(
                        id: id, name: entry["displayName"] as? String ?? id, efforts: efforts.flatMap { $0.isEmpty ? nil : $0 },
                        fastTier: fast, isDefault: entry["isDefault"] as? Bool ?? false
                    )
                }
            }
        }
    }
}

/// The menu that picks a chat's, a schedule's or Settings' model options:
/// the model, then the effort, context size and fast mode where the agent
/// has them. Each choice calls `onChange` with the new options.
@MainActor
final class AgentModelMenu: NSObject {
    private let kind: AgentChoice
    private var options: AgentModelOptions
    private let onChange: (AgentModelOptions) -> Void
    private let menu = NSMenu()
    private var locked = false
    private var note: String?

    private let profile: ProfileContext

    private init(kind: AgentChoice, profile: ProfileContext, options: AgentModelOptions, onChange: @escaping (AgentModelOptions) -> Void) {
        self.kind = kind
        self.profile = profile
        self.options = options
        self.onChange = onChange
    }

    /// The menu stays with the items' targets while it is open.
    private static var current: AgentModelMenu?

    /// Pops the menu up just below `view`, or with `above` just above it.
    /// `locked` greys every choice out, with `note` saying why; `note`
    /// otherwise goes at the bottom.
    static func popUp(
        from view: NSView, above: Bool = false, kind: AgentChoice, profile: ProfileContext, options: AgentModelOptions, locked: Bool = false,
        note: String? = nil, onChange: @escaping (AgentModelOptions) -> Void
    ) {
        if kind.provider == nil { AgentModelCatalog.refresh(kind.kind, profile: profile) }
        let controller = AgentModelMenu(kind: kind, profile: profile, options: options, onChange: onChange)
        current = controller
        controller.locked = locked
        controller.note = note
        controller.build()
        // The CLI may answer while the menu is open, which then fills in.
        NotificationCenter.default.addObserver(
            controller, selector: #selector(modelsChanged(_:)), name: .agentModelsDidChange, object: nil
        )
        let menu = controller.menu
        if above { return menu.popUp(above: view) }
        let below = view.isFlipped ? view.bounds.maxY + 4 : view.bounds.minY - 4
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: below), in: view)
    }

    @objc private func modelsChanged(_ notification: Notification) {
        build()
    }

    private func build() {
        menu.removeAllItems()
        menu.autoenablesItems = false
        let locked = locked
        func add(_ title: String, checked: Bool, enabled: Bool = true, toolTip: String? = nil, _ change: @escaping (inout AgentModelOptions) -> Void) {
            let item = NSMenuItem(title: title, action: #selector(choose(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = Change(change)
            item.state = checked ? .on : .off
            item.isEnabled = enabled && !locked
            item.toolTip = toolTip
            item.indentationLevel = 1
            menu.addItem(item)
        }

        menu.addItem(.sectionHeader(title: "Model"))
        add("Default", checked: options.model == nil) { $0.model = nil }
        let models = profile.providers.models(for: kind)
        for model in models {
            add(model.isDefault ? model.name + " (default)" : model.name, checked: options.model == model.id) { $0.model = model.id }
        }
        if models.isEmpty {
            let loading = kind.provider == nil && AgentModelCatalog.loading.contains(kind.kind)
            let item = NSMenuItem(title: loading ? "Loading models…" : "No list from \(profile.providers.displayName(kind))", action: nil, keyEquivalent: "")
            item.isEnabled = false
            item.indentationLevel = 1
            menu.addItem(item)
        }
        if let model = options.model, !models.contains(where: { $0.id == model }) {
            add(model, checked: true) { $0.model = model }
        }
        let custom = NSMenuItem(title: "Custom…", action: #selector(customModel(_:)), keyEquivalent: "")
        custom.target = self
        custom.isEnabled = !locked
        custom.indentationLevel = 1
        menu.addItem(custom)

        let efforts = kind.effortLevels(model: options.model)
        if !efforts.isEmpty {
            menu.addItem(.separator())
            menu.addItem(.sectionHeader(title: "Thinking effort"))
            add("Default", checked: options.effort == nil) { $0.effort = nil }
            for effort in efforts {
                add(effort, checked: options.effort == effort) { $0.effort = effort }
            }
        }

        let sizes = kind.contextSizes
        if !sizes.isEmpty {
            menu.addItem(.separator())
            menu.addItem(.sectionHeader(title: "Context window"))
            add("Default", checked: options.context == nil) { $0.context = nil }
            // Claude Code's 1M is a suffix on a model.
            let needsModel = kind.kind == .claude && options.model == nil
            for size in sizes {
                add(
                    size.title, checked: options.context == size.value, enabled: !needsModel,
                    toolTip: needsModel ? "Pick a model first." : nil
                ) { $0.context = size.value }
            }
        }

        if kind.fastTier(model: options.model) != nil {
            menu.addItem(.separator())
            add("Fast mode", checked: options.fast, toolTip: "Faster output at a higher price, where the account allows it.") { $0.fast.toggle() }
            menu.items.last?.indentationLevel = 0
        }

        if let note {
            menu.addItem(.separator())
            let item = NSMenuItem(title: note, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
    }

    private final class Change {
        let apply: (inout AgentModelOptions) -> Void
        init(_ apply: @escaping (inout AgentModelOptions) -> Void) { self.apply = apply }
    }

    @objc private func choose(_ sender: NSMenuItem) {
        guard let change = sender.representedObject as? Change else { return }
        var options = self.options
        change.apply(&options)
        commit(options)
    }

    /// Asks for a model id the list doesn't have.
    @objc private func customModel(_ sender: NSMenuItem) {
        let alert = NSAlert()
        alert.messageText = "Model for \(profile.providers.displayName(kind))"
        alert.informativeText = "The model's id or alias, as the CLI's --model flag takes it."
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 22))
        field.stringValue = options.model ?? ""
        field.placeholderString = profile.providers.models(for: kind).first?.id ?? "model id"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let model = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        var options = self.options
        options.model = model.isEmpty ? nil : model
        commit(options)
    }

    private func commit(_ options: AgentModelOptions) {
        let options = options.supported(by: kind)
        AgentModelMenu.current = nil
        guard options != self.options else { return }
        onChange(options)
    }
}

extension Notification.Name {
    /// Posted when a CLI's list of models changes.
    static let agentModelsDidChange = Notification.Name("TillerAgentModelsDidChange")
}
