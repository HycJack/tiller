import AppKit
import os

/// A profile has its own cookies and site data, history, open tabs, saved
/// passwords, settings and agent chats, in `Profiles/<id>` under the root
/// folder, and Chromium's data in `Chromium/<id>`. One Tiller process runs
/// every open profile, each in a window of its own (see `ProfileContext`).
struct Profile: Codable, Equatable, Sendable {
    let id: String
    var name: String
    var created: Date
    /// The `ProfileColor` its square and avatar show in, when one was
    /// picked; else one from its place among the profiles.
    var color: String? = nil
    /// Up to two characters of its own, an emoji too, its square and avatar
    /// show in place of its initials.
    var label: String? = nil
}

enum ProfileError: LocalizedError {
    case emptyName
    case duplicateName(String)
    case open(String)
    case running(String)
    case longLabel

    var errorDescription: String? {
        switch self {
        case .emptyName: "A profile needs a name."
        case .duplicateName(let name): "There is already a profile called \(name)."
        case .open(let name): "\(name) is open. Close its window first, then delete it."
        case .running(let name): "\(name) is open in another copy of Tiller. Quit it first."
        case .longLabel: "A label is one or two characters."
        }
    }
}

/// Every profile, listed in `profiles.json` in the root folder with the one
/// used last, which a plain launch, links from other apps and the `tiller` CLI
/// pick, and the ones open when Tiller last quit, which the next launch
/// opens again. Each change re-reads the file under `profiles.lock`.
enum Profiles {
    /// The profile that data from before profiles existed moved into.
    static let defaultID = "default"

    /// `~/Library/Application Support/Tiller`, or the folder in `TILLER_DATA_DIR`.
    /// tiller_mcp reads the same variable to find `profiles.json`.
    static let root: String = {
        var path = NSHomeDirectory() + "/Library/Application Support/Tiller"
        if let dir = ProcessInfo.processInfo.environment["TILLER_DATA_DIR"], !dir.isEmpty {
            path = URL(fileURLWithPath: dir).path
        }
        // Absolute, with no symlinks and the disk's own capitalization, since
        // Chromium resolves its folders once they exist and won't take a
        // profile folder whose path then doesn't start with the root's.
        // Foundation's own resolving drops `/private`, so it can't be used.
        // The folder may not exist yet, so the part that does is resolved.
        var existing = path, rest = ""
        while existing != "/" {
            if let resolved = realpath(existing, nil) {
                defer { free(resolved) }
                return String(cString: resolved) + rest
            }
            let url = URL(fileURLWithPath: existing)
            rest = "/" + url.lastPathComponent + rest
            existing = url.deletingLastPathComponent().path
        }
        return path
    }()

    /// Chromium's own folder: `Local State`, `chrome_debug.log` and the
    /// like, with every profile's Chromium data in a folder inside it, since
    /// Chromium makes a profile only of a folder right inside its own.
    static var chromiumRoot: String { root + "/Chromium" }

    static func folder(for id: String) -> String {
        root + "/Profiles/" + id
    }

    /// Where Chromium keeps the profile's cookies, cache and site data.
    static func cachePath(for id: String) -> String {
        chromiumRoot + "/" + id
    }

    /// The profile's settings, in a user defaults suite of its own. Launch
    /// arguments (`-homepage https://…`) still override them.
    static func defaults(for id: String) -> UserDefaults {
        UserDefaults(suiteName: suiteName(for: id)) ?? .standard
    }

    static func suiteName(for id: String) -> String {
        (Bundle.main.bundleIdentifier ?? "dev.sorrycc.tiller") + ".profile." + id
    }

    /// In the order they were created. The first access creates the default
    /// profile when there is none.
    static var all: [Profile] {
        let list = read()
        return list.profiles.isEmpty ? ensureOne().profiles : list.profiles
    }

    static func profile(_ id: String) -> Profile? {
        all.first { $0.id == id }
    }

    /// The profile's name, which may have changed since it opened.
    static func name(of id: String) -> String {
        profile(id)?.name ?? id
    }

    static func find(_ idOrName: String, in profiles: [Profile]? = nil) -> Profile? {
        let profiles = profiles ?? all
        return profiles.first { $0.id == idOrName }
            ?? profiles.first { $0.name.localizedCaseInsensitiveCompare(idOrName) == .orderedSame }
    }

    /// The profile a plain launch, links from other apps and the CLI pick.
    static var lastUsed: Profile {
        let list = read()
        let profiles = list.profiles.isEmpty ? ensureOne().profiles : list.profiles
        return list.lastUsed.flatMap { id in profiles.first { $0.id == id } } ?? profiles[0]
    }

