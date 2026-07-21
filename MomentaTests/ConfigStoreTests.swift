import Foundation
import Testing
@testable import Momenta

@MainActor
struct ConfigStoreTests {
    private func freshDefaults() -> UserDefaults {
        let suite = "MomentaTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private let workspaces = [TogglWorkspace(id: 101, name: "Freelance")]

    private func existingClient(
        id: Int = 7,
        goals: [YearMonth: MonthlyGoal] = [:],
        enabled: Bool = true
    ) -> ClientConfig {
        ClientConfig(
            id: id,
            workspaceID: 101,
            workspaceName: "Freelance",
            togglName: "Acme",
            displayNameOverride: "ACME",
            colorHex: "#5B8DEF",
            isEnabled: enabled,
            isArchivedInToggl: false,
            pacing: .calendarDays,
            goalHistory: goals
        )
    }

    // MARK: Merge

    @Test func mergeAddsNewClientsDisabled() {
        let store = ConfigStore(defaults: freshDefaults())
        store.merge(workspaces: workspaces, togglClients: [
            TogglClientDTO(id: 7, wid: 101, name: "Acme", archived: false),
        ])
        #expect(store.clients.count == 1)
        #expect(store.clients[0].isEnabled == false)
        #expect(store.clients[0].workspaceName == "Freelance")
        #expect(store.clients[0].state(for: YearMonth(year: 2026, month: 7)) == .disabled)
    }

    @Test func mergeKeepsLocalConfigAndUpdatesIdentity() {
        let defaults = freshDefaults()
        let store = ConfigStore(defaults: defaults)
        store.merge(workspaces: workspaces, togglClients: [
            TogglClientDTO(id: 7, wid: 101, name: "Acme", archived: false),
        ])
        var config = store.clients[0]
        config.isEnabled = true
        config.displayNameOverride = "ACME"
        config.pacing = .calendarDays
        store.update(config)

        // Client renamed in Toggl and moved to a new workspace.
        let newWorkspaces = workspaces + [TogglWorkspace(id: 102, name: "Side")]
        store.merge(workspaces: newWorkspaces, togglClients: [
            TogglClientDTO(id: 7, wid: 102, name: "Acme Corp", archived: false),
        ])
        let merged = store.clients[0]
        #expect(merged.togglName == "Acme Corp")
        #expect(merged.workspaceID == 102)
        #expect(merged.workspaceName == "Side")
        // Local configuration survives.
        #expect(merged.isEnabled)
        #expect(merged.displayNameOverride == "ACME")
        #expect(merged.pacing == .calendarDays)
    }

    @Test func mergeArchivesMissingClientWithHistory() {
        let store = ConfigStore(defaults: freshDefaults())
        store.merge(workspaces: workspaces, togglClients: [
            TogglClientDTO(id: 7, wid: 101, name: "Acme", archived: false),
        ])
        var config = store.clients[0]
        config.goalHistory[YearMonth(year: 2026, month: 6)] = MonthlyGoal(hourlyRate: 100, input: .hours(50))
        store.update(config)

        store.merge(workspaces: workspaces, togglClients: [])

        #expect(store.clients.count == 1)
        #expect(store.clients[0].isArchivedInToggl)
        #expect(store.clients[0].isEnabled == false)
        #expect(!store.clients[0].goalHistory.isEmpty)
    }

    @Test func mergeDropsMissingClientWithoutHistory() {
        let store = ConfigStore(defaults: freshDefaults())
        store.merge(workspaces: workspaces, togglClients: [
            TogglClientDTO(id: 7, wid: 101, name: "Acme", archived: false),
        ])
        store.merge(workspaces: workspaces, togglClients: [])
        #expect(store.clients.isEmpty)
    }

    @Test func mergeRespectsTogglArchivedFlag() {
        let store = ConfigStore(defaults: freshDefaults())
        store.merge(workspaces: workspaces, togglClients: [
            TogglClientDTO(id: 7, wid: 101, name: "Acme", archived: true),
        ])
        #expect(store.clients[0].isArchivedInToggl)
    }

    @Test func onlyUserAuthoredMutationsEmitUploadChanges() {
        let store = ConfigStore(defaults: freshDefaults())
        var userChanges = 0
        var reconciliations = 0
        store.onUserChange = { _ in userChanges += 1 }
        store.onTogglReconciliation = { reconciliations += 1 }

        store.merge(workspaces: workspaces, togglClients: [
            TogglClientDTO(id: 7, wid: 101, name: "Acme", archived: false),
        ])
        #expect(userChanges == 0)
        #expect(reconciliations == 1)

        var edited = store.clients[0]
        edited.isEnabled = true
        store.update(edited)
        #expect(userChanges == 1)

        let projected = SyncedConfigPayload(
            clients: [7: SyncedClientConfig(client: edited)],
            order: [7]
        )
        store.applySyncedPayload(projected)
        #expect(userChanges == 1)
        #expect(reconciliations == 1)
    }

    // MARK: Ordering

    @Test func moveReordersClientsAndPersists() {
        let defaults = freshDefaults()
        let store = ConfigStore(defaults: defaults)
        store.merge(workspaces: workspaces, togglClients: [
            TogglClientDTO(id: 1, wid: 101, name: "Alpha", archived: false),
            TogglClientDTO(id: 2, wid: 101, name: "Beta", archived: false),
            TogglClientDTO(id: 3, wid: 101, name: "Gamma", archived: false),
        ])

        // Drag Gamma to the front.
        store.move(ids: [1, 2, 3], fromOffsets: IndexSet(integer: 2), toOffset: 0)
        #expect(store.clients.map(\.id) == [3, 1, 2])

        let relaunched = ConfigStore(defaults: defaults)
        #expect(relaunched.clients.map(\.id) == [3, 1, 2])
    }

    @Test func mergePreservesManualOrderAndAppendsNewcomers() {
        let store = ConfigStore(defaults: freshDefaults())
        store.merge(workspaces: workspaces, togglClients: [
            TogglClientDTO(id: 1, wid: 101, name: "Alpha", archived: false),
            TogglClientDTO(id: 2, wid: 101, name: "Beta", archived: false),
        ])
        store.move(ids: [1, 2], fromOffsets: IndexSet(integer: 1), toOffset: 0)
        #expect(store.clients.map(\.id) == [2, 1])

        // A later refresh must not shuffle the user's arrangement; new
        // clients simply append.
        store.merge(workspaces: workspaces, togglClients: [
            TogglClientDTO(id: 1, wid: 101, name: "Alpha", archived: false),
            TogglClientDTO(id: 2, wid: 101, name: "Beta", archived: false),
            TogglClientDTO(id: 3, wid: 101, name: "Aardvark", archived: false),
        ])
        #expect(store.clients.map(\.id) == [2, 1, 3])
    }

    // MARK: Persistence

    @Test func configsSurviveRelaunch() {
        let defaults = freshDefaults()
        let store = ConfigStore(defaults: defaults)
        store.merge(workspaces: workspaces, togglClients: [
            TogglClientDTO(id: 7, wid: 101, name: "Acme", archived: false),
        ])
        var config = store.clients[0]
        config.isEnabled = true
        config.goalHistory[YearMonth(year: 2026, month: 7)] = MonthlyGoal(hourlyRate: 120, input: .hours(80))
        store.update(config)

        let relaunched = ConfigStore(defaults: defaults)
        #expect(relaunched.clients == store.clients)
    }

    // MARK: Goal versioning

    @Test func setGoalDefaultScopePreservesHistory() {
        let store = ConfigStore(defaults: freshDefaults())
        let may = YearMonth(year: 2026, month: 5)
        let june = YearMonth(year: 2026, month: 6)
        let july = YearMonth(year: 2026, month: 7)
        let oldGoal = MonthlyGoal(hourlyRate: 100, input: .hours(60))
        seed(store, existingClient(goals: [may: oldGoal, june: oldGoal]))

        let newGoal = MonthlyGoal(hourlyRate: 120, input: .hours(80))
        store.setGoal(newGoal, forClient: 7, from: july, retroactive: false)

        let history = store.client(id: 7)!.goalHistory
        #expect(history[may] == oldGoal)
        #expect(history[june] == oldGoal)
        #expect(history[july] == newGoal)
    }

    @Test func setGoalRetroactiveRewritesAllRecordedMonths() {
        let store = ConfigStore(defaults: freshDefaults())
        let may = YearMonth(year: 2026, month: 5)
        let july = YearMonth(year: 2026, month: 7)
        let oldGoal = MonthlyGoal(hourlyRate: 100, input: .hours(60))
        seed(store, existingClient(goals: [may: oldGoal]))

        let newGoal = MonthlyGoal(hourlyRate: 120, input: .revenue(9600))
        store.setGoal(newGoal, forClient: 7, from: july, retroactive: true)

        let history = store.client(id: 7)!.goalHistory
        #expect(history[may] == newGoal)
        #expect(history[july] == newGoal)
    }

    @Test func setGoalReplacesExplicitFutureVersions() {
        let store = ConfigStore(defaults: freshDefaults())
        let july = YearMonth(year: 2026, month: 7)
        let august = YearMonth(year: 2026, month: 8)
        let stale = MonthlyGoal(hourlyRate: 100, input: .hours(60))
        seed(store, existingClient(goals: [august: stale]))

        let newGoal = MonthlyGoal(hourlyRate: 120, input: .hours(80))
        store.setGoal(newGoal, forClient: 7, from: july, retroactive: false)

        let history = store.client(id: 7)!.goalHistory
        #expect(history[august] == newGoal)
        #expect(history[july] == newGoal)
    }

    /// merge is the only public entry to add clients (Toggl is the source of
    /// truth), so tests seed through it plus update.
    private func seed(_ store: ConfigStore, _ config: ClientConfig) {
        store.merge(
            workspaces: [TogglWorkspace(id: config.workspaceID, name: config.workspaceName)],
            togglClients: [TogglClientDTO(id: config.id, wid: config.workspaceID, name: config.togglName, archived: false)]
        )
        store.update(config)
    }
}

struct GoalDraftTests {
    @Test func editingHoursDerivesRevenue() {
        var draft = GoalDraft(goal: nil)
        draft.setRate(120)
        draft.setHours(80)
        #expect(draft.revenue == 9600)
        #expect(draft.authoritative == .hours)
    }

