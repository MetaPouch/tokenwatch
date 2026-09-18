import Foundation
#if canImport(Security)
import Security
#endif

/// Reads a generic-password Keychain item TokenWatch itself did not create (e.g. the Claude CLI's
/// `Claude Code-credentials` item). Read-only -- TokenWatch never writes to another app's Keychain
/// item or service.
public enum ExternalKeychainReader {
    /// Returns the UTF-8 string value of the first generic-password item matching `service`,
    /// or `nil` if no such item is readable.
    public static func readString(service: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
