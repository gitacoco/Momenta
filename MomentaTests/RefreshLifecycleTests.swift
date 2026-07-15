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
        appState.displaySettings.perClientSplit = true

        let relaunched = AppState(
            provider: CountingProvider(),
            account: disconnectedAccount(),
            config: ConfigStore(defaults: freshDefaults()),
            snapshotCache: tempCache(),
            defaults: defaults,
            autoRefresh: false
        )
        #expect(relaunched.displaySettings.aggregationPeriod == .week)
        #expect(relaunched.displaySettings.perClientSplit == true)
    }
}
