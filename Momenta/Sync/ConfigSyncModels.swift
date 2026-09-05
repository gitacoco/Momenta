import Foundation

/// Momenta-authored settings attached to a Toggl client. Toggl identity
/// fields deliberately do not cross devices: every Mac refreshes those from
/// Toggl and projects these settings onto the matching stable client ID.
struct SyncedClientConfig: Codable, Equatable, Sendable {
    var clientID: Int
    var displayNameOverride: String?
    var colorHex: String
    var isEnabled: Bool
    var pacing: PacingMode
    var customWorkDays: Set<Int>?
    var daysOff: Set<CalendarDay>?
    var goalHistory: [YearMonth: MonthlyGoal]
    var currencyCode: String?
    /// Mirrors `ClientConfig.billableFlag` (nil == billable). Optional so
    /// payloads written before this field decode cleanly.
    var billableFlag: Bool?
    /// Mirrors `ClientConfig.dormantHourlyRate`: the rate parked while billing
    /// is off, so re-enabling on another Mac can still offer it.
    var dormantHourlyRate: Decimal?
    /// Mirrors `ClientConfig.workWindow` (nil == the shared default window).
    /// Optional so payloads written before this field decode cleanly.
    var workWindow: WorkWindow?
    /// A content identity, not a local file name. The matching bytes live in
    /// a separate per-client CKAsset record.
    var logoRevision: String?

    init(
        clientID: Int,
        displayNameOverride: String?,
        colorHex: String,
        isEnabled: Bool,
        pacing: PacingMode,
        customWorkDays: Set<Int>? = nil,
        goalHistory: [YearMonth: MonthlyGoal],
        currencyCode: String?,
        billableFlag: Bool? = nil,
        dormantHourlyRate: Decimal? = nil,
        workWindow: WorkWindow? = nil,
        daysOff: Set<CalendarDay>? = nil,
        logoRevision: String?
    ) {
        self.clientID = clientID
        self.displayNameOverride = displayNameOverride
        self.colorHex = colorHex
        self.isEnabled = isEnabled
        self.pacing = pacing
        self.customWorkDays = customWorkDays
        self.goalHistory = goalHistory
        self.currencyCode = currencyCode
        self.billableFlag = billableFlag
        self.dormantHourlyRate = dormantHourlyRate
        self.workWindow = workWindow
        self.daysOff = daysOff
        self.logoRevision = logoRevision
    }

    init(client: ClientConfig, logoRevision: String? = nil) {
        clientID = client.id
        displayNameOverride = client.displayNameOverride
        colorHex = client.colorHex
        isEnabled = client.isEnabled
        pacing = client.pacing
        customWorkDays = client.customWorkDays
        goalHistory = client.goalHistory
        currencyCode = client.currencyCode
        billableFlag = client.billableFlag
        dormantHourlyRate = client.dormantHourlyRate
        workWindow = client.workWindow
        daysOff = client.daysOff
        self.logoRevision = logoRevision
    }

    func applying(to client: ClientConfig, localLogoFileName: String?) -> ClientConfig {
        var projected = client
        projected.displayNameOverride = displayNameOverride
        projected.colorHex = colorHex
        projected.isEnabled = isEnabled
        projected.pacing = pacing
        projected.customWorkDays = customWorkDays
        projected.goalHistory = goalHistory
        projected.currencyCode = currencyCode
        projected.billableFlag = billableFlag
        projected.dormantHourlyRate = dormantHourlyRate
        projected.workWindow = workWindow
        projected.daysOff = daysOff
        projected.logoFileName = localLogoFileName
        return projected
    }

    /// Re-establishes the invariant `ClientConfig.setBillable(true)` keeps: a
    /// billable client records a rate on every goal version. A merge can take
    /// the flag from one side and a rate-less month from the other, and the
    /// editor's recovery would not repair it — that only inspects the current
    /// month, which the same merge can leave complete.
    mutating func normalizeBillingRates() {
        goalHistory = BillingRates.normalized(
            history: goalHistory,
            isBillable: billableFlag ?? true,
            dormantRate: dormantHourlyRate
        )
    }

