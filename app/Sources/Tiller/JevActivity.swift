import AppKit

extension Notification.Name {
    /// A run_task run moved on. The object is the `JevRun`.
    static let jevRunDidChange = Notification.Name("TillerJevRunDidChange")
}

/// A run_task run, as tiller_mcp reports it through `jev.progress`: one
/// report as it starts, before each decision, before each action and as it
/// ends.
struct JevRun {
    let id: String
    let tabID: Int
    let goal: String
    let started = Date()
    /// When the last report came. A run that goes quiet for long, as when
    /// its agent was killed, is let go.
    var heard = Date()
    var steps = 0
    /// What it is doing, in a few words: "Click button "Search"".
    var activity = JevRun.reading
    /// "click", "type", "select", "scroll", "wait"; nil while deciding.
    var kind: String?
    /// Set once it ends: done, blocked, out_of_steps, stopped or error.
    var status: String?
    /// How it ended, in one line.
    var summary: String?
    /// The user pressed Stop; the next report is told so.
    var stopRequested = false

    var isRunning: Bool { status == nil }

    static let reading = "Reading the page"

    /// `click [12] button "Search"` as `Click button "Search"`: refs mean
    /// nothing to a person.
    static func readable(_ action: String) -> String {
        let plain = action.replacingOccurrences(of: #"\[[^\]]*\] "#, with: "", options: .regularExpression)
        return plain.prefix(1).uppercased() + plain.dropFirst()
    }
}

/// Shows run_task at work over the page it works on: a capsule at the bottom
/// of the page with the current step, the time and a Stop button, and a ring
/// that marks each element before it is clicked, typed into or set. Only the
/// selected tab's run shows; switching to a tab with one running shows it.
@MainActor
final class JevOverlay {
    private let container: NSView
    /// The selected tab's id, and a tab's view by id, from the window.
    private let selectedTab: () -> Int?
    private let hostView: (Int) -> NSView?
    private var runs: [String: JevRun] = [:]
    private lazy var capsule: JevActivityView = {
        let view = JevActivityView()
        view.onStop = { [weak self] in self?.stopShownRun() }
        return view
    }()
    private let ring = JevTargetRing()
    /// The run the capsule shows.
    private var shown: String?
    private var tick: Timer?
    private var hideWork: DispatchWorkItem?

    /// A run that hasn't reported for this long has lost its agent.
    private static let quietLimit: TimeInterval = 90

    init(container: NSView, selectedTab: @escaping () -> Int?, hostView: @escaping (Int) -> NSView?) {
        self.container = container
        self.selectedTab = selectedTab
        self.hostView = hostView
    }

    /// `jev.progress`: takes a report and answers whether to stop.
    func progress(_ params: [String: Any]) throws -> [String: Any] {
        guard let id = params["run"] as? String else { throw ControlError("jev.progress needs a run") }
        let phase = params["phase"] as? String ?? ""
        if phase == "start" {
            guard let tab = params["tab_id"] as? Int else { throw ControlError("jev.progress needs a tab_id to start") }
            // One run per tab: a new one takes an old one's place.
            runs = runs.filter { $0.value.tabID != tab }
            runs[id] = JevRun(id: id, tabID: tab, goal: params["goal"] as? String ?? "")
        }
        guard var run = runs[id] else { return ["stop": false] }
        run.heard = Date()
        if let steps = params["steps"] as? Int { run.steps = steps }
        switch phase {
        case "thinking":
            run.activity = "Choosing the next step"
            run.kind = nil
        case "writing":
            run.activity = (params["action"] as? String) ?? "Writing a field's value"
            run.kind = nil
        case "act":
            run.activity = JevRun.readable(params["action"] as? String ?? "")
            run.kind = params["kind"] as? String
            if run.tabID == selectedTab(), let rect = params["rect"] as? [String: Any] {
                mark(rect, scale: params["dpr"] as? Double, tab: run.tabID)
            }
        case "end":
            run.status = params["status"] as? String ?? "error"
            run.summary = params["summary"] as? String
            run.steps = params["steps"] as? Int ?? run.steps
        default:
            break
        }
        runs[id] = run
        NotificationCenter.default.post(name: .jevRunDidChange, object: run)
        if run.tabID == selectedTab() { show(run) }
        if !run.isRunning {
            // Kept a while for the capsule to show how it ended.
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
                MainActor.assumeIsolated {
                    if self?.runs[id]?.isRunning == false { self?.runs[id] = nil }
                }
            }
        }
        return ["stop": run.stopRequested]
    }

