import CloudKit
import Foundation

struct CloudConfigRecord: Equatable, Sendable {
    var schemaVersion: Int
    var payloadData: Data
    /// Device-local archive of CKRecord ID/change-tag metadata.
    var systemFields: Data
}

struct CloudLogoRecord: Equatable, Sendable {
    var revision: String
    var bytes: Data
}

enum CloudSyncDatabaseError: Error, LocalizedError, Sendable {
    case conflict(server: CloudConfigRecord)
    case malformedRecord
    case cloud(String)

    var errorDescription: String? {
        switch self {
        case .conflict:
            return "The iCloud configuration changed on another Mac."
        case .malformedRecord:
            return "The iCloud configuration could not be decoded."
        case .cloud(let message):
            return message
        }
    }
}

protocol CloudSyncDatabase: Sendable {
    func accountStatus() async throws -> CKAccountStatus
    func fetchConfig(togglUserID: Int) async throws -> CloudConfigRecord?
    func saveConfig(
        togglUserID: Int,
        schemaVersion: Int,
        payloadData: Data,
        systemFields: Data?
    ) async throws -> CloudConfigRecord
    func fetchLogo(togglUserID: Int, clientID: Int, revision: String) async throws -> CloudLogoRecord?
    func saveLogo(
        togglUserID: Int,
        clientID: Int,
        revision: String,
        fileURL: URL
    ) async throws
    func deleteLogo(togglUserID: Int, clientID: Int, revision: String) async throws
}

/// Small private-database adapter for the two known record types. It uses the
/// default zone and explicit `ifServerRecordUnchanged` saves; no CKSyncEngine,
/// custom zone, subscription, or operation queue is involved.
final class CloudKitSyncDatabase: CloudSyncDatabase, @unchecked Sendable {
    static let containerIdentifier = "iCloud.com.zhibangjiang.Momenta"

    private enum RecordType {
        static let config = "MomentaConfig"
        static let logo = "MomentaLogo"
    }

    private enum Field {
        static let schemaVersion = "schemaVersion"
        static let payload = "payload"
        static let revision = "revision"
        static let asset = "asset"
    }

    private let suppliedContainer: CKContainer?
    private lazy var container = suppliedContainer
        ?? CKContainer(identifier: Self.containerIdentifier)
    private lazy var database = container.privateCloudDatabase

    init(container: CKContainer? = nil) {
        suppliedContainer = container
    }

    func accountStatus() async throws -> CKAccountStatus {
        try await container.accountStatus()
    }

    func fetchConfig(togglUserID: Int) async throws -> CloudConfigRecord? {
        let id = configRecordID(togglUserID)
        guard let record = try await fetchRecord(id) else { return nil }
        return try Self.configRecord(from: record)
    }

    func saveConfig(
        togglUserID: Int,
        schemaVersion: Int,
        payloadData: Data,
        systemFields: Data?
    ) async throws -> CloudConfigRecord {
        let id = configRecordID(togglUserID)
        let record: CKRecord
        if let systemFields {
            record = try Self.record(fromSystemFields: systemFields)
            guard record.recordID == id else { throw CloudSyncDatabaseError.malformedRecord }
        } else {
            record = CKRecord(recordType: RecordType.config, recordID: id)
        }
        record[Field.schemaVersion] = NSNumber(value: schemaVersion)
        record[Field.payload] = payloadData as NSData

        do {
            let result = try await database.modifyRecords(
                saving: [record],
                deleting: [],
                savePolicy: .ifServerRecordUnchanged,
                atomically: false
            )
            guard let savedResult = result.saveResults[id] else {
                throw CloudSyncDatabaseError.cloud("CloudKit returned no config save result.")
            }
            let saved = try savedResult.get()
            return try Self.configRecord(from: saved)
        } catch {
            throw try Self.mapSaveError(error)
        }
    }

    func fetchLogo(togglUserID: Int, clientID: Int, revision: String) async throws -> CloudLogoRecord? {
        guard let record = try await fetchRecord(logoRecordID(togglUserID, clientID, revision)) else {
            return nil
        }
        guard let revision = record[Field.revision] as? String,
              let asset = record[Field.asset] as? CKAsset,
              let fileURL = asset.fileURL
        else { throw CloudSyncDatabaseError.malformedRecord }
        return CloudLogoRecord(revision: revision, bytes: try Data(contentsOf: fileURL))
    }

