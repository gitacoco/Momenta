import SwiftUI

/// Popover content: month navigation, unit toggle, client cards, warnings.
struct DashboardView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 380)
        .task {
            // Refresh whenever the popover opens; BON-16 adds throttling.
            await appState.refresh()
        }
    }

    // MARK: Header

    private var header: some View {
        @Bindable var appState = appState
        return HStack(spacing: 8) {
            Button {
                appState.select(month: appState.selectedMonth.previous)
            } label: {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(.borderless)
            .disabled(!appState.canGoToPreviousMonth)

            Text(Format.monthTitle(appState.selectedMonth, timeZone: appState.timeZone))
                .font(.headline)
                .frame(minWidth: 110)

            Button {
                appState.select(month: appState.selectedMonth.next)
            } label: {
                Image(systemName: "chevron.right")
            }
            .buttonStyle(.borderless)
            .disabled(!appState.canGoToNextMonth)

            Spacer()

            Picker("Unit", selection: $appState.displayUnit) {
                ForEach(DisplayUnit.allCases) { unit in
                    Text(unit.label).tag(unit)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()

            Button {
                Task { await appState.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .disabled(appState.isLoading)

            SettingsLink {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if appState.progresses.isEmpty && !appState.hasConfiguredClients {
            EmptyStateView()
        } else {
            ScrollView {
                VStack(spacing: 10) {
                    if let uncategorized = appState.uncategorized, uncategorized.noClientHours > 0.05 {
                        uncategorizedBanner(hours: uncategorized.noClientHours)
                    }
                    ForEach(appState.progresses) { progress in
                        ClientCardView(progress: progress, unit: appState.displayUnit)
                    }
                    if !appState.needsSetupClients.isEmpty {
                        needsSetupHint
                    }
                }
                .padding(12)
            }
            .frame(maxHeight: 520)
        }
    }

    private func uncategorizedBanner(hours: Decimal) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
            Text("\(Format.hours(hours)) this month is not assigned to any client")
                .font(.callout)
            Spacer()
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(.yellow.opacity(0.12)))
    }

    private var needsSetupHint: some View {
        HStack(spacing: 8) {
            Image(systemName: "slider.horizontal.3")
                .foregroundStyle(.secondary)
            Text(needsSetupText)
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
            SettingsLink {
                Text("Set up")
                    .font(.callout)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.4)))
    }

    private var needsSetupText: String {
        let names = appState.needsSetupClients.map(\.displayName).joined(separator: ", ")
        return "\(names): set a rate and goal to start tracking"
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 6) {
            if appState.isLoading {
                ProgressView()
                    .controlSize(.small)
                Text("Refreshing…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if let error = appState.lastError {
                Image(systemName: "wifi.exclamationmark")
                    .foregroundStyle(.secondary)
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else if let fetchedAt = appState.selectedSnapshot?.fetchedAt {
                Text("Updated \(fetchedAt.formatted(date: .omitted, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.borderless)
            .font(.caption)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}
