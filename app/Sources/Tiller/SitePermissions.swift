import AppKit
import AVFoundation

/// A device a page can ask for through getUserMedia.
enum MediaDevice: String, CaseIterable, Sendable {
    case camera
    case microphone

    var mediaType: AVMediaType { self == .camera ? .video : .audio }

    /// "camera", "microphone" or "camera and microphone".
    static func names(_ devices: Set<MediaDevice>) -> String {
        allCases.filter(devices.contains).map(\.rawValue).joined(separator: " and ")
    }
}

/// What a site may do with a device, once the user has chosen.
enum SitePermission: String, Sendable {
    case allow
    case block
}

/// A page's request for the camera or microphone, waiting for an answer.
struct MediaRequest: Equatable {
    /// The core's id, to answer it with.
    let id: UInt64
    /// The site asking, as `SitePermissions.origin` writes it.
    let origin: String
    let devices: Set<MediaDevice>
}

/// The camera and microphone choices a profile remembers for each site, in
/// its user defaults as `{origin: {device: "allow" | "block"}}`.
struct SitePermissions: @unchecked Sendable {
    let defaults: UserDefaults
    private static let key = "sitePermissions"

    enum Decision: Equatable {
        case allow
        case block
        case ask
    }

    /// Blocked if any device asked for is blocked, allowed if every one is
    /// allowed, and asked otherwise.
    func decision(for devices: Set<MediaDevice>, origin: String) -> Decision {
        let saved = permissions(for: origin)
        if devices.contains(where: { saved[$0] == .block }) { return .block }
        if !devices.isEmpty, devices.allSatisfy({ saved[$0] == .allow }) { return .allow }
        return .ask
    }

    func permissions(for origin: String) -> [MediaDevice: SitePermission] {
        Self.decode(all[origin] ?? [:])
    }

    /// Every site with a saved choice, by origin.
    var all: [String: [String: String]] {
        defaults.dictionary(forKey: Self.key) as? [String: [String: String]] ?? [:]
    }

    /// Saves `permission` for each of `devices`, or forgets the choice when nil.
    func set(_ permission: SitePermission?, for devices: Set<MediaDevice>, origin: String) {
        var all = all
        var site = all[origin] ?? [:]
        for device in devices { site[device.rawValue] = permission?.rawValue }
        all[origin] = site.isEmpty ? nil : site
        save(all)
    }

    func remove(_ origins: Set<String>) {
        var all = all
        for origin in origins { all[origin] = nil }
        save(all)
    }

    func removeAll() {
        save([:])
    }

    private func save(_ all: [String: [String: String]]) {
        if all.isEmpty {
            defaults.removeObject(forKey: Self.key)
        } else {
            defaults.set(all, forKey: Self.key)
        }
        NotificationCenter.default.post(name: .sitePermissionsDidChange, object: nil)
    }

    private static func decode(_ site: [String: String]) -> [MediaDevice: SitePermission] {
        var result: [MediaDevice: SitePermission] = [:]
        for (device, permission) in site {
            if let device = MediaDevice(rawValue: device), let permission = SitePermission(rawValue: permission) {
                result[device] = permission
            }
        }
        return result
    }

    /// `https://meet.google.com/` as `https://meet.google.com`, keeping a
    /// port and dropping any path, so every page of a site shares its choices.
    static func origin(_ url: String) -> String {
        guard let components = URLComponents(string: url), let scheme = components.scheme?.lowercased(),
            let host = components.host, !host.isEmpty
        else {
            return url.hasSuffix("/") ? String(url.dropLast()) : url
        }
        let port = components.port.map { ":\($0)" } ?? ""
        return "\(scheme)://\(host.lowercased())\(port)"
    }

    /// The origin without `https://`, for showing.
    static func displayName(_ origin: String) -> String {
        origin.hasPrefix("https://") ? String(origin.dropFirst("https://".count)) : origin
    }
}

/// Whether macOS lets Tiller use the camera and microphone, which it decides
/// for the app as a whole, before any site's choice counts.
@MainActor
enum SystemMediaAccess {
    /// The devices macOS refuses Tiller, without asking.
    static func refused(_ devices: Set<MediaDevice>) -> Set<MediaDevice> {
        devices.filter {
            let status = AVCaptureDevice.authorizationStatus(for: $0.mediaType)
            return status == .denied || status == .restricted
        }
    }

    /// Asks macOS for each device it hasn't decided on yet, then calls
    /// `done` with the devices it refuses.
    static func request(_ devices: Set<MediaDevice>, done: @escaping @MainActor (Set<MediaDevice>) -> Void) {
        let undecided = devices.filter { AVCaptureDevice.authorizationStatus(for: $0.mediaType) == .notDetermined }
        ask(MediaDevice.allCases.filter(undecided.contains)) {
            done(refused(devices))
        }
    }

    /// Asks for each of `devices` in turn, as macOS shows one prompt at a time.
    private static func ask(_ devices: [MediaDevice], then done: @escaping @MainActor () -> Void) {
        guard let next = devices.first else { return done() }
        AVCaptureDevice.requestAccess(for: next.mediaType) { _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    ask(Array(devices.dropFirst()), then: done)
                }
            }
        }
    }

    /// Opens Privacy & Security at the camera's or the microphone's list.
    static func openSettings(for devices: Set<MediaDevice>) {
        let pane = devices.contains(.camera) ? "Privacy_Camera" : "Privacy_Microphone"
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }
}

extension Notification.Name {
    /// A site's camera or microphone choice was saved or removed.
    static let sitePermissionsDidChange = Notification.Name("TillerSitePermissionsDidChange")
}