    /// Makes `id` the profile a plain launch and the CLI pick. Called each
    /// time a profile's window comes to the front, so the lock is only taken
    /// when the list says another profile.
    static func markUsed(_ id: String) {
        guard read().lastUsed != id else { return }
        update { $0.lastUsed = id }
    }

    /// The profiles open when Tiller last quit, which still exist.
    static var lastOpen: [Profile] {
        let list = read()
        return (list.open ?? []).compactMap { id in list.profiles.first { $0.id == id } }
    }

    /// Remembers which profiles are open, for the next launch.
    static func setOpen(_ ids: [String]) {
        update { $0.open = ids }
    }

    private static func ensureOne() -> List {
        update { list in
            if list.profiles.isEmpty {
                list.profiles = [Profile(id: defaultID, name: "Default", created: Date())]
            }
        }
    }

    static func create(named name: String) throws -> Profile {
        var profile: Profile?
        try update { list in
            let name = try validName(name, for: nil, in: list)
            var id: String
            repeat {
                id = String(UUID().uuidString.lowercased().prefix(8))
            } while list.profiles.contains { $0.id == id }
            profile = Profile(id: id, name: name, created: Date())
            list.profiles.append(profile!)
        }
        NotificationCenter.default.post(name: .profilesDidChange, object: nil)
        return profile!
    }

    static func rename(_ id: String, to name: String) throws {
        try update { list in
            let name = try validName(name, for: id, in: list)
            guard let index = list.profiles.firstIndex(where: { $0.id == id }) else { return }
            list.profiles[index].name = name
        }
        NotificationCenter.default.post(name: .profilesDidChange, object: nil)
    }

    /// Gives the profile's square and avatar `color`, or back the one from
    /// its place among the profiles for nil.
    static func setColor(_ id: String, to color: ProfileColor?) {
        update { list in
            guard let index = list.profiles.firstIndex(where: { $0.id == id }) else { return }
            list.profiles[index].color = color?.rawValue
        }
        NotificationCenter.default.post(name: .profilesDidChange, object: nil)
    }

    /// Gives the profile's square and avatar up to two characters of its own
    /// in place of its initials, or back its initials for an empty label.
    static func setLabel(_ id: String, to label: String) throws {
        let label = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard label.count <= 2 else { throw ProfileError.longLabel }
        update { list in
            guard let index = list.profiles.firstIndex(where: { $0.id == id }) else { return }
            list.profiles[index].label = label.isEmpty ? nil : label
        }
        NotificationCenter.default.post(name: .profilesDidChange, object: nil)
    }

