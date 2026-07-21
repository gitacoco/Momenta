import Foundation
import Security
import Testing
@testable import Momenta

final class InMemoryTokenStore: SynchronizableTokenStore, @unchecked Sendable {
    private(set) var localToken: String?
    private(set) var syncedToken: String?

    var token: String? { localToken }

    init(token: String? = nil, syncedToken: String? = nil) {
        localToken = token
        self.syncedToken = syncedToken
    }

    func save(_ token: String) throws { localToken = token }
    func load() throws -> String? { localToken }
    func delete() throws { localToken = nil }

    func save(_ token: String, scope: TokenItemScope) throws {
        switch scope {
        case .local: localToken = token
        case .synchronizable: syncedToken = token
        case .any: throw KeychainError(status: errSecParam)
        }
    }

    func load(scope: TokenItemScope) throws -> String? {
        switch scope {
        case .local: return localToken
        case .synchronizable: return syncedToken
        case .any: return localToken ?? syncedToken
        }
    }

    func delete(scope: TokenItemScope) throws {
        switch scope {
        case .local: localToken = nil
        case .synchronizable: syncedToken = nil
        case .any:
            localToken = nil
            syncedToken = nil
        }
    }
}

/// Multi-response transport: serves queued responses in order (/me,
/// /workspaces, then optional /me/organizations) so the connect flow can be
/// driven end to end.
final class SequenceTransport: HTTPTransport, @unchecked Sendable {
    private var queue: [Result<(Data, Int), Error>]
    private(set) var requests: [URLRequest] = []

    init(_ responses: [Result<(Data, Int), Error>]) {
        queue = responses
    }

    func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        guard !queue.isEmpty else { throw TogglAPIError.other("No stubbed response") }
        switch queue.removeFirst() {
        case .success(let (data, status)):
            let response = HTTPURLResponse(
                url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil
            )!
            return (data, response)
        case .failure(let error):
            throw error
        }
    }
}

