import AppKit
import Testing
@testable import Tiller

struct SitePermissionsTests {
    /// A store over fresh user defaults of its own.
    private func makeStore() -> (SitePermissions, () -> Void) {
        let suite = "TillerTests.SitePermissions.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        return (SitePermissions(defaults: defaults), { defaults.removePersistentDomain(forName: suite) })
    }

    @Test func asksWithNoSavedChoice() {
        let (store, cleanup) = makeStore()
        defer { cleanup() }
        #expect(store.decision(for: [.camera, .microphone], origin: "https://meet.google.com") == .ask)
    }

    @Test func allowsOnlyWhenEveryDeviceIsAllowed() {
        let (store, cleanup) = makeStore()
        defer { cleanup() }
        let site = "https://meet.google.com"
        store.set(.allow, for: [.microphone], origin: site)
        #expect(store.decision(for: [.microphone], origin: site) == .allow)
        // The camera was never allowed, so a call wanting both asks.
        #expect(store.decision(for: [.camera, .microphone], origin: site) == .ask)
        store.set(.allow, for: [.camera], origin: site)
        #expect(store.decision(for: [.camera, .microphone], origin: site) == .allow)
    }

    @Test func oneBlockedDeviceBlocksTheRequest() {
        let (store, cleanup) = makeStore()
        defer { cleanup() }
        let site = "https://example.com"
        store.set(.allow, for: [.microphone], origin: site)
        store.set(.block, for: [.camera], origin: site)
        #expect(store.decision(for: [.camera, .microphone], origin: site) == .block)
        #expect(store.decision(for: [.microphone], origin: site) == .allow)
    }

    @Test func choicesBelongToTheirSite() {
        let (store, cleanup) = makeStore()
        defer { cleanup() }
        store.set(.allow, for: [.camera], origin: "https://a.example")
        #expect(store.decision(for: [.camera], origin: "https://b.example") == .ask)
        #expect(store.decision(for: [.camera], origin: "http://a.example") == .ask)
    }

    @Test func forgettingAChoiceAsksAgain() {
        let (store, cleanup) = makeStore()
        defer { cleanup() }
        let site = "https://example.com"
        store.set(.block, for: [.camera, .microphone], origin: site)
        store.set(nil, for: [.camera], origin: site)
        #expect(store.decision(for: [.camera], origin: site) == .ask)
        #expect(store.all[site] == ["microphone": "block"])
        store.set(nil, for: [.microphone], origin: site)
        #expect(store.all[site] == nil)

        store.set(.allow, for: [.camera], origin: "https://a.example")
        store.set(.allow, for: [.camera], origin: "https://b.example")
        store.remove(["https://a.example"])
        #expect(Set(store.all.keys) == ["https://b.example"])
        store.removeAll()
        #expect(store.all.isEmpty)
    }

    @Test func originDropsThePathAndKeepsThePort() {
        #expect(SitePermissions.origin("https://meet.google.com/") == "https://meet.google.com")
        #expect(SitePermissions.origin("https://Meet.Google.com/abc-defg-hij?x=1") == "https://meet.google.com")
        #expect(SitePermissions.origin("http://localhost:8080/") == "http://localhost:8080")
        #expect(SitePermissions.origin("file:///") == "file://")
    }

    @Test func namesDevicesInAFixedOrder() {
        #expect(MediaDevice.names([.microphone, .camera]) == "camera and microphone")
        #expect(MediaDevice.names([.microphone]) == "microphone")
        #expect(SitePermissions.displayName("https://meet.google.com") == "meet.google.com")
        #expect(SitePermissions.displayName("http://localhost:8080") == "http://localhost:8080")
    }
}

@Suite(.serialized)
@MainActor
struct MediaPermissionBarTests {
    @Test func requestOffersTheThreeAnswers() {
        _ = NSApplication.shared
        let bar = MediaPermissionBar()
        var answers: [MediaPermissionBar.Answer] = []
        bar.onAnswer = { answers.append($0) }
        bar.show(.request(MediaRequest(id: 1, origin: "https://meet.google.com", devices: [.camera, .microphone])))
        #expect(bar.accessibilityLabel() == "meet.google.com wants to use your camera and microphone.")
        #expect(!bar.blockButton.isHidden && !bar.allowOnceButton.isHidden && !bar.allowButton.isHidden)
        #expect(bar.settingsButton.isHidden)
        bar.allowOnceButton.performClick(nil)
        bar.blockButton.performClick(nil)
        bar.allowButton.performClick(nil)
        #expect(answers == [.allowOnce, .block, .allowAlways])
    }

    @Test func refusalOffersSystemSettings() {
        _ = NSApplication.shared
        let bar = MediaPermissionBar()
        var opened = false
        bar.onOpenSettings = { opened = true }
        bar.show(.refused([.microphone]))
        #expect(bar.accessibilityLabel()?.hasPrefix("macOS isn't letting Tiller use your microphone.") == true)
        #expect(bar.blockButton.isHidden && bar.allowButton.isHidden)
        #expect(!bar.settingsButton.isHidden)
        bar.settingsButton.performClick(nil)
        #expect(opened)
    }
}