    /// Toggl reconciliation creates disabled clients with deterministic
    /// defaults. Those identity-only rows are not historical user settings
    /// and must not force a first-sync merge confirmation on a clean Mac.
    var hasUserSettings: Bool {
        displayNameOverride != nil
            || colorHex.uppercased() != ConfigStore.defaultColor(for: clientID).uppercased()
            || isEnabled
            || pacing != .weekdays
            || customWorkDays != nil
            || !goalHistory.isEmpty
            || currencyCode != nil
            || billableFlag != nil
            || dormantHourlyRate != nil
            || workWindow != nil
            || !(daysOff ?? []).isEmpty
            || logoRevision != nil
    }
}

/// The complete, account-scoped payload stored as one CloudKit record. This
/// is also persisted locally as an independent sync shadow. UI projection is
/// allowed to omit clients that Toggl has not returned yet; the shadow is not.
struct SyncedConfigPayload: Codable, Equatable, Sendable {
    var clients: [Int: SyncedClientConfig]
    var order: [Int]
    /// Distinguishes a deliberate drag reorder from the deterministic order
    /// produced when Toggl clients are first reconciled on a clean Mac.
    var userAuthoredOrder: Bool? = nil

    static let empty = SyncedConfigPayload(clients: [:], order: [])

    var hasUserSettings: Bool {
        clients.values.contains(where: \.hasUserSettings) || userAuthoredOrder == true
    }

    /// Updates one projected client while preserving every unmatched entry.
    mutating func update(client: ClientConfig, logoRevision: String?) {
        clients[client.id] = SyncedClientConfig(client: client, logoRevision: logoRevision)
        if !order.contains(client.id) {
            order.append(client.id)
        }
    }

    /// Reorders only IDs visible on this Mac. Unknown IDs retain their slots,
    /// so a later upload cannot erase or casually reshuffle remote-only data.
    mutating func updateVisibleOrder(_ visibleOrder: [Int]) {
        let visibleSet = Set(visibleOrder)
        var replacements = visibleOrder.makeIterator()
        var merged = order.map { existing in
            visibleSet.contains(existing) ? (replacements.next() ?? existing) : existing
        }
        let known = Set(merged)
        merged += visibleOrder.filter { !known.contains($0) }
        order = Self.deduplicated(merged)
        userAuthoredOrder = true
    }

    /// Three-way merge against the last payload accepted by this device.
    /// Same-field conflicts choose the value CloudKit accepted first (server),
    /// while independent fields and goal months are retained.
    static func merge(
        base: SyncedConfigPayload,
        local: SyncedConfigPayload,
        server: SyncedConfigPayload
    ) -> SyncedConfigPayload {
        let ids = Set(base.clients.keys)
            .union(local.clients.keys)
            .union(server.clients.keys)
        var mergedClients: [Int: SyncedClientConfig] = [:]

        for id in ids {
            switch (base.clients[id], local.clients[id], server.clients[id]) {
            case (_, let local?, nil):
                // Client entries are never deleted merely because a Toggl/UI
                // projection is temporarily missing them.
                mergedClients[id] = local
            case (_, nil, let server?):
                mergedClients[id] = server
            case (let base, let local?, let server?):
                mergedClients[id] = mergeClient(base: base, local: local, server: server)
            case (_, nil, nil):
                break
            }
        }

        let chosenOrder = mergeField(base: base.order, local: local.order, server: server.order)
            ?? server.order
        let completeOrder = completedOrder(
            chosenOrder,
            fallbacks: [server.order, local.order, base.order],
            clientIDs: mergedClients.keys
        )
        let orderWasAuthored = mergeField(
            base: base.userAuthoredOrder ?? false,
            local: local.userAuthoredOrder ?? false,
            server: server.userAuthoredOrder ?? false
        ) ?? false
        return SyncedConfigPayload(
            clients: mergedClients,
            order: completeOrder,
            userAuthoredOrder: orderWasAuthored ? true : nil
        )
    }

