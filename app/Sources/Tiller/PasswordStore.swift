import CryptoKit
import Foundation
import Security

/// A login in plaintext, only held while importing or filling.
struct SavedLogin: Sendable {
    /// scheme://host, plus :port when it isn't the default.
    let origin: String
    let username: String
    let password: String
    let created: Date

    var id: String { origin + "\n" + username }

    /// The origin of an http(s) URL, or nil for anything else.
    static func origin(of url: String) -> String? {
        guard let components = URLComponents(string: url),
            let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
            let host = components.host?.lowercased(), !host.isEmpty
        else { return nil }
        let isDefaultPort = components.port == (scheme == "https" ? 443 : 80)
        let port = components.port.flatMap { isDefaultPort ? nil : ":\($0)" } ?? ""
        return "\(scheme)://\(host)\(port)"
    }
}

enum PasswordStoreError: LocalizedError {
    case keyMissing
    case keychain(OSStatus)
    case keychainDenied
    case unreadable

    var errorDescription: String? {
        switch self {
        case .keyMissing: "Tiller's password key is missing from the keychain, so its saved passwords can't be read. Remove them in Settings > Passwords, then import again."
        case .keychain(let status): "Keychain error \(status)."
        case .keychainDenied: "Access to Tiller's password key in the keychain was denied."
        case .unreadable: "This password couldn't be decrypted."
        }
    }
}

/// A profile's saved passwords, in `passwords.json` in its folder. Sites and
/// usernames are stored in the clear, as Chrome stores them, so Tiller can tell
/// which pages have a login without asking for the keychain. Each password is
/// sealed with AES-GCM under a key kept in the login keychain.
@MainActor
final class PasswordStore {
    let profileID: String

    struct Entry: Codable, Sendable {
        let origin: String
        let username: String
        /// AES-GCM nonce, ciphertext and tag.
        let sealed: Data
        let created: Date

        var id: String { origin + "\n" + username }
    }

    /// Sorted by site, then username.
    private(set) var entries: [Entry] = [] {
        didSet { byOrigin = Dictionary(grouping: entries, by: \.origin) }
    }
    /// `entries` by origin. The address bar asks on every page change.
    private var byOrigin: [String: [Entry]] = [:]
    private let path: String
    /// Whether `entries` holds the file yet. It is read off the main thread
    /// as a profile opens, and announced with `passwordsDidChange`.
    private var loaded = false

    init(profileID: String, folder: String) {
        self.profileID = profileID
        path = folder + "/passwords.json"
        let path = path
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let entries = Self.read(path)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.didRead(entries) }
            }
        }
    }

    nonisolated private static func read(_ path: String) -> [Entry] {
        guard let data = FileManager.default.contents(atPath: path) else { return [] }
        return (try? JSONDecoder().decode([Entry].self, from: data)) ?? []
    }

    private func didRead(_ entries: [Entry]) {
        guard !loaded else { return }
        loaded = true
        guard !entries.isEmpty else { return }
        self.entries = entries
        NotificationCenter.default.post(name: .passwordsDidChange, object: self)
    }

    /// Reads the file now if the read in the background hasn't landed, so
    /// a change starts from what is saved rather than from nothing.
    private func loadNow() {
        guard !loaded else { return }
        loaded = true
        entries = Self.read(path)
    }

    func logins(for origin: String) -> [Entry] {
        byOrigin[origin] ?? []
    }

    /// The password of `entry`. macOS may ask before handing Tiller its key.
    func password(for entry: Entry) async throws -> String {
        let profileID = profileID
        let key = try await Task.detached { try PasswordKey.load(profileID: profileID, create: false) }.value
        guard let box = try? AES.GCM.SealedBox(combined: entry.sealed),
            let plain = try? AES.GCM.open(box, using: key),
            let password = String(data: plain, encoding: .utf8)
        else { throw PasswordStoreError.unreadable }
        return password
    }

    /// Adds `logins`, replacing saved ones with the same site and username.
    /// Returns how many were saved.
    func merge(_ logins: [SavedLogin]) async throws -> Int {
        guard !logins.isEmpty else { return 0 }
        loadNow()
        let hasEntries = !entries.isEmpty
        let profileID = profileID
        let key = try await Task.detached { try PasswordKey.load(profileID: profileID, create: !hasEntries) }.value
        var byID = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
        for login in logins {
            guard let sealed = try AES.GCM.seal(Data(login.password.utf8), using: key).combined else { continue }
            byID[login.id] = Entry(origin: login.origin, username: login.username, sealed: sealed, created: login.created)
        }
        try save(Array(byID.values))
        return logins.count
    }

    func remove(_ ids: Set<String>) throws {
        loadNow()
        try save(entries.filter { !ids.contains($0.id) })
    }

    /// Also deletes the key, so the next import starts fresh.
    func removeAll() throws {
        try save([])
        PasswordKey.delete(profileID: profileID)
    }

    private func save(_ entries: [Entry]) throws {
        let sorted = entries.sorted { ($0.origin, $0.username) < ($1.origin, $1.username) }
        let data = try JSONEncoder().encode(sorted)
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        // What was saved replaces the file's contents, should the read still be on its way.
        loaded = true
        self.entries = sorted
        NotificationCenter.default.post(name: .passwordsDidChange, object: self)
    }
}

