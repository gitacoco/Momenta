import SwiftUI

/// A readout of the existing goal and pacing controls, with calculation
/// details kept behind an information button.
struct GoalOutlookSection: View {
    @Environment(AppState.self) private var appState
    let client: ClientConfig
    let editor: GoalEditorState
    @State private var showsDetails = false

    private var outlook: GoalOutlook? {
        guard let goal = editor.draft.monthlyGoal,
              let snapshot = appState.snapshots[editor.month] else { return nil }
        return GoalOutlook(
            goalHours: goal.hours,
            client: client,
            snapshot: snapshot,
            timeZone: appState.timeZone,
            now: appState.displayNow
        )
    }

    var body: some View {
        if editor.month == appState.currentMonth {
            Section {
                LabeledContent {
                    result
                } label: {
                    HStack(spacing: 6) {
                        Text("Per planned day after today")
                        Button("How this is calculated", systemImage: "info.circle") {
                            showsDetails = true
                        }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .popover(isPresented: $showsDetails) {
                            Text(explanation)
                                .font(.callout)
                                .frame(width: 280, alignment: .leading)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(16)
                        }
                    }
                }
            }
            .task(id: editor.month) {
                await appState.loadGoalSnapshotIfNeeded(for: editor.month)
            }
        }
    }

    @ViewBuilder
    private var result: some View {
        if editor.draft.monthlyGoal == nil {
            Text("—")
                .foregroundStyle(.secondary)
                .accessibilityLabel("Enter a monthly goal to calculate the daily pace")
        } else if let outlook {
            if let hours = outlook.hoursPerPlannedDay {
                Text(Format.hoursAndMinutes(hours))
                    .monospacedDigit()
                    .fontWeight(.medium)
                    .accessibilityIdentifier("goalOutlookValue")
            } else {
                Text("No planned days left")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else if appState.loadingMonths.contains(editor.month) {
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel("Loading logged hours")
        } else {
            Button("Load logged hours") {
                Task { await appState.loadGoalSnapshotIfNeeded(for: editor.month) }
            }
            .buttonStyle(.borderless)
        }
    }

    private var explanation: String {
        guard let outlook else {
            return "Uses your monthly goal, logged hours, planned days, and days off. A valid goal and loaded time entries are needed."
        }
        let remaining = Format.hoursAndMinutes(outlook.remainingHours)
        let logged = Format.hoursAndMinutes(outlook.loggedHours)
        if outlook.plannedDays == 0 {
            return "\(logged) logged this month. \(remaining) remaining, with no planned days after today. Adjust the monthly goal, planned days, or days off to make room."
        }
        return "\(logged) logged this month. \(remaining) remaining across \(outlook.plannedDays) planned days after today.\n\nDays off are excluded. Assumes no additional work today; more logged time lowers this pace. Uses the latest loaded time entries."
    }
}