    /// Conservative first-sync merge when two devices have historical config
    /// but no common ancestor. Server wins ambiguous same fields; client IDs,
    /// non-overlapping goal months, and local-only order IDs are retained.
    static func initialMerge(
        local: SyncedConfigPayload,
        server: SyncedConfigPayload
    ) -> SyncedConfigPayload {
        let ids = Set(local.clients.keys).union(server.clients.keys)
        var mergedClients: [Int: SyncedClientConfig] = [:]
        for id in ids {
            switch (local.clients[id], server.clients[id]) {
            case (let local?, let server?):
                var chosen = server
                chosen.goalHistory = local.goalHistory.merging(server.goalHistory) { _, serverValue in
                    serverValue
                }
                // Optional settings the server never authored fall back to
                // this Mac's value rather than being erased by adoption.
                // `dormantHourlyRate` makes this load-bearing rather than
                // cosmetic: it is the only remaining record of the rate a
                // non-billable client restores from, so dropping it takes the
                // recovery data with it.
                if chosen.logoRevision == nil {
                    chosen.logoRevision = local.logoRevision
                }
                if chosen.displayNameOverride == nil {
                    chosen.displayNameOverride = local.displayNameOverride
                }
                if chosen.billableFlag == nil {
                    chosen.billableFlag = local.billableFlag
                }
                if chosen.dormantHourlyRate == nil {
                    chosen.dormantHourlyRate = local.dormantHourlyRate
                }
                if chosen.customWorkDays == nil {
                    chosen.customWorkDays = local.customWorkDays
                }
                if chosen.currencyCode == nil {
                    chosen.currencyCode = local.currencyCode
                }
                if chosen.workWindow == nil {
                    chosen.workWindow = local.workWindow
                }
                // Without a common base, retain dates selected on either Mac.
                if local.daysOff != nil || server.daysOff != nil {
                    chosen.daysOff = (local.daysOff ?? []).union(server.daysOff ?? [])
                }
                chosen.normalizeBillingRates()
                mergedClients[id] = chosen
            case (let local?, nil):
                mergedClients[id] = local
            case (nil, let server?):
                mergedClients[id] = server
            case (nil, nil):
                break
            }
        }
        let order = completedOrder(
            server.order,
            fallbacks: [local.order],
            clientIDs: mergedClients.keys
        )
        return SyncedConfigPayload(
            clients: mergedClients,
            order: order,
            userAuthoredOrder: local.userAuthoredOrder == true || server.userAuthoredOrder == true
                ? true
                : nil
        )
    }

    private static func mergeClient(
        base: SyncedClientConfig?,
        local: SyncedClientConfig,
        server: SyncedClientConfig
    ) -> SyncedClientConfig {
        var merged = SyncedClientConfig(
            clientID: local.clientID,
            displayNameOverride: mergeField(
                base: base?.displayNameOverride,
                local: local.displayNameOverride,
                server: server.displayNameOverride
            ),
            colorHex: mergeField(base: base?.colorHex, local: local.colorHex, server: server.colorHex)
                ?? server.colorHex,
            isEnabled: mergeField(base: base?.isEnabled, local: local.isEnabled, server: server.isEnabled)
                ?? server.isEnabled,
            pacing: mergeField(base: base?.pacing, local: local.pacing, server: server.pacing)
                ?? server.pacing,
            customWorkDays: mergeField(
                base: base?.customWorkDays,
                local: local.customWorkDays,
                server: server.customWorkDays
            ),
            goalHistory: mergeDictionary(
                base: base?.goalHistory ?? [:],
                local: local.goalHistory,
                server: server.goalHistory
            ),
            currencyCode: mergeField(
                base: base?.currencyCode,
                local: local.currencyCode,
                server: server.currencyCode
            ),
            billableFlag: mergeField(
                base: base?.billableFlag,
                local: local.billableFlag,
                server: server.billableFlag
            ),
            dormantHourlyRate: mergeField(
                base: base?.dormantHourlyRate,
                local: local.dormantHourlyRate,
                server: server.dormantHourlyRate
            ),
            workWindow: mergeField(
                base: base?.workWindow,
                local: local.workWindow,
                server: server.workWindow
            ),
            daysOff: mergeDaysOff(base: base?.daysOff, local: local.daysOff, server: server.daysOff),
            logoRevision: mergeField(
                base: base?.logoRevision,
                local: local.logoRevision,
                server: server.logoRevision
            )
        )
        // The fields above merge independently, so the billing flag and the
        // goal months can come from different sides.
        merged.normalizeBillingRates()
        return merged
    }

