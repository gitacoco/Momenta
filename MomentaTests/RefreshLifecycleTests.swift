import Foundation
import Testing
@testable import Momenta

/// Counts fetches; mutations happen on the main actor only.
final class CountingProvider: DataProvider, @unchecked Sendable {
    private(set) var snapshotLoads = 0

    func loadSnapshot(for month: YearMonth, timeZone: TimeZone, now: Date) async throws -> TimeEntrySnapshot {
        snapshotLoads += 1
        return TimeEntrySnapshot(month: month, fetchedAt: now, entries: [])
    }

    func availableMonths(asOf now: Date, timeZone: TimeZone) async throws -> [YearMonth] {
        [YearMonth(containing: now, timeZone: timeZone)]
    }
}

@MainActor
struct RefreshLifecycleTests {
    private func freshDefaults() -> UserDefaults {
        let suite = "MomentaTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private func tempCache() -> SnapshotCache {
        SnapshotCache(fileURL: FileManager.default.temporaryDirectory
            .appending(path: "momenta-tests-\(UUID().uuidString).json"))
    }

    private func disconnectedAccount() -> AccountManager {
        AccountManager(
            tokenStore: InMemoryTokenStore(),
            transport: SequenceTransport([]),
            defaults: freshDefaults()
        )
    }

    /// An account restored as connected (token + snapshot present) whose API
    /// calls are served by the given transport.
    private func connectedAccount(transport: any HTTPTransport) -> AccountManager {
        let defaults = freshDefaults()
        let snapshot = AccountSnapshot(
            fullname: "Z", email: "z@x.dev",
            workspaces: [TogglWorkspace(id: 101, name: "Freelance")],
            connectedAt: Date()
        )
        defaults.set(try! JSONEncoder().encode(snapshot), forKey: "toggl.accountSnapshot")
        return AccountManager(
            tokenStore: InMemoryTokenStore(token: "tok"),
            transport: transport,
            defaults: defaults
        )
    }

