import CommonCrypto
import Foundation
import Security

enum ChromeImportError: LocalizedError {
    case notInstalled
    /// The OS or security software kept Tiller out of Chrome's folder. Usually
    /// Full Disk Access, but endpoint/EDR software can block it even with FDA on.
    case noAccess
    case keychainDenied
    case keyNotFound
    case keychain(OSStatus)
    case unreadable(String)

    var errorDescription: String? {
        switch self {
        case .notInstalled: "Google Chrome's data wasn't found on this Mac."
        case .noAccess: "Tiller couldn't read Chrome's data. This is usually Full Disk Access — grant it to Tiller in System Settings and try again. If it's already on, security or endpoint (EDR) software may be blocking the read; check with your IT/security admin."
        case .keychainDenied: "Access to Chrome's key in the keychain was denied."
        case .keyNotFound: "Chrome's key isn't in the keychain."
        case .keychain(let status): "Keychain error \(status)."
        case .unreadable(let message): message
        }
    }

    /// System Settings > Privacy & Security > Full Disk Access.
    static let privacySettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
}

struct ChromeProfile: Sendable {
    /// Folder name inside Chrome's data folder, like "Default" or "Profile 1".
    let directory: String
    let name: String
}

/// Times in Chrome's databases are microseconds since 1601-01-01 UTC, the same
/// clock CEF's cookie times use.
enum ChromeTime {
    static let unixOffset: Double = 11_644_473_600

    static func date(_ micro: Int64) -> Date {
        Date(timeIntervalSince1970: Double(micro) / 1_000_000 - unixOffset)
    }

    static var now: Int64 { Int64((Date().timeIntervalSince1970 + unixOffset) * 1_000_000) }
}

/// One cookie in the shape `tiller_cookies_import` takes. See tiller_core.h.
struct ImportedCookie: Encodable, Sendable {
    let url: String
    let name: String
    let value: String
    let domain: String
    let path: String
    let secure: Bool
    let httpOnly: Bool
    let hasExpires: Bool
    let creation: Int64
    let lastAccess: Int64
    let expires: Int64
    let sameSite: String
    let priority: String

    enum CodingKeys: String, CodingKey {
        case url, name, value, domain, path, secure, creation, expires, priority
        case httpOnly = "httponly"
        case hasExpires = "has_expires"
        case lastAccess = "last_access"
        case sameSite = "same_site"
    }
}

/// The search engine and homepage from Chrome's Preferences. Nil means Chrome
/// uses its built-in default.
struct ChromePreferences: Sendable {
    var searchURL: String?
    var homepage: String?
}

/// An extension installed in a Chrome profile.
struct ChromeExtension: Sendable {
    let id: String
    /// The version's folder, with manifest.json in it.
    let folder: String
    let enabled: Bool
    /// Loaded unpacked from a folder of the user's rather than installed.
    let unpacked: Bool
}

/// Reads one Chrome profile. Runs off the main thread: the databases can be
/// large and the keychain prompt blocks.
struct ChromeReader: Sendable {
    let profileDirectory: String

    /// Where Chrome's top-level data lives. A Finder-made copy (see
    /// FinderChromeCopy) passes its own root here.
    init(profile: ChromeProfile, dataDirectory: String = ChromeReader.defaultDataDirectory) {
        profileDirectory = dataDirectory + "/" + profile.directory
    }

    static var defaultDataDirectory: String {
        #if DEBUG
        // For testing against a made-up profile: `-chromeDataDir /path`.
        if let dir = UserDefaults.standard.string(forKey: "chromeDataDir") { return dir }
        #endif
        return NSHomeDirectory() + "/Library/Application Support/Google/Chrome"
    }

    /// Profiles listed in Chrome's Local State, Default first. The second value
    /// is the profile Chrome used last.
    static func profiles(in dataDirectory: String = defaultDataDirectory) throws -> (profiles: [ChromeProfile], lastUsed: String?) {
        let data = try read(dataDirectory + "/Local State")
        guard let state = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let profile = state["profile"] as? [String: Any]
        else { throw ChromeImportError.unreadable("Chrome's Local State file isn't valid JSON.") }
        let cache = profile["info_cache"] as? [String: [String: Any]] ?? [:]
        var profiles = cache.map { ChromeProfile(directory: $0.key, name: $0.value["name"] as? String ?? $0.key) }
        if profiles.isEmpty { profiles = [ChromeProfile(directory: "Default", name: "Default")] }
        profiles.sort { ($0.directory == "Default" ? 0 : 1, $0.name) < ($1.directory == "Default" ? 0 : 1, $1.name) }
        return (profiles, profile["last_used"] as? String)
    }

