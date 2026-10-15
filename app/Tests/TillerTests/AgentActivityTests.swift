import AppKit
import Testing
@testable import Tiller

@Suite(.serialized)
@MainActor
struct AgentActivityTests {
    init() { _ = NSApplication.shared }

    @Test func durationsCountSecondsThenMinutes() {
        #expect(ThinkingRowView.duration(0.4) == "0s")
        #expect(ThinkingRowView.duration(24.9) == "24s")
        #expect(ThinkingRowView.duration(65) == "1m 05s")
    }

    @Test func commandOutputShowsItsLastLineWithoutColors() {
        #expect(AgentSession.lastLine(of: "one\ntwo\n\n") == "two")
        #expect(AgentSession.lastLine(of: "\u{1B}[32mServing\u{1B}[0m on :8000\n") == "Serving on :8000")
        // A progress bar redraws its line.
        #expect(AgentSession.lastLine(of: "10%\r55%\r") == "55%")
        #expect(AgentSession.lastLine(of: "  \n") == nil)
        let long = String(repeating: "x", count: 300)
        #expect(AgentSession.lastLine(of: long)?.count == 201)
    }

    @Test func thinkingRowSaysWhatTheAgentIsBusyWith() throws {
        let transcript = TranscriptView()
        transcript.activity = ("Running hooks", nil)
        transcript.showThinking()
        let row = try #require(transcript.thinkingForTesting)
        #expect(row.textForTesting.main == "Running hooks…")
        #expect(row.textForTesting.detail == nil)

        transcript.activity = ("Thinking", "Verifying the prime sum")
        #expect(row.textForTesting.main == "Thinking…")
        #expect(row.textForTesting.detail == "Verifying the prime sum")

        // With nothing known, a sailing phrase.
        transcript.activity = nil
        #expect(row.textForTesting.main.hasSuffix("…"))
        #expect(row.textForTesting.main != "Thinking…")
        #expect(row.textForTesting.detail == nil)
    }

    @Test func aNewRowEndsTheActivity() {
        let transcript = TranscriptView()
        transcript.activity = ("Retrying", nil)
        transcript.add(NoteView(text: "Stopped"))
        #expect(transcript.activity == nil)
        transcript.showThinking()
        #expect(transcript.thinkingForTesting?.textForTesting.main != "Retrying…")
    }

    @Test func reasoningShowsItsHeadingAndOpensToTheRest() {
        let row = ToolRowView(reasoning: "**Planning the page**\n\nIt needs a camera preview.", seconds: 12.3)
        #expect(row.outcome == .done)
        #expect(row.textForTesting == "Thought for 12s  Planning the page")
        #expect(row.accessibilityPerformPress())
        #expect(row.textForTesting.contains("It needs a camera preview."))
        #expect(row.accessibilityPerformPress())
        #expect(!row.textForTesting.contains("camera"))
    }

    @Test func reasoningWithNothingMoreDoesNotOpen() {
        let row = ToolRowView(reasoning: "**Verifying the prime sum**", seconds: 0.2)
        #expect(row.textForTesting == "Thought for 1s  Verifying the prime sum")
        #expect(!row.accessibilityPerformPress())
    }

    @Test func aCallShownEarlyIsFilledIn() {
        let row = ToolRowView(name: "Write", detail: "")
        #expect(row.textForTesting == "Write file")
        row.fill(detail: "/tmp/page.html", full: nil)
        #expect(row.textForTesting == "Write file\n/tmp/page.html")
        row.finish(isError: false, summary: "")
        #expect(row.textForTesting == "Write file  /tmp/page.html")
    }

    @Test func aRunningCommandShowsItsOutput() {
        let row = ToolRowView(name: "shell", detail: "python3 -m http.server")
        row.showProgress("Serving HTTP on :: port 8000", isOutput: true)
        #expect(row.textForTesting == "shell\npython3 -m http.server\nServing HTTP on :: port 8000")
        row.finish(isError: false, summary: "")
        #expect(row.textForTesting == "shell  python3 -m http.server")
    }

    @Test func reasoningRecordsRoundTrip() throws {
        let records: [AgentRecord] = [.reasoning("**Plan**", seconds: 3), .reasoning("x", seconds: nil)]
        let data = try JSONEncoder().encode(records)
        #expect(try JSONDecoder().decode([AgentRecord].self, from: data) == records)
    }
}
