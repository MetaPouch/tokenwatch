import Foundation

/// Claude OAuth credential shape written by the Claude CLI, shared by the Keychain item and the
/// `~/.claude/.credentials.json` file fallback: `{"claudeAiOauth": {"accessToken": "..."}}`.
struct ClaudeCredentialsFile: Decodable {
    struct OAuth: Decodable {
        let accessToken: String
    }
    let claudeAiOauth: OAuth
}

/// Resolves a Claude Code OAuth access token: Keychain item `Claude Code-credentials` (written
/// by the `claude` CLI) first, then `~/.claude/.credentials.json`.
public struct ClaudeAuthStore: Sendable {
    private static let keychainService = "Claude Code-credentials"

    public init() {}

    public func accessToken() -> String? {
        if let fromKeychain = Self.parse(ExternalKeychainReader.readString(service: Self.keychainService)) {
            return fromKeychain
        }
        let path = NSHomeDirectory() + "/.claude/.credentials.json"
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return Self.parse(String(data: data, encoding: .utf8))
    }

    private static func parse(_ json: String?) -> String? {
        guard let json, let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(ClaudeCredentialsFile.self, from: data).claudeAiOauth.accessToken
    }
}
