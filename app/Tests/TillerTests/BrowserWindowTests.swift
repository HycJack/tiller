import AppKit
import Testing
@testable import Tiller

@Suite(.serialized)
@MainActor
struct BrowserWindowTests {
    private func makeWindow() -> RecordingBrowserWindow {
        _ = NSApplication.shared
        let window = RecordingBrowserWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        #expect(!window.isVisible)
        return window
    }

    private func mouseEvent(_ type: NSEvent.EventType, button: Int, in window: NSWindow) -> NSEvent {
        let event = NSEvent.mouseEvent(
            with: type, location: NSPoint(x: 50, y: 50), modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: 0, clickCount: 1, pressure: 0
        )!
        let cgEvent = event.cgEvent!
        cgEvent.setIntegerValueField(.mouseEventButtonNumber, value: Int64(button))
        return NSEvent(cgEvent: cgEvent)!
    }

    @discardableResult
    private func send(_ type: NSEvent.EventType, button: Int, to window: NSWindow) -> NSEvent {
        let event = mouseEvent(type, button: button, in: window)
        window.sendEvent(event)
        return event
    }

    @discardableResult
    private func sendSwipe(deltaX: CGFloat, phase: NSEvent.Phase, to window: NSWindow) -> NSEvent {
        let event = SwipeEvent(window: window, deltaX: deltaX, phase: phase)
        window.sendEvent(event)
        return event
    }

    @Test(arguments: [CGFloat(1), CGFloat(-1)])
    func logitechSwipeNavigatesOnceAtEnd(deltaX: CGFloat) {
        let window = makeWindow()
        defer { window.close() }
        var back = 0
        var forward = 0
        window.onGoBack = { back += 1 }
        window.onGoForward = { forward += 1 }

        // Captured Options+ events start at zero and carry direction on ended.
        sendSwipe(deltaX: 0, phase: .began, to: window)
        sendSwipe(deltaX: deltaX, phase: .changed, to: window)
        #expect(back == 0 && forward == 0)
        sendSwipe(deltaX: deltaX, phase: .ended, to: window)
        #expect(back == (deltaX > 0 ? 1 : 0))
        #expect(forward == (deltaX < 0 ? 1 : 0))
        #expect(window.forwardedEvents.isEmpty)
    }

    @Test(arguments: [CGFloat(1), CGFloat(-1)])
    func unphasedSwipeNavigates(deltaX: CGFloat) {
        let window = makeWindow()
        defer { window.close() }
        var back = 0
        var forward = 0
        window.onGoBack = { back += 1 }
        window.onGoForward = { forward += 1 }

        sendSwipe(deltaX: deltaX, phase: [], to: window)
        #expect(back == (deltaX > 0 ? 1 : 0))
        #expect(forward == (deltaX < 0 ? 1 : 0))
        #expect(window.forwardedEvents.isEmpty)
    }

    @Test
    func cancelledOrEmptySwipeDoesNotNavigate() {
        let window = makeWindow()
        defer { window.close() }
        var navigations = 0
        window.onGoBack = { navigations += 1 }
        window.onGoForward = { navigations += 1 }

        sendSwipe(deltaX: 0, phase: .began, to: window)
        sendSwipe(deltaX: 1, phase: .changed, to: window)
        sendSwipe(deltaX: 1, phase: .cancelled, to: window)
        sendSwipe(deltaX: 0, phase: .ended, to: window)
        #expect(navigations == 0)
        #expect(window.forwardedEvents.isEmpty)
    }

    @Test
    func verticalSwipeAndScrollAreForwarded() {
        let window = makeWindow()
        defer { window.close() }
        var navigations = 0
        window.onGoBack = { navigations += 1 }
        window.onGoForward = { navigations += 1 }
        let vertical = SwipeEvent(window: window, deltaX: 0, deltaY: 1, phase: .ended)
        let scroll = SwipeEvent(window: window, deltaX: 1, phase: .ended, type: .scrollWheel)

        window.sendEvent(vertical)
        window.sendEvent(scroll)
        #expect(navigations == 0)
        #expect(window.forwardedEvents == [vertical, scroll])
    }

    @Test
    func swipeBelongsToEventWindow() {
        let first = makeWindow()
        let second = makeWindow()
        defer { first.close(); second.close() }
        var firstBack = 0
        var secondBack = 0
        first.onGoBack = { firstBack += 1 }
        second.onGoBack = { secondBack += 1 }
        let event = SwipeEvent(window: second, deltaX: 1, phase: .ended)

        first.sendEvent(event)
        #expect(firstBack == 0 && secondBack == 0)
        #expect(first.forwardedEvents == [event])
        second.sendEvent(event)
        #expect(firstBack == 0 && secondBack == 1)
        #expect(second.forwardedEvents.isEmpty)
    }

    @Test(arguments: [3, 4])
    func sideButtonNavigatesOnceOnRelease(button: Int) {
        let window = makeWindow()
        defer { window.close() }
        var back = 0
        var forward = 0
        window.onGoBack = { back += 1 }
        window.onGoForward = { forward += 1 }

        send(.otherMouseDown, button: button, to: window)
        send(.otherMouseDragged, button: button, to: window)
        #expect(back == 0 && forward == 0)
        send(.otherMouseUp, button: button, to: window)
        #expect(back == (button == 3 ? 1 : 0))
        #expect(forward == (button == 4 ? 1 : 0))
        // A page must not also receive the click and navigate a second time.
        #expect(window.forwardedEvents.isEmpty)
    }