/// The 256-bit key sealing a profile's passwords, as a generic password item
/// in the login keychain. Tiller is ad-hoc signed, so after each rebuild macOS
/// asks before letting the new binary read it.
enum PasswordKey {
    private static let service = "Tiller Saved Passwords"
    /// Where the key was kept while the app was called Mini.
    private static let oldService = "Mini Saved Passwords"

    /// The default profile keeps the key from before profiles existed.
    private static func account(for profileID: String) -> String {
        profileID == Profiles.defaultID ? "key" : "key." + profileID
    }

    private static func baseQuery(service: String = service, profileID: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(for: profileID),
        ]
    }

    /// Reads the profile's key, creating it if missing and `create` is set.
    /// For the default profile, a key saved by Mini is copied under the new
    /// name, and the old item is left as is.
    static func load(profileID: String, create: Bool) throws -> SymmetricKey {
        if let key = try read(service: service, profileID: profileID) { return key }
        if profileID == Profiles.defaultID, let key = try read(service: oldService, profileID: profileID) {
            try add(key, profileID: profileID)
            return key
        }
        guard create else { throw PasswordStoreError.keyMissing }
        let key = SymmetricKey(size: .bits256)
        try add(key, profileID: profileID)
        return key
    }

    /// Nil if there is no item for `service`.
    private static func read(service: String, profileID: String) throws -> SymmetricKey? {
        var query = baseQuery(service: service, profileID: profileID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data, data.count == 32 else { throw PasswordStoreError.keyMissing }
            return SymmetricKey(data: data)
        case errSecItemNotFound:
            return nil
        case errSecUserCanceled, errSecAuthFailed, errSecInteractionNotAllowed:
            throw PasswordStoreError.keychainDenied
        default:
            throw PasswordStoreError.keychain(status)
        }
    }

    private static func add(_ key: SymmetricKey, profileID: String) throws {
        var add = baseQuery(profileID: profileID)
        add[kSecValueData as String] = key.withUnsafeBytes { Data($0) }
        add[kSecAttrLabel as String] = service
        let added = SecItemAdd(add as CFDictionary, nil)
        guard added == errSecSuccess else { throw PasswordStoreError.keychain(added) }
    }

    static func delete(profileID: String) {
        SecItemDelete(baseQuery(profileID: profileID) as CFDictionary)
    }
}

/// JavaScript that fills a login into the page. It checks the page's origin
/// first, in case the tab navigated since the user asked. The password field
/// is the first visible one; the username field is the nearest text field
/// before it. A page with only a username field (the first step of a two-step
/// sign-in) gets the username.
enum LoginFill {
    static func script(origin: String, username: String, password: String) -> String {
        let arguments = (try? JSONSerialization.data(withJSONObject: [origin, username, password]))
            .map { String(decoding: $0, as: UTF8.self) } ?? "[]"
        return """
            (([origin, username, password]) => {
              if (location.origin !== origin) return;
              const visible = (el) => !el.disabled && !el.readOnly && el.getClientRects().length > 0;
              const inputs = [...document.querySelectorAll('input')].filter(visible);
              const isText = (el) => ['text', 'email', 'tel', ''].includes(el.getAttribute('type') ?? '')
                || /username|email/.test(el.autocomplete);
              const set = (el, value) => {
                el.focus();
                Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set.call(el, value);
                el.dispatchEvent(new Event('input', { bubbles: true }));
                el.dispatchEvent(new Event('change', { bubbles: true }));
              };
              const pw = inputs.find((el) => el.type === 'password');
              const user = pw
                ? inputs.slice(0, inputs.indexOf(pw)).reverse().find(isText)
                : inputs.find((el) => isText(el) && /user|mail|login|account/i.test(el.name + el.id + el.autocomplete));
              if (user && username) set(user, username);
              if (pw) set(pw, password);
            })(\(arguments));
            """
    }
}

extension Notification.Name {
    static let passwordsDidChange = Notification.Name("TillerPasswordsDidChange")
}
