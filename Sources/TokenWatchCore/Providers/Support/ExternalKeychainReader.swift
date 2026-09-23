import Foundation
#if canImport(Security)
import Security
#endif

/// Reads a generic-password Keychain item TokenWatch itself did not create (e.g. the Claude CLI's
/// `Claude Code-credentials` item). Read-only -- TokenWatch never writes to another app's Keychain
/// item or service.
///
/// macOS asks "TokenWatch wants to use your confidential information" the first time TokenWatch
/// reads such an item itself, because the item's access list trusts only the apps that wrote or
/// were allowed to read it. An item written with Apple's `security` command-line tool (as Claude
/// Code writes its sign-in) trusts that tool, though -- so when the access list says so,
/// `readStringSilently` reads it through `/usr/bin/security` instead, and there's no prompt.
public enum ExternalKeychainReader {
    private static let securityTool = "/usr/bin/security"

    /// The item's value, read through the `security` tool when the item's access list already
    /// trusts it (no prompt), else read directly -- which is where macOS may ask for approval the
    /// first time. `nil` if there's no such item or it can't be read.
    public static func readStringSilently(service: String) async -> String? {
        if trustsSecurityTool(service: service),
           let result = await BoundedSubprocess.run(executablePath: securityTool, arguments: ["find-generic-password", "-s", service, "-w"], timeout: 10),
           result.exitCode == 0 {
            let value = String(decoding: result.stdout, as: UTF8.self).trimmingCharacters(in: .newlines)
            if !value.isEmpty { return value }
        }
        return readString(service: service)
    }

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

    /// Whether `/usr/bin/security` can read the item without a prompt: its decrypt entry trusts
    /// the tool (or any app), and its partition list -- when it has one -- admits Apple's command-
    /// line tools (`apple-tool:`). Only the item's access list is inspected, never its secret, so
    /// this itself never prompts. Uses the file-based keychain's ACL API, the only way to read an
    /// item's access list; deprecated, but it's what the login keychain still uses.
    public static func trustsSecurityTool(service: String) -> Bool {
        var item: SecKeychainItem?
        guard SecKeychainFindGenericPassword(nil, UInt32(service.utf8.count), service, 0, nil, nil, nil, &item) == errSecSuccess,
              let item
        else { return false }
        var access: SecAccess?
        var list: CFArray?
        guard SecKeychainItemCopyAccess(item, &access) == errSecSuccess, let access,
              SecAccessCopyACLList(access, &list) == errSecSuccess, let acls = list as? [SecACL]
        else { return false }

        var decryptTrusted = false
        var partitionsAllowTool = true
        for acl in acls {
            let authorizations = SecACLCopyAuthorizations(acl) as? [String] ?? []
            var applications: CFArray?
            var description: CFString?
            var prompt = SecKeychainPromptSelector()
            guard SecACLCopyContents(acl, &applications, &description, &prompt) == errSecSuccess else { continue }
            if authorizations.contains(kSecACLAuthorizationDecrypt as String) {
                // A nil application list means any application may decrypt.
                decryptTrusted = decryptTrusted || applications.map { applicationPaths($0).contains(securityTool) } ?? true
            }
            if authorizations.contains(kSecACLAuthorizationPartitionID as String) {
                partitionsAllowTool = partitions(fromHexPlist: description as String?)?.contains("apple-tool:") ?? false
            }
        }
        return decryptTrusted && partitionsAllowTool
    }

    private static func applicationPaths(_ applications: CFArray) -> [String] {
        (applications as? [SecTrustedApplication] ?? []).compactMap { application in
            var data: CFData?
            guard SecTrustedApplicationCopyData(application, &data) == errSecSuccess, let bytes = data as Data? else { return nil }
            return String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    /// The partition ACL entry's description is a hex-encoded XML plist: `{Partitions: [...]}`.
    static func partitions(fromHexPlist hex: String?) -> [String]? {
        guard let hex, hex.count.isMultiple(of: 2) else { return nil }
        var bytes = Data(capacity: hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        let plist = try? PropertyListSerialization.propertyList(from: bytes, format: nil)
        return (plist as? [String: Any])?["Partitions"] as? [String]
    }
}
