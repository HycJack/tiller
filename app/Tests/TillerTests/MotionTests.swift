import AppKit
import Testing
@testable import Tiller

/// The fades and pops are Core Animation animations of their own, since
/// AppKit's animator leaves some views unfaded. These check each one is
/// added, from and to where it should be, and that the view's state lands
/// at once for whatever reads it meanwhile.
@Suite(.serialized)
@MainActor
struct MotionTests {
    private func makeWindow() -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 400), styleMask: [.titled], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView!.wantsLayer = true
        return window
    }

    private func fade(of view: NSView) -> CABasicAnimation? {
        view.layer?.animation(forKey: "fade") as? CABasicAnimation
    }

    @Test(.enabled(if: !Theme.reduceMotion)) func showingFadesInFromClear() {
        let window = makeWindow()
        defer { window.close() }
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 20, height: 20))
        view.isHidden = true
        window.contentView!.addSubview(view)

        view.setShown(true)
        #expect(!view.isHidden)
        #expect(view.alphaValue == 1)
        let animation = fade(of: view)
        #expect(animation?.fromValue as? Float == 0)
        #expect(animation?.toValue as? Float == 1)

        // Shown already, the same call does nothing more.
        view.layer?.removeAllAnimations()
        view.setShown(true)
        #expect(fade(of: view) == nil)
    }

    @Test(.enabled(if: !Theme.reduceMotion)) func hidingIsAtOnceUnlessItFadesOut() {
        let window = makeWindow()
        defer { window.close() }
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 20, height: 20))
        window.contentView!.addSubview(view)

        view.setShown(false)
        #expect(view.isHidden)

        view.isHidden = false
        view.setShown(false, fadesOut: true)
        // Still there while it fades, at alpha 0 underneath.
        #expect(!view.isHidden)
        #expect(view.alphaValue == 0)
        #expect(fade(of: view)?.toValue as? Float == 0)

        // Shown again before the fade ends, it eases back and stays.
        view.setShown(true)
        #expect(!view.isHidden)
        #expect(view.alphaValue == 1)
        #expect(fade(of: view)?.toValue as? Float == 1)
    }

    @Test func outsideAWindowNothingAnimates() {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 20, height: 20))
        view.wantsLayer = true
        view.isHidden = true
        view.setShown(true, alpha: 0.5)
        #expect(!view.isHidden)
        #expect(view.alphaValue == 0.5)
        #expect(fade(of: view) == nil)
        view.setShown(false, fadesOut: true)
        #expect(view.isHidden)
    }

    @Test(.enabled(if: !Theme.reduceMotion)) func newChatSuggestionsComeInOneAfterAnother() throws {
        let window = makeWindow()
        defer { window.close() }
        let empty = AgentEmptyState(frame: NSRect(x: 0, y: 0, width: 300, height: 300))
        window.contentView!.addSubview(empty)

        empty.appear()
        let stack = try #require(empty.subviews.first as? NSStackView)
        let starts = stack.arrangedSubviews.compactMap { ($0.layer?.animation(forKey: "fadeUp") as? CABasicAnimation)?.beginTime }
        #expect(starts.count == stack.arrangedSubviews.count)
        #expect(starts == starts.sorted())
        #expect(Set(starts).count == starts.count)
    }

    @Test(.enabled(if: !Theme.reduceMotion)) func popScalesAboutTheMiddle() throws {
        let window = makeWindow()
        defer { window.close() }
        let button = HoverButton(frame: NSRect(x: 0, y: 0, width: 24, height: 24))
        window.contentView!.addSubview(button)

        button.pop()
        let animation = try #require(button.layer?.animation(forKey: "pop") as? CAKeyframeAnimation)
        let last = try #require(animation.values?.last as? NSValue)
        #expect(CATransform3DIsIdentity(last.caTransform3DValue))
    }

    @Test(.enabled(if: !Theme.reduceMotion)) func droppingInEasesDownToRest() {
        let window = makeWindow()
        defer { window.close() }
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 20, height: 20))
        window.contentView!.addSubview(view)

        view.dropIn(distance: 6)
        let animation = view.layer?.animation(forKey: "dropIn") as? CABasicAnimation
        #expect(abs(animation?.fromValue as? CGFloat ?? 0) == 6)
        #expect(animation?.toValue as? CGFloat == 0)
        // The view itself stays where it rests.
        #expect(view.frame.origin == .zero)
    }
}
