import AppKit

// MARK: Scheduled pane

/// Settings > Scheduled: the profile's scheduled prompts, with buttons to
/// add, edit, run and remove them.
final class ScheduledSettingsPane: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSMenuItemValidation {
    static let paneTitle = "Scheduled"

    private let table = SettingsTableView()
    private let addButton = NSButton(title: "Add…", target: nil, action: nil)
    private let editButton = NSButton(title: "Edit…", target: nil, action: nil)
    private let runButton = NSButton(title: "Run Now", target: nil, action: nil)
    private let removeButton = NSButton(title: "Remove", target: nil, action: nil)
    private let note = SettingsPane.wrappingNote(width: SettingsPane.tableWidth)
    private var placeholder: NSTextField?
    /// The editor sheet while it is open.
    private var editorWindow: NSWindow?
    private var store: AgentScheduleStore { profile.schedules }
    private var schedules: [ScheduledPrompt] { store.schedules }
    private let profile: ProfileContext

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        formatter.doesRelativeDateFormatting = true
        return formatter
    }()

    init(profile: ProfileContext) {
        self.profile = profile
        super.init(nibName: nil, bundle: nil)
        title = Self.paneTitle
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        for (id, title, width) in [
            ("on", "On", 30.0), ("name", "Name", 130.0), ("rule", "Runs", 140.0), ("next", "Next Run", 120.0),
            ("last", "Last Run", 180.0),
        ] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = title
            column.width = width
            table.addTableColumn(column)
        }
        table.allowsMultipleSelection = true
        table.style = .inset
        table.rowHeight = 22
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(edit(_:))
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let (tableBox, placeholder) = SettingsPane.withPlaceholder(scroll, "No Scheduled Prompts")
        self.placeholder = placeholder

        for (button, action) in [
            (addButton, #selector(add(_:))),
            (editButton, #selector(edit(_:))),
            (runButton, #selector(runNow(_:))),
            (removeButton, #selector(remove(_:))),
        ] {
            button.target = self
            button.action = action
        }
        let buttons = NSStackView(views: [addButton, editButton, NSView(), runButton, removeButton])
        buttons.spacing = 8

        let stack = NSStackView(views: [tableBox, buttons, note])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        let view = NSView()
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            scroll.widthAnchor.constraint(equalToConstant: SettingsPane.tableWidth),
            scroll.heightAnchor.constraint(equalToConstant: SettingsPane.tableHeight),
            buttons.widthAnchor.constraint(equalTo: scroll.widthAnchor),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -20),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
        ])
        self.view = view
        view.layoutSubtreeIfNeeded()
        preferredContentSize = view.fittingSize
        NotificationCenter.default.addObserver(self, selector: #selector(reload(_:)), name: .agentSchedulesDidChange, object: nil)
        reload(nil)
        showDefaultNote()
        #if DEBUG
        Self.shown = self
        #endif
    }

    @objc private func reload(_ notification: Notification?) {
        let selected = table.selectedRowIndexes
        table.reloadData()
        table.selectRowIndexes(selected.filteredIndexSet { $0 < schedules.count }, byExtendingSelection: false)
        updateControls()
    }

    private func updateControls() {
        let count = table.selectedRowIndexes.count
        editButton.isEnabled = count == 1
        runButton.isEnabled = count == 1
        removeButton.isEnabled = count > 0
        placeholder?.isHidden = !schedules.isEmpty
    }

    private func showDefaultNote() {
        SettingsPane.show(
            "Each run sends its prompt in a new chat in the agent panel, while this profile's Tiller is open. "
                + "A run missed while Tiller was closed or the Mac slept happens once when it's back. "
                + "Agents can also create and change these when asked in a chat.",
            in: note
        )
    }

    func numberOfRows(in tableView: NSTableView) -> Int { schedules.count }

    func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
        guard schedules.indices.contains(row) else { return nil }
        let schedule = schedules[row]
        func label(_ text: String, secondary: Bool = true) -> NSTableCellView {
            let cell = SettingsPane.textCell(tableView, text)
            cell.textField?.textColor = secondary ? .secondaryLabelColor : .labelColor
            cell.textField?.toolTip = text
            return cell
        }
        switch column?.identifier.rawValue {
        case "on":
            let checkbox = NSButton(checkboxWithTitle: "", target: self, action: #selector(toggleEnabled(_:)))
            checkbox.tag = row
            checkbox.state = schedule.enabled ? .on : .off
            checkbox.setAccessibilityLabel("\(schedule.name) On")
            return checkbox
        case "name":
            let name = label(schedule.name, secondary: false)
            name.textField?.toolTip = schedule.prompt
            return name
        case "rule":
            return label(schedule.rule.displayText)
        case "next":
            if !schedule.enabled { return label("Off") }
            return label(schedule.nextRun.map(Self.dateFormatter.string(from:)) ?? "Never")
        default:
            guard let date = schedule.lastRun else { return label("Never") }
            let text = Self.dateFormatter.string(from: date) + (schedule.lastResult.map { " · " + $0.displayText } ?? "")
            let last = label(text)
            if schedule.lastResult?.isProblem == true { last.textField?.textColor = .systemRed }
            return last
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateControls()
    }

    @objc private func toggleEnabled(_ sender: NSButton) {
        guard schedules.indices.contains(sender.tag) else { return }
        store.setEnabled(sender.state == .on, for: schedules[sender.tag].id)
    }

    @objc private func add(_ sender: Any?) {
        presentEditor(for: nil)
    }

    /// Edit > Delete and the Delete key remove the selected schedules, after asking.
    @objc func delete(_ sender: Any?) {
        guard removeButton.isEnabled else { return NSSound.beep() }
        remove(sender)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        menuItem.action == #selector(delete(_:)) ? removeButton.isEnabled : true
    }

    @objc private func edit(_ sender: Any?) {
        // A double-click edits the row clicked, a button the one selected.
        let row = sender as? NSTableView === table && table.clickedRow >= 0 ? table.clickedRow : table.selectedRow
        guard schedules.indices.contains(row) else { return }
        presentEditor(for: schedules[row])
    }

    private func presentEditor(for schedule: ScheduledPrompt?) {
        guard let window = view.window, editorWindow == nil else { return }
        let editor = ScheduleEditorController(schedule: schedule, profile: profile)
        let sheet = NSWindow(contentViewController: editor)
        sheet.styleMask = [.titled]
        sheet.isReleasedWhenClosed = false
        editor.onDone = { [weak self, weak window, weak sheet] saved in
            if let sheet { window?.endSheet(sheet) }
            self?.editorWindow = nil
            guard let saved else { return }
            self?.store.save(saved)
            ScheduleNotifications.shared.askForPermission()
        }
        editorWindow = sheet
        window.beginSheet(sheet)
    }

    #if DEBUG
    /// The pane last loaded, for `ui.scheduleEditor`.
    static weak var shown: ScheduledSettingsPane?

    /// Opens the editor for a new schedule with `prompt` typed in.
    func addForTesting(prompt: String) {
        presentEditor(for: nil)
        (editorWindow?.contentViewController as? ScheduleEditorController)?.setPromptForTesting(prompt)
    }
    #endif

    @objc private func runNow(_ sender: Any?) {
        guard table.selectedRowIndexes.count == 1, schedules.indices.contains(table.selectedRow) else { return }
        profile.scheduler.runNow(schedules[table.selectedRow].id)
    }

    /// Asks first. Chats from earlier runs stay in history.
    @objc private func remove(_ sender: Any?) {
        let indexes = table.selectedRowIndexes
        let picked = indexes.compactMap { schedules.indices.contains($0) ? schedules[$0] : nil }
        guard !picked.isEmpty, let window = view.window else { return }
        let alert = NSAlert()
        alert.messageText = picked.count == 1 ? "Remove “\(picked[0].name)”?" : "Remove \(picked.count) scheduled prompts?"
        alert.informativeText = "It stops running. Chats from earlier runs stay in the agent panel's history."
        alert.addButton(withTitle: "Remove")
        alert.buttons[0].hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            MainActor.assumeIsolated {
                guard let self else { return }
                self.store.remove(Set(picked.map(\.id)))
                self.table.deselectAll(nil)
            }
        }
    }
}

