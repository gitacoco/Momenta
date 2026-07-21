import Foundation
import Observation

/// Non-secret account info shown on the Account page. Persisted in
/// UserDefaults; the API token itself lives only in the Keychain.
struct AccountSnapshot: Codable, Equatable, Sendable {
    /// Stable Toggl identity used to scope CloudKit records and to ensure a
    /// synchronizable Keychain item has not changed accounts underneath an
    /// existing local snapshot. Optional for snapshots written by v0.1.
    var togglUserID: Int?
    var fullname: String
    var email: String
    var workspaces: [TogglWorkspace]
    var connectedAt: Date
    /// Optional so snapshots written by older releases still decode and do
    /// not make a valid Keychain token appear disconnected after an update.
    var defaultWorkspaceId: Int?
    var organizations: [TogglOrganization]?

    init(
        togglUserID: Int? = nil,
        fullname: String,
        email: String,
        workspaces: [TogglWorkspace],
        connectedAt: Date,
        defaultWorkspaceId: Int? = nil,
        organizations: [TogglOrganization]? = nil
    ) {
        self.togglUserID = togglUserID
        self.fullname = fullname
        self.email = email
        self.workspaces = workspaces
        self.connectedAt = connectedAt
        self.defaultWorkspaceId = defaultWorkspaceId
        self.organizations = organizations
    }

    var defaultOrganization: TogglOrganization? {
        guard let organizations, !organizations.isEmpty else { return nil }
        guard let defaultWorkspaceId,
              let organizationID = workspaces.first(where: { $0.id == defaultWorkspaceId })?.organizationId
        else {
            return organizations.first
        }
        return organizations.first(where: { $0.id == organizationID }) ?? organizations.first
    }

    var visibleWorkspaces: [TogglWorkspace] {
        guard let organization = defaultOrganization,
              organization.supportsMultipleWorkspaces
        else { return [] }
        let matches = workspaces.filter { $0.organizationId == organization.id }
        return matches.count > 1 ? matches : []
    }
}

/// Owns the Toggl connection lifecycle: token entry and validation,
/// connection state across relaunches, and disconnecting.
@MainActor
@Observable
final class AccountManager {
    enum ConnectionState: Equatable {
        case disconnected
        case validating
        case connected(AccountSnapshot)
        case failed(TogglAPIError)
    }

    struct DiscoveredSyncedAccount: Equatable, Sendable {
        var togglUserID: Int
        var fullname: String
        var email: String
    }

    enum CredentialAttention: Equatable, Sendable {
        case conflictingLocalAndSyncedTokens
        case syncedTokenMissing
        case accountMismatch(expectedEmail: String, foundEmail: String)
        case operation(String)

        var message: String {
            switch self {
            case .conflictingLocalAndSyncedTokens:
                return "This Mac and iCloud contain different Toggl credentials. Reconnect the account you want to use."
            case .syncedTokenMissing:
                return "The iCloud Keychain credential is no longer available. Reconnect or stop using iCloud sync on this Mac."
            case .accountMismatch(let expectedEmail, let foundEmail):
                return "iCloud Keychain now contains \(foundEmail), but this Mac is connected as \(expectedEmail). Confirm the account before continuing."
            case .operation(let message):
                return message
            }
        }
    }

    private static let snapshotKey = "toggl.accountSnapshot"
    private static let lastSyncKey = "toggl.lastSyncAt"
    private static let iCloudCredentialKey = "momenta.iCloud.credentialEnabled"

    private let tokenStore: any TokenStore
    private let transport: any HTTPTransport
    private let defaults: UserDefaults

    private(set) var state: ConnectionState = .disconnected
    private(set) var lastSyncAt: Date?
    private(set) var usesICloudCredential = false
    private(set) var discoveredSyncedAccount: DiscoveredSyncedAccount?
    private(set) var credentialAttention: CredentialAttention?
    /// Bumped on every connect/disconnect so consumers holding token-bound
    /// resources (API clients, caches) know to rebuild them.
    private(set) var generation = 0
    /// A token becomes usable by data providers only after the account
    /// identity has been validated for the current process. It is never
    /// persisted outside Keychain.
    private var validatedToken: String?
    private var pendingSyncedToken: String?
    private var pendingSyncedMe: TogglMe?