    private func togglRoutes() -> RoutingTransport {
        RoutingTransport(routes: [
            ("time_entries/current", "null"),
            ("time_entries", "[]"),
            ("workspaces/101/projects", "[]"),
            ("workspaces", #"[{"id":101,"name":"Freelance"}]"#),
        ])
    }

    // MARK: Throttling

    @Test func popoverOpensWithinIntervalReuseLastFetch() async {
        let provider = CountingProvider()
        let appState = AppState(
            provider: provider,
            account: disconnectedAccount(),
            config: ConfigStore(defaults: freshDefaults()),
            snapshotCache: tempCache(),
            defaults: freshDefaults(),
            autoRefresh: false
        )
        await appState.refreshIfNeeded()
        await appState.refreshIfNeeded()
        await appState.refreshIfNeeded()
        #expect(provider.snapshotLoads == 1)
    }

    @Test func manualRefreshBypassesThrottle() async {
        let provider = CountingProvider()
        let appState = AppState(
            provider: provider,
            account: disconnectedAccount(),
            config: ConfigStore(defaults: freshDefaults()),
            snapshotCache: tempCache(),
            defaults: freshDefaults(),
            autoRefresh: false
        )
        await appState.refreshIfNeeded()
        await appState.refresh(force: true)
        #expect(provider.snapshotLoads == 2)
    }

    // MARK: Disk cache

    @Test func snapshotCacheRoundtrip() {
        let cache = tempCache()
        defer { cache.clear() }
        let month = YearMonth(year: 2026, month: 6)
        let snapshot = TimeEntrySnapshot(
            month: month,
            fetchedAt: Date(timeIntervalSince1970: 1_780_000_000),
            entries: [TimeEntry(id: 1, clientID: 7, start: Date(timeIntervalSince1970: 1_779_000_000), stop: nil)]
        )
        cache.save([month: snapshot])
        let loaded = cache.load()
        #expect(loaded[month]?.entries.first?.id == 1)
        #expect(loaded[month]?.entries.first?.isRunning == true)
        cache.clear()
        #expect(cache.load().isEmpty)
    }

    @Test func demoDataNeverTouchesDisk() async {
        let cache = tempCache()
        defer { cache.clear() }
        let appState = AppState(
            provider: CountingProvider(),
            account: disconnectedAccount(),
            config: ConfigStore(defaults: freshDefaults()),
            snapshotCache: cache,
            defaults: freshDefaults(),
            autoRefresh: false
        )
        await appState.refresh()
        #expect(!appState.snapshots.isEmpty)
        #expect(cache.load().isEmpty)
    }

    @Test func connectedSnapshotsPersistAndSurviveRelaunch() async {
        let cache = tempCache()
        defer { cache.clear() }
        let transport = togglRoutes()
        let account = connectedAccount(transport: transport)
        let appState = AppState(
            provider: CountingProvider(),
            account: account,
            config: ConfigStore(defaults: freshDefaults()),
            snapshotCache: cache,
            defaults: freshDefaults(),
            autoRefresh: false
        )
        await appState.refresh()
        #expect(!cache.load().isEmpty)

        // Relaunch: cached months are visible before any network call.
        let relaunched = AppState(
            provider: CountingProvider(),
            account: disconnectedAccount(),
            config: ConfigStore(defaults: freshDefaults()),
            snapshotCache: cache,
            defaults: freshDefaults(),
            autoRefresh: false
        )
        #expect(!relaunched.snapshots.isEmpty)
    }

    // MARK: Time zone change

    @Test func timeZoneChangeInvalidatesCaches() async {
        let cache = tempCache()
        defer { cache.clear() }
        let transport = togglRoutes()
        let appState = AppState(
            provider: CountingProvider(),
            account: connectedAccount(transport: transport),
            config: ConfigStore(defaults: freshDefaults()),
            snapshotCache: cache,
            defaults: freshDefaults(),
            autoRefresh: false
        )
        await appState.refresh()
        #expect(!cache.load().isEmpty)

        appState.displaySettings.timeZoneIdentifier = "Pacific/Kiritimati"

        // Synchronous effects: memory and disk cleared, selection reset. The
        // spawned refetch task repopulates later.
        #expect(cache.load().isEmpty)
        #expect(appState.selectedMonth == appState.currentMonth)
    }

    @Test func concurrentMonthLoadsTrackIndependently() async {
        // BON-21: a month finishing must not clear another month's in-flight
        // state — the gated provider holds both loads open at once.
        let provider = GatedProvider()
        let appState = AppState(
            provider: provider,
            account: disconnectedAccount(),
            config: ConfigStore(defaults: freshDefaults()),
            snapshotCache: tempCache(),
            defaults: freshDefaults(),
            autoRefresh: false
        )
        let previous = appState.currentMonth.previous
        let refreshTask = Task { await appState.refresh() }
        await waitUntil { !appState.loadingMonths.isEmpty }
        appState.select(month: previous)
        await waitUntil { appState.loadingMonths.count == 2 }
        #expect(appState.loadingMonths.contains(appState.currentMonth))
        #expect(appState.loadingMonths.contains(previous))
        provider.open()
        await refreshTask.value
        await waitUntil { appState.loadingMonths.isEmpty }
        #expect(appState.snapshots[previous] != nil)
    }

    @Test func displaySettingsPersistAcrossRelaunch() {
        let defaults = freshDefaults()
        let appState = AppState(
            provider: CountingProvider(),
            account: disconnectedAccount(),
            config: ConfigStore(defaults: freshDefaults()),
            snapshotCache: tempCache(),
            defaults: defaults,
            autoRefresh: false
        )
        appState.displaySettings.aggregationPeriod = .week
        appState.displaySettings.menuBarObjectMode = .both
        appState.displaySettings.menuBarVisualization = .waterline
        appState.displaySettings.showsOverallPercentage = true

        let relaunched = AppState(
            provider: CountingProvider(),
            account: disconnectedAccount(),
            config: ConfigStore(defaults: freshDefaults()),
            snapshotCache: tempCache(),
            defaults: defaults,
            autoRefresh: false
        )
        #expect(relaunched.displaySettings.aggregationPeriod == .week)
        #expect(relaunched.displaySettings.menuBarObjectMode == .both)
        #expect(relaunched.displaySettings.menuBarVisualization == .waterline)
        #expect(relaunched.displaySettings.showsOverallPercentage)
    }
}

/// Polls a main-actor condition with a bounded budget (~2s) so async state
/// transitions can be awaited without arbitrary fixed sleeps.
@MainActor
private func waitUntil(_ condition: () -> Bool) async {
    for _ in 0..<400 where !condition() {
        try? await Task.sleep(for: .milliseconds(5))
    }
}

/// Suspends every snapshot load until `open(throwing:)` is called, counting
/// entries, so tests can observe in-flight state deterministically and choose
/// whether the gated request ultimately succeeds or fails.
private final class GatedProvider: DataProvider, @unchecked Sendable {
    private let lock = NSLock()
    private let gatesAvailableMonths: Bool
    private var isOpen = false
    private var failure: Error?
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var loadCount = 0
    private var monthsCalls = 0

