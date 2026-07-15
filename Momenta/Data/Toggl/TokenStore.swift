import Foundation
import Security

/// Storage for the Toggl API token. The only production conformer is the
/// Keychain; nothing else may ever hold the token at rest.
protocol TokenStore: Sendable {
    func save(_ token: String) throws
    func load() throws -> String?
    func delete() throws
}

struct KeychainError: Error, Equatable {
    var status: OSStatus
}

/// Generic-password Keychain storage. The token never touches UserDefaults,
/// files, or logs.
struct KeychainTokenStore: TokenStore {
    var service: String = "com.zhibangjiang.Momenta"
    var account: String = "toggl-api-token"

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    func save(_ token: String) throws {
        let data = Data(token.utf8)
        let update = [kSecValueData as String: data]
        let status = SecItemUpdate(baseQuery as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = baseQuery
            add[kSecValueData as String] = data
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainError(status: addStatus) }
        } else {
            guard status == errSecSuccess else { throw KeychainError(status: status) }
        }
    }

    func load() throws -> String? {
        var query = baseQuery
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
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError(status: status)
        }
    }
}