    init(
        tokenStore: any TokenStore = KeychainTokenStore(),
        transport: any HTTPTransport = URLSession.shared,
        defaults: UserDefaults = .standard
    ) {
        self.tokenStore = tokenStore
        self.transport = transport
        self.defaults = defaults
        usesICloudCredential = defaults.bool(forKey: Self.iCloudCredentialKey)

        // Relaunch: connected as long as both the token and the snapshot
        // survived. A synchronizable token is held back from API clients until
        // the launch/foreground identity check validates it against /me.
        let restoredToken = Self.loadRestoredToken(
            from: tokenStore,
            usesICloudCredential: usesICloudCredential
        )
        if restoredToken != nil,
           let data = defaults.data(forKey: Self.snapshotKey),
           let snapshot = try? JSONDecoder().decode(AccountSnapshot.self, from: data) {
            state = .connected(snapshot)
            if !usesICloudCredential {
                validatedToken = restoredToken
            }
        }
        lastSyncAt = defaults.object(forKey: Self.lastSyncKey) as? Date
    }

    private static func loadRestoredToken(
        from store: any TokenStore,
        usesICloudCredential: Bool
    ) -> String? {
        if usesICloudCredential,
           let store = store as? any SynchronizableTokenStore {
            return try? store.load(scope: .synchronizable)
        }
        return try? store.load()
    }

    var isConnected: Bool {
        if case .connected = state { return true }
        return false
    }

    /// Validates the token against /me, fetches workspaces, and only then
    /// persists the token to the Keychain and the snapshot to UserDefaults.
    func connect(token: String) async {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        state = .validating
        let client = TogglAPIClient(token: trimmed, transport: transport)
        do {
            let me = try await client.me()
            let workspaces = try await client.workspaces()
            // Plan metadata is supplemental. A temporary failure here must
            // not reject an otherwise valid account connection.
            let organizations = try? await client.organizations()
            try saveActiveToken(trimmed)
            let snapshot = AccountSnapshot(
                togglUserID: me.id,
                fullname: me.fullname,
                email: me.email,
                workspaces: workspaces,
                connectedAt: Date(),
                defaultWorkspaceId: me.defaultWorkspaceId,
                organizations: organizations
            )
            persist(snapshot)
            validatedToken = trimmed
            discoveredSyncedAccount = nil
            pendingSyncedToken = nil
            pendingSyncedMe = nil
            credentialAttention = nil
            generation += 1
            state = .connected(snapshot)
        } catch let error as TogglAPIError {
            state = .failed(error)
        } catch {
            state = .failed(.other(error.localizedDescription))
        }
    }

    /// One-time migration for snapshots created before organization/plan
    /// metadata was stored. It is intentionally best-effort and never changes
    /// a connected account into a failure state.
    func refreshMetadataIfNeeded() async {
        guard case .connected(let snapshot) = state,
              snapshot.organizations == nil,
              let client = apiClient()
        else { return }

        do {
            let me = try await client.me()
            let workspaces = try await client.workspaces()
            let organizations = try await client.organizations()
            var updated = snapshot
            updated.workspaces = workspaces
            updated.defaultWorkspaceId = me.defaultWorkspaceId
            updated.organizations = organizations
            persist(updated)
            state = .connected(updated)
        } catch {
            // Keep the cached connection usable; opening Account again can
            // retry once network access or quota is available.
        }
    }

    // MARK: iCloud credential lifecycle

