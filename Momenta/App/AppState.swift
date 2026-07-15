import Foundation
import Observation

/// Deep-link target inside the Settings window.
enum SettingsDestination: Equatable, Sendable {
    case account
    case clients(clientID: Int?)
}

@MainActor
@Observable
final class AppState {
    /// Demo data source used before any Toggl account is connected.
    private let fallbackProvider: any DataProvider
    private var togglProvider: TogglDataProvider?
    private var togglProviderGeneration = -1
    let account: AccountManager
    let config: ConfigStore
    private let snapshotCache: SnapshotCache
    private let defaults: UserDefaults

    private static let displaySettingsKey = "momenta.displaySettings"
    /// Repeated popover opens within this window reuse the last fetch.
    static let minAutoRefreshInterval: TimeInterval = 60

    var snapshots: [YearMonth: TimeEntrySnapshot] = [:]
    var displaySettings = DisplaySettings() {
        didSet {
            if let data = try? JSONEncoder().encode(displaySettings) {
                defaults.set(data, forKey: Self.displaySettingsKey)
            }
            if oldValue.timeZoneIdentifier != displaySettings.timeZoneIdentifier {
                handleTimeZoneChange()
            }
        }
    }
    var selectedMonth: YearMonth
    var availableMonths: [YearMonth] = []
    var isLoading = false
    var lastError: String?
    /// Classified error from the most recent failed fetch, for state-specific
    /// icons and recovery paths in the UI.
    var lastAPIError: TogglAPIError?
    var clientListLoading = false
    var clientListError: String?
    /// Popover chart unit toggle. View state only, resets with the process.
    var displayUnit: DisplayUnit = .revenue
    /// Set right before opening the Settings window to land on a specific
    /// page (and client). Consumed by SettingsView / ClientsSettingsView.
    var pendingSettingsDestination: SettingsDestination?

    private var lastAutoRefreshAt: Date?

    init(
        provider: any DataProvider,
        account: AccountManager = AccountManager(),
        config: ConfigStore = ConfigStore(),
        snapshotCache: SnapshotCache = SnapshotCache(),
        defaults: UserDefaults = .standard,
        autoRefresh: Bool = true
    ) {
        self.fallbackProvider = provider
        self.account = account
        self.config = config
        self.snapshotCache = snapshotCache
        self.defaults = defaults
        var settings = DisplaySettings()
        if let data = defaults.data(forKey: Self.displaySettingsKey),
           let decoded = try? JSONDecoder().decode(DisplaySettings.self, from: data) {
            settings = decoded
        }
        displaySettings = settings
        // The last successful snapshots stay visible offline and on relaunch.
        snapshots = snapshotCache.load()
        selectedMonth = YearMonth(containing: Date(), timeZone: settings.timeZone)
        availableMonths = Set(snapshots.keys)
            .union([YearMonth(containing: Date(), timeZone: settings.timeZone)])
            .sorted()
        if autoRefresh {
            Task {
                // Launch refresh respects manual-only mode too.
                await self.refreshIfNeeded()
            }
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

    /// Popover-open path: disabled entirely in manual-refresh mode, and
    /// throttled otherwise so repeatedly opening and closing the popover
    /// cannot burn through the API quota. Manual refresh bypasses both.
    func refreshIfNeeded() async {
        guard displaySettings.autoRefreshOnOpen else { return }
        if let last = lastAutoRefreshAt,
           Date().timeIntervalSince(last) < Self.minAutoRefreshInterval {
            return
        }
        await refresh()
    }

    /// Full refresh: available months, the current month, and the selected
    /// month. Historical months are treated as stable — they refetch only on
    /// a manual (forced) refresh.
    func refresh(force: Bool = false) async {
        lastAutoRefreshAt = Date()
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
            store(try await provider.loadSnapshot(for: currentMonth, timeZone: timeZone, now: now), for: currentMonth)
            if selectedMonth != currentMonth, force || snapshots[selectedMonth] == nil {
                store(try await provider.loadSnapshot(for: selectedMonth, timeZone: timeZone, now: now), for: selectedMonth)
            }
            lastError = nil
            lastAPIError = nil
            account.markSynced(at: now)
        } catch {
            recordFetchError(error)
        }
    }

    private func store(_ snapshot: TimeEntrySnapshot, for month: YearMonth) {
        snapshots[month] = snapshot
        // Demo data never touches the disk cache.
        if account.isConnected {
            snapshotCache.save(snapshots)
        }
    }

    private func recordFetchError(_ error: Error) {
        lastAPIError = error as? TogglAPIError
        lastError = lastAPIError?.errorDescription ?? error.localizedDescription
    }

    /// Month boundaries move with the time zone: cached snapshots computed
    /// under the old zone are invalid, so drop and refetch them.
    private func handleTimeZoneChange() {
        snapshots.removeAll()
        snapshotCache.clear()
        selectedMonth = currentMonth
        Task {
            await self.refresh(force: true)
        }
    }

    /// Drops all cached month data. Offered when disconnecting the account.
    func clearCache() {
        snapshots.removeAll()
        snapshotCache.clear()
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
            let month = selectedMonth
            store(try await provider.loadSnapshot(for: month, timeZone: timeZone, now: Date()), for: month)
            lastError = nil
            lastAPIError = nil
        } catch {
            recordFetchError(error)
        }
    }

    // MARK: Freshness

    /// True when what's on screen is a cached snapshot that could not be (or
    /// deliberately isn't being) refreshed.
    var isShowingStaleData: Bool {
        guard selectedSnapshot != nil else { return false }
        if lastAPIError != nil { return true }
        return !account.isConnected && !config.clients.isEmpty
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

    /// Every enabled, non-archived client. Each of these always gets a row in
    /// the popover — with data, with a "needs setup" prompt, or with an
    /// explicit "no data" explanation. Nothing enabled ever disappears.
    var visibleClients: [ClientConfig] {
        clients.filter { $0.isEnabled && !$0.isArchivedInToggl }
    }

    var progressByClientID: [Int: ClientProgress] {
        Dictionary(uniqueKeysWithValues: progresses.map { ($0.client.id, $0) })
    }

    /// Why data for the selected month may be missing, in user terms.
    var dataUnavailableReason: String {
        if let message = lastError {
            return message
        }
        if !account.isConnected {
            return "Not connected to Toggl."
        }
        return "No data fetched for this month yet."
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
