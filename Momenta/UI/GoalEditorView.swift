import SwiftUI

/// Fields a needs-setup item can jump-focus to.
enum ClientField: Hashable {
    case displayName
    case rate
    case hours
    case revenue
}

/// The goal half of the editor: hours and revenue side by side like a
/// currency converter — edit either field and the other follows, using the
/// rate from the Client Profile section. Saving writes a per-month goal
/// version (rate included); "this month and onward" by default, retroactive
/// only after an explicit confirmation.
struct GoalEditorSection: View {
    @Environment(AppState.self) private var appState
    let client: ClientConfig
    @Binding var draft: GoalDraft
    var focus: FocusState<ClientField?>.Binding

    @State private var showRetroDialog = false
    @State private var savedFeedback = false

    private let converterFieldWidth: CGFloat = 140

    private var month: YearMonth {
        appState.currentMonth
    }

    private var hasHistoricalMonths: Bool {
        client.goalHistory.keys.contains { $0 < month }
    }

    private var isDirty: Bool {
        draft != GoalDraft(goal: client.goal(for: month))
    }

    var body: some View {
        Section {
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
        } header: {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Monthly Goal")
                    Text("Saves as you edit; changes apply from \(Format.monthTitle(month, timeZone: appState.timeZone)) onward.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .textCase(nil)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                if savedFeedback {
                    Label("Saved", systemImage: "checkmark")
                        .font(.callout)
                        .foregroundStyle(.green)
                        .transition(.opacity)
                }
                if hasHistoricalMonths {
                    Menu {
                        Button("Apply Current Goal to All Past Months…", role: .destructive) {
                            showRetroDialog = true
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuIndicator(.hidden)
                    .fixedSize()
                }
            }
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
            Button("Rewrite All Past Months", role: .destructive) {
                apply(retroactive: true)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every recorded past month will be overwritten with the current rate and goal. Normal edits never touch past months.")
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
                .textFieldStyle(.plain)
                .multilineTextAlignment(textAlignment)
                .frame(minWidth: min(width, 88), idealWidth: width, maxWidth: width)
                .focused(focus, equals: focusTag)
                .labelsHidden()
                .onSubmit(commitIfDirty)
        }
    }

    // MARK: Bindings

    private var hoursBinding: Binding<Decimal?> {
        Binding { draft.hours } set: { draft.setHours($0) }
    }

    private var revenueBinding: Binding<Decimal?> {
        Binding { draft.revenue } set: { draft.setRevenue($0) }
    }

    // MARK: Saving

    /// Auto-save: a complete, changed draft persists as soon as editing
    /// pauses. Scope is always "this month and onward"; rewriting history
    /// hides behind the explicit menu + confirmation.
    private func commitIfDirty() {
        guard draft.monthlyGoal != nil, isDirty else { return }
        apply(retroactive: false)
    }

    private func apply(retroactive: Bool) {
        guard let goal = draft.monthlyGoal ?? client.goal(for: month) else { return }
        appState.config.setGoal(goal, forClient: client.id, from: month, retroactive: retroactive)
        withAnimation {
            savedFeedback = true
        }
        Task {
            try? await Task.sleep(for: .seconds(2))
            withAnimation {
                savedFeedback = false
            }
        }
    }
}

/// Read-only, per-month record of goal versions.
struct GoalHistoryView: View {
    let client: ClientConfig
    @State private var expanded = false

    var body: some View {
        Section {
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
    }

    private func historyLine(_ goal: MonthlyGoal) -> String {
        let authored = goal.isAuthoredInHours ? "hours-led" : "revenue-led"
        let code = client.currency
        return "\(Format.hours(goal.hours)) · \(Format.currency(goal.revenue, code: code)) @ \(Format.currency(goal.hourlyRate, code: code))/h · \(authored)"
    }
}
