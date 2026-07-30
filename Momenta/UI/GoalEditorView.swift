import SwiftUI

/// Fields a needs-setup item can jump-focus to.
enum ClientField: Hashable {
    case displayName
    case rate
    case hours
    case revenue
}

/// Months the editor can address. Toggl only guarantees the current month and
/// two previous months, so expose that window even before a refresh has filled
/// `availableMonths`; cached and recorded older months remain selectable.
enum GoalMonthOptions {
    static func make(
        current: YearMonth,
        available: [YearMonth],
        recorded: [YearMonth]
    ) -> [YearMonth] {
        Set(available)
            .union(recorded)
            .union([current.previous.previous, current.previous, current])
            .filter { $0 <= current }
            .sorted(by: >)
    }
}

/// The goal half of the editor: hours and revenue side by side like a
/// currency converter — edit either field and the other follows, using the
/// rate from the Client Profile section. Saving writes a per-month goal
/// version (rate included); "this month and onward" by default, retroactive
/// only after an explicit confirmation.
struct GoalEditorSection: View {
    @Environment(AppState.self) private var appState
    let client: ClientConfig
    @Binding var editor: GoalEditorState
    var focus: FocusState<ClientField?>.Binding

    @State private var showRetroDialog = false
    @State private var showHistoricalSaveDialog = false
    @State private var showUnsavedSwitchDialog = false
    @State private var pendingMonth: YearMonth?

    private let converterFieldWidth: CGFloat = 140

    private var month: YearMonth {
        editor.month
    }

    private var draft: GoalDraft {
        editor.draft
    }

    private var liveClient: ClientConfig {
        appState.config.client(id: client.id) ?? client
    }

    private var monthOptions: [YearMonth] {
        GoalMonthOptions.make(
            current: appState.currentMonth,
            available: appState.availableMonths,
            recorded: Array(liveClient.goalHistory.keys)
        )
    }

    private var isHistoricalMonth: Bool {
        month < appState.currentMonth
    }

    /// Past months come from the account's navigable Toggl history as well as
    /// goal versions retained beyond that API window. Looking only at goal
    /// keys makes the retroactive action disappear for the exact first-goal
    /// case where history needs to be backfilled.
    private var historicalMonths: [YearMonth] {
        monthOptions
            .filter { $0 < appState.currentMonth }
            .sorted()
    }

    private var hasHistoricalMonths: Bool {
        !historicalMonths.isEmpty
    }

    private var isDirty: Bool {
        editor.draft != GoalEditorState(client: liveClient, month: month).draft
    }

    var body: some View {
        Section {
            LabeledContent("Goal month") {
                Picker("Goal month", selection: monthBinding) {
                    ForEach(monthOptions, id: \.self) { option in
                        Text(Format.monthTitle(option, timeZone: appState.timeZone))
                            .tag(option)
                    }
                }
                .labelsHidden()
                .fixedSize()
                .accessibilityHint("Choose the month whose goal you want to edit")
            }

            if !client.isBillable {
                // Non-billable clients have no rate or revenue: a single hours
                // target, as a standard label-left / field-right row.
                LabeledContent("Hours") {
                    TextField("Hours", value: hoursBinding, format: .number.precision(.fractionLength(0...2)))
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.trailing)
                        .frame(minWidth: 56, idealWidth: 70, maxWidth: 70)
                        .focused(focus, equals: .hours)
                        .labelsHidden()
                        .onSubmit(commitIfDirty)
                }
            } else {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .bottom, spacing: 12) {
                    converterField(
                        "Hours",
                        value: hoursBinding,
                        focusTag: .hours,
                        width: converterFieldWidth,
                        alignment: .leading,
                        textAlignment: .leading
                    )
                    Spacer(minLength: 0)
                    Image(systemName: "arrow.left.arrow.right")
                        .foregroundStyle(.secondary)
                        .padding(.bottom, 5)
                    Spacer(minLength: 0)
                    converterField(
                        "Revenue (\(client.currency))",
                        value: revenueBinding,
                        focusTag: .revenue,
                        width: converterFieldWidth,
                        alignment: .trailing,
                        textAlignment: .trailing
                    )
                }

                VStack(alignment: .leading, spacing: 10) {
                    converterField(
                        "Hours",
                        value: hoursBinding,
                        focusTag: .hours,
                        width: converterFieldWidth,
                        alignment: .leading,
                        textAlignment: .leading
                    )
                    Image(systemName: "arrow.up.arrow.down")
                        .foregroundStyle(.secondary)
                    converterField(
                        "Revenue (\(client.currency))",
                        value: revenueBinding,
                        focusTag: .revenue,
                        width: converterFieldWidth,
                        alignment: .leading,
                        textAlignment: .leading
                    )
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 2)
            }

