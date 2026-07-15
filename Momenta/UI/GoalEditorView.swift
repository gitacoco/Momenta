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

    @State private var showScopeDialog = false
    @State private var savedFeedback = false

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
            HStack(alignment: .bottom, spacing: 12) {
                converterField(
                    "Hours",
                    value: hoursBinding,
                    focusTag: .hours,
                    width: 120
                )
                Image(systemName: "arrow.left.arrow.right")
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 5)
                converterField(
                    "Revenue (\(client.currency))",
                    value: revenueBinding,
                    focusTag: .revenue,
                    width: 140
                )
                Spacer()
            }
            .padding(.vertical, 2)
        } header: {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Monthly Goal")
                    Text("Hours and revenue stay in sync — edit either side. Changes apply from \(Format.monthTitle(month, timeZone: appState.timeZone)) onward.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .textCase(nil)
                }
                Spacer()
                if savedFeedback {
                    Label("Saved", systemImage: "checkmark")
                        .font(.callout)
                        .foregroundStyle(.green)
                        .transition(.opacity)
                }
                Button("Save") {
                    save()
                }
                .disabled(draft.monthlyGoal == nil || !isDirty)
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

    private func converterField(
        _ title: String,
        value: Binding<Decimal?>,
        focusTag: ClientField,
        width: CGFloat
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("0", value: value, format: .number.precision(.fractionLength(0...2)))
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: width)
                .focused(focus, equals: focusTag)
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
        let code = client.currency
        return "\(Format.hours(goal.hours)) · \(Format.currency(goal.revenue, code: code)) @ \(Format.currency(goal.hourlyRate, code: code))/h · \(authored)"
    }
}