    /// After the selected tab changes: shows its run, or nothing.
    func selectionChanged() {
        let tab = selectedTab()
        if let run = runs.values.first(where: { $0.tabID == tab && $0.isRunning }) {
            show(run)
        } else {
            hide(animated: false)
        }
        ring.isHidden = true
    }

    /// After a tab's view moved to the front, back over it.
    func bringToFront() {
        if ring.superview != nil { container.addSubview(ring, positioned: .above, relativeTo: nil) }
        if capsule.superview != nil { container.addSubview(capsule, positioned: .above, relativeTo: nil) }
    }

    func tabClosed(_ id: Int) {
        for run in runs.values where run.tabID == id {
            runs[run.id]?.stopRequested = true
            if shown == run.id { hide(animated: false) }
        }
    }

    // MARK: Capsule

    private func show(_ run: JevRun) {
        hideWork?.cancel()
        hideWork = nil
        if capsule.superview == nil {
            capsule.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(capsule, positioned: .above, relativeTo: nil)
            NSLayoutConstraint.activate([
                capsule.centerXAnchor.constraint(equalTo: container.centerXAnchor),
                capsule.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -Theme.Padding.sheet),
                capsule.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor, constant: Theme.Padding.panel),
                capsule.widthAnchor.constraint(lessThanOrEqualToConstant: 560),
            ])
        }
        let appearing = shown == nil || capsule.isHidden
        shown = run.id
        capsule.update(run)
        if appearing {
            capsule.isHidden = false
            capsule.alphaValue = 0
            withEasing(Theme.Duration.slide) { capsule.animator().alphaValue = 1 }
        }
        if run.isRunning {
            if tick == nil {
                let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.tock() }
                }
                RunLoop.main.add(timer, forMode: .common)
                tick = timer
            }
        } else {
            stopTicking()
            let work = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated { self?.hide(animated: true) }
            }
            hideWork = work
            // Longer for a run that didn't get there, which is worth reading.
            DispatchQueue.main.asyncAfter(deadline: .now() + (run.status == "done" ? 2.5 : 6), execute: work)
        }
    }

    private func tock() {
        guard let id = shown, var run = runs[id], run.isRunning else { return stopTicking() }
        if Date().timeIntervalSince(run.heard) > Self.quietLimit {
            run.status = "error"
            run.summary = "Lost touch with the task; its agent may have stopped"
            runs[id] = run
            NotificationCenter.default.post(name: .jevRunDidChange, object: run)
            show(run)
            return
        }
        capsule.updateClock(run)
    }

    private func stopTicking() {
        tick?.invalidate()
        tick = nil
    }

    private func hide(animated: Bool) {
        stopTicking()
        hideWork?.cancel()
        hideWork = nil
        shown = nil
        guard capsule.superview != nil, !capsule.isHidden else { return }
        guard animated else { capsule.isHidden = true; return }
        fadeOut(capsule, Theme.Duration.slide) { [weak self] in
            guard let self, self.shown == nil else { return }
            self.capsule.isHidden = true
        }
    }

    /// The capsule's Stop: the run's next report is told to stop.
    func stopShownRun() {
        guard let id = shown, runs[id]?.isRunning == true else { return }
        runs[id]?.stopRequested = true
        runs[id]?.activity = "Stopping after this step"
        if let run = runs[id] { capsule.update(run) }
    }

    // MARK: Ring

    /// Rings `rect`, in the page's CSS pixels, for a moment. `scale` is the
    /// page's devicePixelRatio, which takes in its zoom.
    private func mark(_ rect: [String: Any], scale: Double?, tab: Int) {
        guard let view = hostView(tab), let window = view.window,
              let x = rect["x"] as? Double, let y = rect["y"] as? Double,
              let width = rect["width"] as? Double, let height = rect["height"] as? Double
        else { return }
        // CSS pixels to points: the zoom is what devicePixelRatio has over
        // the display's scale.
        let points = CGFloat(scale ?? window.backingScaleFactor) / window.backingScaleFactor
        let top = view.isFlipped ? CGFloat(y) * points : view.bounds.height - CGFloat(y + height) * points
        var frame = NSRect(x: CGFloat(x) * points, y: top, width: CGFloat(width) * points, height: CGFloat(height) * points)
        frame = container.convert(frame, from: view).insetBy(dx: -3, dy: -3)
        // Something the size of the page, such as a body that takes clicks,
        // isn't worth ringing.
        guard frame.width > 4, frame.height > 4, frame.width < container.bounds.width * 0.9 || frame.height < container.bounds.height * 0.9 else { return }
        if ring.superview == nil {
            container.addSubview(ring, positioned: .below, relativeTo: capsule.superview == nil ? nil : capsule)
        }
        ring.flash(at: frame.intersection(container.bounds))
    }
}

