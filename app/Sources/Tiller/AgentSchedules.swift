import AppKit
import UserNotifications

struct ScheduleError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// When a scheduled prompt runs, in the local time zone.
enum ScheduleRule: Codable, Equatable {
    case every(minutes: Int)
    case daily(hour: Int, minute: Int)
    case weekdays(hour: Int, minute: Int)
    case cron(String)

    /// The first time after `date` the rule matches. Nil if it never does,
    /// as for a cron expression that names February 30th.
    func nextDate(after date: Date, calendar: Calendar = .current) -> Date? {
        switch self {
        case .every(let minutes):
            return date.addingTimeInterval(TimeInterval(max(1, minutes) * 60))
        case .daily(let hour, let minute):
            return calendar.nextDate(
                after: date, matching: DateComponents(hour: hour, minute: minute, second: 0), matchingPolicy: .nextTime
            )
        case .weekdays(let hour, let minute):
            var from = date
            for _ in 0..<8 {
                guard let next = calendar.nextDate(
                    after: from, matching: DateComponents(hour: hour, minute: minute, second: 0), matchingPolicy: .nextTime
                ) else { return nil }
                if !calendar.isDateInWeekend(next) { return next }
                from = next
            }
            return nil
        case .cron(let text):
            return (try? CronExpression(text))?.nextDate(after: date, calendar: calendar)
        }
    }

    /// Checks a cron expression, and that the rule ever runs.
    func validate() throws {
        switch self {
        case .every(let minutes):
            guard minutes >= 1 else { throw ScheduleError("Runs at most once a minute.") }
        case .daily, .weekdays:
            break
        case .cron(let text):
            let expression = try CronExpression(text)
            guard expression.nextDate(after: Date()) != nil else { throw ScheduleError("This expression never matches a date.") }
        }
    }

    var displayText: String {
        switch self {
        case .every(let minutes):
            if minutes == 60 { return "Every hour" }
            if minutes % 60 == 0 { return "Every \(minutes / 60) hours" }
            return minutes == 1 ? "Every minute" : "Every \(minutes) minutes"
        case .daily(let hour, let minute):
            return "Every day at " + Self.time(hour, minute)
        case .weekdays(let hour, let minute):
            return "Weekdays at " + Self.time(hour, minute)
        case .cron(let text):
            return "Cron: " + text
        }
    }

    private static func time(_ hour: Int, _ minute: Int) -> String {
        let date = Calendar.current.date(from: DateComponents(hour: hour, minute: minute)) ?? Date()
        return date.formatted(date: .omitted, time: .shortened)
    }
}

/// A five-field cron expression: minute, hour, day of month, month and day
/// of week. Each field takes `*`, numbers, ranges (`1-5`), steps (`*/15`,
/// `0-30/10`) and lists of those. Months and days of week also take their
/// three-letter English names, and Sunday is 0 or 7. As in cron, when both
/// day fields are restricted a day matching either one runs.
struct CronExpression: Equatable {
    let minutes: [Int]
    let hours: [Int]
    let days: Set<Int>
    let months: Set<Int>
    let weekdays: Set<Int>
    let anyDay: Bool
    let anyWeekday: Bool

    private static let monthNames = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
    private static let dayNames = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"]

    init(_ text: String) throws {
        let fields = text.split(whereSeparator: \.isWhitespace)
        guard fields.count == 5 else {
            throw ScheduleError("A cron expression has five fields: minute, hour, day, month and day of week.")
        }
        minutes = try Self.field(fields[0], 0...59, name: "minute").sorted()
        hours = try Self.field(fields[1], 0...23, name: "hour").sorted()
        days = try Self.field(fields[2], 1...31, name: "day")
        months = try Self.field(fields[3], 1...12, name: "month", names: Self.monthNames, firstName: 1)
        weekdays = Set(try Self.field(fields[4], 0...7, name: "day of week", names: Self.dayNames, firstName: 0).map { $0 % 7 })
        anyDay = fields[2].hasPrefix("*")
        anyWeekday = fields[4].hasPrefix("*")
    }

