import CloudKit
import Foundation
import Observation

@MainActor
@Observable
final class ICloudSyncManager {
    enum State: Equatable {
        case off
        case waitingForAccountConfirmation
        case waitingForInitialMerge
        case syncing
        case synced
        case needsAttention(String)

        var label: String {
            switch self {
            case .off: return "Off"
            case .waitingForAccountConfirmation: return "Confirm account"
            case .waitingForInitialMerge: return "Confirm merge"
            case .syncing: return "Syncing"
            case .synced: return "Synced"
            case .needsAttention: return "Needs attention"
            }
        }
    }

    private static let lastSuccessKey = "momenta.iCloud.lastSuccessfulSyncAt"

    let account: AccountManager
    private let config: ConfigStore
    private let database: any CloudSyncDatabase
    private let localStore: ConfigSyncStateStore
    private let defaults: UserDefaults
    private var pendingInitialRecord: CloudConfigRecord?
    private var pendingInitialPayload: SyncedConfigPayload?
    private var syncTask: Task<Void, Never>?
    private var isSyncInProgress = false
    private var needsAnotherSync = false

    private(set) var state: State
    private(set) var lastSuccessfulSyncAt: Date?

    init(
        account: AccountManager,
        config: ConfigStore,
        database: any CloudSyncDatabase = CloudKitSyncDatabase(),
        defaults: UserDefaults = .standard
    ) {
        self.account = account
        self.config = config
        self.database = database
        self.defaults = defaults
        localStore = ConfigSyncStateStore(defaults: defaults)
        state = account.usesICloudCredential ? .syncing : .off
        lastSuccessfulSyncAt = defaults.object(forKey: Self.lastSuccessKey) as? Date

        config.onUserChange = { [weak self] change in
            self?.capture(change)
        }
        config.onTogglReconciliation = { [weak self] in
            self?.projectCurrentShadow()
        }
    }

    isolated deinit {
        syncTask?.cancel()
    }

    var isEnabled: Bool {
        account.usesICloudCredential
    }

    var attentionMessage: String? {
        if let message = account.credentialAttention?.message { return message }
        if case .needsAttention(let message) = state { return message }
        return nil
    }

    @discardableResult
    func enable() async -> Bool {
        state = .syncing
        let enabled = await account.enableICloudCredentialSync()
        guard enabled else {
            state = account.discoveredSyncedAccount == nil
                ? .needsAttention(account.credentialAttention?.message ?? "iCloud sync could not be enabled.")
                : .waitingForAccountConfirmation
            return false
        }
        await syncNow()
        return true
    }

    func confirmDiscoveredAccount() async {
        state = .syncing
        guard await account.confirmDiscoveredSyncedAccount() else {
            state = .needsAttention(account.credentialAttention?.message ?? "The Toggl account could not be connected.")
            return
        }
        await syncNow()
    }

    func cancelDiscoveredAccount() {
        account.cancelDiscoveredSyncedAccount()
        state = .off
    }

    func stopUsingOnThisMac() {
        do {
            try account.stopUsingICloudCredentialOnThisMac()
            syncTask?.cancel()
            syncTask = nil
            needsAnotherSync = false
            pendingInitialRecord = nil
            pendingInitialPayload = nil
            state = .off
        } catch {
            state = .needsAttention(error.localizedDescription)
        }
    }

    func disconnectOnAllMacs() {
        account.disconnect()
        syncTask?.cancel()
        syncTask = nil
        needsAnotherSync = false
        pendingInitialRecord = nil
        pendingInitialPayload = nil
        state = .off
    }

    func handleForeground() async {
        guard account.usesICloudCredential else { return }
        await account.validateICloudCredentialForForeground()
        guard account.credentialAttention == nil else {
            state = .needsAttention(account.credentialAttention?.message ?? "The Toggl account needs attention.")
            return
        }
        await syncNow()
    }

    func retry() {
        scheduleSync()
    }

    func confirmInitialMerge() async {
        guard let record = pendingInitialRecord,
              let remote = pendingInitialPayload,
              let userID = connectedUserID
        else { return }
        var local = localStore.load(togglUserID: userID)
        local.shadow = .initialMerge(local: local.shadow, server: remote)
        local.base = remote
        local.recordSystemFields = record.systemFields
        local.hasCompletedSync = true
        local.isDirty = true
        localStore.save(local, togglUserID: userID)
        pendingInitialRecord = nil
        pendingInitialPayload = nil
        await saveCandidate(
            local.shadow,
            userID: userID,
            state: local,
            serverPayload: remote,
            serverRecord: record
        )
    }