    // MARK: Keychain

    /// Chrome's cookie and password key, from its "Chrome Safe Storage"
    /// keychain item. macOS asks the user before handing it over.
    static func safeStorageKey() throws -> ChromeKey {
        #if DEBUG
        if let password = UserDefaults.standard.string(forKey: "chromeSafeStoragePassword") {
            return ChromeKey(password: Data(password.utf8))
        }
        #endif
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Chrome Safe Storage",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let password = result as? Data else { throw ChromeImportError.keyNotFound }
            return ChromeKey(password: password)
        case errSecItemNotFound: throw ChromeImportError.keyNotFound
        case errSecUserCanceled, errSecAuthFailed, errSecInteractionNotAllowed: throw ChromeImportError.keychainDenied
        default: throw ChromeImportError.keychain(status)
        }
    }

    // MARK: Data

    /// Cookies Tiller can set, and how many were left out because they are
    /// partitioned (CEF can't set those), expired or couldn't be decrypted.
    func cookies(key: ChromeKey) throws -> (cookies: [ImportedCookie], skipped: Int) {
        try withDatabase("Cookies") { db in
            let version = try db.query("SELECT value FROM meta WHERE key = 'version'") { Int($0.string(0)) ?? 0 }.first ?? 0
            // From version 24, the plaintext starts with a SHA-256 of the host.
            let hashPrefix = version >= 24 ? 32 : 0
            let now = ChromeTime.now
            let rows = try db.query("""
                SELECT host_key, name, value, encrypted_value, path, creation_utc, expires_utc, last_access_utc,
                    is_secure, is_httponly, has_expires, samesite, priority, top_frame_site_key
                FROM cookies
                """) { row -> ImportedCookie? in
                let host = row.string(0)
                let hasExpires = row.int(10) != 0
                guard row.string(13).isEmpty, !(hasExpires && row.int(6) < now) else { return nil }
                var value = row.string(2)
                let encrypted = row.data(3)
                if !encrypted.isEmpty {
                    guard let plain = key.decrypt(encrypted), plain.count >= hashPrefix,
                        let text = String(data: plain.dropFirst(hashPrefix), encoding: .utf8)
                    else { return nil }
                    value = text
                }
                let secure = row.int(8) != 0
                let path = row.string(4).hasPrefix("/") ? row.string(4) : "/"
                let isDomain = host.hasPrefix(".")
                let sameSite = switch row.int(11) {
                case 0: "none"
                case 1: "lax"
                case 2: "strict"
                default: "unspecified"
                }
                let priority = switch row.int(12) {
                case 0: "low"
                case 2: "high"
                default: "medium"
                }
                return ImportedCookie(
                    url: "\(secure ? "https" : "http")://\(isDomain ? String(host.dropFirst()) : host)\(path)",
                    name: row.string(1), value: value, domain: isDomain ? host : "", path: path,
                    secure: secure, httpOnly: row.int(9) != 0, hasExpires: hasExpires,
                    creation: row.int(5), lastAccess: row.int(7), expires: row.int(6),
                    sameSite: sameSite, priority: priority
                )
            }
            let cookies = rows.compactMap { $0 }
            return (cookies, rows.count - cookies.count)
        } ?? ([], 0)
    }

    /// Saved logins for web pages, newest per site and username. Skips sites
    /// marked "never save", non-web logins and passwords that don't decrypt.
    func logins(key: ChromeKey) throws -> (logins: [SavedLogin], skipped: Int) {
        try withDatabase("Login Data") { db in
            let rows = try db.query(
                "SELECT origin_url, username_value, password_value, date_created FROM logins WHERE blacklisted_by_user = 0"
            ) { row -> SavedLogin? in
                guard let origin = SavedLogin.origin(of: row.string(0)),
                    let plain = key.decrypt(row.data(2)), !plain.isEmpty,
                    let password = String(data: plain, encoding: .utf8)
                else { return nil }
                return SavedLogin(
                    origin: origin, username: row.string(1), password: password,
                    created: ChromeTime.date(row.int(3))
                )
            }
            var newest: [String: SavedLogin] = [:]
            for login in rows.compactMap({ $0 }) {
                let id = login.id
                if newest[id].map({ $0.created < login.created }) ?? true { newest[id] = login }
            }
            return (Array(newest.values), rows.count - newest.count)
        } ?? ([], 0)
    }

    /// Every web page in Chrome's history that isn't hidden.
    func history() throws -> [HistoryPage] {
        try withDatabase("History") { db in
            try db.query("""
                SELECT url, title, visit_count, last_visit_time, typed_count FROM urls
                WHERE hidden = 0 AND (url LIKE 'http://%' OR url LIKE 'https://%')
                """) { row in
                HistoryPage(
                    url: row.string(0), title: row.string(1), visitCount: Int(row.int(2)),
                    lastVisit: ChromeTime.date(row.int(3)), typedCount: Int(row.int(4))
                )
            }
        } ?? []
    }

    func preferences() throws -> ChromePreferences {
        let data = try Self.read(profileDirectory + "/Preferences")
        guard let prefs = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ChromeImportError.unreadable("Chrome's Preferences file isn't valid JSON.")
        }
        var result = ChromePreferences()
        // Written when the user picks a default engine; missing means Chrome's own default.
        if let search = prefs["default_search_provider_data"] as? [String: Any],
            let template = search["template_url_data"] as? [String: Any],
            let url = template["url"] as? String, !url.isEmpty
        {
            result.searchURL = url
        }
        // Tiller's homepage opens at launch, which is what Chrome's startup pages
        // do. Chrome's own homepage only backs its Home button, so it comes second.
        let session = prefs["session"] as? [String: Any]
        let startup = (session?["restore_on_startup"] as? Int) == 4 ? session?["startup_urls"] as? [String] : nil
        let homepage = (prefs["homepage_is_newtabpage"] as? Bool) == true ? nil : prefs["homepage"] as? String
        result.homepage = [startup?.first, homepage].compactMap { $0 }.first { url in
            url.hasPrefix("http://") || url.hasPrefix("https://")
        }
        return result
    }

    /// Extensions from the Web Store and ones loaded unpacked, from the
    /// profile's `Secure Preferences`, with how many were left out: Chrome's
    /// own, ones installed by policy and ones whose files are missing.
    func extensions() throws -> (extensions: [ChromeExtension], skipped: Int) {
        var settings: [String: [String: Any]] = [:]
        for name in ["Preferences", "Secure Preferences"] {
            guard let data = try? Self.read(profileDirectory + "/" + name),
                let prefs = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let found = (prefs["extensions"] as? [String: Any])?["settings"] as? [String: [String: Any]]
            else { continue }
            settings.merge(found) { $1 }
        }
        // Without its settings, list what's installed, as if all were on.
        if settings.isEmpty {
            let folder = profileDirectory + "/Extensions"
            let ids: [String]
            do {
                ids = try FileManager.default.contentsOfDirectory(atPath: folder)
            } catch {
                if case CocoaError.fileReadNoSuchFile = Self.mapped(error) { return ([], 0) }
                throw Self.mapped(error)
            }
            for id in ids where id.count == 32 {
                let versions = (try? FileManager.default.contentsOfDirectory(atPath: folder + "/" + id)) ?? []
                if let version = versions.max(by: { $0.compare($1, options: .numeric) == .orderedAscending }) {
                    settings[id] = ["path": id + "/" + version, "location": 1]
                }
            }
        }
        var found: [ChromeExtension] = []
        var skipped = 0
        for (id, setting) in settings.sorted(by: { $0.key < $1.key }) {
            guard let path = setting["path"] as? String else { continue }
            // 5 and 10 are Chrome's own, 7 and 9 installed by an admin's policy.
            let location = setting["location"] as? Int ?? 1
            let unpacked = location == 4
            let folder = path.hasPrefix("/") ? path : profileDirectory + "/Extensions/" + path
            guard ![5, 7, 9, 10].contains(location),
                FileManager.default.fileExists(atPath: folder + "/manifest.json")
            else {
                skipped += 1
                continue
            }
            let reasons = setting["disable_reasons"]
            let disabled = (reasons as? [Any]).map { !$0.isEmpty } ?? ((reasons as? Int ?? 0) != 0)
                || (setting["state"] as? Int) == 0
            found.append(ChromeExtension(id: id, folder: folder, enabled: !disabled, unpacked: unpacked))
        }
        return (found, skipped)
    }

    // MARK: Files

    /// Opens a copy of one of the profile's databases, since Chrome keeps the
    /// live file locked. Returns nil if the profile has no such database.
    private func withDatabase<T>(_ name: String, _ body: (SQLiteDatabase) throws -> T) throws -> T? {
        let source = profileDirectory + "/" + name
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("tiller-chrome-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let copy = temp.appendingPathComponent(name).path
        do {
            try Self.copy(source, to: copy)
        } catch CocoaError.fileReadNoSuchFile {
            return nil
        }
        // A journal copied along lets SQLite finish or undo a write Chrome was in the middle of.
        for suffix in ["-journal", "-wal"] {
            try? Self.copy(source + suffix, to: copy + suffix)
        }
        do {
            return try body(try SQLiteDatabase(path: copy))
        } catch let error as SQLiteError {
            throw ChromeImportError.unreadable("Couldn't read Chrome's \(name) database: \(error)")
        }
    }

    private static func copy(_ source: String, to destination: String) throws {
        do {
            try FileManager.default.copyItem(atPath: source, toPath: destination)
        } catch {
            throw mapped(error)
        }
    }

    private static func read(_ path: String) throws -> Data {
        do {
            return try Data(contentsOf: URL(fileURLWithPath: path))
        } catch {
            let error = mapped(error)
            if case CocoaError.fileReadNoSuchFile = error { throw ChromeImportError.notInstalled }
            throw error
        }
    }

    /// Turns permission errors into `.noAccess` and anything else missing into
    /// `fileReadNoSuchFile`.
    private static func mapped(_ error: Error) -> Error {
        let nsError = error as NSError
        let posix = (nsError.userInfo[NSUnderlyingErrorKey] as? NSError).flatMap {
            $0.domain == NSPOSIXErrorDomain ? Int32($0.code) : nil
        }
        if nsError.code == NSFileReadNoPermissionError || posix == EPERM || posix == EACCES {
            return ChromeImportError.noAccess
        }
        if nsError.code == NSFileReadNoSuchFileError || nsError.code == NSFileNoSuchFileError || posix == ENOENT {
            return CocoaError(.fileReadNoSuchFile)
        }
        return error
    }
}

