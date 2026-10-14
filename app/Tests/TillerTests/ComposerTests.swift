import AppKit
import Testing
@testable import Tiller

@Suite(.serialized)
@MainActor
struct ComposerTests {
    private final class Receiver: NSObject {
        var clicks = 0
        @objc func clicked(_ sender: Any?) { clicks += 1 }
    }

    private func makeComposer() -> (NSWindow, Composer) {
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 300), styleMask: [.titled], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        let composer = Composer()
        composer.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(composer)
        NSLayoutConstraint.activate([
            composer.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 12),
            composer.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -12),
            composer.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor, constant: -12),
        ])
        window.contentView!.layoutSubtreeIfNeeded()
        return (window, composer)
    }

    @Test func emptyFieldDisablesSend() {
        let (window, composer) = makeComposer()
        defer { window.close() }
        #expect(composer.isEmpty)
        #expect(!composer.sendButton.isEnabled)

        composer.text = "  \n "
        #expect(composer.isEmpty)
        #expect(!composer.sendButton.isEnabled)

        composer.text = " hello"
        #expect(!composer.isEmpty)
        #expect(composer.sendButton.isEnabled)
        #expect(composer.sendButton.mode == .send)
    }

    @Test func busyEmptyFieldStops() {
        let (window, composer) = makeComposer()
        defer { window.close() }
        composer.isBusy = true
        #expect(composer.sendButton.mode == .stop)
        #expect(composer.sendButton.isEnabled)

        // Written while busy, the message is queued with the same button.
        composer.text = "next"
        #expect(composer.sendButton.mode == .send)

        composer.text = ""
        composer.isBusy = false
        #expect(composer.sendButton.mode == .send)
        #expect(!composer.sendButton.isEnabled)
    }

    @Test func queuedMessagesEnableSend() {
        let (window, composer) = makeComposer()
        defer { window.close() }
        composer.hasQueued = true
        #expect(composer.sendButton.isEnabled)
    }

    @Test func busyChangesPlaceholder() {
        let (window, composer) = makeComposer()
        defer { window.close() }
        composer.placeholder = "Ask Codex about this page…"
        #expect(composer.textView.placeholder == "Ask Codex about this page…")
        composer.isBusy = true
        #expect(composer.textView.placeholder == "Queue a follow-up…")
        composer.isBusy = false
        #expect(composer.textView.placeholder == "Ask Codex about this page…")
    }

    @Test func fieldGrowsWithLinesUpToALimit() {
        let (window, composer) = makeComposer()
        defer { window.close() }
        let oneLine = composer.fittingSize.height
        composer.text = "one\ntwo\nthree"
        window.contentView!.layoutSubtreeIfNeeded()
        let threeLines = composer.fittingSize.height
        #expect(threeLines > oneLine)

        composer.text = Array(repeating: "line", count: 60).joined(separator: "\n")
        window.contentView!.layoutSubtreeIfNeeded()
        let capped = composer.fittingSize.height
        composer.text = Array(repeating: "line", count: 120).joined(separator: "\n")
        window.contentView!.layoutSubtreeIfNeeded()
        #expect(composer.fittingSize.height == capped)
        #expect(capped > threeLines)
    }

    /// The send button reaches its action, as the chat sets it up.
    @Test func sendButtonSends() {
        let (window, composer) = makeComposer()
        defer { window.close() }
        let receiver = Receiver()
        composer.sendButton.target = receiver
        composer.sendButton.action = #selector(Receiver.clicked(_:))
        composer.text = "hello"
        composer.sendButton.performClick(nil)
        #expect(receiver.clicks == 1)

        // Nothing to send: the button is off.
        composer.text = ""
        composer.sendButton.performClick(nil)
        #expect(receiver.clicks == 1)
    }
}

