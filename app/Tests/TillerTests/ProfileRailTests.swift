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
        #expect(colors["b"] == .orange)
    }
}
