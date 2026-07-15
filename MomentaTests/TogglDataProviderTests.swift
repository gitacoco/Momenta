import Foundation
import Testing
@testable import Momenta

/// Routes stubbed responses by URL path substring and counts hits per route,
/// so multi-endpoint flows can be asserted without ordering assumptions.
final class RoutingTransport: HTTPTransport, @unchecked Sendable {
    private var routes: [(pattern: String, data: Data)]
    private(set) var hits: [String: Int] = [:]

    init(routes: [(String, String)]) {
        self.routes = routes.map { ($0.0, Data($0.1.utf8)) }
    }

    func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = request.url!.absoluteString
        guard let route = routes.first(where: { url.contains($0.pattern) }) else {
            throw TogglAPIError.other("No route for \(url)")
        }
        hits[route.pattern, default: 0] += 1
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        return (route.data, response)
    }
}

struct TogglDataProviderTests {
    let utc = TimeZone(identifier: "UTC")!
    let july = YearMonth(year: 2026, month: 7)

    private func iso(_ date: Date) -> String {
        date.formatted(.iso8601)
    }

    private func makeProvider(now: Date, includeRunning: Bool = true) -> (TogglDataProvider, RoutingTransport) {
        let julyStart = july.start(in: utc)
        let juneEntry = iso(julyStart.addingTimeInterval(-3600))       // June 30, 23:00Z
        let julyEntry = iso(julyStart.addingTimeInterval(9 * 3600))    // July 1, 09:00Z
        let entriesJSON = """
        [
          {"id":1,"workspace_id":101,"project_id":31,"start":"\(julyEntry)","stop":"\(iso(julyStart.addingTimeInterval(12 * 3600)))","duration":10800,"description":"in month"},
          {"id":2,"workspace_id":101,"project_id":31,"start":"\(juneEntry)","stop":"\(iso(julyStart))","duration":3600,"description":"before month"}
        ]
        """
        let runningJSON = includeRunning
            ? #"{"id":9,"workspace_id":101,"project_id":32,"start":"\#(iso(now.addingTimeInterval(-1800)))","stop":null,"duration":-1784127600,"description":"live"}"#
            : "null"
        let transport = RoutingTransport(routes: [
            ("time_entries/current", runningJSON),
            ("time_entries", entriesJSON),
            ("workspaces/101/projects", #"[{"id":31,"workspace_id":101,"client_id":7,"name":"Website","active":true},{"id":32,"workspace_id":101,"client_id":null,"name":"Internal","active":true}]"#),
            ("workspaces", #"[{"id":101,"name":"Freelance"}]"#),
        ])
        let provider = TogglDataProvider(api: TogglAPIClient(token: "tok", transport: transport))
        return (provider, transport)
    }

    @Test func currentMonthSnapshotFiltersNormalizesAndMergesRunningEntry() async throws {
        let now = july.start(in: utc).addingTimeInterval(14 * 86_400)
        let (provider, _) = makeProvider(now: now)

        let snapshot = try await provider.loadSnapshot(for: july, timeZone: utc, now: now)

        // The June 30 entry (fetched due to margin) is filtered out; the July
        // entry and the running entry remain, sorted by start.
        #expect(snapshot.entries.map(\.id) == [1, 9])
        #expect(snapshot.entries[0].clientID == 7)      // resolved via project
        #expect(snapshot.entries[1].clientID == nil)    // project without client
        #expect(snapshot.entries[1].isRunning)
        #expect(snapshot.month == july)
    }

    @Test func historicalMonthSkipsRunningEntryEndpoint() async throws {
        // "Now" is September: July is historical.
        let now = july.next.next.start(in: utc).addingTimeInterval(5 * 86_400)
        let (provider, transport) = makeProvider(now: now)

        _ = try await provider.loadSnapshot(for: july, timeZone: utc, now: now)

        #expect(transport.hits["time_entries/current"] == nil)
        #expect(transport.hits["time_entries"] == 1)
    }

    @Test func projectCatalogIsCachedAcrossLoads() async throws {
        let now = july.start(in: utc).addingTimeInterval(14 * 86_400)
        let (provider, transport) = makeProvider(now: now)

        _ = try await provider.loadSnapshot(for: july, timeZone: utc, now: now)
        _ = try await provider.loadSnapshot(for: july.previous, timeZone: utc, now: now)

        #expect(transport.hits["workspaces/101/projects"] == 1)
        #expect(transport.hits["workspaces"] == 1)
    }

    @Test func futureMonthReturnsEmptySnapshotWithoutFetching() async throws {
        let now = july.start(in: utc).addingTimeInterval(86_400)
        let (provider, transport) = makeProvider(now: now)

        let futureMonth = july.next.next
        let snapshot = try await provider.loadSnapshot(for: futureMonth, timeZone: utc, now: now)

        #expect(snapshot.entries.isEmpty)
        #expect(transport.hits.isEmpty)
    }

    @Test func availableMonthsSpanApiReach() async throws {
        let now = july.start(in: utc).addingTimeInterval(86_400)
        let (provider, _) = makeProvider(now: now)
        let months = try await provider.availableMonths(asOf: now, timeZone: utc)
        #expect(months == [YearMonth(year: 2026, month: 5), YearMonth(year: 2026, month: 6), july])
    }
}
