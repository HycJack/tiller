import Foundation

/// A saved agent chat. The CLI keeps the conversation itself under
/// `sessionID`; Tiller keeps what the panel showed, to show it again.
struct AgentConversation: Codable, Equatable {
    let id: String
    var kind: AgentKind
    /// The provider the chat runs on, if the user added one for its CLI.
    var provider: String? = nil
    /// The first message's first line until the agent names the chat.
    var title: String
    var sessionID: String?
    /// The folder the agent ran in. The CLIs keep sessions by folder, so
    /// resuming runs there again.
    var directory: String?
    /// The built-in tools this chat allows. Nil for chats saved before chats
    /// had their own, which use Settings'.
    var tools: [AgentTool]?
    /// The model, effort, context and fast mode this chat runs with. Nil for
    /// chats saved before chats had them, which use Settings'.
    var modelOptions: AgentModelOptions?
    /// The scheduled prompt that started the chat, if one did.
    var scheduleID: String?
    var created: Date
    var updated: Date

    var choice: AgentChoice { AgentChoice(kind, provider: provider) }

    /// The first line of the first message, shortened.
    static func title(from text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).first { !$0.allSatisfy(\.isWhitespace) } ?? ""
        let words = line.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        if words.isEmpty { return "Images" }
        return words.count > 60 ? String(words.prefix(60)) + "…" : words
    }
}

/// One row of a saved transcript.
enum AgentRecord: Codable, Equatable, Sendable {
    /// `images` are file names in the chat's folder.
    case user(text: String, images: [String])
    /// `date` is when the text came, nil in transcripts saved before texts had one.
    case text(String, date: Date? = nil)
    /// `isError` is nil for a call that never finished. `full` is the
    /// call's input past what `detail` keeps, nil when there is no more or
    /// in transcripts saved before calls kept it.
    case tool(name: String, detail: String, isError: Bool?, summary: String, full: String? = nil)
    case note(String)
    case error(String)
}

/// A profile's agent chats, kept in `agent-chats` in its folder: `index.json` lists
/// them and the panel's open tabs, and each chat has a folder with its
/// transcript and attached images.
@MainActor
final class AgentHistoryStore {
    private struct Index: Codable {
        var conversations: [AgentConversation] = []
        /// A conversation id per open tab, or "" for a new, empty chat.
        var tabs: [String] = []
        var selectedTab = 0
    }

    private let profileFolder: String
    private let directory: URL
    private var indexURL: URL { directory.appendingPathComponent("index.json") }
    private var index: Index
    private var indexChanged = false
    /// Transcripts waiting to be written, by conversation id.
    private var pendingRecords: [String: [AgentRecord]] = [:]
    /// The transcripts set this run whose write hasn't reached disk, by
    /// conversation id, so a read never gets the file from before it. Each
    /// is numbered, so a write finishing drops only what it wrote.
    private var knownRecords: [String: (records: [AgentRecord], version: Int)] = [:]
    private var recordsVersion = 0
    private var writeScheduled = false

    init(folder: String) {
        profileFolder = folder
        directory = URL(fileURLWithPath: folder + "/agent-chats")
        let data = try? Data(contentsOf: directory.appendingPathComponent("index.json"))
        index = data.flatMap { try? JSONDecoder().decode(Index.self, from: $0) } ?? Index()
        removeUnsavedFolders()
    }

    /// Newest first.
    var conversations: [AgentConversation] {
        index.conversations.sorted { $0.updated > $1.updated }
    }

    func conversation(_ id: String) -> AgentConversation? {
        index.conversations.first { $0.id == id }
    }

    /// Adds or replaces `conversation`.
    func save(_ conversation: AgentConversation) {
        if let i = index.conversations.firstIndex(where: { $0.id == conversation.id }) {
            guard index.conversations[i] != conversation else { return }
            index.conversations[i] = conversation
        } else {
            index.conversations.append(conversation)
        }
        indexChanged = true
        scheduleWrite()
    }

    func delete(_ id: String) {
        index.conversations.removeAll { $0.id == id }
        pendingRecords[id] = nil
        knownRecords[id] = nil
        indexChanged = true
        scheduleWrite()
        // After any write of its transcript still on its way.
        let folder = folder(for: id)
        Self.writer.async { try? FileManager.default.removeItem(at: folder) }
    }

    /// Where a chat keeps its transcript and images. Created when first written.
    func folder(for id: String) -> URL {
        directory.appendingPathComponent(id, isDirectory: true)
    }

    func records(for id: String) -> [AgentRecord] {
        unwrittenRecords(for: id) ?? Self.readRecords(in: folder(for: id))
    }

    /// The transcript set this run whose write hasn't reached disk, if any.
    /// A chat reads this first, then the file off the main thread.
    func unwrittenRecords(for id: String) -> [AgentRecord]? {
        knownRecords[id]?.records
    }

    /// The transcript in a chat's folder. Safe off the main thread.
    nonisolated static func readRecords(in folder: URL) -> [AgentRecord] {
        let data = try? Data(contentsOf: folder.appendingPathComponent("transcript.json"))
        return data.flatMap { try? JSONDecoder().decode([AgentRecord].self, from: $0) } ?? []
    }

    func setRecords(_ records: [AgentRecord], for id: String) {
        pendingRecords[id] = records
        recordsVersion += 1
        knownRecords[id] = (records, recordsVersion)
        scheduleWrite()
    }

