import Foundation
import Observation

/// Non-secret account info shown on the Account page. Persisted in
/// UserDefaults; the API token itself lives only in the Keychain.
struct AccountSnapshot: Codable, Equatable, Sendable {
    var fullname: String
    var email: String
    var workspaces: [TogglWorkspace]
    var connectedAt: Date
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

    private static let snapshotKey = "toggl.accountSnapshot"
    private static let lastSyncKey = "toggl.lastSyncAt"

    private let tokenStore: any TokenStore
    private let transport: any HTTPTransport
    private let defaults: UserDefaults

    private(set) var state: ConnectionState = .disconnected
    private(set) var lastSyncAt: Date?

    init(
        tokenStore: any TokenStore = KeychainTokenStore(),
        transport: any HTTPTransport = URLSession.shared,
        defaults: UserDefaults = .standard
    ) {
        self.tokenStore = tokenStore
        self.transport = transport
        self.defaults = defaults

        // Relaunch: connected as long as both the token and the snapshot
        // survived. No network call here; the next refresh validates naturally.
        if (try? tokenStore.load()) != nil,
           let data = defaults.data(forKey: Self.snapshotKey),
           let snapshot = try? JSONDecoder().decode(AccountSnapshot.self, from: data) {
            state = .connected(snapshot)
        }
        lastSyncAt = defaults.object(forKey: Self.lastSyncKey) as? Date
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
            try tokenStore.save(trimmed)
            let snapshot = AccountSnapshot(
                fullname: me.fullname,
                email: me.email,
                workspaces: workspaces,
                connectedAt: Date()
            )
            if let data = try? JSONEncoder().encode(snapshot) {
                defaults.set(data, forKey: Self.snapshotKey)
            }
            state = .connected(snapshot)
        } catch let error as TogglAPIError {
            state = .failed(error)
        } catch {
            state = .failed(.other(error.localizedDescription))
        }
    }

    /// Removes the token and account info. Clearing cached month data is the
    /// caller's choice, made in the confirmation dialog.
    func disconnect() {
        try? tokenStore.delete()
        defaults.removeObject(forKey: Self.snapshotKey)
        defaults.removeObject(forKey: Self.lastSyncKey)
        lastSyncAt = nil
        state = .disconnected
    }

    /// Called by the sync layer after a successful refresh.
    func markSynced(at date: Date = Date()) {
        lastSyncAt = date
        defaults.set(date, forKey: Self.lastSyncKey)
    }

    /// An API client bound to the stored token, when connected.
    func apiClient() -> TogglAPIClient? {
        guard let token = try? tokenStore.load() else { return nil }
        return TogglAPIClient(token: token, transport: transport)
    }
}