    func saveLogo(
        togglUserID: Int,
        clientID: Int,
        revision: String,
        fileURL: URL
    ) async throws {
        let id = logoRecordID(togglUserID, clientID, revision)
        let record = try await fetchRecord(id) ?? CKRecord(recordType: RecordType.logo, recordID: id)
        record[Field.revision] = revision as NSString
        record[Field.asset] = CKAsset(fileURL: fileURL)
        do {
            let result = try await database.modifyRecords(
                saving: [record],
                deleting: [],
                savePolicy: .ifServerRecordUnchanged,
                atomically: false
            )
            guard let save = result.saveResults[id] else {
                throw CloudSyncDatabaseError.cloud("CloudKit returned no Logo save result.")
            }
            _ = try save.get()
        } catch {
            throw Self.mapGenericError(error)
        }
    }

    func deleteLogo(togglUserID: Int, clientID: Int, revision: String) async throws {
        let id = logoRecordID(togglUserID, clientID, revision)
        do {
            let result = try await database.modifyRecords(
                saving: [],
                deleting: [id],
                savePolicy: .ifServerRecordUnchanged,
                atomically: false
            )
            guard let deletion = result.deleteResults[id] else { return }
            _ = try deletion.get()
        } catch let error as CKError where error.code == .unknownItem {
            return
        } catch {
            throw Self.mapGenericError(error)
        }
    }

    private func fetchRecord(_ id: CKRecord.ID) async throws -> CKRecord? {
        do {
            let results = try await database.records(for: [id])
            guard let result = results[id] else { return nil }
            do {
                return try result.get()
            } catch let error as CKError where error.code == .unknownItem {
                return nil
            }
        } catch let error as CKError where error.code == .unknownItem {
            return nil
        } catch {
            throw Self.mapGenericError(error)
        }
    }

    private func configRecordID(_ togglUserID: Int) -> CKRecord.ID {
        CKRecord.ID(recordName: "momenta-config-\(togglUserID)")
    }

    private func logoRecordID(_ togglUserID: Int, _ clientID: Int, _ revision: String) -> CKRecord.ID {
        CKRecord.ID(recordName: "momenta-logo-\(togglUserID)-\(clientID)-\(revision)")
    }

    private static func configRecord(from record: CKRecord) throws -> CloudConfigRecord {
        guard let version = record[Field.schemaVersion] as? NSNumber,
              let data = record[Field.payload] as? Data
        else { throw CloudSyncDatabaseError.malformedRecord }
        return CloudConfigRecord(
            schemaVersion: version.intValue,
            payloadData: data,
            systemFields: systemFields(from: record)
        )
    }

    private static func systemFields(from record: CKRecord) -> Data {
        let archiver = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: archiver)
        archiver.finishEncoding()
        return archiver.encodedData
    }

    private static func record(fromSystemFields data: Data) throws -> CKRecord {
        let unarchiver = try NSKeyedUnarchiver(forReadingFrom: data)
        unarchiver.requiresSecureCoding = true
        defer { unarchiver.finishDecoding() }
        guard let record = CKRecord(coder: unarchiver) else {
            throw CloudSyncDatabaseError.malformedRecord
        }
        return record
    }

    private static func mapSaveError(_ error: Error) throws -> Error {
        if let ckError = error as? CKError,
           ckError.code == .serverRecordChanged,
           let server = ckError.userInfo[CKRecordChangedErrorServerRecordKey] as? CKRecord {
            return CloudSyncDatabaseError.conflict(server: try configRecord(from: server))
        }
        return mapGenericError(error)
    }

    private static func mapGenericError(_ error: Error) -> Error {
        if let error = error as? CloudSyncDatabaseError { return error }
        if let error = error as? CKError {
            return CloudSyncDatabaseError.cloud(error.localizedDescription)
        }
        return CloudSyncDatabaseError.cloud(error.localizedDescription)
    }
}
