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
            currencyCode: "USD",
            logoRevision: logo
        )
    }

    private func payload(_ clients: [SyncedClientConfig], order: [Int]? = nil) -> SyncedConfigPayload {
        SyncedConfigPayload(
            clients: Dictionary(uniqueKeysWithValues: clients.map { ($0.clientID, $0) }),
            order: order ?? clients.map(\.clientID)
        )
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