    private static func field(
        _ text: Substring, _ range: ClosedRange<Int>, name: String, names: [String] = [], firstName: Int = 0
    ) throws -> Set<Int> {
        let bad = ScheduleError("“\(text)” isn't a valid \(name). Use \(range.lowerBound)–\(range.upperBound), *, ranges, steps or lists.")
        func value(_ part: Substring) throws -> Int {
            if let number = Int(part) { return number }
            if let index = names.firstIndex(of: part.lowercased()) { return index + firstName }
            throw bad
        }
        var values = Set<Int>()
        for part in text.split(separator: ",", omittingEmptySubsequences: false) {
            let pieces = part.split(separator: "/", omittingEmptySubsequences: false)
            guard pieces.count <= 2, !pieces[0].isEmpty else { throw bad }
            var step = 1
            if pieces.count == 2 {
                guard let number = Int(pieces[1]), number > 0 else { throw bad }
                step = number
            }
            let base = pieces[0]
            let lower: Int, upper: Int
            if base == "*" {
                (lower, upper) = (range.lowerBound, range.upperBound)
            } else if let dash = base.firstIndex(of: "-") {
                lower = try value(base[..<dash])
                upper = try value(base[base.index(after: dash)...])
            } else {
                lower = try value(base)
                // `5/15` means from 5 to the end, every 15.
                upper = pieces.count == 2 ? range.upperBound : lower
            }
            guard range.contains(lower), range.contains(upper), lower <= upper else { throw bad }
            values.formUnion(stride(from: lower, through: upper, by: step))
        }
        return values
    }

    /// The first minute after `date` that matches. Looks a day at a time,
    /// up to five years ahead so a February 29th is found.
    func nextDate(after date: Date, calendar: Calendar = .current) -> Date? {
        var day = calendar.startOfDay(for: date)
        for _ in 0..<(366 * 5) {
            let parts = calendar.dateComponents([.year, .month, .day, .weekday], from: day)
            if let year = parts.year, let month = parts.month, let dayOfMonth = parts.day, let weekday = parts.weekday,
                months.contains(month), matches(day: dayOfMonth, weekday: weekday - 1)
            {
                for hour in hours {
                    for minute in minutes {
                        let wanted = DateComponents(year: year, month: month, day: dayOfMonth, hour: hour, minute: minute)
                        guard let candidate = calendar.date(from: wanted), candidate > date else { continue }
                        // A time skipped when clocks go forward doesn't exist that day.
                        let got = calendar.dateComponents([.day, .hour, .minute], from: candidate)
                        guard got.day == dayOfMonth, got.hour == hour, got.minute == minute else { continue }
                        return candidate
                    }
                }
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { return nil }
            day = next
        }
        return nil
    }

    private func matches(day: Int, weekday: Int) -> Bool {
        let dayMatches = days.contains(day), weekdayMatches = weekdays.contains(weekday)
        return anyDay || anyWeekday ? dayMatches && weekdayMatches : dayMatches || weekdayMatches
    }
}

/// A prompt the agent panel sends by itself on a schedule, in a new chat.
struct ScheduledPrompt: Codable, Equatable {
    enum Result: Codable, Equatable {
        case running
        case finished
        case failed(String)
        case stopped
        case skipped(String)

        var displayText: String {
            switch self {
            case .running: "Running…"
            case .finished: "Finished"
            case .failed(let message): "Failed: " + message
            case .stopped: "Stopped"
            case .skipped(let reason): "Skipped: " + reason
            }
        }

        var isProblem: Bool {
            switch self {
            case .failed, .skipped: true
            default: false
            }
        }
    }

    let id: String
    var name: String
    /// What is sent. A leading `/name` calls that skill.
    var prompt: String
    var kind: AgentKind
    /// The provider its runs use, if the user added one for its CLI.
    var provider: String?
    var tools: [AgentTool]
    /// The model, effort, context and fast mode its runs use. Nil follows
    /// Settings' for its agent.
    var modelOptions: AgentModelOptions?
    var rule: ScheduleRule
    var enabled: Bool
    /// When it next runs. Nil while it is off or its rule never matches.
    var nextRun: Date?
    var lastRun: Date?
    var lastResult: Result?
    /// The chat of the last run.
    var lastChat: String?

    init(name: String, prompt: String, choice: AgentChoice, tools: [AgentTool], rule: ScheduleRule) {
        id = UUID().uuidString
        self.name = name
        self.prompt = prompt
        kind = choice.kind
        provider = choice.provider
        self.tools = tools
        self.rule = rule
        enabled = true
    }

