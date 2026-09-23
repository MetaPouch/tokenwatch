import Foundation
#if canImport(Security)
import Security
#endif
#if canImport(LocalAuthentication)
import LocalAuthentication
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

    /// Whether an item exists, without reading its value -- see `KeychainPresence`.
    public func contains(account: String) -> Bool {
        KeychainPresence.exists(service: service, account: account)
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

/// Keychain *existence* checks that never raise macOS's "allow access" prompt, even for another
/// app's item: the query asks only for attributes (the prompt guards the secret, not the item's
/// existence) and forbids any authentication UI outright. Verified from an unsigned binary not on
/// the Claude CLI item's access list: it answers found / not-found in milliseconds, no dialog.
public enum KeychainPresence {
    public static func exists(service: String, account: String? = nil) -> Bool {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        if let account { query[kSecAttrAccount as String] = account }
        let context = LAContext()
        context.interactionNotAllowed = true
        query[kSecUseAuthenticationContext as String] = context
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        // Present but locked/needing authentication still means it exists.
        return status == errSecSuccess || status == errSecInteractionNotAllowed
    }
}