    /// Migrates a connected local credential to a synchronizable Keychain
    /// item. On a new Mac, discovers the synced account and pauses for an
    /// explicit confirmation instead of silently adopting it.
    @discardableResult
    func enableICloudCredentialSync() async -> Bool {
        guard let store = tokenStore as? any SynchronizableTokenStore else {
            credentialAttention = .operation("This Keychain store does not support iCloud synchronization.")
            return false
        }

        do {
            let local = try store.load(scope: .local)
            let synced = try store.load(scope: .synchronizable)
            if let local, let synced, local != synced {
                validatedToken = nil
                credentialAttention = .conflictingLocalAndSyncedTokens
                return false
            }

            if case .connected(let snapshot) = state,
               let token = local ?? synced {
                let me = try await TogglAPIClient(token: token, transport: transport).me()
                guard accountMatches(snapshot: snapshot, me: me) else {
                    validatedToken = nil
                    credentialAttention = .accountMismatch(
                        expectedEmail: snapshot.email,
                        foundEmail: me.email
                    )
                    return false
                }

                if synced == nil {
                    try store.save(token, scope: .synchronizable)
                }
                guard try store.load(scope: .synchronizable) == token else {
                    throw KeychainError(status: errSecDecode)
                }
                // Validate the exact item that will survive migration before
                // removing the only known-good legacy credential.
                let verifiedMe = try await TogglAPIClient(token: token, transport: transport).me()
                guard verifiedMe.id == me.id else {
                    throw TogglAPIError.other("The iCloud Keychain credential changed during migration.")
                }
                try store.delete(scope: .local)

                usesICloudCredential = true
                defaults.set(true, forKey: Self.iCloudCredentialKey)
                validatedToken = token
                var updated = snapshot
                updated.togglUserID = me.id
                updated.fullname = me.fullname
                updated.email = me.email
                persist(updated)
                state = .connected(updated)
                credentialAttention = nil
                generation += 1
                return true
            }

            guard let synced else {
                credentialAttention = .operation("No Toggl credential was found in iCloud Keychain.")
                return false
            }
            return await discoverSyncedAccount(token: synced)
        } catch let error as TogglAPIError {
            credentialAttention = .operation(error.errorDescription ?? "Could not validate the Toggl account.")
        } catch {
            credentialAttention = .operation(error.localizedDescription)
        }
        return false
    }

    /// Completes new-Mac bootstrap only after the user has seen and accepted
    /// the Toggl identity discovered from the synchronized token.
    func confirmDiscoveredSyncedAccount() async -> Bool {
        guard let token = pendingSyncedToken, let me = pendingSyncedMe else { return false }
        state = .validating
        do {
            let client = TogglAPIClient(token: token, transport: transport)
            let workspaces = try await client.workspaces()
            let organizations = try? await client.organizations()
            let snapshot = AccountSnapshot(
                togglUserID: me.id,
                fullname: me.fullname,
                email: me.email,
                workspaces: workspaces,
                connectedAt: Date(),
                defaultWorkspaceId: me.defaultWorkspaceId,
                organizations: organizations
            )
            usesICloudCredential = true
            defaults.set(true, forKey: Self.iCloudCredentialKey)
            persist(snapshot)
            validatedToken = token
            pendingSyncedToken = nil
            pendingSyncedMe = nil
            discoveredSyncedAccount = nil
            credentialAttention = nil
            generation += 1
            state = .connected(snapshot)
            return true
        } catch let error as TogglAPIError {
            state = .failed(error)
        } catch {
            state = .failed(.other(error.localizedDescription))
        }
        return false
    }

    func cancelDiscoveredSyncedAccount() {
        pendingSyncedToken = nil
        pendingSyncedMe = nil
        discoveredSyncedAccount = nil
        credentialAttention = nil
        state = .disconnected
    }

    /// Stops Momenta using the synchronizable item on this Mac without
    /// deleting it from iCloud. A verified local copy is created first so the
    /// current connection remains usable offline and after relaunch.
    func stopUsingICloudCredentialOnThisMac() throws {
        guard let store = tokenStore as? any SynchronizableTokenStore,
              let token = try store.load(scope: .synchronizable)
        else { throw KeychainError(status: errSecItemNotFound) }
        try store.save(token, scope: .local)
        guard try store.load(scope: .local) == token else {
            throw KeychainError(status: errSecDecode)
        }
        usesICloudCredential = false
        defaults.set(false, forKey: Self.iCloudCredentialKey)
        validatedToken = token
        credentialAttention = nil
        generation += 1
    }