    /// Deletes the folder of a chat that was never saved, such as one that
    /// only has images attached.
    func discardUnsaved(_ id: String) {
        guard conversation(id) == nil else { return }
        try? FileManager.default.removeItem(at: folder(for: id))
    }

    // MARK: Open tabs

    var openTabs: [String] { index.tabs }
    var selectedTab: Int { index.selectedTab }

    func setOpenTabs(_ tabs: [String], selected: Int) {
        guard tabs != index.tabs || selected != index.selectedTab else { return }
        index.tabs = tabs
        index.selectedTab = selected
        indexChanged = true
        scheduleWrite()
    }

    // MARK: Writing

    /// Writes pending changes now rather than after the short delay. The
    /// encoding and writing happen on a background queue, in order, from a
    /// copy of what is pending: a long agent run saves its transcript twice
    /// a second, and the whole of it each time.
    func flush() {
        writeScheduled = false
        let transcripts = pendingRecords.filter { conversation($0.key) != nil }
        let versions = transcripts.keys.compactMap { id in knownRecords[id].map { (id, $0.version) } }
        pendingRecords.removeAll()
        let index = indexChanged ? self.index : nil
        indexChanged = false
        guard !transcripts.isEmpty || index != nil else { return }
        let directory = directory, indexURL = indexURL
        Self.writer.async {
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                for (id, records) in transcripts {
                    let folder = directory.appendingPathComponent(id, isDirectory: true)
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    try Self.write(JSONEncoder().encode(records), to: folder.appendingPathComponent("transcript.json"))
                }
                if let index {
                    try Self.write(JSONEncoder().encode(index), to: indexURL)
                }
            } catch {
                NSLog("Tiller: could not save agent chats: %@", error.localizedDescription)
            }
            // On disk now: the copies in memory can go, unless set again since.
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let store = self else { return }
                    for (id, version) in versions where store.knownRecords[id]?.version == version {
                        store.knownRecords[id] = nil
                    }
                }
            }
        }
    }

    /// Blocks until every write so far is on disk. For quitting.
    func waitForWrites() {
        Self.writer.sync {}
    }

    /// One queue, so writes land in the order they were made.
    private static let writer = DispatchQueue(label: "dev.sorrycc.tiller.agent-chats", qos: .utility)

    nonisolated private static func write(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// Streaming adds rows quickly, so writes wait a moment.
    private func scheduleWrite() {
        guard !writeScheduled else { return }
        writeScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.writeScheduled else { return }
                self.flush()
            }
        }
    }

    /// Folders of chats that were never saved, left by the last run, and the
    /// images folder older versions of Tiller used.
    private func removeUnsavedFolders() {
        // Deleting runs on the writer queue, after any write already on it
        // and off the main thread, which is building the window meanwhile.
        let directory = directory, saved = Set(index.conversations.map(\.id)), profileFolder = profileFolder
        Self.writer.async {
            let manager = FileManager.default
            try? manager.removeItem(atPath: profileFolder + "/agent-attachments")
            for name in (try? manager.contentsOfDirectory(atPath: directory.path)) ?? [] where name != "index.json" && !saved.contains(name) {
                try? manager.removeItem(at: directory.appendingPathComponent(name))
            }
        }
    }
}

/// The title Claude Code, Qoder CLI or Grok Build gave a session, from the
/// session file it writes under its projects folder. Nil if there is none yet.
enum AgentSessionTitle {
    nonisolated static func read(kind: AgentKind, sessionID: String, directory: String) -> String? {
        let home: String
        switch kind {
        case .grok:
            return grokTitle(sessionID: sessionID, directory: directory)
        case .claude:
            home = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"] ?? NSHomeDirectory() + "/.claude"
        case .qodercli:
            home = NSHomeDirectory() + "/.qoder"
        case .codex, .agy:
            return nil
        }
        // Both name a project's folder after its path, with every character
        // other than a letter or digit made a dash.
        let resolved = URL(fileURLWithPath: directory).resolvingSymlinksInPath().path
        let project = String(resolved.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" })
        let path = "\(home)/projects/\(project)/\(sessionID).jsonl"
        guard let file = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? file.close() }
        // Titles are appended as they change, so the end has the latest.
        let size = (try? file.seekToEnd()) ?? 0
        try? file.seek(toOffset: size > 262_144 ? size - 262_144 : 0)
        guard let data = try? file.readToEnd() else { return nil }
        for line in data.split(separator: 0x0A).reversed() {
            guard line.count < 4096,
                let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any]
            else { continue }
            let title: String? = switch object["type"] as? String {
            case "custom-title": object["customTitle"] as? String
            case "ai-title": object["aiTitle"] as? String
            default: nil
            }
            if let title, !title.isEmpty { return title }
        }
        return nil
    }

    /// grok keeps a session in a folder named after its folder's path,
    /// percent-encoded, with the title in `summary.json`.
    nonisolated private static func grokTitle(sessionID: String, directory: String) -> String? {
        let home = ProcessInfo.processInfo.environment["GROK_HOME"] ?? NSHomeDirectory() + "/.grok"
        let resolved = URL(fileURLWithPath: directory).resolvingSymlinksInPath().path
        guard let project = resolved.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")),
            let data = FileManager.default.contents(atPath: "\(home)/sessions/\(project)/\(sessionID)/summary.json"),
            let summary = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let title = summary["generated_title"] as? String, !title.isEmpty
        else { return nil }
        return title
    }
}