    var choice: AgentChoice {
        get { AgentChoice(kind, provider: provider) }
        set {
            kind = newValue.kind
            provider = newValue.provider
        }
    }

    /// What has to hold before it is saved, from Settings or a chat.
    func validate() throws {
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ScheduleError("Write the prompt to send.")
        }
        try rule.validate()
    }
}

/// The profile's scheduled prompts, in `agent-schedules.json` in its folder.
@MainActor
final class AgentScheduleStore {
    private(set) var schedules: [ScheduledPrompt]
    private let folder: String
    private let path: String

    init(folder: String) {
        self.folder = folder
        path = folder + "/agent-schedules.json"
        let data = try? Data(contentsOf: URL(fileURLWithPath: path))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        schedules = data.flatMap { try? decoder.decode([ScheduledPrompt].self, from: $0) } ?? []
        // A run the last Tiller didn't see end ended with it.
        for index in schedules.indices where schedules[index].lastResult == .running {
            schedules[index].lastResult = .stopped
        }
    }

    func schedule(_ id: String) -> ScheduledPrompt? {
        schedules.first { $0.id == id }
    }

    /// Adds or replaces `schedule`, timing its next run from now when it is
    /// new, turned on or given a new rule. Renaming it or changing its prompt
    /// keeps the run already due, so an edit doesn't restart the countdown.
    func save(_ schedule: ScheduledPrompt) {
        var schedule = schedule
        if let old = self.schedule(schedule.id), old.enabled, schedule.enabled, old.rule == schedule.rule,
            let next = old.nextRun {
            schedule.nextRun = next
        } else {
            schedule.nextRun = schedule.enabled ? schedule.rule.nextDate(after: Date()) : nil
        }
        if let index = schedules.firstIndex(where: { $0.id == schedule.id }) {
            schedules[index] = schedule
        } else {
            schedules.append(schedule)
        }
        write()
    }

    func setEnabled(_ enabled: Bool, for id: String) {
        guard var schedule = schedule(id), schedule.enabled != enabled else { return }
        schedule.enabled = enabled
        save(schedule)
    }

    func remove(_ ids: Set<String>) {
        schedules.removeAll { ids.contains($0.id) }
        write()
    }

    /// Times the next run from `date`.
    func advance(_ id: String, after date: Date) {
        update(id) { $0.nextRun = $0.enabled ? $0.rule.nextDate(after: date) : nil }
    }

    /// Times every enabled schedule's next run from now, for a change of time zone.
    func rescheduleAll() {
        let now = Date()
        for index in schedules.indices {
            schedules[index].nextRun = schedules[index].enabled ? schedules[index].rule.nextDate(after: now) : nil
        }
        write()
    }

    func record(_ result: ScheduledPrompt.Result, for id: String, at date: Date? = nil, chat: String? = nil) {
        update(id) { schedule in
            schedule.lastResult = result
            if let date { schedule.lastRun = date }
            if let chat { schedule.lastChat = chat }
        }
    }

    private func update(_ id: String, _ change: (inout ScheduledPrompt) -> Void) {
        guard let index = schedules.firstIndex(where: { $0.id == id }) else { return }
        let before = schedules[index]
        change(&schedules[index])
        if schedules[index] != before { write() }
    }

    private func write() {
        do {
            try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(schedules).write(to: URL(fileURLWithPath: path), options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        } catch {
            NSLog("Tiller: could not save scheduled prompts: %@", error.localizedDescription)
        }
        NotificationCenter.default.post(name: .agentSchedulesDidChange, object: self)
    }
}

/// How a scheduled run's first turn ended.
enum AgentRunOutcome {
    /// With the agent's last text, if it wrote any.
    case finished(String?)
    case failed(String)
    case stopped
}

/// Sends a profile's scheduled prompts when they are due, in its window.
/// One timer is armed for the soonest; it is re-armed when schedules change, the Mac wakes or the clock
/// changes, and never further than ten minutes out, so a timer that slept
/// with the Mac can't run late by much. A run missed while Tiller was closed
/// or the Mac slept happens once, then the rule takes over again.
@MainActor
final class AgentScheduler: NSObject {
    private weak var profile: ProfileContext?
    private var browser: BrowserWindowController? { profile?.window }
    private var timer: Timer?
    /// Runs wait until this, so a launch finishes before missed runs start.
    private var notBefore = Date.distantPast
    /// The chat each schedule's latest run is in.
    private var running: [String: String] = [:]
    private var started = false
    private let store: AgentScheduleStore