// MARK: Editor

/// A button that lets its key equivalent through to the focused view while
/// `passesKeyEquivalent` says so.
final class PassingButton: NSButton {
    var passesKeyEquivalent: () -> Bool = { false }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        passesKeyEquivalent() ? false : super.performKeyEquivalent(with: event)
    }
}

/// The sheet that adds or edits a scheduled prompt: its name, agent, tools,
/// when it runs and the prompt, where `/` picks a skill as in the panel.
final class ScheduleEditorController: NSViewController, NSTextViewDelegate, NSTextFieldDelegate {
    /// Called with the edited schedule, or nil when cancelled.
    var onDone: ((ScheduledPrompt?) -> Void)?

    private enum RuleKind: Int, CaseIterable {
        case every, daily, weekdays, cron

        var title: String {
            switch self {
            case .every: "Every…"
            case .daily: "Every Day"
            case .weekdays: "Weekdays"
            case .cron: "Cron Expression"
            }
        }
    }

    private let original: ScheduledPrompt?
    private let grid = NSGridView()
    private let nameField = NSTextField()
    private var kindPopUp: NSPopUpButton?
    private var toolBoxes: [NSButton] = []
    private lazy var modelButton = NSButton(title: "", target: self, action: #selector(chooseModel(_:)))
    /// Nil follows Settings' for the agent.
    private var modelOptions: AgentModelOptions?
    private let rulePopUp = NSPopUpButton()
    private let intervalField = NSTextField()
    private let unitPopUp = NSPopUpButton()
    private let timePicker = NSDatePicker()
    private let cronField = NSTextField()
    private let ruleNote = SettingsPane.note()
    private var intervalRow: NSGridRow?
    private var timeRow: NSGridRow?
    private var cronRow: NSGridRow?
    private var promptView: NSTextView!
    private var completion: SkillCompletion!
    private let errorNote = SettingsPane.note()

    private static let fieldWidth: CGFloat = 420

    private var kind: AgentChoice {
        (kindPopUp?.selectedItem?.representedObject as? String).flatMap(AgentChoice.init) ?? profile.providers.current
    }

    private let profile: ProfileContext

    init(schedule: ScheduledPrompt?, profile: ProfileContext) {
        self.profile = profile
        original = schedule
        super.init(nibName: nil, bundle: nil)
        title = schedule == nil ? "New Scheduled Prompt" : "Edit Scheduled Prompt"
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let schedule = original
        grid.rowSpacing = 8
        grid.columnSpacing = 8
        grid.rowAlignment = .firstBaseline
        grid.translatesAutoresizingMaskIntoConstraints = false

        nameField.stringValue = schedule?.name ?? ""
        nameField.placeholderString = "Morning news digest"
        nameField.widthAnchor.constraint(equalToConstant: 260).isActive = true
        addRow("Name:", nameField)

        let providers = profile.providers
        let popUp = SettingsPane.popUp(
            providers.all, title: providers.displayName, image: { $0.logo(size: 16) },
            // A removed provider's schedule offers its CLI instead.
            selected: schedule.map { providers.exists($0.choice) ? $0.choice : AgentChoice($0.kind) } ?? providers.current,
            target: self, action: #selector(kindChanged(_:))
        )
        kindPopUp = popUp
        AgentMenuAvailability.watch(popUp, providers: providers)
        addRow("Agent:", popUp)

        modelOptions = schedule?.modelOptions
        modelButton.bezelStyle = .push
        modelButton.lineBreakMode = .byTruncatingTail
        modelButton.widthAnchor.constraint(lessThanOrEqualToConstant: Self.fieldWidth).isActive = true
        addRow("Model:", modelButton)
        showModelOptions()

        let tools = schedule?.tools ?? profile.settings.agentTools
        toolBoxes = AgentTool.allCases.map { tool in
            let checkbox = NSButton(checkboxWithTitle: tool.displayName, target: nil, action: nil)
            checkbox.state = tools.contains(tool) ? .on : .off
            return checkbox
        }
        let toolStack = NSStackView(views: toolBoxes)
        toolStack.orientation = .vertical
        toolStack.alignment = .leading
        toolStack.spacing = 6
        let toolsRow = addRow("Allowed tools:", toolStack)
        toolsRow.rowAlignment = .none
        toolsRow.cell(at: 0).yPlacement = .top

        for rule in RuleKind.allCases {
            rulePopUp.addItem(withTitle: rule.title)
            rulePopUp.lastItem?.tag = rule.rawValue
        }
        rulePopUp.target = self
        rulePopUp.action = #selector(ruleChanged(_:))
        addRow("Runs:", rulePopUp)

        let formatter = NumberFormatter()
        formatter.allowsFloats = false
        formatter.minimum = 1
        formatter.maximum = 100_000
        intervalField.formatter = formatter
        intervalField.delegate = self
        intervalField.alignment = .right
        intervalField.widthAnchor.constraint(equalToConstant: 60).isActive = true
        unitPopUp.addItems(withTitles: ["Minutes", "Hours"])
        unitPopUp.target = self
        unitPopUp.action = #selector(ruleChanged(_:))
        let intervalStack = NSStackView(views: [intervalField, unitPopUp])
        intervalStack.spacing = 8
        let intervalRow = addRow("Every:", intervalStack)
        SettingsPane.linkLabel(of: intervalRow, to: intervalField)
        self.intervalRow = intervalRow

        timePicker.datePickerStyle = .textFieldAndStepper
        timePicker.datePickerElements = .hourMinute
        timePicker.target = self
        timePicker.action = #selector(ruleChanged(_:))
        timeRow = addRow("At:", timePicker)

        cronField.placeholderString = "0 9 * * 1-5"
        cronField.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        cronField.delegate = self
        cronField.widthAnchor.constraint(equalToConstant: 200).isActive = true
        cronRow = addRow("Expression:", cronField)
        addNote(ruleNote)

        intervalField.integerValue = 60
        timePicker.dateValue = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: Date()) ?? Date()
        var ruleKind = RuleKind.daily
        switch schedule?.rule {
        case .every(let minutes):
            ruleKind = .every
            let hours = minutes % 60 == 0
            intervalField.integerValue = hours ? minutes / 60 : minutes
            unitPopUp.selectItem(at: hours ? 1 : 0)
        case .daily(let hour, let minute), .weekdays(let hour, let minute):
            if case .weekdays = schedule?.rule { ruleKind = .weekdays }
            timePicker.dateValue = Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: Date()) ?? Date()
        case .cron(let text):
            ruleKind = .cron
            cronField.stringValue = text
        case nil:
            break
        }
        rulePopUp.selectItem(withTag: ruleKind.rawValue)

