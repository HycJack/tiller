import AppKit
import Testing
@testable import Tiller

@Suite(.serialized)
@MainActor
struct JevOverlayTests {
    private func overlay(selected: Int? = 1) -> JevOverlay {
        _ = NSApplication.shared
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        return JevOverlay(container: container, selectedTab: { selected }, hostView: { _ in nil })
    }

    private func stop(_ reply: [String: Any]) -> Bool { reply["stop"] as? Bool ?? false }

    @Test func stopReachesTheRunsNextReport() throws {
        let overlay = overlay()
        #expect(try !stop(overlay.progress(["run": "a", "phase": "start", "tab_id": 1, "goal": "g"])))
        #expect(try !stop(overlay.progress(["run": "a", "phase": "thinking", "steps": 0])))
        overlay.stopShownRun()
        #expect(try stop(overlay.progress(["run": "a", "phase": "act", "steps": 0, "action": "click [3] button \"Go\""])))
    }

    @Test func stopLeavesOtherTabsRunsAlone() throws {
        let overlay = overlay(selected: 1)
        _ = try overlay.progress(["run": "a", "phase": "start", "tab_id": 1, "goal": "g"])
        _ = try overlay.progress(["run": "b", "phase": "start", "tab_id": 2, "goal": "h"])
        overlay.stopShownRun()
        #expect(try !stop(overlay.progress(["run": "b", "phase": "thinking"])))
        #expect(try stop(overlay.progress(["run": "a", "phase": "thinking"])))
    }

    @Test func closingTheTabStopsItsRun() throws {
        let overlay = overlay(selected: 1)
        _ = try overlay.progress(["run": "a", "phase": "start", "tab_id": 2, "goal": "g"])
        overlay.tabClosed(2)
        #expect(try stop(overlay.progress(["run": "a", "phase": "thinking"])))
    }

    @Test func unknownRunsAreNeverStopped() throws {
        #expect(try !stop(overlay().progress(["run": "x", "phase": "thinking"])))
        #expect(throws: ControlError.self) { try overlay().progress(["phase": "thinking"]) }
    }

    @Test func stepsReadWithoutRefs() {
        #expect(JevRun.readable(#"click [12] button "Search""#) == #"Click button "Search""#)
        #expect(JevRun.readable(#"type "Zurich" into [3] combobox "From""#) == #"Type "Zurich" into combobox "From""#)
        #expect(JevRun.readable(#"select [4] combobox "Class" → "Business""#) == #"Select combobox "Class" → "Business""#)
    }

    @Test func taskRowsMarkHowARunEnded() {
        #expect(ToolRowView.taskEnding("Done in 2.4 s, 5 steps")?.description == "Done")
        #expect(ToolRowView.taskEnding("Blocked after 1 step: x")?.color == .systemOrange)
        #expect(ToolRowView.taskEnding("Out of steps: took 30 actions")?.color == .systemOrange)
        #expect(ToolRowView.taskEnding("Stopped after 2 steps: the user stopped it in Tiller")?.description == "Stopped")
        #expect(ToolRowView.taskEnding("Error after 0 steps: HTTP 401")?.color == .systemRed)
        #expect(ToolRowView.taskEnding("{\"status\": \"done\"}") == nil)
    }
}