    init(gatesAvailableMonths: Bool = false) {
        self.gatesAvailableMonths = gatesAvailableMonths
    }

    var snapshotLoads: Int {
        lock.withLock { loadCount }
    }

    var availableMonthsCalls: Int {
        lock.withLock { monthsCalls }
    }

    /// Number of calls currently suspended on the gate. Waiting on this (not
    /// on AppState's loading flags) guarantees a caller is actually parked —
    /// and therefore that FIFO `release(_:)` order is deterministic.
    var suspendedLoads: Int {
        lock.withLock { waiters.count }
    }

    func open(throwing error: Error? = nil) {
        let resumable: [CheckedContinuation<Void, Never>] = lock.withLock {
            isOpen = true
            failure = error
            let waiting = waiters
            waiters = []
            return waiting
        }
        resumable.forEach { $0.resume() }
    }

    /// Resumes only the earliest `count` suspended loads (FIFO), leaving the
    /// gate closed for everything else — so tests can release an old request
    /// while a newer one stays in flight.
    func release(_ count: Int = 1) {
        let resumable: [CheckedContinuation<Void, Never>] = lock.withLock {
            let releasing = Array(waiters.prefix(count))
            waiters.removeFirst(min(count, waiters.count))
            return releasing
        }
        resumable.forEach { $0.resume() }
    }

    private func awaitGate() async {
        let openNow = lock.withLock { isOpen }
        if !openNow {
            await withCheckedContinuation { continuation in
                let resumeImmediately = lock.withLock {
                    if isOpen { return true }
                    waiters.append(continuation)
                    return false
                }
                if resumeImmediately {
                    continuation.resume()
                }
            }
        }
    }

    func loadSnapshot(for month: YearMonth, timeZone: TimeZone, now: Date) async throws -> TimeEntrySnapshot {
        lock.withLock { loadCount += 1 }
        await awaitGate()
        if let failure = lock.withLock({ failure }) {
            throw failure
        }
        return TimeEntrySnapshot(month: month, fetchedAt: now, entries: [])
    }

    func availableMonths(asOf now: Date, timeZone: TimeZone) async throws -> [YearMonth] {
        lock.withLock { monthsCalls += 1 }
        if gatesAvailableMonths {
            await awaitGate()
            if let failure = lock.withLock({ failure }) {
                throw failure
            }
        }
        return [YearMonth(containing: now, timeZone: timeZone)]
    }
}

/// Every fetch fails, so "missing and nothing can load" states are reachable.
private struct FailingProvider: DataProvider {
    func loadSnapshot(for month: YearMonth, timeZone: TimeZone, now: Date) async throws -> TimeEntrySnapshot {
        throw TogglAPIError.offline
    }