    /// Merge date membership independently, preserving additions on one Mac
    /// and removals on another instead of replacing the entire calendar.
    private static func mergeDaysOff(
        base: Set<CalendarDay>?,
        local: Set<CalendarDay>?,
        server: Set<CalendarDay>?
    ) -> Set<CalendarDay>? {
        guard base != nil || local != nil || server != nil else { return nil }
        let base = base ?? []
        let local = local ?? []
        let server = server ?? []
        return Set(base.union(local).union(server).filter { day in
            mergeField(base: base.contains(day), local: local.contains(day), server: server.contains(day)) == true
        })
    }

    private static func mergeDictionary<Key: Hashable & Sendable, Value: Equatable & Sendable>(
        base: [Key: Value],
        local: [Key: Value],
        server: [Key: Value]
    ) -> [Key: Value] {
        let keys = Set(base.keys).union(local.keys).union(server.keys)
        var result: [Key: Value] = [:]
        for key in keys {
            if let value: Value = mergeField(base: base[key], local: local[key], server: server[key]) {
                result[key] = value
            }
        }
        return result
    }

    private static func mergeField<Value: Equatable>(
        base: Value?,
        local: Value?,
        server: Value?
    ) -> Value? {
        if local == server { return local }
        if local == base { return server }
        if server == base { return local }
        return server
    }

    private static func completedOrder(
        _ preferred: [Int],
        fallbacks: [[Int]],
        clientIDs: Dictionary<Int, SyncedClientConfig>.Keys
    ) -> [Int] {
        var order = preferred
        for fallback in fallbacks {
            order += fallback
        }
        order += clientIDs.sorted()
        return deduplicated(order).filter { clientIDs.contains($0) }
    }

    private static func deduplicated(_ values: [Int]) -> [Int] {
        var seen: Set<Int> = []
        return values.filter { seen.insert($0).inserted }
    }
}

/// Persisted per-account sync state. `shadow` remains complete even when the
/// current Toggl/UI projection is incomplete; `base` is strictly device-local.
struct ConfigSyncLocalState: Codable, Equatable, Sendable {
    /// Version 2 introduced `billableFlag` and `dormantHourlyRate`; version 3
    /// introduced `workWindow`; version 4 introduced `daysOff`. An older
    /// device would decode the payload fine (unknown keys are ignored), then
    /// re-upload without the field, and a three-way merge on the newer device
    /// would read that as an explicit revert. Failing closed on the older
    /// device instead routes it through the existing unsupported-schema stop
    /// until it updates.
    static let supportedSchemaVersion = 4

    var shadow: SyncedConfigPayload
    var base: SyncedConfigPayload?
    var recordSystemFields: Data?
    var hasCompletedSync: Bool
    var isDirty: Bool
    /// Revision of the bytes currently installed in each device-local Logo
    /// file. This is transport state, not part of the CloudKit config record.
    var installedLogoRevisions: [Int: String]
    /// A newer app may have written a payload this version cannot decode.
    /// Keep the exact remote bytes and metadata locally while uploads are
    /// stopped, so recovery never depends on a lossy partial decode.
    var unsupportedRemoteSchemaVersion: Int? = nil
    var unsupportedRemotePayloadData: Data? = nil
    var unsupportedRemoteSystemFields: Data? = nil

    static let empty = ConfigSyncLocalState(
        shadow: .empty,
        base: nil,
        recordSystemFields: nil,
        hasCompletedSync: false,
        isDirty: false,
        installedLogoRevisions: [:],
        unsupportedRemoteSchemaVersion: nil,
        unsupportedRemotePayloadData: nil,
        unsupportedRemoteSystemFields: nil
    )
}

struct ConfigSyncStateStore {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load(togglUserID: Int) -> ConfigSyncLocalState {
        guard let data = defaults.data(forKey: key(togglUserID)),
              let state = try? JSONDecoder().decode(ConfigSyncLocalState.self, from: data)
        else { return .empty }
        return state
    }

    func save(_ state: ConfigSyncLocalState, togglUserID: Int) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        defaults.set(data, forKey: key(togglUserID))
    }

    func remove(togglUserID: Int) {
        defaults.removeObject(forKey: key(togglUserID))
    }

    private func key(_ togglUserID: Int) -> String {
        "momenta.iCloud.configState.\(togglUserID)"
    }
}