@MainActor
struct AccountManagerTests {
    private static let meJSON = Data(#"{"id":1,"fullname":"Zhibang Jiang","email":"z@example.com"}"#.utf8)
    private static let workspacesJSON = Data(#"[{"id":101,"name":"Freelance","organization_id":10}]"#.utf8)
    private static let organizationsJSON = Data(#"[{"id":10,"name":"Studio","is_multi_workspace_enabled":false,"subscription":{"plan_name":"Free","enterprise":false}}]"#.utf8)

    private func freshDefaults() -> UserDefaults {
        let suite = "MomentaTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test func successfulConnectPersistsTokenAndSnapshot() async {
        let store = InMemoryTokenStore()
        let defaults = freshDefaults()
        let transport = SequenceTransport([
            .success((Self.meJSON, 200)),
            .success((Self.workspacesJSON, 200)),
            .success((Self.organizationsJSON, 200)),
        ])
        let manager = AccountManager(tokenStore: store, transport: transport, defaults: defaults)

        await manager.connect(token: "  tok-abc  ")

        #expect(store.token == "tok-abc") // trimmed
        guard case .connected(let snapshot) = manager.state else {
            Issue.record("Expected connected, got \(manager.state)")
            return
        }
        #expect(snapshot.fullname == "Zhibang Jiang")
        #expect(snapshot.togglUserID == 1)
        #expect(snapshot.workspaces.map(\.id) == [101])
        #expect(snapshot.defaultOrganization?.displayPlanName == "Free")
        #expect(snapshot.visibleWorkspaces.isEmpty)

        // The persisted snapshot must never contain the token.
        let persisted = defaults.data(forKey: "toggl.accountSnapshot").map { String(decoding: $0, as: UTF8.self) } ?? ""
        #expect(!persisted.isEmpty)
        #expect(!persisted.contains("tok-abc"))
    }

    @Test func failedValidationSavesNothing() async {
        let store = InMemoryTokenStore()
        let defaults = freshDefaults()
        let transport = SequenceTransport([.success((Data(), 401))])
        let manager = AccountManager(tokenStore: store, transport: transport, defaults: defaults)

        await manager.connect(token: "bad-token")

        #expect(manager.state == .failed(.unauthorized))
        #expect(store.token == nil)
        #expect(defaults.data(forKey: "toggl.accountSnapshot") == nil)
    }

    @Test func emptyTokenIsIgnored() async {
        let manager = AccountManager(
            tokenStore: InMemoryTokenStore(),
            transport: SequenceTransport([]),
            defaults: freshDefaults()
        )
        await manager.connect(token: "   ")
        #expect(manager.state == .disconnected)
    }

    @Test func disconnectClearsTokenSnapshotAndSyncTime() async {
        let store = InMemoryTokenStore()
        let defaults = freshDefaults()
        let transport = SequenceTransport([
            .success((Self.meJSON, 200)),
            .success((Self.workspacesJSON, 200)),
            .success((Self.organizationsJSON, 200)),
        ])
        let manager = AccountManager(tokenStore: store, transport: transport, defaults: defaults)
        await manager.connect(token: "tok")
        manager.markSynced()
        #expect(manager.lastSyncAt != nil)

        manager.disconnect()

        #expect(store.token == nil)
        #expect(manager.state == .disconnected)
        #expect(manager.lastSyncAt == nil)
        #expect(defaults.data(forKey: "toggl.accountSnapshot") == nil)
        #expect(defaults.object(forKey: "toggl.lastSyncAt") == nil)
    }

    @Test func relaunchRestoresConnectionWithoutNetwork() async {
        let store = InMemoryTokenStore(token: "tok")
        let defaults = freshDefaults()
        let snapshot = AccountSnapshot(
            fullname: "Zhibang Jiang", email: "z@example.com",
            workspaces: [TogglWorkspace(id: 101, name: "Freelance")],
            connectedAt: Date(timeIntervalSince1970: 1_780_000_000)
        )
        defaults.set(try! JSONEncoder().encode(snapshot), forKey: "toggl.accountSnapshot")

        // No stubbed responses: init must not hit the network.
        let manager = AccountManager(tokenStore: store, transport: SequenceTransport([]), defaults: defaults)
        #expect(manager.state == .connected(snapshot))
    }

    @Test func relaunchRestoresLegacySnapshotWithoutPlanMetadata() async {
        struct LegacySnapshot: Codable {
            var fullname: String
            var email: String
            var workspaces: [TogglWorkspace]
            var connectedAt: Date
        }

        let store = InMemoryTokenStore(token: "tok")
        let defaults = freshDefaults()
        let legacy = LegacySnapshot(
            fullname: "Zhibang Jiang",
            email: "z@example.com",
            workspaces: [TogglWorkspace(id: 101, name: "Freelance")],
            connectedAt: Date(timeIntervalSince1970: 1_780_000_000)
        )
        defaults.set(try! JSONEncoder().encode(legacy), forKey: "toggl.accountSnapshot")

        let manager = AccountManager(tokenStore: store, transport: SequenceTransport([]), defaults: defaults)
        guard case .connected(let snapshot) = manager.state else {
            Issue.record("Expected legacy snapshot to remain connected")
            return
        }
        #expect(snapshot.organizations == nil)
        #expect(snapshot.defaultWorkspaceId == nil)
    }

    @Test func missingTokenMeansDisconnectedEvenWithSnapshot() async {
        let defaults = freshDefaults()
        let snapshot = AccountSnapshot(fullname: "Z", email: "z@x.dev", workspaces: [], connectedAt: Date())
        defaults.set(try! JSONEncoder().encode(snapshot), forKey: "toggl.accountSnapshot")

        let manager = AccountManager(
            tokenStore: InMemoryTokenStore(),
            transport: SequenceTransport([]),
            defaults: defaults
        )
        #expect(manager.state == .disconnected)
    }

    @Test func workspaceVisibilityUsesDefaultOrganizationCapabilityNotAccountCount() {
        let workspaces = [
            TogglWorkspace(id: 101, name: "Studio", organizationId: 10),
            TogglWorkspace(id: 202, name: "Community", organizationId: 20),
        ]
        let freeOrganizations = [
            TogglOrganization(
                id: 10,
                name: "Personal",
                subscription: TogglSubscription(planName: "Free", enterprise: false)
            ),
            TogglOrganization(
                id: 20,
                name: "Volunteer",
                subscription: TogglSubscription(planName: "Free", enterprise: false)
            ),
        ]
        let freeSnapshot = AccountSnapshot(
            fullname: "Z",
            email: "z@x.dev",
            workspaces: workspaces,
            connectedAt: Date(),
            defaultWorkspaceId: 101,
            organizations: freeOrganizations
        )
        #expect(freeSnapshot.visibleWorkspaces.isEmpty)

        let enterpriseWorkspaces = [
            TogglWorkspace(id: 301, name: "Design", organizationId: 30),
            TogglWorkspace(id: 302, name: "Engineering", organizationId: 30),
        ]
        let enterpriseSnapshot = AccountSnapshot(
            fullname: "Z",
            email: "z@x.dev",
            workspaces: enterpriseWorkspaces,
            connectedAt: Date(),
            defaultWorkspaceId: 301,
            organizations: [
                TogglOrganization(
                    id: 30,
                    name: "Company",
                    isMultiWorkspaceEnabled: true,
                    subscription: TogglSubscription(planName: "Enterprise", enterprise: true)
                )
            ]
        )
        #expect(enterpriseSnapshot.visibleWorkspaces.map(\.id) == [301, 302])
    }

    @Test func enablingICloudWritesVerifiesThenDeletesLegacyToken() async {
        let store = InMemoryTokenStore()
        let defaults = freshDefaults()
        let transport = SequenceTransport([
            .success((Self.meJSON, 200)),
            .success((Self.workspacesJSON, 200)),
            .success((Self.organizationsJSON, 200)),
            .success((Self.meJSON, 200)),
            .success((Self.meJSON, 200)),
        ])
        let manager = AccountManager(tokenStore: store, transport: transport, defaults: defaults)
        await manager.connect(token: "tok")

        let enabled = await manager.enableICloudCredentialSync()

        #expect(enabled)
        #expect(store.localToken == nil)
        #expect(store.syncedToken == "tok")
        #expect(manager.usesICloudCredential)
        #expect(manager.apiClient() != nil)
    }

    @Test func conflictingLocalAndSyncedTokensNeedAttention() async {
        let store = InMemoryTokenStore(token: "local", syncedToken: "remote")
        let defaults = freshDefaults()
        let snapshot = AccountSnapshot(
            togglUserID: 1,
            fullname: "Z",
            email: "z@example.com",
            workspaces: [],
            connectedAt: Date()
        )
        defaults.set(try! JSONEncoder().encode(snapshot), forKey: "toggl.accountSnapshot")
        let manager = AccountManager(
            tokenStore: store,
            transport: SequenceTransport([]),
            defaults: defaults
        )

        let enabled = await manager.enableICloudCredentialSync()
        #expect(enabled == false)
        #expect(manager.credentialAttention == .conflictingLocalAndSyncedTokens)
        #expect(store.localToken == "local")
        #expect(store.syncedToken == "remote")
    }

    @Test func newMacRequiresConfirmationBeforeAdoptingSyncedToken() async {
        let store = InMemoryTokenStore(syncedToken: "remote")
        let manager = AccountManager(
            tokenStore: store,
            transport: SequenceTransport([
                .success((Self.meJSON, 200)),
                .success((Self.workspacesJSON, 200)),
                .success((Self.organizationsJSON, 200)),
            ]),
            defaults: freshDefaults()
        )

        let enabled = await manager.enableICloudCredentialSync()
        #expect(enabled == false)
        #expect(manager.discoveredSyncedAccount?.email == "z@example.com")
        #expect(manager.apiClient() == nil)

        let confirmed = await manager.confirmDiscoveredSyncedAccount()
        #expect(confirmed)
        guard case .connected(let snapshot) = manager.state else {
            Issue.record("Expected confirmed synced account to connect")
            return
        }
        #expect(snapshot.togglUserID == 1)
        #expect(manager.usesICloudCredential)
        #expect(manager.apiClient() != nil)
    }

    @Test func foregroundRejectsSyncedTokenFromDifferentAccount() async {
        let defaults = freshDefaults()
        defaults.set(true, forKey: "momenta.iCloud.credentialEnabled")
        let snapshot = AccountSnapshot(
            togglUserID: 1,
            fullname: "Z",
            email: "z@example.com",
            workspaces: [],
            connectedAt: Date()
        )
        defaults.set(try! JSONEncoder().encode(snapshot), forKey: "toggl.accountSnapshot")
        let otherMe = Data(#"{"id":2,"fullname":"Other","email":"other@example.com"}"#.utf8)
        let manager = AccountManager(
            tokenStore: InMemoryTokenStore(syncedToken: "replaced"),
            transport: SequenceTransport([.success((otherMe, 200))]),
            defaults: defaults
        )

        #expect(manager.apiClient() == nil)
        await manager.validateICloudCredentialForForeground()
        #expect(manager.apiClient() == nil)
        #expect(manager.credentialAttention == .accountMismatch(
            expectedEmail: "z@example.com",
            foundEmail: "other@example.com"
        ))
    }

    @Test func stoppingICloudOnThisMacKeepsSyncedItemAndCopiesLocalToken() throws {
        let store = InMemoryTokenStore(syncedToken: "remote")
        let defaults = freshDefaults()
        defaults.set(true, forKey: "momenta.iCloud.credentialEnabled")
        let snapshot = AccountSnapshot(
            togglUserID: 1,
            fullname: "Z",
            email: "z@example.com",
            workspaces: [],
            connectedAt: Date()
        )
        defaults.set(try JSONEncoder().encode(snapshot), forKey: "toggl.accountSnapshot")
        let manager = AccountManager(
            tokenStore: store,
            transport: SequenceTransport([]),
            defaults: defaults
        )

        try manager.stopUsingICloudCredentialOnThisMac()

        #expect(manager.usesICloudCredential == false)
        #expect(store.localToken == "remote")
        #expect(store.syncedToken == "remote")
        #expect(manager.apiClient() != nil)
    }

    @Test func localDisconnectDoesNotDeleteDiscoveredSyncedCredential() {
        let store = InMemoryTokenStore(token: "local", syncedToken: "remote")
        let defaults = freshDefaults()
        let snapshot = AccountSnapshot(
            togglUserID: 1,
            fullname: "Z",
            email: "z@example.com",
            workspaces: [],
            connectedAt: Date()
        )
        defaults.set(try! JSONEncoder().encode(snapshot), forKey: "toggl.accountSnapshot")
        let manager = AccountManager(
            tokenStore: store,
            transport: SequenceTransport([]),
            defaults: defaults
        )

        manager.disconnect()

        #expect(store.localToken == nil)
        #expect(store.syncedToken == "remote")
    }
}

struct KeychainTokenStoreTests {
    @Test func keychainErrorsHaveReadableDescriptions() {
        let error = KeychainError(status: errSecMissingEntitlement)

        #expect(error.localizedDescription == "This build of Momenta isn’t entitled to use iCloud Keychain.")
        #expect(!error.localizedDescription.contains("Momenta.KeychainError"))
    }

    /// Round-trips against the real Keychain with a test-specific service so
    /// it never collides with the app's production item.
    @Test func saveLoadOverwriteDelete() throws {
        let store = KeychainTokenStore(
            service: "com.zhibangjiang.Momenta.tests",
            account: "roundtrip-\(UUID().uuidString)"
        )
        defer { try? store.delete() }

        #expect(try store.load() == nil)
        try store.save("first-token")
        #expect(try store.load() == "first-token")
        try store.save("second-token")
        #expect(try store.load() == "second-token")
        try store.delete()
        #expect(try store.load() == nil)
        // Deleting a missing item is not an error.
        try store.delete()
    }

}
