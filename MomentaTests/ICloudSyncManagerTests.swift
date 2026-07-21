import CloudKit
import Foundation
import Testing
@testable import Momenta

final class FakeCloudSyncDatabase: CloudSyncDatabase, @unchecked Sendable {
    var status: CKAccountStatus = .available
    var configRecord: CloudConfigRecord?
    private(set) var configSaveCount = 0
    private(set) var logoSaveCount = 0
    private(set) var logoFetchCount = 0
    private(set) var events: [String] = []
    var logoFetchResponses: [CloudLogoRecord?] = []
    var beforeSaveReturns: (@MainActor @Sendable () -> Void)?

    func accountStatus() async throws -> CKAccountStatus { status }

    func fetchConfig(togglUserID: Int) async throws -> CloudConfigRecord? {
        configRecord
    }

    func saveConfig(
        togglUserID: Int,
        schemaVersion: Int,
        payloadData: Data,
        systemFields: Data?
    ) async throws -> CloudConfigRecord {
        configSaveCount += 1
        events.append("config")
        let saved = CloudConfigRecord(
            schemaVersion: schemaVersion,
            payloadData: payloadData,
            systemFields: Data([UInt8(configSaveCount)])
        )
        configRecord = saved
        await beforeSaveReturns?()
        return saved
    }

    func fetchLogo(
        togglUserID: Int,
        clientID: Int,
        revision: String
    ) async throws -> CloudLogoRecord? {
        logoFetchCount += 1
        guard !logoFetchResponses.isEmpty else { return nil }
        return logoFetchResponses.removeFirst()
    }

    func saveLogo(
        togglUserID: Int,
        clientID: Int,
        revision: String,
        fileURL: URL
    ) async throws {
        logoSaveCount += 1
        events.append("logo:\(clientID):\(revision)")
    }

    func deleteLogo(togglUserID: Int, clientID: Int, revision: String) async throws {}
}