    @Test func editingRevenueDerivesHours() {
        var draft = GoalDraft(goal: nil)
        draft.setRate(100)
        draft.setRevenue(5000)
        #expect(draft.hours == 50)
        #expect(draft.authoritative == .revenue)
    }

    @Test func rateChangeKeepsAuthoritativeSide() {
        var draft = GoalDraft(goal: nil)
        draft.setRate(100)
        draft.setRevenue(6000)
        draft.setRate(120)
        #expect(draft.revenue == 6000) // authoritative input untouched
        #expect(draft.hours == 50)     // derived side recomputed
    }

    @Test func zeroOrMissingRateClearsDerivedSide() {
        var draft = GoalDraft(goal: nil)
        draft.setRate(100)
        draft.setHours(80)
        draft.setRate(nil)
        #expect(draft.hours == 80)
        #expect(draft.revenue == nil)
        #expect(draft.monthlyGoal == nil)
    }

    @Test func initFromExistingGoalPreservesAuthoredSide() {
        let goal = MonthlyGoal(hourlyRate: 95, input: .revenue(5500))
        let draft = GoalDraft(goal: goal)
        #expect(draft.authoritative == .revenue)
        #expect(draft.revenue == 5500)
        #expect(draft.monthlyGoal == goal)
    }

    @Test func monthlyGoalRequiresPositiveValues() {
        var draft = GoalDraft(goal: nil)
        #expect(draft.monthlyGoal == nil)
        draft.setRate(120)
        #expect(draft.monthlyGoal == nil)
        draft.setHours(0)
        #expect(draft.monthlyGoal == nil)
        draft.setHours(80)
        #expect(draft.monthlyGoal == MonthlyGoal(hourlyRate: 120, input: .hours(80)))
    }
}