        let scroll = BoxedTextView.scrollableTextView()
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        let box = NSBox()
        box.boxType = .custom
        box.cornerRadius = Theme.Radius.small
        box.borderColor = Theme.hairline
        box.fillColor = Theme.fill(Theme.Fill.rest)
        box.contentViewMargins = NSSize(width: 1, height: 1)
        box.contentView = scroll
        box.widthAnchor.constraint(equalToConstant: Self.fieldWidth).isActive = true
        box.heightAnchor.constraint(equalToConstant: 120).isActive = true
        let textView = scroll.documentView as! NSTextView
        textView.drawsBackground = false
        textView.string = schedule?.prompt ?? ""
        textView.font = .systemFont(ofSize: Theme.FontSize.body)
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.textContainerInset = NSSize(width: 2, height: 4)
        textView.delegate = self
        textView.setAccessibilityLabel("Prompt")
        promptView = textView
        let library = profile.skills
        completion = SkillCompletion(textView: textView) { [weak self] in
            guard let self else { return [] }
            return AgentSkillCatalog.skills(for: self.kind.kind, library: library)
        }
        let promptRow = addRow("Prompt:", box)
        promptRow.rowAlignment = .none
        promptRow.cell(at: 0).yPlacement = .top
        addNote(SettingsPane.note("Start with /name to call a skill. Type / to pick one."))
        grid.column(at: 0).xPlacement = .trailing

