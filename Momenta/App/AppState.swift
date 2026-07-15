import Foundation
import Observation

@MainActor
@Observable
final class AppState {
    private let provider: any DataProvider
    let account: AccountManager

    var clients: [ClientConfig] = []
    var snapshots: [YearMonth: TimeEntrySnapshot] = [:]
    var displaySettings = DisplaySettings()
    var selectedMonth: YearMonth
    var availableMonths: [YearMonth] = []
    var isLoading = false
    var lastError: String?
    /// Popover chart unit toggle. View state only, resets with the process.
    var displayUnit: DisplayUnit = .revenue

    init(provider: any DataProvider, account: AccountManager = AccountManager()) {
        self.provider = provider
        self.account = account
        self.selectedMonth = YearMonth(containing: Date(), timeZone: .current)
        Task {
            await self.refresh()
        }
    }

    var timeZone: TimeZone {
        displaySettings.timeZone
    }

    var currentMonth: YearMonth {
        YearMonth(containing: Date(), timeZone: timeZone)
    }

    // MARK: Loading

    /// Full refresh: clients, available months, current month, and (if
    /// different) the selected month. Called when the popover opens or the
    /// user asks for a refresh.
    func refresh() async {
        isLoading = true
        defer { isLoading = false }
        let now = Date()
        do {
            clients = try await provider.loadClients()
            availableMonths = try await provider.availableMonths(asOf: now, timeZone: timeZone)
            snapshots[currentMonth] = try await provider.loadSnapshot(for: currentMonth, timeZone: timeZone, now: now)
            if selectedMonth != currentMonth {
                snapshots[selectedMonth] = try await provider.loadSnapshot(for: selectedMonth, timeZone: timeZone, now: now)
            }
            lastError = nil
            account.markSynced(at: now)
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Drops all cached month data. Offered when disconnecting the account.
    func clearCache() {
        snapshots.removeAll()
    }

    func select(month: YearMonth) {
        selectedMonth = month
        guard snapshots[month] == nil else { return }
        // Historical months are fetched on demand and then served from cache.
        Task {
            await self.loadSelectedMonth()
        }
    }

    private func loadSelectedMonth() async {
        isLoading = true
        defer { isLoading = false }
        do {
            snapshots[selectedMonth] = try await provider.loadSnapshot(
                for: selectedMonth, timeZone: timeZone, now: Date()
            )
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: Derived state

    var selectedSnapshot: TimeEntrySnapshot? {
        snapshots[selectedMonth]
    }

    /// Progress cards for the selected month. Running-entry elapsed time is
    /// evaluated at the snapshot's fetch time: no local ticking between syncs.
    var progresses: [ClientProgress] {
        guard let snapshot = selectedSnapshot else { return [] }
        return clients.compactMap { client in
            guard client.isDisplayable(for: selectedMonth) else { return nil }
            return ProgressCalculator.progress(
                for: client,
                entries: snapshot.entries,
                month: selectedMonth,
                timeZone: timeZone,
                now: snapshot.fetchedAt
            )
        }
    }

    var uncategorized: UncategorizedSummary? {
        guard let snapshot = selectedSnapshot else { return nil }
        return ProgressCalculator.uncategorized(
            entries: snapshot.entries,
            clients: clients,
            month: selectedMonth,
            timeZone: timeZone,
            now: snapshot.fetchedAt
        )
    }

    /// Enabled clients that still lack a complete goal for the selected month.
    var needsSetupClients: [ClientConfig] {
        clients.filter { $0.state(for: selectedMonth) == .needsSetup }
    }

    var menuBarAggregate: AggregateProgress? {
        guard let snapshot = snapshots[currentMonth] else { return nil }
        return ProgressCalculator.aggregate(
            clients: clients,
            entries: snapshot.entries,
            month: currentMonth,
            period: displaySettings.aggregationPeriod,
            timeZone: timeZone,
            now: snapshot.fetchedAt
        )
    }

    var hasConfiguredClients: Bool {
        clients.contains { $0.isDisplayable(for: currentMonth) }
    }

    var canGoToPreviousMonth: Bool {
        availableMonths.first.map { $0 < selectedMonth } ?? false
    }

    var canGoToNextMonth: Bool {
        availableMonths.last.map { selectedMonth < $0 } ?? false
    }
}