    /// Moves the profile's folders to the Trash and forgets its settings and
    /// password key. An open profile can't be deleted.
    @MainActor
    static func delete(_ id: String) throws {
        if ProfileContext.opened(id) != nil { throw ProfileError.open(name(of: id)) }
        if runningProcess(id) != nil { throw ProfileError.running(name(of: id)) }
        update { list in
            list.profiles.removeAll { $0.id == id }
            if list.lastUsed == id { list.lastUsed = nil }
            list.open?.removeAll { $0 == id }
        }
        for path in [folder(for: id), cachePath(for: id)] where FileManager.default.fileExists(atPath: path) {
            try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)
        }
        UserDefaults.standard.removePersistentDomain(forName: suiteName(for: id))
        PasswordKey.delete(profileID: id)
        NotificationCenter.default.post(name: .profilesDidChange, object: nil)
    }

    private static func validName(_ name: String, for id: String?, in list: List) throws -> String {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw ProfileError.emptyName }
        // Names must differ, since `tiller --profile` picks one by name.
        if let other = find(name, in: list.profiles), other.id != id {
            throw ProfileError.duplicateName(other.name)
        }
        return name
    }

    // MARK: Control sockets

    /// The control socket an open profile listens on. TILLER_SOCKET, when
    /// set, stands in for the socket of the profile that opens first.
    static func socketPath(for id: String) -> String {
        folder(for: id) + "/control.sock"
    }

    // MARK: Locks

    /// Locks `instance.lock` in the root folder for the life of the process,
    /// so only one Tiller runs. Returns the process that holds it already, or
    /// nil once this one does.
    static func claimApp() -> pid_t? {
        try? FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        switch lock(root + "/instance.lock") {
        case .held: return nil
        case .busy(let pid): return pid
        case .failed: return nil
        }
    }

    /// Locks the profile's `instance.lock` while it is open, so a Tiller from
    /// before profiles shared one process can't open it too, and this one
    /// can't open a profile such a Tiller has. Returns the descriptor to
    /// close when the profile closes, or the process holding the lock.
    static func claim(_ id: String) -> Result<Int32, ProfileError> {
        try? FileManager.default.createDirectory(atPath: folder(for: id), withIntermediateDirectories: true)
        switch lock(lockPath(for: id)) {
        case .held(let fd): return .success(fd)
        case .busy: return .failure(.running(name(of: id)))
        case .failed: return .success(-1)
        }
    }

    /// Unlocks a profile that closed.
    static func release(_ fd: Int32) {
        guard fd >= 0 else { return }
        flock(fd, LOCK_UN)
        close(fd)
    }

    private enum Lock {
        case held(Int32)
        case busy(pid_t)
        case failed
    }

    /// Locks the file at `path` and writes this process's id in it.
    private static func lock(_ path: String) -> Lock {
        let fd = Darwin.open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return .failed }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let pid = processID(in: fd)
            close(fd)
            return .busy(pid)
        }
        ftruncate(fd, 0)
        let text = "\(getpid())"
        _ = text.withCString { pwrite(fd, $0, strlen($0), 0) }
        return .held(fd)
    }

    private static func lockPath(for id: String) -> String {
        folder(for: id) + "/instance.lock"
    }

    /// Another process running profile `id`, or nil when none is.
    static func runningProcess(_ id: String) -> pid_t? {
        let fd = Darwin.open(lockPath(for: id), O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        if flock(fd, LOCK_SH | LOCK_NB) == 0 {
            flock(fd, LOCK_UN)
            return nil
        }
        let pid = processID(in: fd)
        return pid == getpid() ? nil : pid
    }

    /// The pid written in a lock file. 0 when unreadable, which activates nothing.
    private static func processID(in fd: Int32) -> pid_t {
        var buffer = [UInt8](repeating: 0, count: 32)
        let count = pread(fd, &buffer, buffer.count, 0)
        guard count > 0 else { return 0 }
        return pid_t(String(decoding: buffer.prefix(count), as: UTF8.self)) ?? 0
    }

    // MARK: File

    private struct List: Codable, Equatable, Sendable {
        var profiles: [Profile] = []
        /// The id of the profile whose window was in front last.
        var lastUsed: String?
        /// The ids of the profiles open when Tiller last quit, in the order
        /// they opened.
        var open: [String]?
    }

    private static var listURL: URL { URL(fileURLWithPath: root + "/profiles.json") }

    /// The list as last decoded, with the file's modification date then.
    /// Menus and window titles read the list often, so the file is only
    /// decoded again once it has been written.
    private static let lastRead = OSAllocatedUnfairLock<(modified: Date?, list: List)?>(initialState: nil)

    private static func read() -> List {
        let modified = (try? listURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        if let cached = lastRead.withLock({ $0 }), cached.modified == modified { return cached.list }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let list = (try? Data(contentsOf: listURL)).flatMap { try? decoder.decode(List.self, from: $0) } ?? List()
        lastRead.withLock { $0 = (modified, list) }
        return list
    }

    /// Re-reads the list, applies `change` and writes it back if it changed,
    /// all while holding `profiles.lock`.
    @discardableResult
    private static func update(_ change: (inout List) throws -> Void) rethrows -> List {
        try? FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        let fd = Darwin.open(root + "/profiles.lock", O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        if fd >= 0 { flock(fd, LOCK_EX) }
        defer {
            if fd >= 0 {
                flock(fd, LOCK_UN)
                close(fd)
            }
        }
        var list = read()
        let before = list
        try change(&list)
        guard list != before else { return list }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        do {
            try encoder.encode(list).write(to: listURL, options: .atomic)
        } catch {
            NSLog("Tiller: could not save profiles: %@", error.localizedDescription)
        }
        lastRead.withLock { $0 = nil }
        return list
    }
}

/// Asks for a profile's name, as a sheet on `window` or, without one, as a
/// modal alert. `apply` gets the name; an error it throws is shown.
@MainActor
enum ProfileNamePrompt {
    static func run(
        _ message: String, button: String, initial: String = "", placeholder: String = "Name", note: String? = nil,
        on window: NSWindow?, apply: @escaping @MainActor (String) throws -> Void
    ) {
        let alert = NSAlert()
        alert.messageText = message
        if let note { alert.informativeText = note }
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = initial
        field.placeholderString = placeholder
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        let finish = { (response: NSApplication.ModalResponse) in
            guard response == .alertFirstButtonReturn else { return }
            do {
                try apply(field.stringValue)
            } catch {
                let failure = NSAlert()
                failure.alertStyle = .warning
                failure.messageText = error.localizedDescription
                if let window { failure.beginSheetModal(for: window) } else { failure.runModal() }
            }
        }
        if let window {
            alert.beginSheetModal(for: window) { response in
                MainActor.assumeIsolated { finish(response) }
            }
        } else {
            finish(alert.runModal())
        }
    }
}

extension Notification.Name {
    /// Posted when the profiles are added, renamed or removed, and when one
    /// opens or closes.
    static let profilesDidChange = Notification.Name("TillerProfilesDidChange")
}
