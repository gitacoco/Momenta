import Foundation
import Testing
@testable import Momenta

struct ConfigSyncModelsTests {
    private let june = YearMonth(year: 2026, month: 6)
    private let july = YearMonth(year: 2026, month: 7)

    private func client(
        _ id: Int,
        name: String? = nil,
        color: String = "#111111",
        enabled: Bool = false,
        pacing: PacingMode = .weekdays,
        customWorkDays: Set<Int>? = nil,
        billableFlag: Bool? = nil,
        dormantHourlyRate: Decimal? = nil,
        // Nil means "never authored on this side" — the case the initial
        // merge's fallbacks turn on.
        currencyCode: String? = "USD",
        workWindow: WorkWindow? = nil,
        goals: [YearMonth: MonthlyGoal] = [:],
        logo: String? = nil
    ) -> SyncedClientConfig {
        SyncedClientConfig(
            clientID: id,
            displayNameOverride: name,
            colorHex: color,
            isEnabled: enabled,
            pacing: pacing,
            customWorkDays: customWorkDays,
            goalHistory: goals,
            currencyCode: currencyCode,
            billableFlag: billableFlag,
            dormantHourlyRate: dormantHourlyRate,
            workWindow: workWindow,
            logoRevision: logo
        )
    }

    private func payload(_ clients: [SyncedClientConfig], order: [Int]? = nil) -> SyncedConfigPayload {
        SyncedConfigPayload(
            clients: Dictionary(uniqueKeysWithValues: clients.map { ($0.clientID, $0) }),
            order: order ?? clients.map(\.clientID)
        )
    }

    @Test func daysOffMergeIndependentAdditionsAndRemovalsAndProject() throws {
        let first = CalendarDay(year: 2026, month: 9, day: 7)
        let second = CalendarDay(year: 2026, month: 9, day: 8)
        let third = CalendarDay(year: 2026, month: 9, day: 9)
        var original = client(7)
        original.daysOff = [first]
        var local = original
        local.daysOff = [second]
        var server = original
        server.daysOff = [first, third]
        let merged = SyncedConfigPayload.merge(base: payload([original]), local: payload([local]), server: payload([server]))
        let decoded = try JSONDecoder().decode(SyncedConfigPayload.self, from: JSONEncoder().encode(merged))
        let result = try #require(decoded.clients[7])
        #expect(result.daysOff == [second, third])
        let config = ClientConfig(id: 7, workspaceID: 1, workspaceName: "Studio", togglName: "Acme", colorHex: "#111111", isEnabled: true, isArchivedInToggl: false, pacing: .weekdays, goalHistory: [:])
        #expect(result.applying(to: config, localLogoFileName: nil).daysOff == [second, third])
        #expect(SyncedClientConfig(client: result.applying(to: config, localLogoFileName: nil)).daysOff == [second, third])
    }

    @Test func firstSyncRetainsDaysOffFromBothDevices() {
        let first = CalendarDay(year: 2026, month: 9, day: 7)
        let second = CalendarDay(year: 2026, month: 10, day: 1)
        var local = client(7)
        local.daysOff = [first]
        var server = client(7)
        server.daysOff = [second]
        let merged = SyncedConfigPayload.initialMerge(local: payload([local]), server: payload([server]))
        #expect(merged.clients[7]?.daysOff == [first, second])
    }

    @Test func legacySyncPayloadDecodesWithoutDaysOff() throws {
        let data = try JSONEncoder().encode(client(7))
        let decoded = try JSONDecoder().decode(SyncedClientConfig.self, from: data)
        #expect(decoded.daysOff == nil)
    }

    @Test func threeWayMergePreservesIndependentFieldsAndGoalMonths() {
        let juneGoal = MonthlyGoal(hourlyRate: 100, input: .hours(40))
        let julyGoal = MonthlyGoal(hourlyRate: 120, input: .hours(50))
        let base = payload([client(7, goals: [june: juneGoal])])
        let local = payload([client(7, name: "ACME", goals: [june: juneGoal, july: julyGoal])])
        let server = payload([client(7, color: "#FF0000", enabled: true, goals: [june: juneGoal])])

        let merged = SyncedConfigPayload.merge(base: base, local: local, server: server)
        let result = merged.clients[7]

        #expect(result?.displayNameOverride == "ACME")
        #expect(result?.colorHex == "#FF0000")
        #expect(result?.isEnabled == true)
        #expect(result?.goalHistory[july] == julyGoal)
    }