/// The AES key Chrome encrypts cookies and passwords with. Values start with
/// "v10", then AES-128-CBC with a fixed IV of 16 spaces.
struct ChromeKey: Sendable {
    private let key: Data

    /// Derives the key from the keychain password the way Chrome does.
    init(password: Data) {
        var key = Data(count: kCCKeySizeAES128)
        let salt = Data("saltysalt".utf8)
        key.withUnsafeMutableBytes { keyBytes in
            password.withUnsafeBytes { passwordBytes in
                salt.withUnsafeBytes { saltBytes in
                    _ = CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passwordBytes.baseAddress?.assumingMemoryBound(to: CChar.self), password.count,
                        saltBytes.baseAddress?.assumingMemoryBound(to: UInt8.self), salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), 1003,
                        keyBytes.baseAddress?.assumingMemoryBound(to: UInt8.self), kCCKeySizeAES128
                    )
                }
            }
        }
        self.key = key
    }

    /// The plaintext, or nil if `blob` isn't a "v10" value or doesn't decrypt.
    func decrypt(_ blob: Data) -> Data? {
        guard blob.starts(with: Data("v10".utf8)) else { return nil }
        let cipher = blob.dropFirst(3)
        let iv = Data(repeating: 0x20, count: kCCBlockSizeAES128)
        var output = Data(count: cipher.count + kCCBlockSizeAES128)
        var length = 0
        let status = output.withUnsafeMutableBytes { out in
            cipher.withUnsafeBytes { input in
                key.withUnsafeBytes { key in
                    iv.withUnsafeBytes { iv in
                        CCCrypt(
                            CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                            key.baseAddress, key.count, iv.baseAddress,
                            input.baseAddress, input.count, out.baseAddress, out.count, &length
                        )
                    }
                }
            }
        }
        guard status == kCCSuccess else { return nil }
        return output.prefix(length)
    }
}