@MainActor
struct ICloudSyncManagerTests {
    private static let meJSON = Data(#"{"id":1,"fullname":"Z","email":"z@example.com"}"#.utf8)

    private func freshDefaults() -> UserDefaults {
        let suite = "MomentaTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private func connectedAccount(defaults: UserDefaults) -> AccountManager {
        defaults.set(true, forKey: "momenta.iCloud.credentialEnabled")
        let snapshot = AccountSnapshot(
            togglUserID: 1,
            fullname: "Z",
            email: "z@example.com",
            workspaces: [],
            connectedAt: Date()
        )
        defaults.set(try! JSONEncoder().encode(snapshot), forKey: "toggl.accountSnapshot")
        return AccountManager(
            tokenStore: InMemoryTokenStore(syncedToken: "tok"),
            transport: SequenceTransport([.success((Self.meJSON, 200))]),
            defaults: defaults
        )
    }

    private func syncedClient(_ id: Int, color: String = "#111111") -> SyncedClientConfig {
        SyncedClientConfig(
            clientID: id,
            displayNameOverride: nil,
            colorHex: color,
            isEnabled: true,
            pacing: .weekdays,
            goalHistory: [:],
            currencyCode: "USD",
            logoRevision: nil
        )
    }

    private func cloudRecord(_ payload: SyncedConfigPayload, version: Int = 1) -> CloudConfigRecord {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return CloudConfigRecord(
            schemaVersion: version,
            payloadData: try! encoder.encode(payload),
            systemFields: Data([9])
        )
    }

    @Test func higherServerSchemaStopsUploadAndRequestsUpdate() async {
        let defaults = freshDefaults()
        let database = FakeCloudSyncDatabase()
        database.configRecord = cloudRecord(.empty, version: 2)
        let manager = ICloudSyncManager(
            account: connectedAccount(defaults: defaults),
            config: ConfigStore(defaults: defaults),
            database: database,
            defaults: defaults
        )

        await manager.handleForeground()

        guard case .needsAttention(let message) = manager.state else {
            Issue.record("Expected unsupported schema to need attention")
            return
        }
        #expect(message.contains("Update Momenta"))
        #expect(database.configSaveCount == 0)
        let preserved = ConfigSyncStateStore(defaults: defaults).load(togglUserID: 1)
        #expect(preserved.unsupportedRemoteSchemaVersion == 2)
        #expect(preserved.unsupportedRemotePayloadData == database.configRecord?.payloadData)
        #expect(preserved.unsupportedRemoteSystemFields == database.configRecord?.systemFields)
    }

    @Test func previouslySyncedMissingBaseFailsClosed() async {
        let defaults = freshDefaults()
        let database = FakeCloudSyncDatabase()
        let payload = SyncedConfigPayload(clients: [7: syncedClient(7)], order: [7])
        database.configRecord = cloudRecord(payload)
        ConfigSyncStateStore(defaults: defaults).save(
            ConfigSyncLocalState(
                shadow: payload,
                base: nil,
                recordSystemFields: nil,
                hasCompletedSync: true,
                isDirty: true,
                installedLogoRevisions: [:]
            ),
            togglUserID: 1
        )
        let manager = ICloudSyncManager(
            account: connectedAccount(defaults: defaults),
            config: ConfigStore(defaults: defaults),
            database: database,
            defaults: defaults
        )

        await manager.handleForeground()

        guard case .needsAttention(let message) = manager.state else {
            Issue.record("Expected missing base to fail closed")
            return
        }
        #expect(message.contains("base is missing or damaged"))
        #expect(database.configSaveCount == 0)
    }

    @Test func twoHistoricalConfigsRequireInitialMergeConfirmation() async {
        let defaults = freshDefaults()
        let config = ConfigStore(defaults: defaults)
        config.merge(
            workspaces: [TogglWorkspace(id: 10, name: "Studio")],
            togglClients: [TogglClientDTO(id: 7, wid: 10, name: "Local", archived: false)]
        )
        var local = config.clients[0]
        local.isEnabled = true
        local.colorHex = "#00FF00"
        config.update(local)

        let database = FakeCloudSyncDatabase()
        let remote = SyncedConfigPayload(clients: [7: syncedClient(7, color: "#FF0000")], order: [7])
        database.configRecord = cloudRecord(remote)
        let manager = ICloudSyncManager(
            account: connectedAccount(defaults: defaults),
            config: config,
            database: database,
            defaults: defaults
        )

        await manager.handleForeground()

        #expect(manager.state == .waitingForInitialMerge)
        #expect(database.configSaveCount == 0)
    }

    @Test func cleanTogglClientsAdoptRemoteWithoutInitialMergeConfirmation() async {
        let defaults = freshDefaults()
        let config = ConfigStore(defaults: defaults)
        config.merge(
            workspaces: [TogglWorkspace(id: 10, name: "Studio")],
            togglClients: [TogglClientDTO(id: 7, wid: 10, name: "Client", archived: false)]
        )
        #expect(config.clients[0].isEnabled == false)
        #expect(config.clients[0].goalHistory.isEmpty)

        let database = FakeCloudSyncDatabase()
        let remote = SyncedConfigPayload(
            clients: [7: syncedClient(7, color: "#FF0000")],
            order: [7]
        )
        database.configRecord = cloudRecord(remote)
        let manager = ICloudSyncManager(
            account: connectedAccount(defaults: defaults),
            config: config,
            database: database,
            defaults: defaults
        )

        await manager.handleForeground()

        #expect(manager.state == .synced)
        #expect(config.client(id: 7)?.isEnabled == true)
        #expect(config.client(id: 7)?.colorHex == "#FF0000")
        #expect(database.configSaveCount == 0)
    }

    @Test func reorderBeforeEnablingSyncIsRememberedAsUserAuthored() {
        let defaults = freshDefaults()
        let snapshot = AccountSnapshot(
            togglUserID: 1,
            fullname: "Z",
            email: "z@example.com",
            workspaces: [],
            connectedAt: Date()
        )
        defaults.set(try! JSONEncoder().encode(snapshot), forKey: "toggl.accountSnapshot")
        let account = AccountManager(
            tokenStore: InMemoryTokenStore(token: "tok"),
            transport: SequenceTransport([]),
            defaults: defaults
        )
        let config = ConfigStore(defaults: defaults)
        config.merge(
            workspaces: [TogglWorkspace(id: 10, name: "Studio")],
            togglClients: [
                TogglClientDTO(id: 7, wid: 10, name: "A", archived: false),
                TogglClientDTO(id: 8, wid: 10, name: "B", archived: false),
            ]
        )
        let database = FakeCloudSyncDatabase()
        let manager = ICloudSyncManager(
            account: account,
            config: config,
            database: database,
            defaults: defaults
        )

        withExtendedLifetime(manager) {
            config.move(ids: [7, 8], fromOffsets: IndexSet(integer: 0), toOffset: 2)
        }

        let local = ConfigSyncStateStore(defaults: defaults).load(togglUserID: 1)
        #expect(local.shadow.order == [8, 7])
        #expect(local.shadow.userAuthoredOrder == true)
        #expect(local.shadow.hasUserSettings)
        #expect(database.configSaveCount == 0)
    }

    @Test func stoppingSyncPreventsOldShadowFromReprojecting() throws {
        let defaults = freshDefaults()
        let config = ConfigStore(defaults: defaults)
        config.merge(
            workspaces: [TogglWorkspace(id: 10, name: "Studio")],
            togglClients: [TogglClientDTO(id: 7, wid: 10, name: "Client", archived: false)]
        )
        var localClient = config.clients[0]
        localClient.colorHex = "#00FF00"
        config.update(localClient)
        let staleShadow = SyncedConfigPayload(
            clients: [7: syncedClient(7, color: "#FF0000")],
            order: [7]
        )
        ConfigSyncStateStore(defaults: defaults).save(
            ConfigSyncLocalState(
                shadow: staleShadow,
                base: staleShadow,
                recordSystemFields: Data([1]),
                hasCompletedSync: true,
                isDirty: false,
                installedLogoRevisions: [:]
            ),
            togglUserID: 1
        )
        let manager = ICloudSyncManager(
            account: connectedAccount(defaults: defaults),
            config: config,
            database: FakeCloudSyncDatabase(),
            defaults: defaults
        )

        manager.stopUsingOnThisMac()
        config.merge(
            workspaces: [TogglWorkspace(id: 10, name: "Studio")],
            togglClients: [TogglClientDTO(id: 7, wid: 10, name: "Renamed", archived: false)]
        )

        #expect(config.client(id: 7)?.colorHex == "#00FF00")
    }

    @Test func editDuringSaveIsRebasedAndQueuedForNextUpload() async {
        let defaults = freshDefaults()
        let config = ConfigStore(defaults: defaults)
        config.merge(
            workspaces: [TogglWorkspace(id: 10, name: "Studio")],
            togglClients: [TogglClientDTO(id: 7, wid: 10, name: "Client", archived: false)]
        )
        var initial = config.clients[0]
        initial.colorHex = "#00FF00"
        config.update(initial)

        let database = FakeCloudSyncDatabase()
        let manager = ICloudSyncManager(
            account: connectedAccount(defaults: defaults),
            config: config,
            database: database,
            defaults: defaults
        )
        database.beforeSaveReturns = {
            var newest = config.clients[0]
            newest.colorHex = "#0000FF"
            config.update(newest)
            database.beforeSaveReturns = nil
        }

        await manager.handleForeground()

        let local = ConfigSyncStateStore(defaults: defaults).load(togglUserID: 1)
        #expect(local.base?.clients[7]?.colorHex == "#00FF00")
        #expect(local.shadow.clients[7]?.colorHex == "#0000FF")
        #expect(local.isDirty)
        #expect(config.client(id: 7)?.colorHex == "#0000FF")
        #expect(database.configSaveCount == 1)
    }

    @Test func unvalidatedSyncedCredentialNeverFallsBackToDemoData() async {
        let defaults = freshDefaults()
        let account = connectedAccount(defaults: defaults)
        let cacheURL = FileManager.default.temporaryDirectory
            .appending(path: "MomentaTests-\(UUID().uuidString)-snapshots.json")
        defer { try? FileManager.default.removeItem(at: cacheURL) }
        let app = AppState(
            provider: MockDataProvider(),
            account: account,
            config: ConfigStore(defaults: defaults),
            snapshotCache: SnapshotCache(fileURL: cacheURL),
            defaults: defaults,
            autoRefresh: false
        )

        #expect(account.isConnected)
        #expect(account.apiClient() == nil)
        await app.refresh(force: true)

        #expect(app.snapshots.isEmpty)
        #expect(account.lastSyncAt == nil)
        #expect(FileManager.default.fileExists(atPath: cacheURL.path) == false)
    }

    @Test func logoAssetUploadsBeforeConfigReferencesItsRevision() async {
        let defaults = freshDefaults()
        let config = ConfigStore(defaults: defaults)
        config.merge(
            workspaces: [TogglWorkspace(id: 10, name: "Studio")],
            togglClients: [TogglClientDTO(id: 7, wid: 10, name: "Client", archived: false)]
        )
        var client = config.clients[0]
        client.logoFileName = "test-logo.png"
        config.update(client, logoContentChanged: true)
        let database = FakeCloudSyncDatabase()
        let manager = ICloudSyncManager(
            account: connectedAccount(defaults: defaults),
            config: config,
            database: database,
            defaults: defaults
        )

        await manager.handleForeground()

        #expect(database.logoSaveCount == 1)
        #expect(database.configSaveCount == 1)
        #expect(database.events.count == 2)
        #expect(database.events.first?.hasPrefix("logo:7:") == true)
        #expect(database.events.last == "config")
    }

    @Test func delayedLogoIsRetriedOnceWithoutNeedsAttention() async throws {
        let defaults = freshDefaults()
        let clientID = 9_876_543
        let fileName = "client-\(clientID)-icloud"
        defer { LogoStore.deleteLogo(named: fileName) }
        let config = ConfigStore(defaults: defaults)
        config.merge(
            workspaces: [TogglWorkspace(id: 10, name: "Studio")],
            togglClients: [TogglClientDTO(id: clientID, wid: 10, name: "Client", archived: false)]
        )
        var remoteClient = syncedClient(clientID)
        remoteClient.logoRevision = "revision-1"
        let remote = SyncedConfigPayload(clients: [clientID: remoteClient], order: [clientID])
        let database = FakeCloudSyncDatabase()
        database.configRecord = cloudRecord(remote)
        database.logoFetchResponses = [
            nil,
            CloudLogoRecord(revision: "revision-1", bytes: Data([1, 2, 3])),
        ]
        let manager = ICloudSyncManager(
            account: connectedAccount(defaults: defaults),
            config: config,
            database: database,
            defaults: defaults,
            logoRetryDelay: .milliseconds(10)
        )

        await manager.handleForeground()
        try await Task.sleep(for: .milliseconds(100))

        #expect(manager.state == .synced)
        #expect(database.logoFetchCount == 2)
        #expect(config.client(id: clientID)?.logoFileName == fileName)
    }

    @Test func missingLogoDoesNotCreateAnAutomaticRetryLoop() async throws {
        let defaults = freshDefaults()
        let clientID = 9_876_544
        let config = ConfigStore(defaults: defaults)
        config.merge(
            workspaces: [TogglWorkspace(id: 10, name: "Studio")],
            togglClients: [TogglClientDTO(id: clientID, wid: 10, name: "Client", archived: false)]
        )
        var remoteClient = syncedClient(clientID)
        remoteClient.logoRevision = "missing-revision"
        let database = FakeCloudSyncDatabase()
        database.configRecord = cloudRecord(
            SyncedConfigPayload(clients: [clientID: remoteClient], order: [clientID])
        )
        database.logoFetchResponses = [nil, nil]
        let manager = ICloudSyncManager(
            account: connectedAccount(defaults: defaults),
            config: config,
            database: database,
            defaults: defaults,
            logoRetryDelay: .milliseconds(10)
        )

        await manager.handleForeground()
        try await Task.sleep(for: .milliseconds(100))

        #expect(manager.state == .synced)
        #expect(database.logoFetchCount == 2)
        #expect(config.client(id: clientID)?.logoFileName == nil)
    }
}

struct LogoStoreTests {
    @Test func replacingLogoRemovesTheSupersededStorageVariant() throws {
        let clientID = Int.random(in: 10_000_000...99_999_999)
        let source = FileManager.default.temporaryDirectory
            .appending(path: "momenta-logo-\(UUID().uuidString).png")
        try Data([1, 2, 3]).write(to: source)
        defer {
            try? FileManager.default.removeItem(at: source)
            LogoStore.deleteLogo(named: "client-\(clientID).png")
            LogoStore.deleteLogo(named: "client-\(clientID)-icloud")
        }

        let localName = try LogoStore.importLogo(from: source, for: clientID)
        #expect(FileManager.default.fileExists(atPath: LogoStore.url(for: localName).path))

        let syncedName = try LogoStore.installSyncedLogo(Data([4, 5, 6]), for: clientID)
        #expect(!FileManager.default.fileExists(atPath: LogoStore.url(for: localName).path))
        #expect(FileManager.default.fileExists(atPath: LogoStore.url(for: syncedName).path))

        _ = try LogoStore.importLogo(from: source, for: clientID)
        #expect(!FileManager.default.fileExists(atPath: LogoStore.url(for: syncedName).path))
    }
}