    func availableMonths(asOf now: Date, timeZone: TimeZone) async throws -> [YearMonth] {
        [YearMonth(containing: now, timeZone: timeZone)]
    }
}

/// BON-21 acceptance: one week implementation, one clock, no partial weeks.
@MainActor
struct WeekUnificationTests {
    private func freshDefaults() -> UserDefaults {
        let suite = "MomentaTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private func makeAppState(provider: any DataProvider) -> AppState {
        AppState(
            provider: provider,
            account: AccountManager(
                tokenStore: InMemoryTokenStore(),
                transport: SequenceTransport([]),
                defaults: freshDefaults()
            ),
            config: ConfigStore(defaults: freshDefaults()),
            snapshotCache: SnapshotCache(fileURL: FileManager.default.temporaryDirectory
                .appending(path: "momenta-tests-\(UUID().uuidString).json")),
            defaults: freshDefaults(),
            autoRefresh: false
        )
    }

    /// Noon of day 15: the containing week always lies fully inside the month,
    /// so these tests are deterministic on any real date.
    private func midMonth(_ appState: AppState) -> Date {
        appState.currentMonth.start(in: appState.timeZone).addingTimeInterval(14.5 * 86400)
    }

    @Test func menuBarAndPopoverWeekAgreeFieldByField() async {
        let appState = makeAppState(provider: MockDataProvider())
        appState.displayNow = midMonth(appState)
        await appState.refresh()
        appState.displaySettings.aggregationPeriod = .week

        guard case .complete(let popover) = appState.popoverData(),
              let popoverOverall = popover.overall,
              let menuBar = appState.menuBarAggregate else {
            Issue.record("expected complete week data on both surfaces")
            return
        }
        #expect(menuBar.actualRevenue == popoverOverall.actualRevenue)
        #expect(menuBar.targetRevenue == popoverOverall.targetRevenue)
        #expect(menuBar.actualHours == popoverOverall.actualHours)
        #expect(menuBar.targetHours == popoverOverall.targetHours)
        #expect(menuBar.fraction == popoverOverall.fraction)
        #expect(menuBar.shares.count == popoverOverall.shares.count)
        for (menuShare, popoverShare) in zip(menuBar.shares, popoverOverall.shares) {
            #expect(menuShare.client.id == popoverShare.client.id)
            #expect(menuShare.actualRevenue == popoverShare.actualRevenue)
            #expect(menuShare.targetRevenue == popoverShare.targetRevenue)
        }
        // The shares come from the same slices the cards render.
        for share in menuBar.shares {
            #expect(popover.sliceByClientID[share.client.id] != nil)
        }
    }

    @Test func missingMonthPublishesNoAggregateAnywhere() async {
        let appState = makeAppState(provider: FailingProvider())
        appState.displayNow = midMonth(appState)
        appState.displaySettings.aggregationPeriod = .week
        // The period switch spawns a neighbour fetch; wait for its recorded
        // failure — once visible, the in-flight state is already cleared.
        await waitUntil { appState.failedMonths[appState.currentMonth] != nil }

        guard case .unavailable(let missing) = appState.weekDataState(at: appState.displayNow) else {
            Issue.record("expected unavailable without a snapshot")
            return
        }
        #expect(missing == [appState.currentMonth])
        #expect(appState.menuBarAggregate == nil)
        if case .complete = appState.popoverData() {
            Issue.record("popover must not publish a partial week")
        }
        #expect(appState.failedMonths[appState.currentMonth] != nil)
    }

