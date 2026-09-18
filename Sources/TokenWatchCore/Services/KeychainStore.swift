import Foundation
#if canImport(Security)
import Security
#endif

/// Thin wrapper over the `Security` framework keychain APIs. Every credential TokenWatch itself
/// originates (API keys, cached cookies) lives under one service name with an
/// account of the form "<providerID>.<keyName>". TokenWatch never copies OAuth tokens or session
/// files another app already persists on disk -- those are read live from their own storage.
public struct KeychainStore: Sendable {
    public static let serviceName = "dev.tokenwatch.credentials"
    /// Service used for cached derived cookies/sessions (`CursorAuthStore`'s Safari-cookie
    /// fallback), kept distinct from the primary credentials service.
    public static let cookieCacheServiceName = "dev.tokenwatch.cookiecache"

    private let service: String

    public init(service: String = KeychainStore.serviceName) {
        self.service = service
    }

    public func set(account: String, value: String) throws {
        guard let data = value.data(using: .utf8) else {
            throw KeychainError.encoding
        }
        var query = baseQuery(account: account)
        SecItemDelete(query as CFDictionary)
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.osStatus(status)
        }
    }

    public func get(account: String) -> String? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    public func delete(account: String) throws -> Bool {
        let query = baseQuery(account: account)
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.osStatus(status)
        }
        return status == errSecSuccess
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}

public enum KeychainError: Error, Sendable {
    case encoding
    case osStatus(OSStatus)
}
