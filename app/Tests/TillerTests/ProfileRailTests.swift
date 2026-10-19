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