    @Test func fullRefreshRegistersLoadingAndNeverDuplicatesAFetch() async {
        let provider = GatedProvider()
        let appState = makeAppState(provider: provider)
        appState.displayNow = midMonth(appState)

        let refreshTask = Task { await appState.refresh() }
        await waitUntil { !appState.loadingMonths.isEmpty }
        #expect(appState.loadingMonths.contains(appState.currentMonth))

        // While the refresh holds the month in flight, the week gate reports
        // loading — and a neighbour-prepare pass must not fetch it again.
        appState.displaySettings.aggregationPeriod = .week
        guard case .loading(let missing) = appState.weekDataState(at: appState.displayNow) else {
            Issue.record("expected loading while the refresh is in flight")
            return
        }
        #expect(missing == [appState.currentMonth])
        #expect(appState.menuBarAggregate == nil)

        provider.open()
        await refreshTask.value
        await waitUntil { appState.loadingMonths.isEmpty }
        #expect(provider.snapshotLoads == 1)
        guard case .complete = appState.weekDataState(at: appState.displayNow) else {
            Issue.record("expected complete after the refresh landed")
            return
        }
    }

    @Test func refreshJoinsAnInFlightMonthFetchAndInheritsItsFailure() async {
        // Reverse order to the test above: the single-month fetch starts
        // FIRST, then a full refresh requests the same month. The refresh must
        // join the in-flight task — not treat it as already succeeded — and
        // when that task fails, the refresh must observe the failure and must
        // not mark the account as synced.
        let provider = GatedProvider()
        let appState = makeAppState(provider: provider)
        appState.displayNow = midMonth(appState)

        // 1. A single-month load enters flight and is parked on the gate.
        appState.select(month: appState.currentMonth)
        await waitUntil { provider.suspendedLoads == 1 }
        #expect(provider.snapshotLoads == 1)

        // 2. A full refresh for the same month starts afterwards.
        let refreshTask = Task { await appState.refresh() }

        // 3. Before the gate releases, the refresh must not have completed:
        //    nothing is synced and the month still shows as loading.
        try? await Task.sleep(for: .milliseconds(100))
        #expect(appState.account.lastSyncAt == nil)
        #expect(appState.loadingMonths.contains(appState.currentMonth))
        #expect(provider.snapshotLoads == 1)

        // 4. The gated request fails; the refresh inherits the failure.
        provider.open(throwing: TogglAPIError.offline)
        await refreshTask.value
        await waitUntil { appState.loadingMonths.isEmpty }
        #expect(appState.account.lastSyncAt == nil)
        #expect(appState.lastAPIError == .offline)
        #expect(appState.failedMonths[appState.currentMonth] != nil)
        #expect(appState.snapshots[appState.currentMonth] == nil)
        #expect(provider.snapshotLoads == 1)
    }

    @Test func refreshWhoseWorldDiesMidFlightMarksNothing() async {
        // The check-after-await gap: the refresh suspends on the network, the
        // context dies (cache cleared, e.g. via disconnect) while it is
        // suspended, and the resumed refresh must abandon — no months stored,
        // no error cleared, and above all no markSynced restoring a sync time
        // the disconnect just erased.
        let provider = GatedProvider(gatesAvailableMonths: true)
        let appState = makeAppState(provider: provider)
        appState.displayNow = midMonth(appState)

        let refreshTask = Task { await appState.refresh(force: true) }
        await waitUntil { provider.availableMonthsCalls == 1 }

        appState.clearCache()

        provider.open()
        await refreshTask.value
        #expect(appState.account.lastSyncAt == nil)
        #expect(appState.lastError == nil)
        #expect(appState.snapshots.isEmpty)
        // The abandoned refresh never went on to issue month requests.
        #expect(provider.snapshotLoads == 0)
    }

    @Test func timeZoneChangeAbandonsInFlightFetches() async {
        let provider = GatedProvider()
        let appState = makeAppState(provider: provider)
        appState.displayNow = midMonth(appState)
        let month = appState.currentMonth

        // 1. A fetch issued under the old zone enters flight and is parked on
        //    the gate — parked, not merely registered, so FIFO release order
        //    below is deterministic.
        appState.select(month: month)
        await waitUntil { provider.suspendedLoads == 1 }
        #expect(provider.snapshotLoads == 1)

        // 2. The time zone changes: the old fetch is abandoned and the forced
        //    refresh issues a fresh request under the new zone, which parks
        //    behind it. (Same YearMonth key — midday mid-month is the same
        //    month in any zone.)
        appState.displaySettings.timeZoneIdentifier = "Asia/Tokyo"
        await waitUntil { provider.suspendedLoads == 2 }

        // 3. Release only the OLD request. Its result must not land — not in
        //    memory, and it must not tear down the new fetch's registration.
        provider.release(1)
        try? await Task.sleep(for: .milliseconds(100))
        #expect(appState.snapshots[month] == nil)
        #expect(appState.loadingMonths.contains(appState.currentMonth))
        #expect(appState.lastError == nil)

        // 4. The new-zone request lands independently.
        provider.open()
        await waitUntil { appState.snapshots[appState.currentMonth] != nil }
        #expect(provider.snapshotLoads == 2)
    }