    func cancelInitialMerge() {
        pendingInitialRecord = nil
        pendingInitialPayload = nil
        state = .needsAttention("This Mac and iCloud both have existing settings. Confirm the initial merge to continue syncing.")
    }

    func syncNow() async {
        guard account.usesICloudCredential, let userID = connectedUserID else {
            state = account.discoveredSyncedAccount == nil ? .off : .waitingForAccountConfirmation
            return
        }
        guard account.credentialAttention == nil else {
            state = .needsAttention(account.credentialAttention?.message ?? "The Toggl account needs attention.")
            return
        }
        guard !isSyncInProgress else {
            needsAnotherSync = true
            return
        }
        syncTask?.cancel()
        syncTask = nil
        isSyncInProgress = true
        defer {
            isSyncInProgress = false
            if needsAnotherSync {
                needsAnotherSync = false
                scheduleSync()
            }
        }
        state = .syncing

        do {
            guard try await database.accountStatus() == .available else {
                state = .needsAttention("Sign in to iCloud to sync Momenta on this Mac.")
                return
            }
            guard syncIsStillEnabled(for: userID) else { return }
            var local = localStore.load(togglUserID: userID)
            seedShadowIfNeeded(&local)
            localStore.save(local, togglUserID: userID)

            let remoteRecord = try await database.fetchConfig(togglUserID: userID)
            guard syncIsStillEnabled(for: userID) else { return }
            guard let remoteRecord else {
                await saveCandidate(
                    local.shadow,
                    userID: userID,
                    state: local,
                    serverPayload: .empty,
                    serverRecord: nil
                )
                return
            }
            guard remoteRecord.schemaVersion <= ConfigSyncLocalState.supportedSchemaVersion else {
                preserveUnsupported(remoteRecord, userID: userID)
                state = .needsAttention("Update Momenta on this Mac before iCloud sync can continue.")
                return
            }
            let remote = try Self.decodePayload(remoteRecord.payloadData)

            if local.base == nil {
                if local.hasCompletedSync {
                    state = .needsAttention("The local iCloud sync base is missing or damaged. Local and iCloud data were preserved; reconnect sync to recover safely.")
                    return
                }
                if local.shadow.hasUserSettings, remote.hasUserSettings, local.shadow != remote {
                    pendingInitialRecord = remoteRecord
                    pendingInitialPayload = remote
                    state = .waitingForInitialMerge
                    return
                }
                let adopted = local.shadow.hasUserSettings ? local.shadow : remote
                if adopted == remote {
                    await accept(remote, record: remoteRecord, userID: userID, local: local)
                } else {
                    local.base = remote
                    local.recordSystemFields = remoteRecord.systemFields
                    local.hasCompletedSync = true
                    local.isDirty = true
                    await saveCandidate(
                        adopted,
                        userID: userID,
                        state: local,
                        serverPayload: remote,
                        serverRecord: remoteRecord
                    )
                }
                return
            }

            let merged = SyncedConfigPayload.merge(
                base: local.base ?? .empty,
                local: local.shadow,
                server: remote
            )
            if merged == remote {
                await accept(remote, record: remoteRecord, userID: userID, local: local)
            } else {
                await saveCandidate(
                    merged,
                    userID: userID,
                    state: local,
                    serverPayload: remote,
                    serverRecord: remoteRecord
                )
            }
        } catch is CancellationError {
            if syncIsStillEnabled(for: userID) {
                needsAnotherSync = true
            }
        } catch {
            state = .needsAttention(error.localizedDescription)
        }
    }

    private var connectedUserID: Int? {
        guard case .connected(let snapshot) = account.state else { return nil }
        return snapshot.togglUserID
    }

    private func capture(_ change: ConfigStore.UserChange) {
        guard account.usesICloudCredential, let userID = connectedUserID else { return }
        var local = localStore.load(togglUserID: userID)
        seedShadowIfNeeded(&local)
        switch change {
        case .client(let client, let logoContentChanged):
            var revision = local.shadow.clients[client.id]?.logoRevision
            if logoContentChanged {
                if client.logoFileName == nil {
                    revision = nil
                    local.installedLogoRevisions[client.id] = nil
                } else {
                    revision = UUID().uuidString
                    local.installedLogoRevisions[client.id] = revision
                }
            }
            local.shadow.update(client: client, logoRevision: revision)
        case .order(let order):
            local.shadow.updateVisibleOrder(order)
        }
        local.isDirty = true
        localStore.save(local, togglUserID: userID)
        scheduleSync()
    }