    /// Launch/foreground gate for a credential that iCloud may have replaced
    /// while the app was not active. No data provider can obtain the token
    /// until this check succeeds.
    func validateICloudCredentialForForeground() async {
        guard usesICloudCredential,
              let store = tokenStore as? any SynchronizableTokenStore
        else { return }
        do {
            guard let token = try store.load(scope: .synchronizable) else {
                validatedToken = nil
                credentialAttention = .syncedTokenMissing
                generation += 1
                return
            }
            guard case .connected(let snapshot) = state else {
                if discoveredSyncedAccount == nil {
                    _ = await discoverSyncedAccount(token: token)
                }
                return
            }
            // The token was already matched to this account in this process.
            // Re-reading the same Keychain bytes does not require another /me
            // request; a changed token still fails closed until it is verified.
            guard token != validatedToken else { return }
            let me = try await TogglAPIClient(token: token, transport: transport).me()
            guard accountMatches(snapshot: snapshot, me: me) else {
                validatedToken = nil
                credentialAttention = .accountMismatch(
                    expectedEmail: snapshot.email,
                    foundEmail: me.email
                )
                generation += 1
                return
            }
            var updated = snapshot
            updated.togglUserID = me.id
            updated.fullname = me.fullname
            updated.email = me.email
            persist(updated)
            state = .connected(updated)
            validatedToken = token
            credentialAttention = nil
            generation += 1
        } catch let error as TogglAPIError {
            // Offline and transient failures preserve cached/local behavior,
            // but the unvalidated token remains unavailable to API clients.
            validatedToken = nil
            credentialAttention = .operation(error.errorDescription ?? "Could not validate the Toggl account.")
        } catch {
            validatedToken = nil
            credentialAttention = .operation(error.localizedDescription)
        }
    }

    private func discoverSyncedAccount(token: String) async -> Bool {
        do {
            let me = try await TogglAPIClient(token: token, transport: transport).me()
            pendingSyncedToken = token
            pendingSyncedMe = me
            discoveredSyncedAccount = DiscoveredSyncedAccount(
                togglUserID: me.id,
                fullname: me.fullname,
                email: me.email
            )
            credentialAttention = nil
            state = .disconnected
        } catch let error as TogglAPIError {
            credentialAttention = .operation(error.errorDescription ?? "Could not validate the synced Toggl account.")
        } catch {
            credentialAttention = .operation(error.localizedDescription)
        }
        return false
    }

    private func accountMatches(snapshot: AccountSnapshot, me: TogglMe) -> Bool {
        if let togglUserID = snapshot.togglUserID {
            return togglUserID == me.id
        }
        // One-time migration for pre-user-ID snapshots. A local token may be
        // trusted only when the account identity shown to the user still
        // matches; the stable ID is persisted immediately afterward.
        return snapshot.email.localizedCaseInsensitiveCompare(me.email) == .orderedSame
    }

    /// Removes the token and account info. Clearing cached month data is the
    /// caller's choice, made in the confirmation dialog.
    func disconnect() {
        if let store = tokenStore as? any SynchronizableTokenStore {
            // A Mac that is not participating in sync must never delete an
            // unrelated synchronizable credential it merely discovered.
            try? store.delete(scope: usesICloudCredential ? .any : .local)
        } else {
            try? tokenStore.delete()
        }
        defaults.removeObject(forKey: Self.snapshotKey)
        defaults.removeObject(forKey: Self.lastSyncKey)
        defaults.removeObject(forKey: Self.iCloudCredentialKey)
        lastSyncAt = nil
        usesICloudCredential = false
        validatedToken = nil
        pendingSyncedToken = nil
        pendingSyncedMe = nil
        discoveredSyncedAccount = nil
        credentialAttention = nil
        generation += 1
        state = .disconnected
    }

    /// Called by the sync layer after a successful refresh.
    func markSynced(at date: Date = Date()) {
        lastSyncAt = date
        defaults.set(date, forKey: Self.lastSyncKey)
    }

    /// An API client bound to the stored token, when connected.
    func apiClient() -> TogglAPIClient? {
        guard case .connected = state, let token = validatedToken else { return nil }
        return TogglAPIClient(token: token, transport: transport)
    }

    private func saveActiveToken(_ token: String) throws {
        if usesICloudCredential,
           let store = tokenStore as? any SynchronizableTokenStore {
            try store.save(token, scope: .synchronizable)
        } else {
            try tokenStore.save(token)
        }
    }

    private func persist(_ snapshot: AccountSnapshot) {
        if let data = try? JSONEncoder().encode(snapshot) {
            defaults.set(data, forKey: Self.snapshotKey)
        }
    }
}
