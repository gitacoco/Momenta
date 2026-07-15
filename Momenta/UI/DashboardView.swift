import SwiftUI

/// Popover content: month navigation, unit toggle, client cards, warnings.
struct DashboardView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        // Fixed size: MenuBarExtra windows measure their content once and do
        // not reliably grow with it, which can leave the popover collapsed.
        .frame(width: 380, height: 500)
        .task {
            // Refresh when the popover opens, throttled so repeated opens
            // don't burn the API quota.
            await appState.refreshIfNeeded()
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

            Text("Display goals in")
                .font(.callout)
                .foregroundStyle(.secondary)
            Picker("Display goals in", selection: $appState.displayUnit) {
                Image(systemName: "dollarsign").tag(DisplayUnit.revenue)
                Image(systemName: "clock").tag(DisplayUnit.hours)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if appState.visibleClients.isEmpty {
            EmptyStateView()
                .frame(maxHeight: .infinity)
        } else {
            let progressByID = appState.progressByClientID
            ScrollView {
                VStack(spacing: 10) {
                    if appState.selectedSnapshot == nil {
                        dataUnavailableBanner
                    }
                    if let uncategorized = appState.uncategorized, uncategorized.noClientHours > 0.05 {
                        uncategorizedBanner(hours: uncategorized.noClientHours)
                    }
                    // Every enabled client gets a row — data, setup prompt,
                    // or an explicit reason why there's nothing to show.
                    ForEach(appState.visibleClients) { client in
                        switch client.state(for: appState.selectedMonth) {
                        case .configured:
                            if let progress = progressByID[client.id] {
                                ClientCardView(progress: progress, unit: appState.displayUnit)
                            } else {
                                noDataCard(client)
                            }
                        case .needsSetup:
                            setupCard(client)
                        case .disabled, .archived:
                            EmptyView()
                        }
                    }
                }
                .padding(12)
            }
            .frame(maxHeight: .infinity)
        }
    }

    /// Shown when the selected month has no snapshot at all: the numbers
    /// aren't just empty, they're absent — say so and offer a retry.
    private var dataUnavailableBanner: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "icloud.slash")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("No data for this month")
                    .font(.callout.weight(.semibold))
                Text(appState.dataUnavailableReason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Retry") {
                Task { await appState.refresh(force: true) }
            }
            .disabled(appState.isLoading)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(.orange.opacity(0.1)))
    }

    /// A configured client whose data couldn't be loaded still shows up,
    /// with the reason, instead of silently vanishing.
    private func noDataCard(_ client: ClientConfig) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(Color(hex: client.colorHex))
                .frame(width: 9, height: 9)
            Text(client.displayName)
                .font(.headline)
            Spacer()
            Text(appState.dataUnavailableReason)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
    }

    private func setupCard(_ client: ClientConfig) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(Color(hex: client.colorHex))
                .frame(width: 9, height: 9)
            Text(client.displayName)
                .font(.headline)
            Text("needs a rate and goal")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Set up") {
                // Deep-link straight to this client's configuration.
                appState.pendingSettingsDestination = .clients(clientID: client.id)
                openSettings()
            }
            .font(.callout)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
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

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 6) {
            if appState.isLoading {
                ProgressView()
                    .controlSize(.small)
                Text("Refreshing…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                statusLine
            }
            Spacer()
            Button {
                // Manual refresh bypasses the throttle and refetches the
                // selected historical month too.
                Task { await appState.refresh(force: true) }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .disabled(appState.isLoading)

            Button {
                openSettings()
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.borderless)

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.borderless)
            .font(.caption)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    /// One line that always tells the user how trustworthy the numbers are
    /// and what to do next.
    @ViewBuilder
    private var statusLine: some View {
        if let apiError = appState.lastAPIError {
            Image(systemName: errorIcon(apiError))
                .foregroundStyle(.orange)
                .font(.caption)
            Text(staleSuffix(apiError.errorDescription ?? "Refresh failed"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if apiError == .unauthorized {
                Button("Reconnect") {
                    appState.pendingSettingsDestination = .account
                    openSettings()
                }
                .font(.caption)
            }
        } else if let error = appState.lastError {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.orange)
                .font(.caption)
            Text(staleSuffix(error))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        } else if appState.isShowingStaleData {
            Image(systemName: "clock.arrow.circlepath")
                .foregroundStyle(.orange)
                .font(.caption)
            Text("Cached data — connect Toggl to refresh")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if let fetchedAt = appState.selectedSnapshot?.fetchedAt {
            Text("Updated \(fetchedAt.formatted(date: .omitted, time: .shortened))")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func errorIcon(_ error: TogglAPIError) -> String {
        switch error {
        case .offline: return "wifi.slash"
        case .unauthorized: return "key.slash"
        case .rateLimited: return "clock.badge.exclamationmark"
        case .server, .decoding, .other: return "exclamationmark.triangle"
        }
    }

    /// Failure messages mention that cached data is still being shown.
    private func staleSuffix(_ message: String) -> String {
        appState.selectedSnapshot != nil ? "\(message) Showing cached data." : message
    }
}