    @Test func clearCacheAbandonsInFlightFetches() async {
        let provider = GatedProvider()
        let appState = makeAppState(provider: provider)
        appState.displayNow = midMonth(appState)
        let month = appState.currentMonth

        appState.select(month: month)
        await waitUntil { !appState.loadingMonths.isEmpty }

        // Disconnect flow: the user chose to discard cached data. The
        // in-flight state clears immediately with it.
        appState.clearCache()
        #expect(appState.loadingMonths.isEmpty)

        // Releasing the old request must not repopulate memory, restore a
        // sync time, or surface an error for the abandoned fetch.
        provider.open()
        try? await Task.sleep(for: .milliseconds(100))
        #expect(appState.snapshots[month] == nil)
        #expect(appState.account.lastSyncAt == nil)
        #expect(appState.lastError == nil)
        #expect(appState.failedMonths.isEmpty)
    }

    @Test func nilReferenceFollowsTheSharedClock() async {
        let appState = makeAppState(provider: MockDataProvider())
        appState.displayNow = midMonth(appState)
        await appState.refresh()
        appState.displaySettings.aggregationPeriod = .day

        #expect(appState.selectedReference == nil)
        #expect(appState.activeReference == appState.displayNow)
        // The clock moves; a nil reference follows without any sync step.
        let nextDay = appState.displayNow.addingTimeInterval(86400)
        appState.displayNow = nextDay
        #expect(appState.activeReference == nextDay)
        #expect(appState.isReferenceCurrentDay)

        appState.stepBackward()
        #expect(appState.selectedReference != nil)
        #expect(!appState.isReferenceCurrentDay)
        appState.stepForward()
        // Stepping forward into the current day restores clock-following.
        #expect(appState.selectedReference == nil)
    }

    @Test func clockJumpAcrossMonthResyncsSelectedMonth() async {
        let appState = makeAppState(provider: MockDataProvider())
        appState.displayNow = midMonth(appState)
        await appState.refresh()
        appState.displaySettings.refreshMode = .manual

        let nextMonth = appState.currentMonth.next
        let jumped = nextMonth.start(in: appState.timeZone).addingTimeInterval(12 * 3600)
        appState.clockDidJump(now: jumped)

        #expect(appState.currentMonth == nextMonth)
        #expect(appState.selectedMonth == nextMonth)
        #expect(appState.selectedReference == nil)
    }

    @Test func futureMonthsSynthesizeWithoutPersisting() async {
        let appState = makeAppState(provider: MockDataProvider())
        appState.displayNow = midMonth(appState)
        await appState.refresh()
        appState.displaySettings.aggregationPeriod = .week

        // The week containing the 1st of next month straddles forward.
        let calendar = YearMonth.calendar(in: appState.timeZone)
        let nextMonthStart = appState.currentMonth.end(in: appState.timeZone)
        let straddleReference = calendar.dateInterval(of: .weekOfYear, for: nextMonthStart)?.start ?? nextMonthStart

        guard case .complete(let week) = appState.weekDataState(at: straddleReference) else {
            Issue.record("expected a complete forward-straddling week")
            return
        }
        #expect(week.aggregate != nil)
        // Nothing synthetic entered the snapshot store.
        #expect(appState.snapshots.keys.allSatisfy { $0 <= appState.currentMonth })
    }
}