/// The ring around the element run_task is about to act on. It lets the
/// mouse through and fades on its own.
final class JevTargetRing: NSView {
    private var generation = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        isHidden = true
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        guard let layer else { return }
        layer.cornerRadius = Theme.Radius.small
        layer.cornerCurve = .continuous
        layer.borderWidth = 2
        layer.borderColor = Theme.accentColor.layerColor
        layer.backgroundColor = Theme.accent(0.12).layerColor
    }

    func flash(at frame: NSRect) {
        generation += 1
        let current = generation
        let moving = !isHidden && alphaValue > 0
        isHidden = false
        if moving {
            // From the last element to this one, so the eye follows.
            withEasing(Theme.Duration.slide) { animator().frame = frame; animator().alphaValue = 1 }
        } else {
            self.frame = frame
            alphaValue = 0
            withEasing(Theme.Duration.quick) { animator().alphaValue = 1 }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.generation == current else { return }
                fadeOut(self, 0.35) {
                    if self.generation == current { self.isHidden = true }
                }
            }
        }
    }
}

/// The capsule at the bottom of the page while run_task works on it.
final class JevActivityView: NSView {
    var onStop: (() -> Void)?

    private let glass = GlassView()
    private let badge = NSView()
    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "Jev")
    private let activity = NSTextField(labelWithString: "")
    private let clock = NSTextField(labelWithString: "")
    private let stopButton = FirstClickButton()
    private var running = false
    /// What it shows, to draw again in another appearance.
    private var run: JevRun?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true

        badge.wantsLayer = true
        badge.layer?.cornerRadius = 11
        icon.translatesAutoresizingMaskIntoConstraints = false
        badge.addSubview(icon)

        title.font = .systemFont(ofSize: Theme.FontSize.secondary, weight: .semibold)
        title.setContentHuggingPriority(.required, for: .horizontal)
        title.setContentCompressionResistancePriority(.required, for: .horizontal)

        activity.font = .systemFont(ofSize: Theme.FontSize.secondary)
        activity.textColor = .secondaryLabelColor
        activity.lineBreakMode = .byTruncatingTail
        activity.maximumNumberOfLines = 1
        activity.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        clock.font = .monospacedDigitSystemFont(ofSize: Theme.FontSize.caption, weight: .regular)
        clock.textColor = .tertiaryLabelColor
        clock.setContentHuggingPriority(.required, for: .horizontal)
        clock.setContentCompressionResistancePriority(.required, for: .horizontal)

        stopButton.isBordered = false
        stopButton.bezelStyle = .regularSquare
        stopButton.restFill = Theme.Fill.rest
        stopButton.plateRadius = 10
        stopButton.attributedTitle = NSAttributedString(string: "Stop", attributes: [
            .font: NSFont.systemFont(ofSize: Theme.FontSize.caption, weight: .medium),
            .foregroundColor: NSColor.labelColor,
        ])
        stopButton.image = Theme.symbol("stop.fill", size: 8, weight: .bold)
        stopButton.imagePosition = .imageLeading
        stopButton.imageHugsTitle = true
        stopButton.contentTintColor = .labelColor
        stopButton.toolTip = "Stop the task after the step under way"
        stopButton.setAccessibilityLabel("Stop Jev")
        stopButton.target = self
        stopButton.action = #selector(stop(_:))
        stopButton.setContentHuggingPriority(.required, for: .horizontal)
        stopButton.setContentCompressionResistancePriority(.required, for: .horizontal)

        let row = NSStackView(views: [badge, title, activity, clock, stopButton])
        row.spacing = 8
        row.setCustomSpacing(6, after: badge)
        row.setCustomSpacing(6, after: title)
        row.setCustomSpacing(10, after: activity)
        row.edgeInsets = NSEdgeInsets(top: 0, left: 6, bottom: 0, right: 6)
        glass.contentView = row
        glass.cornerRadius = 17
        glass.tintColor = NSColor.windowBackgroundColor.dynamic(alpha: 0.6)
        glass.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glass)
        NSLayoutConstraint.activate([
            glass.topAnchor.constraint(equalTo: topAnchor),
            glass.bottomAnchor.constraint(equalTo: bottomAnchor),
            glass.leadingAnchor.constraint(equalTo: leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: trailingAnchor),
            heightAnchor.constraint(equalToConstant: 34),
            badge.widthAnchor.constraint(equalToConstant: 22),
            badge.heightAnchor.constraint(equalToConstant: 22),
            icon.centerXAnchor.constraint(equalTo: badge.centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: badge.centerYAnchor),
            stopButton.heightAnchor.constraint(equalToConstant: 22),
            stopButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 54),
        ])
        // A soft shadow lifts it off a busy page.
        layer?.shadowOpacity = 0.18
        layer?.shadowRadius = 10
        layer?.shadowOffset = CGSize(width: 0, height: -2)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Jev")
    }

    required init?(coder: NSCoder) { fatalError() }

    func update(_ run: JevRun) {
        self.run = run
        let wasRunning = running
        running = run.isRunning
        let (symbol, color): (String, NSColor) = switch run.status {
        case nil: ("bolt.fill", Theme.accentColor)
        case "done": ("checkmark", .systemGreen)
        case "blocked", "out_of_steps": ("exclamationmark", .systemOrange)
        case "stopped": ("stop.fill", .secondaryLabelColor)
        default: ("xmark", .systemRed)
        }
        icon.image = Theme.symbol(symbol, size: run.status == "stopped" ? 9 : 11, weight: .bold)
        icon.contentTintColor = run.isRunning ? .white : color
        badge.layer?.backgroundColor = (run.isRunning ? color : color.withAlphaComponent(0.18)).layerColor
        activity.stringValue = run.isRunning ? run.activity : Self.ending(run)
        activity.textColor = run.isRunning || run.status == "done" ? .secondaryLabelColor : .labelColor
        activity.toolTip = run.goal.isEmpty ? nil : "Goal: " + run.goal
        stopButton.isHidden = !run.isRunning
        stopButton.isEnabled = !run.stopRequested
        updateClock(run)
        setAccessibilityValue(activity.stringValue)
        if running != wasRunning || badge.layer?.animation(forKey: "pulse") == nil { pulse(running && !Theme.reduceMotion) }
        if wasRunning, !running {
            NSAccessibility.post(element: self, notification: .announcementRequested, userInfo: [
                .announcement: "Jev: " + activity.stringValue,
                .priority: NSAccessibilityPriorityLevel.medium.rawValue,
            ])
        }
    }

    /// While running, the step and the time so far; once ended, nothing,
    /// as the summary already says.
    func updateClock(_ run: JevRun) {
        guard run.isRunning else { clock.stringValue = ""; clock.isHidden = true; return }
        clock.isHidden = false
        let seconds = Date().timeIntervalSince(run.started)
        // The step under way, once the first decision is asked for.
        let step = run.activity == JevRun.reading ? 0 : run.steps + 1
        clock.stringValue = (step > 0 ? "Step \(step) · " : "") + String(format: "%.1f s", seconds)
    }

    /// "Done in 2.4 s, 5 steps" stays as it is; the others lose the step
    /// count before their reason, which the chat keeps.
    private static func ending(_ run: JevRun) -> String {
        guard let summary = run.summary, !summary.isEmpty else { return "Ended" }
        return summary.prefix(1).uppercased() + summary.dropFirst()
    }

    /// The badge breathes while Jev works.
    private func pulse(_ on: Bool) {
        badge.layer?.removeAnimation(forKey: "pulse")
        guard on else { return }
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = 1
        animation.toValue = 0.55
        animation.duration = 0.8
        animation.autoreverses = true
        animation.repeatCount = .infinity
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        badge.layer?.add(animation, forKey: "pulse")
    }

    @objc private func stop(_ sender: Any?) {
        onStop?()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        // Layer colors don't follow the appearance on their own.
        if let run { update(run) }
    }
}

/// Stop takes the click that brings the window forward, so a run can be
/// stopped from another app in one click.
private final class FirstClickButton: HoverButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
