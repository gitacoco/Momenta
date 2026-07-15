import Foundation
import Testing
@testable import Momenta

final class InMemoryTokenStore: TokenStore, @unchecked Sendable {
    private(set) var token: String?

    init(token: String? = nil) {
        self.token = token
    }

    func save(_ token: String) throws { self.token = token }
    func load() throws -> String? { token }
    func delete() throws { token = nil }
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
}

struct KeychainTokenStoreTests {
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