    @Test func explicitClearPropagatesWhenServerStayedAtBase() {
        let base = payload([client(7, name: "ACME", logo: "logo-1")])
        let local = payload([client(7, name: nil, logo: nil)])
        let server = base

        let merged = SyncedConfigPayload.merge(base: base, local: local, server: server)

        #expect(merged.clients[7]?.displayNameOverride == nil)
        #expect(merged.clients[7]?.logoRevision == nil)
    }

    @Test func sameFieldConflictUsesValueCloudKitAcceptedFirst() {
        let base = payload([client(7, color: "#111111")])
        let local = payload([client(7, color: "#00FF00")])
        let server = payload([client(7, color: "#FF0000")])

        let merged = SyncedConfigPayload.merge(base: base, local: local, server: server)

        #expect(merged.clients[7]?.colorHex == "#FF0000")
    }

    @Test func togglDefaultClientsDoNotCountAsUserSettings() {
        let defaultClient = SyncedClientConfig(
            clientID: 7,
            displayNameOverride: nil,
            colorHex: ConfigStore.defaultColor(for: 7),
            isEnabled: false,
            pacing: .weekdays,
            goalHistory: [:],
            currencyCode: nil,
            logoRevision: nil
        )
        let defaultsOnly = payload([defaultClient])

        #expect(defaultsOnly.hasUserSettings == false)

        var authored = defaultsOnly
        authored.clients[7]?.isEnabled = true
        #expect(authored.hasUserSettings)
    }

    @Test func customWorkDaysRoundTripAndMergeAsAField() throws {
        let base = payload([client(7, pacing: .custom, customWorkDays: [2, 4, 6])])
        let local = payload([client(7, pacing: .custom, customWorkDays: [2, 3, 4, 5])])
        let server = base

        let merged = SyncedConfigPayload.merge(base: base, local: local, server: server)
        let encoded = try JSONEncoder().encode(merged)
        let decoded = try JSONDecoder().decode(SyncedConfigPayload.self, from: encoded)
        let projected = decoded.clients[7]?.applying(
            to: ClientConfig(
                id: 7,
                workspaceID: 10,
                workspaceName: "Studio",
                togglName: "Client",
                displayNameOverride: nil,
                colorHex: ConfigStore.defaultColor(for: 7),
                isEnabled: false,
                isArchivedInToggl: false,
                pacing: .weekdays,
                goalHistory: [:]
            ),
            localLogoFileName: nil
        )

        #expect(decoded.clients[7]?.customWorkDays == [2, 3, 4, 5])
        #expect(projected?.pacing == .custom)
        #expect(projected?.customWorkDays == [2, 3, 4, 5])
    }

    @Test func billableFlagRoundTripsAndProjectsAsAField() throws {
        let base = payload([client(7, billableFlag: nil)])
        let local = payload([client(7, billableFlag: false, dormantHourlyRate: 120)])
        let server = base

        let merged = SyncedConfigPayload.merge(base: base, local: local, server: server)
        let encoded = try JSONEncoder().encode(merged)
        let decoded = try JSONDecoder().decode(SyncedConfigPayload.self, from: encoded)
        let projected = decoded.clients[7]?.applying(
            to: ClientConfig(
                id: 7,
                workspaceID: 10,
                workspaceName: "Studio",
                togglName: "Client",
                displayNameOverride: nil,
                colorHex: ConfigStore.defaultColor(for: 7),
                isEnabled: false,
                isArchivedInToggl: false,
                pacing: .weekdays,
                goalHistory: [:]
            ),
            localLogoFileName: nil
        )

        #expect(decoded.clients[7]?.billableFlag == false)
        #expect(projected?.billableFlag == false)
        #expect(projected?.isBillable == false)
        // The parked rate travels with the flag, so re-enabling billing on
        // another Mac can still offer it.
        #expect(decoded.clients[7]?.dormantHourlyRate == 120)
        #expect(projected?.restorableHourlyRate == 120)
    }

    @Test func absentBillableFlagMeansBillableAndNotUserAuthored() {
        // A true default row (no billable flag) stays billable and does not,
        // on its own, count as user settings that force a first-sync prompt.
        let defaults = SyncedClientConfig(
            clientID: 7,
            displayNameOverride: nil,
            colorHex: ConfigStore.defaultColor(for: 7),
            isEnabled: false,
            pacing: .weekdays,
            goalHistory: [:],
            currencyCode: nil,
            logoRevision: nil
        )
        #expect(defaults.billableFlag == nil)
        #expect(defaults.hasUserSettings == false)

        let projected = defaults.applying(
            to: ClientConfig(
                id: 7,
                workspaceID: 10,
                workspaceName: "Studio",
                togglName: "Client",
                displayNameOverride: nil,
                colorHex: ConfigStore.defaultColor(for: 7),
                isEnabled: false,
                isArchivedInToggl: false,
                pacing: .weekdays,
                goalHistory: [:]
            ),
            localLogoFileName: nil
        )
        #expect(projected.isBillable)
    }

