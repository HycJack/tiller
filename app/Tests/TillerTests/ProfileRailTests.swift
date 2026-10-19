import AppKit
import Testing
@testable import Tiller

@Suite
@MainActor
struct ProfileRailTests {
    @Test func initialsTakeTwoWordsOrTwoLetters() {
        #expect(ProfileRailView.initials(for: ["Default", "Work Stuff", "personal"]) == ["De", "WS", "Pe"])
    }

    /// Names that would share their initials are told apart by the first
    /// letter that differs.
    @Test func clashingInitialsUseTheFirstLetterThatDiffers() {
        #expect(ProfileRailView.initials(for: ["Downloads", "Documents"]) == ["Dw", "Dc"])
        #expect(ProfileRailView.initials(for: ["Work", "Workshop"]) == ["Wo", "Ws"])
    }

    @Test func shortAndUnusualNamesStillGetInitials() {
        #expect(ProfileRailView.initials(for: ["A"]) == ["A"])
        #expect(ProfileRailView.initials(for: ["工作"]) == ["工作"])
        #expect(ProfileRailView.initials(for: ["my-team"]) == ["MT"])
    }
}

@Suite
struct ProfileColorTests {
    private func profile(_ id: String, color: String? = nil) -> Profile {
        Profile(id: id, name: id, created: Date(), color: color)
    }

    /// Without a color of their own, the first profiles each get a different
    /// one, by their place in the list, not by the rail's order.
    @Test func profilesWithoutAColorTakeDifferentOnes() {
        let colors = ProfileColor.of((0..<8).map { profile("p\($0)") })
        #expect(Set(colors.values).count == 8)
        #expect(colors["p0"] == .blue)
    }

    @Test func aPickedColorWins() {
        let colors = ProfileColor.of([profile("a", color: "pink"), profile("b", color: "nonsense")])
        #expect(colors["a"] == .pink)
        #expect(colors["b"] == .blue)
    }

    /// A color one profile picked is passed over by those without one, so
    /// two profiles share a color only once all eight are taken.
    @Test func automaticColorsPassOverPickedOnes() {
        let colors = ProfileColor.of([profile("a"), profile("b", color: "orange"), profile("c"), profile("d")])
        #expect(colors["a"] == .blue)
        #expect(colors["b"] == .orange)
        #expect(colors["c"] == .green)
        #expect(colors["d"] == .purple)
        let all = ProfileColor.of(ProfileColor.allCases.map { profile($0.rawValue, color: $0.rawValue) } + [profile("x")])
        #expect(all["x"] == .blue)
    }
}

@Suite
@MainActor
struct ProfileLabelTests {
    private func profile(_ id: String, _ name: String, label: String? = nil) -> Profile {
        Profile(id: id, name: name, created: Date(), label: label)
    }

    /// A label of its own takes the place of the initials, and the initials
    /// are told apart across every profile, so they match the menus'.
    @Test func ownLabelReplacesInitials() {
        let labels = ProfileAvatar.labels(for: [
            profile("a", "Downloads"), profile("b", "Documents", label: "🦊"), profile("c", "Work"),
        ])
        #expect(labels == ["a": "Dw", "b": "🦊", "c": "Wo"])
    }

    @Test func emojiLabelsAreTold() {
        #expect(ProfileAvatar.isEmoji("🦊"))
        #expect(ProfileAvatar.isEmoji("❤️"))
        #expect(!ProfileAvatar.isEmoji("Wo"))
        #expect(!ProfileAvatar.isEmoji("工作"))
    }
}
