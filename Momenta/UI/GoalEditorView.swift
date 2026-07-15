import SwiftUI

/// The core goal editor: rate / hours / revenue with currency-converter
/// behavior. The last-edited goal field is authoritative and highlighted; the
/// other side always shows the derived value. Saving writes a per-month goal
/// version — "this month and onward" by default, retroactive only after an
/// explicit confirmation.
struct GoalEditorView: View {
    @Environment(AppState.self) private var appState
    let client: ClientConfig

    @State private var draft: GoalDraft
    @State private var showScopeDialog = false
    @State private var savedFeedback = false

    init(client: ClientConfig) {
        self.client = client
        let month = YearMonth(containing: Date(), timeZone: .current)
        _draft = State(initialValue: GoalDraft(goal: client.goal(for: month)))
    }

    private var month: YearMonth {
        appState.currentMonth
    }

    private var hasHistoricalMonths: Bool {
        client.goalHistory.keys.contains { $0 < month }
    }

    var body: some View {
        Section("Monthly Goal") {
            TextField("Hourly rate", value: rateBinding, format: .number)
                .multilineTextAlignment(.trailing)

            LabeledContent {
                TextField("Hours", value: hoursBinding, format: .number.precision(.fractionLength(0...2)))
                    .multilineTextAlignment(.trailing)
                    .labelsHidden()
            } label: {
                fieldLabel("Goal in hours", isAuthoritative: draft.authoritative == .hours)
            }

            LabeledContent {
                TextField("Revenue", value: revenueBinding, format: .number.precision(.fractionLength(0...2)))
                    .multilineTextAlignment(.trailing)
                    .labelsHidden()
            } label: {
                fieldLabel("Revenue target", isAuthoritative: draft.authoritative == .revenue)
            }

            HStack {
                // The effective-scope label is always visible, per spec.
                Text("Changes take effect from \(Format.monthTitle(month, timeZone: appState.timeZone)) onward.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if savedFeedback {
                    Label("Saved", systemImage: "checkmark")
                        .font(.caption)
                        .foregroundStyle(.green)
                        .transition(.opacity)
                }
                Button("Save Goal") {
                    save()
                }
                .disabled(draft.monthlyGoal == nil || draft == GoalDraft(goal: client.goal(for: month)))
            }
        }
        .confirmationDialog(
            "Past months have their own recorded goals",
            isPresented: $showScopeDialog
        ) {
            Button("This Month and Onward") {
                apply(retroactive: false)
            }
            Button("Also Rewrite All Past Months", role: .destructive) {
                apply(retroactive: true)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("By default past months keep the goals recorded for them. You can also rewrite every past month to this new goal.")
        }
    }

    private func fieldLabel(_ title: String, isAuthoritative: Bool) -> some View {
        HStack(spacing: 5) {
            Text(title)
                .fontWeight(isAuthoritative ? .semibold : .regular)
            if isAuthoritative {
                Text("SET")
                    .font(.caption2.weight(.bold))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(RoundedRectangle(cornerRadius: 3).fill(.tint.opacity(0.15)))
                    .foregroundStyle(.tint)
            } else {
                Text("derived")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Bindings

    private var rateBinding: Binding<Decimal?> {
        Binding { draft.hourlyRate } set: { draft.setRate($0) }
    }

    private var hoursBinding: Binding<Decimal?> {
        Binding { draft.hours } set: { draft.setHours($0) }
    }

    private var revenueBinding: Binding<Decimal?> {
        Binding { draft.revenue } set: { draft.setRevenue($0) }
    }

    // MARK: Saving

    private func save() {
        guard draft.monthlyGoal != nil else { return }
        if hasHistoricalMonths {
            showScopeDialog = true
        } else {
            apply(retroactive: false)
        }
    }

    private func apply(retroactive: Bool) {
        guard let goal = draft.monthlyGoal else { return }
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
                            }
                        }
                    }
                }
            }
        }
    }

    private func historyLine(_ goal: MonthlyGoal) -> String {
        let authored = goal.isAuthoredInHours ? "hours-led" : "revenue-led"
        return "\(Format.hours(goal.hours)) · \(Format.currency(goal.revenue)) @ \(Format.currency(goal.hourlyRate))/h · \(authored)"
    }
}