            if isHistoricalMonth {
                HStack {
                    Text("Past-month changes are saved only after confirmation.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Revert") {
                        resetDraft()
                    }
                    .disabled(!isDirty)
                    Button("Save \(Format.monthName(month, timeZone: appState.timeZone)) Goal…") {
                        showHistoricalSaveDialog = true
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!isDirty || draft.monthlyGoal == nil)
                }
            } else if hasHistoricalMonths {
                HStack {
                    Spacer()
                    Button {
                        showRetroDialog = true
                    } label: {
                        Label(
                            "Apply \(Format.monthName(month, timeZone: appState.timeZone)) Goal to Past Months…",
                            systemImage: "clock.arrow.circlepath"
                        )
                    }
                    .buttonStyle(.borderless)
                    .disabled(draft.monthlyGoal == nil && liveClient.goal(for: month) == nil)
                    .help("Replace this client's rate and goal in every available past month")
                    .accessibilityHint("Asks for confirmation before changing historical goals")
                }
            }

            GoalHistoryRows(client: liveClient)
        } header: {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Monthly Goal")
                    if isHistoricalMonth {
                        Text("Editing \(Format.monthTitle(month, timeZone: appState.timeZone)); later months stay unchanged.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .textCase(nil)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text("Saves as you edit; changes apply from \(Format.monthTitle(month, timeZone: appState.timeZone)) onward.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .textCase(nil)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer()
            }
        }
        // Persist every complete draft change. Focus/submit hooks below remain
        // as safety nets for formatter updates that settle at edit boundaries.
        .onChange(of: editor) { oldValue, newValue in
            // A month switch replaces the month and draft atomically. Skipping
            // that transition prevents one month's values being saved into
            // the other month during SwiftUI's update pass.
            guard oldValue.month == newValue.month else { return }
            commitIfDirty()
        }
        // Auto-save when focus leaves any goal-related field.
        .onChange(of: focus.wrappedValue) { oldValue, newValue in
            let goalFields: Set<ClientField> = [.rate, .hours, .revenue]
            let leftGoalField = oldValue.map { goalFields.contains($0) } ?? false
            let enteredGoalField = newValue.map { goalFields.contains($0) } ?? false
            if leftGoalField && !enteredGoalField {
                commitIfDirty()
            }
        }
        .onDisappear {
            commitIfDirty()
        }
        .confirmationDialog(
            "Rewrite all past months?",
            isPresented: $showRetroDialog
        ) {
            Button("Apply to \(historicalMonths.count) Past \(historicalMonths.count == 1 ? "Month" : "Months")", role: .destructive) {
                apply(retroactive: true)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The current rate and goal will overwrite this client's goal in every available past month. Normal edits never touch past months.")
        }
        .confirmationDialog(
            "Save \(Format.monthTitle(month, timeZone: appState.timeZone)) goal?",
            isPresented: $showHistoricalSaveDialog
        ) {
            Button("Save \(Format.monthName(month, timeZone: appState.timeZone)) Goal") {
                saveHistoricalGoal()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This records a goal version for \(Format.monthTitle(month, timeZone: appState.timeZone)) only. Later goals stay unchanged.")
        }
        .confirmationDialog(
            "Unsaved \(Format.monthTitle(month, timeZone: appState.timeZone)) changes",
            isPresented: $showUnsavedSwitchDialog
        ) {
            if draft.monthlyGoal != nil {
                Button("Save and Switch") {
                    saveHistoricalGoal()
                    completePendingMonthSwitch()
                }
            }
            Button("Discard and Switch", role: .destructive) {
                completePendingMonthSwitch()
            }
            Button("Cancel", role: .cancel) {
                pendingMonth = nil
            }
        } message: {
            Text("Past-month changes require confirmation before switching months.")
        }
    }

    private func converterField(
        _ title: String,
        value: Binding<Decimal?>,
        focusTag: ClientField,
        width: CGFloat,
        alignment: HorizontalAlignment,
        textAlignment: TextAlignment
    ) -> some View {
        VStack(alignment: alignment, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField(title, value: value, format: .number.precision(.fractionLength(0...2)))
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(textAlignment)
                .frame(minWidth: min(width, 88), idealWidth: width, maxWidth: width)
                .focused(focus, equals: focusTag)
                .labelsHidden()
                .onSubmit(commitIfDirty)
        }
    }

    // MARK: Bindings

    private var monthBinding: Binding<YearMonth> {
        Binding {
            month
        } set: { newMonth in
            guard newMonth != month else { return }
            if isHistoricalMonth && isDirty {
                pendingMonth = newMonth
                showUnsavedSwitchDialog = true
            } else {
                switchToMonth(newMonth)
            }
        }
    }

    private var hoursBinding: Binding<Decimal?> {
        Binding { editor.draft.hours } set: { newValue in
            var updated = editor
            updated.draft.setHours(newValue)
            editor = updated
        }
    }

    private var revenueBinding: Binding<Decimal?> {
        Binding { editor.draft.revenue } set: { newValue in
            var updated = editor
            updated.draft.setRevenue(newValue)
            editor = updated
        }
    }

    // MARK: Saving

    /// Auto-save: every complete, changed draft persists immediately. Scope
    /// is always "this month and onward"; rewriting history hides behind the
    /// explicit menu + confirmation.
    private func commitIfDirty() {
        guard !isHistoricalMonth else { return }
        guard draft.monthlyGoal != nil, isDirty else { return }
        apply(retroactive: false)
    }

    private func apply(retroactive: Bool) {
        guard let goal = draft.monthlyGoal ?? liveClient.goal(for: month) else { return }
        appState.config.setGoal(
            goal,
            forClient: client.id,
            from: month,
            retroactive: retroactive,
            historicalMonths: retroactive ? historicalMonths : []
        )
    }

    private func saveHistoricalGoal() {
        guard isHistoricalMonth, isDirty, let goal = draft.monthlyGoal else { return }
        appState.config.setGoalVersion(goal, forClient: client.id, at: month)
    }

    private func resetDraft() {
        editor = GoalEditorState(client: liveClient, month: month)
    }

    private func switchToMonth(_ newMonth: YearMonth) {
        editor = GoalEditorState(client: liveClient, month: newMonth)
    }

    private func completePendingMonthSwitch() {
        guard let pendingMonth else { return }
        self.pendingMonth = nil
        switchToMonth(pendingMonth)
    }
}

/// Read-only, per-month record of goal versions: a collapsed disclosure row
/// hosted at the bottom of the Monthly Goal section (or in its own section
/// for archived clients, which have no editor).
struct GoalHistoryRows: View {
    let client: ClientConfig
    @State private var expanded = false

    var body: some View {
        DisclosureGroup("Goal History", isExpanded: $expanded) {
            let months = client.goalHistory.keys.sorted(by: >)
            if months.isEmpty {
                Text("No goals recorded yet.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(months, id: \.self) { month in
                    if let goal = client.goalHistory[month] {
                        LabeledContent(month.description) {
                            Text(historyLine(goal))
                                .font(.callout.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.trailing)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
    }

    private func historyLine(_ goal: MonthlyGoal) -> String {
        // Non-billable clients have no rate or revenue: hours only.
        guard client.isBillable else {
            return Format.hours(goal.hours)
        }
        let authored = goal.isAuthoredInHours ? "hours-led" : "revenue-led"
        let code = client.currency
        return "\(Format.hours(goal.hours)) · \(Format.currency(goal.revenue, code: code)) @ \(Format.currency(goal.hourlyRate, code: code))/h · \(authored)"
    }
}