        // Escape closes the skill picker while it shows, and the sheet otherwise.
        let cancel = PassingButton(title: "Cancel", target: self, action: #selector(cancel(_:)))
        cancel.keyEquivalent = "\u{1b}"
        cancel.passesKeyEquivalent = { [weak self] in
            guard let self else { return false }
            return !self.completion.picker.isHidden && self.view.window?.firstResponder === self.promptView
        }
        // Return adds a line in the prompt, so saving takes Cmd+Return.
        let save = NSButton(title: "Save", target: self, action: #selector(save(_:)))
        save.keyEquivalent = "\r"
        save.keyEquivalentModifierMask = .command
        save.bezelColor = .controlAccentColor
        save.toolTip = "Save (⌘↩)"
        errorNote.textColor = .systemRed
        errorNote.lineBreakMode = .byWordWrapping
        errorNote.maximumNumberOfLines = 2
        errorNote.preferredMaxLayoutWidth = 300
        let buttons = NSStackView(views: [errorNote, NSView(), cancel, save])
        buttons.spacing = 8
        buttons.translatesAutoresizingMaskIntoConstraints = false

        let picker = completion.picker
        let view = NSView()
        for subview in [grid, buttons, picker] as [NSView] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(subview)
        }
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: view.topAnchor, constant: 20),
            grid.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            grid.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            // At least: the sheet keeps extra room here while it eases to a new height.
            buttons.topAnchor.constraint(greaterThanOrEqualTo: grid.bottomAnchor, constant: 16),
            buttons.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            buttons.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            buttons.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -20),
            // Opens above the prompt, over the rows there, as in the panel.
            picker.bottomAnchor.constraint(equalTo: box.topAnchor, constant: -4),
            picker.leadingAnchor.constraint(equalTo: box.leadingAnchor),
            picker.trailingAnchor.constraint(equalTo: box.trailingAnchor),
        ])
        self.view = view
        showRuleRows()
        view.layoutSubtreeIfNeeded()
        preferredContentSize = view.fittingSize
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(original == nil ? nameField : promptView)
    }

    /// A labeled row; VoiceOver reads the label as the control's title.
    @discardableResult
    private func addRow(_ label: String, _ control: NSView) -> NSGridRow {
        let title = NSTextField(labelWithString: label)
        if !(control is NSStackView) { control.setAccessibilityTitleUIElement(title) }
        return grid.addRow(with: [title, control])
    }

    private func addNote(_ note: NSTextField) {
        let row = grid.addRow(with: [NSGridCell.emptyContentView, note])
        row.topPadding = -4
        row.bottomPadding = 6
    }

    // MARK: Rule

    private var ruleKind: RuleKind { RuleKind(rawValue: rulePopUp.selectedTag()) ?? .daily }

    private var rule: ScheduleRule {
        let time = Calendar.current.dateComponents([.hour, .minute], from: timePicker.dateValue)
        switch ruleKind {
        case .every: return .every(minutes: intervalField.integerValue * (unitPopUp.indexOfSelectedItem == 1 ? 60 : 1))
        case .daily: return .daily(hour: time.hour ?? 9, minute: time.minute ?? 0)
        case .weekdays: return .weekdays(hour: time.hour ?? 9, minute: time.minute ?? 0)
        case .cron: return .cron(cronField.stringValue.trimmingCharacters(in: .whitespaces))
        }
    }

    /// Only the rows the picked kind of rule uses.
    private func showRuleRows() {
        intervalRow?.isHidden = ruleKind != .every
        timeRow?.isHidden = ruleKind != .daily && ruleKind != .weekdays
        cronRow?.isHidden = ruleKind != .cron
        showRuleNote()
    }

    /// When it would next run, or what is wrong with the rule.
    private func showRuleNote() {
        do {
            if ruleKind == .cron, cronField.stringValue.trimmingCharacters(in: .whitespaces).isEmpty {
                return SettingsPane.show("Minute, hour, day, month, day of week. 0 9 * * 1-5 is 9:00 on weekdays.", in: ruleNote)
            }
            try rule.validate()
            let next = rule.nextDate(after: Date()).map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "never"
            SettingsPane.show("Next run: \(next)", in: ruleNote)
        } catch {
            SettingsPane.show(error.localizedDescription, in: ruleNote, warning: true)
        }
    }

    /// A new kind of rule shows other rows, so the sheet eases to the new
    /// height with its top edge in place. The interval's unit and the time
    /// change only the note.
    @objc private func ruleChanged(_ sender: Any?) {
        guard sender as? NSPopUpButton === rulePopUp, let window = view.window else { return showRuleRows() }
        let rows = [intervalRow, timeRow, cronRow]
        let wasHidden = rows.map { $0?.isHidden ?? true }
        showRuleRows()
        let size = view.fittingSize
        // Rows that need more room than the sheet has show once it has grown,
        // since they can't be squeezed meanwhile.
        let grows = size.height > view.frame.height
        if grows {
            for (row, hidden) in zip(rows, wasHidden) { row?.isHidden = hidden }
        }
        var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: size))
        frame.origin = NSPoint(x: window.frame.minX, y: window.frame.maxY - frame.height)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Theme.reduceMotion ? 0 : Theme.Duration.panel
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().setFrame(frame, display: true)
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                if grows { self?.showRuleRows() }
            }
        }
    }

    @objc private func kindChanged(_ sender: Any?) {
        completion.hide()
        // Options for one agent don't carry over to another.
        modelOptions = nil
        showModelOptions()
    }

    // MARK: Model

    private func showModelOptions() {
        let kind = kind
        if let modelOptions {
            modelButton.title = modelOptions.summary(for: kind)
        } else {
            let options = profile.settings.agentModelOptions(for: kind)
            let name = profile.providers.displayName(kind)
            modelButton.title = "As in Settings (" + (options.isDefault ? "\(name)'s own" : options.summary(for: kind)) + ")"
        }
    }

    @objc private func chooseModel(_ sender: NSButton) {
        let kind = kind
        AgentModelMenu.popUp(
            from: sender, kind: kind, profile: profile, options: modelOptions ?? profile.settings.agentModelOptions(for: kind)
        ) { [weak self] options in
            self?.modelOptions = options
            self?.showModelOptions()
        }
    }

    func controlTextDidChange(_ notification: Notification) {
        showRuleNote()
    }

    // MARK: Prompt

    func textDidChange(_ notification: Notification) {
        completion.update()
    }

    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if completion.handle(selector) { return true }
        if selector == #selector(NSResponder.insertNewline(_:)) {
            textView.insertNewlineIgnoringFieldEditor(nil)
            return true
        }
        return false
    }

    #if DEBUG
    func setPromptForTesting(_ text: String) {
        promptView.string = text
        view.window?.makeFirstResponder(promptView)
        completion.update()
    }
    #endif

    // MARK: Done

    @objc private func cancel(_ sender: Any?) {
        onDone?(nil)
    }

    @objc private func save(_ sender: Any?) {
        let prompt = promptView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        if ruleKind == .every, intervalField.integerValue < 1 { return showError("Pick how often it runs.") }
        var name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { name = AgentConversation.title(from: prompt) }
        let tools = zip(AgentTool.allCases, toolBoxes).filter { $0.1.state == .on }.map(\.0)
        var schedule = original ?? ScheduledPrompt(name: name, prompt: prompt, choice: kind, tools: tools, rule: rule)
        schedule.name = name
        schedule.prompt = prompt
        schedule.choice = kind
        schedule.tools = tools
        schedule.modelOptions = modelOptions
        schedule.rule = rule
        do {
            try schedule.validate()
        } catch {
            return showError(error.localizedDescription)
        }
        onDone?(schedule)
    }

    private func showError(_ message: String) {
        errorNote.stringValue = message
        NSSound.beep()
    }
}
