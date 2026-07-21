import Foundation
import Security

/// Storage for the Toggl API token. The only production conformer is the
/// Keychain; nothing else may ever hold the token at rest.
protocol TokenStore: Sendable {
    func save(_ token: String) throws
    func load() throws -> String?
    func delete() throws
}

/// Exact Keychain item selection. `kSecAttrSynchronizable` participates in
/// item identity, so migration code must never use one ambiguous query for
/// local and iCloud-backed credentials.
enum TokenItemScope: Sendable {
    case local
    case synchronizable
    /// Discovery/delete query only. Keychain does not allow adding an item
    /// with `kSecAttrSynchronizableAny`.
    case any
}

/// Extra operations available from the production Keychain store. Keeping
/// these separate from `TokenStore` preserves the small injectable protocol
/// used by account tests and non-Keychain test doubles.
protocol SynchronizableTokenStore: TokenStore {
    func save(_ token: String, scope: TokenItemScope) throws
    func load(scope: TokenItemScope) throws -> String?
    func delete(scope: TokenItemScope) throws
}

struct KeychainError: Error, Equatable {
    var status: OSStatus
}

/// Generic-password Keychain storage. The token never touches UserDefaults,
/// files, or logs.
struct KeychainTokenStore: SynchronizableTokenStore {
    var service: String = "com.zhibangjiang.Momenta"
    var account: String = "toggl-api-token"

    private func baseQuery(scope: TokenItemScope) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        switch scope {
        case .local:
            query[kSecAttrSynchronizable as String] = kCFBooleanFalse
        case .synchronizable:
            query[kSecAttrSynchronizable as String] = kCFBooleanTrue
        case .any:
            query[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny
        }
        return query
    }

    func save(_ token: String) throws {
        try save(token, scope: .local)
    }

    func save(_ token: String, scope: TokenItemScope) throws {
        guard scope != .any else { throw KeychainError(status: errSecParam) }
        let data = Data(token.utf8)
        let update = [kSecValueData as String: data]
        let query = baseQuery(scope: scope)
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainError(status: addStatus) }
        } else {
            guard status == errSecSuccess else { throw KeychainError(status: status) }
        }
    }

    func load() throws -> String? {
        try load(scope: .local)
    }

    func load(scope: TokenItemScope) throws -> String? {
        var query = baseQuery(scope: scope)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { return nil }
            return String(decoding: data, as: UTF8.self)
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError(status: status)
        }
    }

    func delete() throws {
        try delete(scope: .local)
    }

    func delete(scope: TokenItemScope) throws {
        let status = SecItemDelete(baseQuery(scope: scope) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError(status: status)
        }
    }
}