    init(profile: ProfileContext) {
        self.profile = profile
        store = profile.schedules
    }

    func start() {
        guard !started else { return arm() }
        started = true
        notBefore = Date().addingTimeInterval(5)
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(changed(_:)), name: .agentSchedulesDidChange, object: store)
        center.addObserver(self, selector: #selector(changed(_:)), name: .NSSystemClockDidChange, object: nil)
        center.addObserver(self, selector: #selector(timeZoneChanged(_:)), name: .NSSystemTimeZoneDidChange, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(changed(_:)), name: NSWorkspace.didWakeNotification, object: nil
        )
        ScheduleNotifications.shared.install()
        arm()
    }

    /// The profile closed: no more runs.
    func stop() {
        started = false
        timer?.invalidate()
        timer = nil
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    @objc private func changed(_ notification: Notification) { arm() }

    @objc private func timeZoneChanged(_ notification: Notification) { store.rescheduleAll() }

    private func arm() {
        timer?.invalidate()
        timer = nil
        guard started, let next = store.schedules.filter(\.enabled).compactMap(\.nextRun).min() else { return }
        let fire = min(max(next, notBefore), Date().addingTimeInterval(600))
        let timer = Timer(fire: fire, interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.runDue() }
        }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func runDue() {
        let now = Date()
        if now >= notBefore {
            let due = store.schedules.filter { $0.enabled && ($0.nextRun ?? .distantFuture) <= now }
            for schedule in due.sorted(by: { $0.nextRun! < $1.nextRun! }) {
                store.advance(schedule.id, after: now)
                run(schedule)
            }
        }
        arm()
    }

    /// Runs `id` now, on or off, without moving its next run. For Run Now.
    func runNow(_ id: String) {
        guard let schedule = store.schedule(id) else { return }
        run(schedule)
    }

    private func run(_ schedule: ScheduledPrompt) {
        let now = Date()
        guard let browser else {
            return store.record(.skipped("no browser window was open"), for: schedule.id, at: now)
        }
        if let chat = running[schedule.id], browser.isAgentChatBusy(chat) {
            return store.record(.skipped("the last run was still working"), for: schedule.id, at: now)
        }
        askForNotifications()
        let id = schedule.id, name = schedule.name
        let chat = browser.runScheduledPrompt(schedule) { [weak self] chat, outcome in
            self?.finished(id: id, name: name, chat: chat, outcome: outcome)
        }
        running[schedule.id] = chat
        store.record(.running, for: schedule.id, at: now, chat: chat)
    }

    private func finished(id: String, name: String, chat: String, outcome: AgentRunOutcome) {
        if running[id] == chat { running[id] = nil }
        let result: ScheduledPrompt.Result, body: String
        switch outcome {
        case .finished(let text):
            result = .finished
            let line = text?.split(whereSeparator: \.isNewline).first { !$0.allSatisfy(\.isWhitespace) }
            body = line.map { $0.count > 200 ? String($0.prefix(200)) + "…" : String($0) } ?? "Finished."
        case .failed(let message):
            result = .failed(message)
            body = "Failed: " + message
        case .stopped:
            result = .stopped
            body = "Stopped."
        }
        // A later run of the same schedule owns the result now.
        if store.schedule(id)?.lastChat == chat { store.record(result, for: id) }
        guard let profile else { return }
        ScheduleNotifications.shared.notify(title: name, body: body, chat: chat, profile: profile.id)
    }

    func askForNotifications() {
        ScheduleNotifications.shared.askForPermission()
    }
}

/// The notifications scheduled runs post, for every profile. Clicking one
/// shows its chat in its profile's window.
@MainActor
final class ScheduleNotifications: NSObject, UNUserNotificationCenterDelegate {
    static let shared = ScheduleNotifications()

    private var asked = false

    func install() {
        UNUserNotificationCenter.current().delegate = self
    }