    @Test(arguments: [2, 5, 6])
    func otherButtonsAreForwardedToAppKit(button: Int) {
        let window = makeWindow()
        defer { window.close() }
        var navigations = 0
        window.onGoBack = { navigations += 1 }
        window.onGoForward = { navigations += 1 }

        let down = send(.otherMouseDown, button: button, to: window)
        let drag = send(.otherMouseDragged, button: button, to: window)
        let up = send(.otherMouseUp, button: button, to: window)
        #expect(navigations == 0)
        #expect(window.forwardedEvents == [down, drag, up])
    }

    @Test
    func ordinaryClicksAreForwardedToAppKit() {
        let window = makeWindow()
        defer { window.close() }
        var navigations = 0
        window.onGoBack = { navigations += 1 }
        window.onGoForward = { navigations += 1 }

        let leftDown = send(.leftMouseDown, button: 0, to: window)
        let leftUp = send(.leftMouseUp, button: 0, to: window)
        let rightDown = send(.rightMouseDown, button: 1, to: window)
        let rightUp = send(.rightMouseUp, button: 1, to: window)
        #expect(navigations == 0)
        #expect(window.forwardedEvents == [leftDown, leftUp, rightDown, rightUp])
    }

    @Test
    func navigationBelongsToEventWindow() {
        let first = makeWindow()
        let second = makeWindow()
        defer { first.close(); second.close() }
        var firstBack = 0
        var secondBack = 0
        first.onGoBack = { firstBack += 1 }
        second.onGoBack = { secondBack += 1 }
        let down = mouseEvent(.otherMouseDown, button: 3, in: second)
        let up = mouseEvent(.otherMouseUp, button: 3, in: second)
        first.sendEvent(down)
        first.sendEvent(up)
        #expect(firstBack == 0 && secondBack == 0)
        #expect(first.forwardedEvents == [down, up])

        second.sendEvent(down)
        second.sendEvent(up)
        #expect(firstBack == 0)
        #expect(secondBack == 1)
        #expect(second.forwardedEvents.isEmpty)
    }

    @Test
    func sheetPreventsNavigation() {
        let window = makeWindow()
        let sheet = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        sheet.isReleasedWhenClosed = false
        window.beginSheet(sheet)
        defer { window.endSheet(sheet); sheet.close(); window.close() }
        var navigations = 0
        window.onGoBack = { navigations += 1 }
        window.onGoForward = { navigations += 1 }

        for button in [3, 4] {
            send(.otherMouseDown, button: button, to: window)
            send(.otherMouseUp, button: button, to: window)
        }
        for deltaX in [CGFloat(1), CGFloat(-1)] {
            sendSwipe(deltaX: deltaX, phase: .ended, to: window)
        }
        #expect(navigations == 0)
        #expect(window.forwardedEvents.isEmpty)
    }

    @Test
    func modalWindowPreventsNavigation() {
        let window = makeWindow()
        let modal = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        modal.isReleasedWhenClosed = false
        let session = NSApp.beginModalSession(for: modal)
        defer { NSApp.endModalSession(session); modal.close(); window.close() }
        var navigations = 0
        window.onGoBack = { navigations += 1 }
        window.onGoForward = { navigations += 1 }

        for button in [3, 4] {
            send(.otherMouseDown, button: button, to: window)
            send(.otherMouseUp, button: button, to: window)
        }
        for deltaX in [CGFloat(1), CGFloat(-1)] {
            sendSwipe(deltaX: deltaX, phase: .ended, to: window)
        }
        #expect(navigations == 0)
        #expect(window.forwardedEvents.isEmpty)
    }
}

// AppKit has no public swipe constructor; mirror the captured type, direction and phase.
private final class SwipeEvent: NSEvent, @unchecked Sendable {
    private let targetWindow: NSWindow
    private let horizontalDelta: CGFloat
    private let verticalDelta: CGFloat
    private let swipePhase: NSEvent.Phase
    private let eventType: NSEvent.EventType

    init(window: NSWindow, deltaX: CGFloat, deltaY: CGFloat = 0,
         phase: NSEvent.Phase, type: NSEvent.EventType = .swipe) {
        targetWindow = window
        horizontalDelta = deltaX
        verticalDelta = deltaY
        swipePhase = phase
        eventType = type
        super.init()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var window: NSWindow? { targetWindow }
    override var type: NSEvent.EventType { eventType }
    override var deltaX: CGFloat { horizontalDelta }
    override var deltaY: CGFloat { verticalDelta }
    override var phase: NSEvent.Phase { swipePhase }
}

@MainActor
private final class RecordingBrowserWindow: BrowserWindow {
    var forwardedEvents: [NSEvent] = []

    override func sendEventToAppKit(_ event: NSEvent) {
        forwardedEvents.append(event)
    }
}