    private func scheduleSync() {
        syncTask?.cancel()
        syncTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            await self?.runScheduledSync()
        }
    }

    private func runScheduledSync() async {
        syncTask = nil
        await syncNow()
    }

    private func seedShadowIfNeeded(_ local: inout ConfigSyncLocalState) {
        guard local.shadow.clients.isEmpty, !local.hasCompletedSync, !config.clients.isEmpty else { return }
        var payload = SyncedConfigPayload.empty
        for client in config.clients {
            let revision: String?
            if client.logoFileName != nil {
                revision = UUID().uuidString
                local.installedLogoRevisions[client.id] = revision
            } else {
                revision = nil
            }
            payload.update(client: client, logoRevision: revision)
        }
        payload.order = config.clients.map(\.id)
        local.shadow = payload
        local.isDirty = true
    }

    private func projectCurrentShadow() {
        guard account.usesICloudCredential, let userID = connectedUserID else { return }
        let local = localStore.load(togglUserID: userID)
        config.applySyncedPayload(local.shadow)
    }

    private func saveCandidate(
        _ initialCandidate: SyncedConfigPayload,
        userID: Int,
        state initialState: ConfigSyncLocalState,
        serverPayload initialServer: SyncedConfigPayload,
        serverRecord initialRecord: CloudConfigRecord?
    ) async {
        var candidate = initialCandidate
        var server = initialServer
        var record = initialRecord
        var local = initialState

        do {
            for _ in 0..<3 {
                try await uploadLocalLogos(
                    candidate: candidate,
                    server: server,
                    userID: userID,
                    local: local
                )
                guard syncIsStillEnabled(for: userID) else { return }
                do {
                    let saved = try await database.saveConfig(
                        togglUserID: userID,
                        schemaVersion: ConfigSyncLocalState.supportedSchemaVersion,
                        payloadData: try Self.encodePayload(candidate),
                        systemFields: record?.systemFields
                    )
                    guard syncIsStillEnabled(for: userID) else { return }
                    local = reconciledLocalState(
                        acceptedPayload: candidate,
                        acceptedSystemFields: saved.systemFields,
                        original: local,
                        userID: userID
                    )
                    localStore.save(local, togglUserID: userID)
                    await deleteSupersededLogos(candidate: candidate, server: server, userID: userID)
                    guard syncIsStillEnabled(for: userID) else { return }
                    await projectAndDownload(local.shadow, userID: userID, local: local)
                    guard syncIsStillEnabled(for: userID) else { return }
                    markSucceeded()
                    if local.isDirty { needsAnotherSync = true }
                    return
                } catch CloudSyncDatabaseError.conflict(let latestRecord) {
                    guard latestRecord.schemaVersion <= ConfigSyncLocalState.supportedSchemaVersion else {
                        preserveUnsupported(latestRecord, userID: userID)
                        state = .needsAttention("Update Momenta on this Mac before iCloud sync can continue.")
                        return
                    }
                    guard syncIsStillEnabled(for: userID) else { return }
                    let latest = try Self.decodePayload(latestRecord.payloadData)
                    candidate = .merge(base: server, local: candidate, server: latest)
                    server = latest
                    record = latestRecord
                    continue
                }
            }
            state = .needsAttention("iCloud changed repeatedly while Momenta was saving. Retry when the other Mac is idle.")
        } catch is CancellationError {
            if syncIsStillEnabled(for: userID) {
                needsAnotherSync = true
            }
        } catch {
            state = .needsAttention(error.localizedDescription)
        }
    }

    private func accept(
        _ payload: SyncedConfigPayload,
        record: CloudConfigRecord,
        userID: Int,
        local original: ConfigSyncLocalState
    ) async {
        let local = reconciledLocalState(
            acceptedPayload: payload,
            acceptedSystemFields: record.systemFields,
            original: original,
            userID: userID
        )
        localStore.save(local, togglUserID: userID)
        guard syncIsStillEnabled(for: userID) else { return }
        await projectAndDownload(local.shadow, userID: userID, local: local)
        guard syncIsStillEnabled(for: userID) else { return }
        markSucceeded()
        if local.isDirty { needsAnotherSync = true }
    }

    private func uploadLocalLogos(
        candidate: SyncedConfigPayload,
        server: SyncedConfigPayload,
        userID: Int,
        local: ConfigSyncLocalState
    ) async throws {
        for (clientID, client) in candidate.clients {
            guard syncIsStillEnabled(for: userID) else { throw CancellationError() }
            guard let revision = client.logoRevision,
                  revision != server.clients[clientID]?.logoRevision,
                  local.installedLogoRevisions[clientID] == revision,
                  let fileName = config.client(id: clientID)?.logoFileName
            else { continue }
            try await database.saveLogo(
                togglUserID: userID,
                clientID: clientID,
                revision: revision,
                fileURL: LogoStore.url(for: fileName)
            )
            guard syncIsStillEnabled(for: userID) else { throw CancellationError() }
        }
    }

    private func deleteSupersededLogos(
        candidate: SyncedConfigPayload,
        server: SyncedConfigPayload,
        userID: Int
    ) async {
        for (clientID, old) in server.clients
        where old.logoRevision != candidate.clients[clientID]?.logoRevision {
            guard syncIsStillEnabled(for: userID) else { return }
            guard let oldRevision = old.logoRevision else { continue }
            try? await database.deleteLogo(
                togglUserID: userID,
                clientID: clientID,
                revision: oldRevision
            )
        }
    }

    private func projectAndDownload(
        _ payload: SyncedConfigPayload,
        userID: Int,
        local original: ConfigSyncLocalState
    ) async {
        var local = original
        var fileNames: [Int: String] = [:]
        var logoWarning: String?

        for (clientID, synced) in payload.clients {
            guard syncIsStillEnabled(for: userID) else { return }
            guard config.client(id: clientID) != nil else { continue }
            guard let revision = synced.logoRevision else {
                if let existing = config.client(id: clientID)?.logoFileName {
                    LogoStore.deleteLogo(named: existing)
                }
                local.installedLogoRevisions[clientID] = nil
                continue
            }
            if local.installedLogoRevisions[clientID] == revision,
               let existing = config.client(id: clientID)?.logoFileName {
                fileNames[clientID] = existing
                continue
            }
            do {
                guard let remote = try await database.fetchLogo(
                    togglUserID: userID,
                    clientID: clientID,
                    revision: revision
                ),
                      remote.revision == revision
                else {
                    logoWarning = "A client Logo is still syncing. Momenta will retry."
                    continue
                }
                guard syncIsStillEnabled(for: userID) else { return }
                if let existing = config.client(id: clientID)?.logoFileName {
                    LogoStore.deleteLogo(named: existing)
                }
                fileNames[clientID] = try LogoStore.installSyncedLogo(remote.bytes, for: clientID)
                local.installedLogoRevisions[clientID] = revision
            } catch {
                logoWarning = "A client Logo could not be downloaded. Momenta will retry."
            }
        }
        guard syncIsStillEnabled(for: userID) else { return }
        localStore.save(local, togglUserID: userID)
        config.applySyncedPayload(payload, localLogoFileNames: fileNames)
        if let logoWarning {
            state = .needsAttention(logoWarning)
        }
    }

    private func syncIsStillEnabled(for userID: Int) -> Bool {
        account.usesICloudCredential && connectedUserID == userID
    }

    /// A cloud request can yield the main actor while the user edits another
    /// setting. Rebase those newer local edits onto the payload CloudKit just
    /// accepted instead of letting the older request overwrite them.
    private func reconciledLocalState(
        acceptedPayload: SyncedConfigPayload,
        acceptedSystemFields: Data,
        original: ConfigSyncLocalState,
        userID: Int
    ) -> ConfigSyncLocalState {
        let latest = localStore.load(togglUserID: userID)
        var reconciled = latest.shadow == original.shadow ? original : latest
        if latest.shadow == original.shadow {
            reconciled.shadow = acceptedPayload
        } else {
            reconciled.shadow = .merge(
                base: original.shadow,
                local: acceptedPayload,
                server: latest.shadow
            )
        }
        reconciled.base = acceptedPayload
        reconciled.recordSystemFields = acceptedSystemFields
        reconciled.hasCompletedSync = true
        reconciled.isDirty = reconciled.shadow != acceptedPayload
        reconciled.unsupportedRemoteSchemaVersion = nil
        reconciled.unsupportedRemotePayloadData = nil
        reconciled.unsupportedRemoteSystemFields = nil
        return reconciled
    }

    private func preserveUnsupported(_ record: CloudConfigRecord, userID: Int) {
        var local = localStore.load(togglUserID: userID)
        local.unsupportedRemoteSchemaVersion = record.schemaVersion
        local.unsupportedRemotePayloadData = record.payloadData
        local.unsupportedRemoteSystemFields = record.systemFields
        localStore.save(local, togglUserID: userID)
    }

    private func markSucceeded() {
        if case .needsAttention = state { return }
        let now = Date()
        lastSuccessfulSyncAt = now
        defaults.set(now, forKey: Self.lastSuccessKey)
        state = .synced
    }

    private static func encodePayload(_ payload: SyncedConfigPayload) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(payload)
    }

    private static func decodePayload(_ data: Data) throws -> SyncedConfigPayload {
        try JSONDecoder().decode(SyncedConfigPayload.self, from: data)
    }
}
