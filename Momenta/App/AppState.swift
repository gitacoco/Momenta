import Foundation
import Observation

@MainActor
@Observable
final class AppState {
    /// Demo data source used before any Toggl account is connected.
    private let fallbackProvider: any DataProvider
    private var togglProvider: TogglDataProvider?
    private var togglProviderGeneration = -1
    let account: AccountManager
    let config: ConfigStore

    var snapshots: [YearMonth: TimeEntrySnapshot] = [:]
    var displaySettings = DisplaySettings()
    var selectedMonth: YearMonth
    var availableMonths: [YearMonth] = []
    var isLoading = false
    var lastError: String?
    var clientListLoading = false
    var clientListError: String?
    /// Popover chart unit toggle. View state only, resets with the process.
    var displayUnit: DisplayUnit = .revenue

    init(
        provider: any DataProvider,
        account: AccountManager = AccountManager(),
        config: ConfigStore = ConfigStore()
    ) {
        self.fallbackProvider = provider
        self.account = account
        self.config = config
        self.selectedMonth = YearMonth(containing: Date(), timeZone: .current)
        Task {
            await self.refresh()
        }
    }

    /// Client configs driving all display. ConfigStore holds the real,
    /// Toggl-reconciled configs; before any account is connected the demo
    /// clients keep the dashboard alive.
    var clients: [ClientConfig] {
        if !config.clients.isEmpty {
            return config.clients
        }
        return account.isConnected ? [] : MockDataProvider.sampleClients()
    }

    var timeZone: TimeZone {
        displaySettings.timeZone
    }

    var currentMonth: YearMonth {
        YearMonth(containing: Date(), timeZone: timeZone)
    }

    // MARK: Data source selection

    /// The provider to fetch with right now:
    /// - connected: the Toggl-backed provider (rebuilt when the account changes),
    /// - never connected (no real configs): the demo provider,
    /// - disconnected but real configs exist: nil — no fetching, cached
    ///   snapshots stay visible.
    private func activeProvider() -> (any DataProvider)? {
        if account.isConnected, let api = account.apiClient() {
            if togglProvider == nil || togglProviderGeneration != account.generation {
                togglProvider = TogglDataProvider(api: api)
                togglProviderGeneration = account.generation
            }
            return togglProvider
        }
        togglProvider = nil
        return config.clients.isEmpty ? fallbackProvider : nil
    }

    // MARK: Loading

    /// Full refresh: available months, current month, and (if needed) the
    /// selected month. Called when the popover opens or the user asks for a
    /// refresh.
    func refresh() async {
        guard let provider = activeProvider() else {
            // Offline-by-choice (disconnected, real data cached): no fetching.
            availableMonths = Set(snapshots.keys).union([currentMonth]).sorted()
            return
        }
        isLoading = true
        defer { isLoading = false }
        let now = Date()
        do {
            let fetchable = try await provider.availableMonths(asOf: now, timeZone: timeZone)
            availableMonths = Set(fetchable).union(snapshots.keys).sorted()
            snapshots[currentMonth] = try await provider.loadSnapshot(for: currentMonth, timeZone: timeZone, now: now)
            if selectedMonth != currentMonth, snapshots[selectedMonth] == nil {
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

    /// Fetches the Toggl client list (all workspaces, sequentially to respect
    /// free-plan limits) and reconciles it into ConfigStore. Called when the
    /// Clients settings page opens and from its manual refresh button.
    func refreshClientList() async {
        guard let api = account.apiClient() else { return }
        clientListLoading = true
        defer { clientListLoading = false }
        do {
            let workspaces = try await api.workspaces()
            var allClients: [TogglClientDTO] = []
            for workspace in workspaces {
                allClients += try await api.clients(workspaceID: workspace.id)
            }
            config.merge(workspaces: workspaces, togglClients: allClients)
            clientListError = nil
        } catch let error as TogglAPIError {
            clientListError = error.errorDescription
        } catch {
            clientListError = error.localizedDescription
        }
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
        guard let provider = activeProvider() else { return }
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