    /// Asked once per launch at most; macOS shows the prompt only the first time.
    func askForPermission() {
        guard !asked else { return }
        asked = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func notify(title: String, body: String, chat: String, profile: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.userInfo = ["chat": chat, "profile": profile]
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error { NSLog("Tiller: could not post a notification: %@", error.localizedDescription) }
        }
    }

    /// Clicking a run's notification shows its chat.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let info = response.notification.request.content.userInfo
        let chat = info["chat"] as? String
        let profile = info["profile"] as? String ?? Profiles.defaultID
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                guard let chat, let context = ProfileContext.opened(profile) else { return }
                context.show()
                context.window?.showAgentChat(chat)
            }
        }
        completionHandler()
    }

    /// Shown while Tiller is in front too.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list])
    }
}

// MARK: Control socket

/// list_schedules, save_schedule, delete_schedule and run_schedule from
/// tiller_mcp. A chat can't give a schedule built-in tools it doesn't have
/// itself, nor change the prompt, agent or tools of one that has more, and a
/// chat a schedule started can only list them, so an unattended run can't
/// make more runs. Requests carry the chat's id as `chat`; one without it
/// counts as a chat with no built-in tools.
@MainActor
enum AgentScheduleControl {
    private struct Caller {
        var kind: AgentChoice?
        var tools: Set<AgentTool> = []
        var isScheduledRun = false
    }

    /// The tools a schedule's runs have. Antigravity CLI can't be limited,
    /// so its runs have them all.
    private static func effectiveTools(of schedule: ScheduledPrompt) -> Set<AgentTool> {
        schedule.kind == .agy ? Set(AgentTool.allCases) : Set(schedule.tools)
    }

    static func control(_ method: String, params: [String: Any], profile: ProfileContext) throws -> Any {
        let store = profile.schedules
        let caller = params["user"] as? Bool == true
            ? Caller(tools: Set(AgentTool.allCases)) : caller(params["chat"] as? String, profile: profile)
        if method != "schedules.list", caller.isScheduledRun {
            throw ControlError("A scheduled run can list schedules but not change or run them. Ask the user to do it from a chat they started, or in Settings > Scheduled.")
        }
        switch method {
        case "schedules.list":
            return [
                "schedules": store.schedules.map { describe($0, profile: profile) },
                "agents": profile.providers.all.map { ["agent": $0.rawValue, "name": profile.providers.displayName($0)] },
            ]
        case "schedules.save":
            return try save(params, caller: caller, profile: profile)
        case "schedules.delete":
            let schedule = try find(params, in: store)
            store.remove([schedule.id])
            return ["deleted": schedule.name, "id": schedule.id]
        case "schedules.run":
            let schedule = try find(params, in: store)
            profile.scheduler.runNow(schedule.id)
            let after = store.schedule(schedule.id)
            return ["ran": schedule.name, "id": schedule.id, "result": after?.lastResult?.displayText ?? "", "chat": after?.lastChat ?? ""]
        default:
            throw ControlError("unknown method \(method)")
        }
    }

    private static func caller(_ chat: String?, profile: ProfileContext) -> Caller {
        guard let chat, let conversation = profile.agentHistory.conversation(chat) else { return Caller() }
        return Caller(
            kind: conversation.choice,
            tools: conversation.kind == .agy ? Set(AgentTool.allCases) : Set(conversation.tools ?? profile.settings.agentTools),
            isScheduledRun: conversation.scheduleID != nil
        )
    }

    private static func find(_ params: [String: Any], in store: AgentScheduleStore) throws -> ScheduledPrompt {
        guard let id = params["id"] as? String, !id.isEmpty else { throw ControlError("id is required. Get it from list_schedules.") }
        guard let schedule = store.schedule(id) else { throw ControlError("No scheduled prompt has the id \(id). Get it from list_schedules.") }
        return schedule
    }

