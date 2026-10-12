import AppKit

/// Handles navigation buttons and swipes before Chromium's child view takes the event.
/// Keeping this on the browser window also leaves Settings and popups alone.
@MainActor
class BrowserWindow: NSWindow {
    var onGoBack: (() -> Void)?
    var onGoForward: (() -> Void)?

    override func sendEvent(_ event: NSEvent) {
        guard event.window === self else {
            sendEventToAppKit(event)
            return
        }

        let backwards: Bool
        if (event.type == .otherMouseDown || event.type == .otherMouseUp || event.type == .otherMouseDragged),
           event.buttonNumber == 3 || event.buttonNumber == 4 {
            // AppKit numbers buttons from zero: 2 is the middle button, 3/4
            // are Back/Forward on standard five-button mice. Consume the
            // whole click so the page cannot navigate a second time.
            guard event.type == .otherMouseUp else { return }
            backwards = event.buttonNumber == 3
        } else if event.type == .swipe, event.deltaY == 0 {
            // Options+ emits a zero-delta began swipe, then a directional ended swipe.
            // Consume the gesture and navigate on completion, or on an unphased swipe.
            guard event.deltaX != 0, event.phase.isEmpty || event.phase == .ended else { return }
            backwards = event.deltaX > 0
        } else {
            sendEventToAppKit(event)
            return
        }

        guard attachedSheet == nil, NSApp.modalWindow == nil else { return }
        if backwards {
            onGoBack?()
        } else {
            onGoForward?()
        }
    }

    // A separate dispatch boundary lets tests check forwarding without an
    // active window or view hit-testing.
    func sendEventToAppKit(_ event: NSEvent) {
        super.sendEvent(event)
    }
}