    @Test func MissingProjectedClientSurvivesAnotherClientEditAndUpload() {
        let remoteOnlyGoal = MonthlyGoal(hourlyRate: 200, input: .revenue(20_000))
        let base = payload([
            client(7),
            client(99, name: "Remote X", goals: [june: remoteOnlyGoal]),
        ], order: [99, 7])
        // Mac B has not fetched client 99 from Toggl yet. Its UI projection
        // edits client 7, but its independent shadow retains 99.
        var local = base
        local.clients[7]?.isEnabled = true
        let server = base

        let merged = SyncedConfigPayload.merge(base: base, local: local, server: server)

        #expect(merged.clients[99]?.goalHistory[june] == remoteOnlyGoal)
        #expect(merged.order == [99, 7])
        #expect(merged.clients[7]?.isEnabled == true)
    }

    @Test func visibleReorderKeepsUnknownIDsInTheirExistingSlots() {
        var shadow = payload([client(1), client(2), client(99)], order: [1, 99, 2])

        shadow.updateVisibleOrder([2, 1])

        #expect(shadow.order == [2, 99, 1])
        #expect(shadow.clients[99] != nil)
        #expect(shadow.userAuthoredOrder == true)
        #expect(shadow.hasUserSettings)
    }

    @Test func initialMergeKeepsBothSidesAndUsesServerForAmbiguousFields() {
        let localGoal = MonthlyGoal(hourlyRate: 100, input: .hours(40))
        let serverGoal = MonthlyGoal(hourlyRate: 120, input: .hours(50))
        let local = payload([
            client(1, color: "#00FF00", goals: [june: localGoal]),
            client(2, name: "Local only"),
        ], order: [2, 1])
        let server = payload([
            client(1, color: "#FF0000", goals: [july: serverGoal]),
            client(3, name: "Server only"),
        ], order: [3, 1])

        let merged = SyncedConfigPayload.initialMerge(local: local, server: server)

        #expect(merged.clients[1]?.colorHex == "#FF0000")
        #expect(merged.clients[1]?.goalHistory[june] == localGoal)
        #expect(merged.clients[1]?.goalHistory[july] == serverGoal)
        #expect(merged.clients[2] != nil)
        #expect(merged.clients[3] != nil)
        #expect(merged.order == [3, 1, 2])
    }

    @Test func initialMergeKeepsLocalSettingsTheServerNeverAuthored() {
        // Adoption takes the server's client wholesale, so anything only this
        // Mac ever set has to be rescued. `dormantHourlyRate` is the sharp
        // case: it is the only record of the rate a non-billable client
        // restores from, so losing it here is unrecoverable — the editor
        // fallback would have nothing left to offer.
        let local = payload([
            client(
                1,
                customWorkDays: [2, 4],
                billableFlag: false,
                dormantHourlyRate: 120,
                currencyCode: "EUR"
            ),
        ])
        let server = payload([client(1, color: "#FF0000", currencyCode: nil)])

        let merged = SyncedConfigPayload.initialMerge(local: local, server: server)

        #expect(merged.clients[1]?.colorHex == "#FF0000")
        #expect(merged.clients[1]?.billableFlag == false)
        #expect(merged.clients[1]?.dormantHourlyRate == 120)
        #expect(merged.clients[1]?.customWorkDays == [2, 4])
        #expect(merged.clients[1]?.currencyCode == "EUR")
    }

    @Test func initialMergeLeavesNoRatelessMonthOnABillableClient() {
        // The flag comes from the server, the rate-less month from this Mac.
        // The editor's recovery cannot repair this one: it inspects the
        // current month, and July is already complete.
        let june = YearMonth(year: 2026, month: 6)
        let local = payload([
            client(1, billableFlag: false, goals: [june: MonthlyGoal(hourlyRate: 0, input: .hours(15))]),
        ])
        let server = payload([
            client(1, billableFlag: true, goals: [july: MonthlyGoal(hourlyRate: 80, input: .hours(40))]),
        ])

        let merged = SyncedConfigPayload.initialMerge(local: local, server: server)

        #expect(merged.clients[1]?.billableFlag == true)
        #expect(merged.clients[1]?.goalHistory[june]?.hourlyRate == 80)
        #expect(merged.clients[1]?.goalHistory[june]?.hours == 15)
        #expect(merged.clients[1]?.goalHistory[july]?.hourlyRate == 80)
    }

