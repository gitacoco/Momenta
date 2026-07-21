import AppKit
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
    /// Single instance shared by the status item (AppKit) and the SwiftUI
    /// Settings scene.
    static let shared = AppState(provider: MockDataProvider())

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
            if oldValue.aggregationPeriod != displaySettings.aggregationPeriod {
                // A day/week anchor is meaningless under a different granularity.
                resetReferenceToNow()
            }
            if oldValue.refreshMode != displaySettings.refreshMode
                || oldValue.refreshIntervalMinutes != displaySettings.refreshIntervalMinutes {
                rescheduleIntervalRefresh()
            }
        }
    }
    var selectedMonth: YearMonth
    var availableMonths: [YearMonth] = []
    /// The app's single observable "now": every UI surface (menu bar, Settings
    /// preview, popover) derives "current day/week/month" from this one value,
    /// so no two consumers can straddle a midnight by calling `Date()`
    /// independently. Advanced by a boundary-scheduled tick plus wake /
    /// clock-change / time-zone invalidation — see `clockDidJump`.
    /// Settable directly only by the clock and by tests.
    var displayNow: Date = Date()
    /// Months with a fetch in flight, tracked individually so concurrent
    /// loads cannot clobber each other's state and the week gate can check
    /// exactly the months it is missing.
    var loadingMonths: Set<YearMonth> = []
    /// Most recent failure message per month, cleared when a snapshot lands.
    var failedMonths: [YearMonth: String] = [:]
    /// Whether the full refresh cycle is running (distinct from single-month
    /// loads so neither can clear the other's in-flight state).
    private var isRefreshing = false
    var isLoading: Bool { isRefreshing || !loadingMonths.isEmpty }
    var lastError: String?
    /// Classified error from the most recent failed fetch, for state-specific
    /// icons and recovery paths in the UI.
    var lastAPIError: TogglAPIError?
    var clientListLoading = false
    var clientListError: String?
    var clientListAPIError: TogglAPIError?
    /// Popover chart unit toggle. View state only, resets with the process.
    var displayUnit: DisplayUnit = .hours
    /// Historical anchor for the popover's period navigation. `nil` means
    /// "follow `displayNow`" — the current period is then never a stored value
    /// that can go stale, and the popover agrees with the menu bar at every
    /// render by construction. Set only by backward navigation; stepping
    /// forward back into the current period resets it to nil.
    /// View state only, resets with the process.
    var selectedReference: Date? = nil
    /// Set right before opening the Settings window to land on a specific
    /// page (and client). Consumed by SettingsView / ClientsSettingsView.
    var pendingSettingsDestination: SettingsDestination?

    private var lastAutoRefreshAt: Date?
    /// The world a network operation was issued in. Captured when the provider
    /// is obtained and re-validated after every await — an operation that
    /// outlives its world (time-zone switch, cache clear, account change)
    /// must abandon silently instead of landing results or marking success.
    private struct FetchContext {
        var epoch: Int
        var accountGeneration: Int
        var timeZoneIdentifier: String
    }

    private func currentFetchContext() -> FetchContext {
        FetchContext(
            epoch: fetchEpoch,
            accountGeneration: account.generation,
            timeZoneIdentifier: timeZone.identifier
        )
    }

    /// Throws `CancellationError` when the captured context no longer matches
    /// the live world. Callers treat that as silent abandonment: no error is
    /// recorded, nothing is cleared, nothing is marked synced.
    private func validate(_ context: FetchContext) throws {
        guard context.epoch == fetchEpoch,
              context.accountGeneration == account.generation,
              context.timeZoneIdentifier == timeZone.identifier else {
            throw CancellationError()
        }
    }

    /// One in-flight fetch per month, tagged with the world it was issued in.
    /// A caller finding a live entry awaits that task and inherits its outcome
    /// instead of issuing a second request; an entry from a stale world is
    /// never joined and its result never lands.
    private struct MonthFetch {
        var task: Task<Void, Error>
        var epoch: Int
        var accountGeneration: Int
    }
    @ObservationIgnored private var monthFetches: [YearMonth: MonthFetch] = [:]
    /// Bumped whenever in-flight request context becomes invalid — time-zone
    /// change or cache clear. Account switches are covered by comparing
    /// `account.generation` directly.
    @ObservationIgnored private var fetchEpoch = 0
    @ObservationIgnored private var boundaryTick: Task<Void, Never>?
    @ObservationIgnored private var intervalRefreshTick: Task<Void, Never>?
    @ObservationIgnored private var wakeObserver: NSObjectProtocol?
    @ObservationIgnored private var clockChangeObserver: NSObjectProtocol?
    @ObservationIgnored private var timeZoneChangeObserver: NSObjectProtocol?

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
        startClock()
        rescheduleIntervalRefresh()
        if autoRefresh {
            Task {
                // Launch refresh respects manual-only mode too.
                await self.refreshIfNeeded()
            }
        }
    }

    isolated deinit {
        boundaryTick?.cancel()
        intervalRefreshTick?.cancel()
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
        if let clockChangeObserver {
            NotificationCenter.default.removeObserver(clockChangeObserver)
        }
        if let timeZoneChangeObserver {
            NotificationCenter.default.removeObserver(timeZoneChangeObserver)
        }
    }

    // MARK: Display clock

    /// One clock for the whole app: a tick scheduled at the next day boundary
    /// (day boundaries subsume week and month rollovers), plus the two events
    /// that can jump the wall clock past a boundary without the tick firing
    /// on time — system sleep and manual clock changes.
    private func startClock() {
        scheduleBoundaryTick()
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.clockDidJump() }
        }
        clockChangeObserver = NotificationCenter.default.addObserver(
            forName: .NSSystemClockDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.clockDidJump() }
        }
        timeZoneChangeObserver = NotificationCenter.default.addObserver(
            forName: .NSSystemTimeZoneDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.systemTimeZoneDidChange() }
        }
    }

    /// The user travelled (or the system zone changed). Only relevant while
    /// following the system zone — a manually pinned zone keeps its boundaries
    /// wherever the machine goes. Cached snapshots were computed under the old
    /// zone's month boundaries, so this is a full time-zone invalidation.
    private func systemTimeZoneDidChange() {
        guard displaySettings.timeZoneIdentifier == nil else { return }
        handleTimeZoneChange()
    }

    private func scheduleBoundaryTick() {
        boundaryTick?.cancel()
        let calendar = YearMonth.calendar(in: timeZone)
        guard let nextDay = calendar.date(
            byAdding: .day, value: 1, to: calendar.startOfDay(for: displayNow)
        ) else { return }
        let delay = max(1, nextDay.timeIntervalSince(Date()))
        boundaryTick = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.clockDidJump()
        }
    }

    /// Drives the `.interval` refresh mode: a loop that fetches every
    /// user-chosen span of minutes and no-ops in any other mode. Restarted
    /// whenever the mode or interval changes so a new cadence takes effect at
    /// once. Each tick uses the throttled `refresh()`, so a popover-open fetch
    /// moments earlier is reused rather than double-spent.
    private func rescheduleIntervalRefresh() {
        intervalRefreshTick?.cancel()
        intervalRefreshTick = nil
        guard displaySettings.refreshMode == .interval else { return }
        let minutes = displaySettings.refreshIntervalMinutes
        let seconds = TimeInterval(max(DisplaySettings.refreshIntervalRange.lowerBound, minutes)) * 60
        intervalRefreshTick = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(seconds))
                guard !Task.isCancelled else { return }
                guard let self else { return }
                await self.refresh()
            }
        }
    }

    /// Advances `displayNow` and performs the rollover work: re-schedule the
    /// next tick, keep `selectedMonth` on the current month while following
    /// "now", and prepare week neighbours. Passive by nature, so the fetch
    /// side respects manual-refresh mode. `now` is injectable for tests only;
    /// production callers always land on the real clock.
    func clockDidJump(now: Date = Date()) {
        displayNow = now
        scheduleBoundaryTick()
        if selectedReference == nil {
            let month = currentMonth
            if month != selectedMonth {
                selectedMonth = month
                if displaySettings.allowsPassiveFetch, snapshots[month] == nil {
                    Task { await self.loadMonth(month) }
                }
            }
        }
        prepareWeekNeighbors(userInitiated: false)
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
        YearMonth(containing: displayNow, timeZone: timeZone)
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
        guard displaySettings.allowsPassiveFetch else { return }
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
        // The context is captured with the provider and re-validated after
        // every await: a refresh whose world died mid-flight must not update
        // months, clear errors, or mark the account synced.
        let context = currentFetchContext()
        isRefreshing = true
        defer { isRefreshing = false }
        let now = Date()
        do {
            let fetchable = try await provider.availableMonths(asOf: now, timeZone: timeZone)
            try validate(context)
            availableMonths = Set(fetchable).union(snapshots.keys).sorted()
            try await fetchMonth(currentMonth, provider: provider, now: now, context: context)
            if selectedMonth != currentMonth, force || snapshots[selectedMonth] == nil {
                try await fetchMonth(selectedMonth, provider: provider, now: now, context: context)
            }
            try validate(context)
            lastError = nil
            lastAPIError = nil
            account.markSynced(at: now)
        } catch {
            recordFetchError(error)
        }
        // A straddling week may need a past neighbour month on top of the two
        // months above. Manual refresh counts as user intent.
        prepareWeekNeighbors(userInitiated: force)
    }

    private func store(_ snapshot: TimeEntrySnapshot, for month: YearMonth) {
        snapshots[month] = snapshot
        failedMonths[month] = nil
        // Demo data never touches the disk cache.
        if account.isConnected {
            snapshotCache.save(snapshots)
        }
    }

    private func recordFetchError(_ error: Error) {
        // An abandoned stale-context fetch is not a failure the user acts on.
        guard !(error is CancellationError) else { return }
        lastAPIError = error as? TogglAPIError
        lastError = lastAPIError?.errorDescription ?? error.localizedDescription
    }

    /// Month boundaries move with the time zone: cached snapshots computed
    /// under the old zone are invalid, so drop and refetch them. The display
    /// clock re-anchors too — "today" may differ under the new zone.
    private func handleTimeZoneChange() {
        invalidateInFlightFetches()
        snapshots.removeAll()
        snapshotCache.clear()
        selectedReference = nil
        selectedMonth = currentMonth
        clockDidJump()
        Task {
            await self.refresh(force: true)
        }
    }

    /// Drops all cached month data. Offered when disconnecting the account.
    /// In-flight fetches are abandoned too — their results belong to the
    /// context the user just chose to discard.
    func clearCache() {
        invalidateInFlightFetches()
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
            clientListAPIError = nil
        } catch let error as TogglAPIError {
            clientListError = error.errorDescription
            clientListAPIError = error
        } catch {
            clientListError = error.localizedDescription
            clientListAPIError = nil
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
        await loadMonth(selectedMonth)
    }

    private func loadMonth(_ month: YearMonth) async {
        guard let provider = activeProvider() else { return }
        let context = currentFetchContext()
        do {
            try await fetchMonth(month, provider: provider, now: Date(), context: context)
            lastError = nil
            lastAPIError = nil
        } catch {
            recordFetchError(error)
        }
    }

    /// Single chokepoint for month fetches: every caller — the full refresh,
    /// on-demand history loads, week neighbours — comes through here. A month
    /// already in flight is never requested twice (Toggl's quota is too tight
    /// for duplicates); the second caller instead awaits the same task and
    /// inherits its success or failure, so a refresh joining an in-flight
    /// load cannot report success before that load actually finishes.
    /// Joins and landings are both epoch-checked: a task issued under an old
    /// time zone, cache, or account is neither joined nor allowed to store.
    private func fetchMonth(
        _ month: YearMonth,
        provider: any DataProvider,
        now: Date,
        context: FetchContext
    ) async throws {
        try validate(context)
        if let inFlight = monthFetches[month],
           inFlight.epoch == fetchEpoch,
           inFlight.accountGeneration == account.generation {
            try await inFlight.task.value
            // The joined task may have completed just before the world died;
            // this caller must not resume into a success path regardless.
            try validate(context)
            return
        }
        loadingMonths.insert(month)
        let fetch = Task {
            let snapshot = try await provider.loadSnapshot(for: month, timeZone: timeZone, now: now)
            // The world may have changed while the request was out (time-zone
            // switch, cache clear, account change): a stale result must not
            // land in memory, on disk, or in a caller's success path.
            try self.validate(context)
            self.store(snapshot, for: month)
        }
        monthFetches[month] = MonthFetch(
            task: fetch,
            epoch: context.epoch,
            accountGeneration: context.accountGeneration
        )
        defer {
            // Identity check: an invalidation may already have installed a
            // newer fetch for this month; this older caller must not tear
            // down the newer task's registration or loading state.
            if monthFetches[month]?.task == fetch {
                monthFetches[month] = nil
                loadingMonths.remove(month)
            }
        }
        do {
            try await fetch.value
            // Same window as the join path: the store may have landed in the
            // instant before an invalidation; the caller still must not
            // continue as a success in the new world.
            try validate(context)
        } catch {
            // Recorded here, in the same main-actor turn as the defer above,
            // so failure and in-flight state never disagree mid-transition.
            // Abandoned (stale-context) fetches are not failures.
            if !(error is CancellationError) {
                failedMonths[month] = (error as? TogglAPIError)?.errorDescription
                    ?? error.localizedDescription
            }
            throw error
        }
    }

    /// Abandons every in-flight month fetch. Their results were requested in
    /// a world (time zone, cache, account) that no longer exists; completed
    /// tasks fail the epoch guard and land nothing.
    private func invalidateInFlightFetches() {
        fetchEpoch += 1
        for fetch in monthFetches.values {
            fetch.task.cancel()
        }
        monthFetches.removeAll()
        loadingMonths.removeAll()
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

    /// Progress for a loaded month; the popover derives all period views from
    /// these via `popoverData()`. Running-entry elapsed time is evaluated at
    /// the snapshot's fetch time: no local ticking between syncs.
    func progresses(for month: YearMonth) -> [ClientProgress] {
        guard let snapshot = snapshots[month] else { return [] }
        return clients.compactMap { client in
            guard client.isDisplayable(for: month) else { return nil }
            return ProgressCalculator.progress(
                for: client,
                entries: snapshot.entries,
                month: month,
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

    /// The status item's aggregate, always at the shared clock. Week routes
    /// through the unified slice path; an incomplete week publishes nothing
    /// (the label renders its explicit empty state) rather than a partial
    /// number.
    var menuBarAggregate: AggregateProgress? {
        switch displaySettings.aggregationPeriod {
        case .week:
            guard case .complete(let week) = weekDataState(at: displayNow) else { return nil }
            return week.aggregate
        case .day, .month:
            return singleMonthAggregate(at: displayNow)
        }
    }

    /// Day/month aggregate for the month containing `reference`. Never valid
    /// for weeks — those stitch across months via `weekDataState(at:)`.
    private func singleMonthAggregate(at reference: Date) -> AggregateProgress? {
        let month = YearMonth(containing: reference, timeZone: timeZone)
        guard let snapshot = snapshots[month] else { return nil }
        return ProgressCalculator.aggregate(
            clients: clients,
            entries: snapshot.entries,
            month: month,
            period: displaySettings.aggregationPeriod == .day ? .day : .month,
            timeZone: timeZone,
            now: snapshot.fetchedAt,
            periodReference: reference
        )
    }

    var hasConfiguredClients: Bool {
        clients.contains { $0.isDisplayable(for: currentMonth) }
    }

    // MARK: Popover period navigation

    /// The reference the popover is showing: an explicit historical anchor,
    /// or the shared clock when following "now".
    var activeReference: Date {
        selectedReference ?? displayNow
    }

    /// True when the shown day is the actual current day, so the day bullet
    /// uses the live catch-up pace rather than a frozen day-start pace.
    var isReferenceCurrentDay: Bool {
        YearMonth.calendar(in: timeZone).isDate(activeReference, inSameDayAs: displayNow)
    }

    func stepBackward() {
        guard canGoBackward else { return }
        switch displaySettings.aggregationPeriod {
        case .day: moveReference(byDays: -1)
        case .week: moveReference(byDays: -7)
        case .month: moveReference(toMonth: selectedMonth.previous)
        }
    }

    func stepForward() {
        guard canGoForward else { return }
        switch displaySettings.aggregationPeriod {
        case .day: moveReference(byDays: 1)
        case .week: moveReference(byDays: 7)
        case .month: moveReference(toMonth: selectedMonth.next)
        }
    }

    var canGoBackward: Bool {
        guard let earliest = availableMonths.first else { return false }
        switch displaySettings.aggregationPeriod {
        case .day: return earliestMonth(steppingDays: -1) >= earliest
        case .week: return earliestMonth(steppingDays: -7) >= earliest
        case .month: return earliest < selectedMonth
        }
    }

    var canGoForward: Bool {
        let calendar = YearMonth.calendar(in: timeZone)
        switch displaySettings.aggregationPeriod {
        case .day:
            return calendar.startOfDay(for: activeReference) < calendar.startOfDay(for: displayNow)
        case .week:
            guard let current = calendar.dateInterval(of: .weekOfYear, for: displayNow)?.start,
                  let shown = calendar.dateInterval(of: .weekOfYear, for: activeReference)?.start
            else { return false }
            return shown < current
        case .month:
            return selectedMonth < currentMonth
        }
    }

    private func moveReference(byDays days: Int) {
        guard let stepped = YearMonth.calendar(in: timeZone)
            .date(byAdding: .day, value: days, to: activeReference) else { return }
        setReference(stepped)
    }

    private func moveReference(toMonth month: YearMonth) {
        setReference(month.start(in: timeZone))
    }

    /// Stores an explicit historical anchor — or returns to clock-following
    /// when the target lands in the current period, so "current" is never a
    /// stored value that can go stale.
    private func setReference(_ date: Date) {
        selectedReference = isInCurrentPeriod(date) ? nil : date
        syncSelectedMonthToReference()
    }

    private func isInCurrentPeriod(_ date: Date) -> Bool {
        let calendar = YearMonth.calendar(in: timeZone)
        switch displaySettings.aggregationPeriod {
        case .day:
            return calendar.isDate(date, inSameDayAs: displayNow)
        case .week:
            return calendar.dateInterval(of: .weekOfYear, for: date)?.start
                == calendar.dateInterval(of: .weekOfYear, for: displayNow)?.start
        case .month:
            return YearMonth(containing: date, timeZone: timeZone) == currentMonth
        }
    }

    /// Re-anchors the popover to the current day/week/month.
    func resetReferenceToNow() {
        selectedReference = nil
        syncSelectedMonthToReference()
    }

    /// Every reference change is explicit user navigation, so the week
    /// neighbour fetch below counts as manual intent.
    private func syncSelectedMonthToReference() {
        let month = YearMonth(containing: activeReference, timeZone: timeZone)
        if month != selectedMonth {
            select(month: month)
        }
        prepareWeekNeighbors(userInitiated: true)
    }

    /// Months a Monday–Sunday week around `reference` touches (one, or two when
    /// it straddles a month boundary).
    private func weekMonths(for reference: Date) -> Set<YearMonth> {
        let calendar = YearMonth.calendar(in: timeZone)
        guard let week = calendar.dateInterval(of: .weekOfYear, for: reference) else {
            return [YearMonth(containing: reference, timeZone: timeZone)]
        }
        var months: Set<YearMonth> = []
        for offset in 0..<7 {
            if let day = calendar.date(byAdding: .day, value: offset, to: week.start) {
                months.insert(YearMonth(containing: day, timeZone: timeZone))
            }
        }
        return months
    }

    /// Earliest month a backward step would land in (a week step's earliest
    /// touched month), used to bound backward navigation.
    private func earliestMonth(steppingDays days: Int) -> YearMonth {
        let calendar = YearMonth.calendar(in: timeZone)
        guard let stepped = calendar.date(byAdding: .day, value: days, to: activeReference) else {
            return selectedMonth
        }
        if displaySettings.aggregationPeriod == .week {
            return weekMonths(for: stepped).min() ?? YearMonth(containing: stepped, timeZone: timeZone)
        }
        return YearMonth(containing: stepped, timeZone: timeZone)
    }

    /// Fetches the past months a Mon–Sun week needs. Explicit navigation and
    /// manual refresh count as user intent and may always fetch; passive
    /// callers (popover open, boundary tick) respect manual-refresh mode.
    /// Future months are never fetched — they synthesize locally.
    func prepareWeekNeighbors(userInitiated: Bool) {
        guard displaySettings.aggregationPeriod == .week else { return }
        guard userInitiated || displaySettings.allowsPassiveFetch else { return }
        for month in weekMonths(for: activeReference)
        where snapshots[month] == nil && month <= currentMonth && !loadingMonths.contains(month) {
            Task { await loadMonth(month) }
        }
    }

    // MARK: Week data (shared by the menu bar and the popover)

    /// UI-neutral payload for one full Mon–Sun week: the per-client slices the
    /// cards render and the aggregate built from those same slices. The menu
    /// bar consumes the aggregate; the popover consumes both.
    struct WeekData {
        var sliceByClientID: [Int: ClientPeriodSlice]
        /// Nil when no client carries a goal for the week.
        var aggregate: AggregateProgress?
    }

    /// A week is published only when every past month it touches is loaded.
    /// The missing set travels with the state so an unrelated in-flight month
    /// can never misclassify this week — the check is an intersection, not a
    /// global flag.
    enum WeekDataState {
        case complete(WeekData)
        case loading(missing: Set<YearMonth>)
        case unavailable(missing: Set<YearMonth>)
    }

    func weekDataState(at reference: Date) -> WeekDataState {
        let months = weekMonths(for: reference)
        // Future months are always synthesizable locally; only past and
        // current months can be genuinely missing.
        let missing = Set(months.filter { $0 <= currentMonth && snapshots[$0] == nil })
        guard missing.isEmpty else {
            return missing.isDisjoint(with: loadingMonths)
                ? .unavailable(missing: missing)
                : .loading(missing: missing)
        }

        var progressByClientMonth: [Int: [YearMonth: ClientProgress]] = [:]
        for month in months {
            let monthProgresses = month > currentMonth
                ? synthesizedProgresses(for: month)
                : progresses(for: month)
            for progress in monthProgresses {
                progressByClientMonth[progress.client.id, default: [:]][month] = progress
            }
        }
        // Config order so the menu bar's per-client shares match the user's
        // arrangement, exactly like the single-month aggregate.
        var ordered: [ClientPeriodSlice] = []
        var byID: [Int: ClientPeriodSlice] = [:]
        for client in visibleClients {
            guard let byMonth = progressByClientMonth[client.id], !byMonth.isEmpty else { continue }
            let slice = ProgressCalculator.weekSlice(
                client: client,
                progressByMonth: byMonth,
                reference: reference,
                timeZone: timeZone
            )
            ordered.append(slice)
            byID[client.id] = slice
        }
        return .complete(WeekData(
            sliceByClientID: byID,
            aggregate: ProgressCalculator.weekAggregate(slices: ordered)
        ))
    }

    /// Planned-only progress for a month after the current one, derived
    /// entirely from local configuration (goal + pacing): empty entries, all
    /// actuals nil. Never fetched from Toggl, never persisted.
    private func synthesizedProgresses(for month: YearMonth) -> [ClientProgress] {
        clients.compactMap { client in
            guard client.isDisplayable(for: month) else { return nil }
            return ProgressCalculator.progress(
                for: client,
                entries: [],
                month: month,
                timeZone: timeZone,
                now: displayNow
            )
        }
    }

    // MARK: Popover period data

    /// Everything the popover derives for the active period + reference. Built
    /// by one `popoverData()` call per render so the month accrual, slices,
    /// and Overall are computed from a single pass instead of once per access.
    struct PopoverData {
        var progressByClientID: [Int: ClientProgress]
        var sliceByClientID: [Int: ClientPeriodSlice]
        var overall: AggregateProgress?
    }

    /// The popover's completeness gate. Day/month satisfy it structurally
    /// (a missing selected-month snapshot yields no numbers plus the existing
    /// unavailable banner); the week cases surface the gate explicitly.
    enum PeriodDataState {
        case complete(PopoverData)
        case loading(missing: Set<YearMonth>)
        case unavailable(missing: Set<YearMonth>)
    }

    func popoverData() -> PeriodDataState {
        switch displaySettings.aggregationPeriod {
        case .month:
            return .complete(PopoverData(
                progressByClientID: monthProgressByID(),
                sliceByClientID: [:],
                overall: singleMonthOverall()
            ))
        case .day:
            let monthProgress = monthProgressByID()
            let isCurrent = isReferenceCurrentDay
            let slices = monthProgress.mapValues { progress in
                ProgressCalculator.daySlice(
                    progress: progress,
                    reference: activeReference,
                    isCurrentDay: isCurrent,
                    timeZone: timeZone
                )
            }
            return .complete(PopoverData(
                progressByClientID: monthProgress,
                sliceByClientID: slices,
                overall: singleMonthOverall()
            ))
        case .week:
            switch weekDataState(at: activeReference) {
            case .complete(let week):
                return .complete(PopoverData(
                    progressByClientID: [:],
                    sliceByClientID: week.sliceByClientID,
                    overall: week.aggregate
                ))
            case .loading(let missing):
                return .loading(missing: missing)
            case .unavailable(let missing):
                return .unavailable(missing: missing)
            }
        }
    }

    private func monthProgressByID() -> [Int: ClientProgress] {
        Dictionary(
            uniqueKeysWithValues: progresses(for: selectedMonth).map { ($0.client.id, $0) }
        )
    }

    /// Day/month Overall at the active reference, both units carried. Nil
    /// when no configured client contributes.
    private func singleMonthOverall() -> AggregateProgress? {
        guard let aggregate = singleMonthAggregate(at: activeReference),
              !aggregate.shares.isEmpty else { return nil }
        return aggregate
    }
}