    private static func save(_ params: [String: Any], caller: Caller, profile: ProfileContext) throws -> Any {
        let store = profile.schedules, providers = profile.providers
        let original = (params["id"] as? String).map(\.isEmpty) == false ? try find(params, in: store) : nil

        let prompt = (params["prompt"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let rule = try params["rule"].map(parseRule)
        let kind = try (params["agent"] as? String).map { name in
            guard let kind = AgentChoice(rawValue: name), providers.exists(kind) else {
                throw ControlError("agent is one of \(providers.all.map(\.rawValue).joined(separator: ", ")).")
            }
            return kind
        }
        let modelChange = try parseModelOptions(params)
        let tools = try (params["tools"] as? [Any]).map { list in
            try list.map { item in
                guard let name = item as? String, let tool = AgentTool(rawValue: name) else {
                    throw ControlError("tools are any of read, write and shell.")
                }
                return tool
            }
        }

        var schedule: ScheduledPrompt
        if let original {
            schedule = original
            let changesWhatRuns = (prompt != nil && prompt != original.prompt) || (kind != nil && kind != original.choice)
                || (tools != nil && Set(tools!) != Set(original.tools))
            if changesWhatRuns, !effectiveTools(of: original).isSubset(of: caller.tools) {
                throw ControlError("“\(original.name)” can \(names(effectiveTools(of: original).subtracting(caller.tools))), which this chat can't, so its prompt, agent and tools can only be changed in Settings > Scheduled. Its name, timing and whether it is on can still be changed here.")
            }
        } else {
            guard let prompt, !prompt.isEmpty else { throw ControlError("prompt is required for a new schedule.") }
            guard let rule else { throw ControlError("rule is required for a new schedule.") }
            schedule = ScheduledPrompt(
                name: AgentConversation.title(from: prompt), prompt: prompt, choice: caller.kind ?? providers.current, tools: [], rule: rule
            )
        }
        if let tools {
            let extra = Set(tools).subtracting(caller.tools)
            guard extra.isEmpty else {
                throw ControlError("This chat can't \(names(extra)), so a schedule it makes can't either. The user can turn that on in Settings > Scheduled.")
            }
            schedule.tools = AgentTool.allCases.filter(tools.contains)
        }
        if let prompt { schedule.prompt = prompt }
        if let rule { schedule.rule = rule }
        if let kind, kind != schedule.choice {
            schedule.choice = kind
            // Options for one agent don't carry over to another.
            schedule.modelOptions = nil
        }
        if let modelChange {
            var options = schedule.modelOptions ?? profile.settings.agentModelOptions(for: schedule.choice)
            modelChange(&options)
            try checkModelOptions(options, for: schedule.choice, providers: providers)
            schedule.modelOptions = options
        }
        if let name = (params["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            schedule.name = name
        }
        if let enabled = params["enabled"] as? Bool { schedule.enabled = enabled }
        if schedule.kind == .agy, !effectiveTools(of: schedule).isSubset(of: caller.tools) {
            throw ControlError("\(AgentKind.agy.displayName) always has every tool, and this chat can't \(names(effectiveTools(of: schedule).subtracting(caller.tools))), so it can't schedule it. The user can in Settings > Scheduled.")
        }
        do {
            try schedule.validate()
        } catch {
            throw ControlError(error.localizedDescription)
        }
        store.save(schedule)
        ScheduleNotifications.shared.askForPermission()
        var result = describe(store.schedule(schedule.id) ?? schedule, profile: profile)
        result["created"] = original == nil
        return result
    }

    /// `model`, `effort`, `context` and `fast`, where an empty string goes
    /// back to the CLI's own. Nil when none is given.
    private static func parseModelOptions(_ params: [String: Any]) throws -> ((inout AgentModelOptions) -> Void)? {
        func text(_ key: String) throws -> String?? {
            guard let value = params[key] else { return nil }
            guard let string = value as? String else { throw ControlError("\(key) is a string; an empty one means the CLI's own.") }
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return .some(trimmed.isEmpty ? nil : trimmed)
        }
        let model = try text("model"), effort = try text("effort"), context = try text("context")
        let fast = params["fast"] as? Bool
        guard model != nil || effort != nil || context != nil || fast != nil else { return nil }
        return { options in
            if let model { options.model = model }
            if let effort { options.effort = effort }
            if let context { options.context = context }
            if let fast { options.fast = fast }
        }
    }

    /// Refuses options the agent doesn't have, saying which it does.
    private static func checkModelOptions(_ options: AgentModelOptions, for kind: AgentChoice, providers: AgentProviderStore) throws {
        let name = providers.displayName(kind)
        if let effort = options.effort, !kind.effortLevels(model: options.model).contains(effort) {
            let levels = kind.effortLevels(model: options.model)
            throw ControlError("effort for \(name) is one of \(levels.joined(separator: ", ")), or empty for its own.")
        }
        if let context = options.context {
            let sizes = kind.contextSizes.map(\.value)
            if sizes.isEmpty { throw ControlError("\(name) has no context window choice.") }
            if !sizes.contains(context) { throw ControlError("context for \(name) is one of \(sizes.joined(separator: ", ")).") }
            if kind.kind == .claude, options.model == nil { throw ControlError("context 1m for \(name) needs a model, such as opus.") }
        }
        if options.fast, kind.fastTier(model: options.model) == nil {
            throw ControlError("\(name) has no fast mode\(kind.kind == .codex ? " for this model" : "").")
        }
    }

    /// `{"every_minutes": 30}`, `{"daily": "09:00"}`, `{"weekdays": "09:00"}`
    /// or `{"cron": "0 9 * * 1-5"}`.
    private static func parseRule(_ value: Any) throws -> ScheduleRule {
        let usage = "rule is one of {\"every_minutes\": 30}, {\"daily\": \"09:00\"}, {\"weekdays\": \"09:00\"} or {\"cron\": \"0 9 * * 1-5\"}."
        guard let object = value as? [String: Any], object.count == 1, let (key, field) = object.first else {
            throw ControlError(usage)
        }
        func time(_ field: Any) throws -> (Int, Int) {
            let parts = (field as? String)?.split(separator: ":").compactMap { Int($0) } ?? []
            guard parts.count == 2, (0...23).contains(parts[0]), (0...59).contains(parts[1]) else {
                throw ControlError("\(key) takes a 24-hour time, HH:MM.")
            }
            return (parts[0], parts[1])
        }
        switch key {
        case "every_minutes":
            guard let minutes = (field as? NSNumber)?.intValue, minutes >= 1 else { throw ControlError("every_minutes is a whole number, 1 or more.") }
            return .every(minutes: minutes)
        case "daily":
            let (hour, minute) = try time(field)
            return .daily(hour: hour, minute: minute)
        case "weekdays":
            let (hour, minute) = try time(field)
            return .weekdays(hour: hour, minute: minute)
        case "cron":
            guard let text = field as? String else { throw ControlError(usage) }
            return .cron(text.trimmingCharacters(in: .whitespaces))
        default:
            throw ControlError(usage)
        }
    }

    private static func describe(_ schedule: ScheduledPrompt, profile: ProfileContext) -> [String: Any] {
        let dates = ISO8601DateFormatter()
        var rule: [String: Any]
        switch schedule.rule {
        case .every(let minutes): rule = ["every_minutes": minutes]
        case .daily(let hour, let minute): rule = ["daily": String(format: "%02d:%02d", hour, minute)]
        case .weekdays(let hour, let minute): rule = ["weekdays": String(format: "%02d:%02d", hour, minute)]
        case .cron(let text): rule = ["cron": text]
        }
        rule["text"] = schedule.rule.displayText
        var result: [String: Any] = [
            "id": schedule.id, "name": schedule.name, "prompt": schedule.prompt, "agent": schedule.choice.rawValue,
            "tools": schedule.tools.map(\.rawValue), "rule": rule, "enabled": schedule.enabled,
        ]
        let options = schedule.modelOptions ?? profile.settings.agentModelOptions(for: schedule.choice)
        if let model = options.model { result["model"] = model }
        if let effort = options.effort { result["effort"] = effort }
        if let context = options.context { result["context"] = context }
        if options.fast { result["fast"] = true }
        if let next = schedule.nextRun { result["next_run"] = dates.string(from: next) }
        if let last = schedule.lastRun { result["last_run"] = dates.string(from: last) }
        if let outcome = schedule.lastResult { result["last_result"] = outcome.displayText }
        return result
    }

    private static func names(_ tools: Set<AgentTool>) -> String {
        AgentTool.allCases.filter(tools.contains).map { $0.displayName.lowercased() }.joined(separator: " or ")
    }
}

extension Notification.Name {
    /// Posted when a scheduled prompt is added, changed, run or removed.
    static let agentSchedulesDidChange = Notification.Name("TillerAgentSchedulesDidChange")
}