    @Test func threeWayMergeLeavesNoRatelessMonthOnABillableClient() {
        // Same split, reached the other way: only the server flips billing,
        // so the flag and the goal months resolve from different sides.
        let june = YearMonth(year: 2026, month: 6)
        let ratelessJune = MonthlyGoal(hourlyRate: 0, input: .hours(15))
        let base = payload([client(1, billableFlag: false, goals: [june: ratelessJune])])
        let local = base
        let server = payload([
            client(
                1,
                billableFlag: true,
                goals: [june: ratelessJune, july: MonthlyGoal(hourlyRate: 80, input: .hours(40))]
            ),
        ])

        let merged = SyncedConfigPayload.merge(base: base, local: local, server: server)

        #expect(merged.clients[1]?.billableFlag == true)
        #expect(merged.clients[1]?.goalHistory[june]?.hourlyRate == 80)
        #expect(merged.clients[1]?.goalHistory[june]?.hours == 15)
    }

    @Test func mergeLeavesANonBillableClientsRatelessMonthsAlone() {
        let june = YearMonth(year: 2026, month: 6)
        let local = payload([
            client(
                1,
                billableFlag: false,
                dormantHourlyRate: 120,
                goals: [june: MonthlyGoal(hourlyRate: 0, input: .hours(15))]
            ),
        ])
        let server = payload([client(1, billableFlag: false, dormantHourlyRate: 120)])

        let merged = SyncedConfigPayload.initialMerge(local: local, server: server)

        #expect(merged.clients[1]?.billableFlag == false)
        #expect(merged.clients[1]?.goalHistory[june]?.hourlyRate == 0)
    }

    @Test func initialMergeStillPrefersTheServerWhereBothSidesAuthored() {
        let local = payload([
            client(1, billableFlag: false, dormantHourlyRate: 120, currencyCode: "EUR"),
        ])
        let server = payload([
            client(1, billableFlag: true, dormantHourlyRate: 80, currencyCode: "GBP"),
        ])

        let merged = SyncedConfigPayload.initialMerge(local: local, server: server)

        #expect(merged.clients[1]?.billableFlag == true)
        #expect(merged.clients[1]?.dormantHourlyRate == 80)
        #expect(merged.clients[1]?.currencyCode == "GBP")
    }

    @Test func initialMergeKeepsALocalWorkWindowTheServerNeverAuthored() {
        // A v2 payload has no work window at all, so adoption would otherwise
        // reset this Mac's custom hours to the 9:00-18:00 default and upload
        // that. Nil means "never authored": the editor always writes a
        // non-nil window once touched.
        let custom = WorkWindow(startMinute: 7 * 60, endMinute: 15 * 60)
        let local = payload([client(1, workWindow: custom)])
        let server = payload([client(1, color: "#FF0000")])

        let merged = SyncedConfigPayload.initialMerge(local: local, server: server)

        #expect(merged.clients[1]?.colorHex == "#FF0000")
        #expect(merged.clients[1]?.workWindow == custom)
    }

    @Test func initialMergePrefersTheServerWorkWindowWhenBothAuthored() {
        let localWindow = WorkWindow(startMinute: 7 * 60, endMinute: 15 * 60)
        let serverWindow = WorkWindow(startMinute: 10 * 60, endMinute: 19 * 60)
        let local = payload([client(1, workWindow: localWindow)])
        let server = payload([client(1, workWindow: serverWindow)])

        let merged = SyncedConfigPayload.initialMerge(local: local, server: server)

        #expect(merged.clients[1]?.workWindow == serverWindow)
    }

    @Test func syncStateStorePersistsShadowBaseAndDirtyState() {
        let suite = "MomentaTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let store = ConfigSyncStateStore(defaults: defaults)
        let state = ConfigSyncLocalState(
            shadow: payload([client(7, name: "ACME")]),
            base: payload([client(7)]),
            recordSystemFields: Data([1, 2, 3]),
            hasCompletedSync: true,
            isDirty: true,
            installedLogoRevisions: [7: "logo-1"]
        )

        store.save(state, togglUserID: 42)

        #expect(store.load(togglUserID: 42) == state)
        #expect(store.load(togglUserID: 99) == .empty)
    }
}
