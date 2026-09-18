import Foundation

/// `~/.codex/auth.json` (or `$CODEX_HOME/auth.json`) shape, as written by the Codex CLI.
struct CodexAuthFile: Decodable {
    struct Tokens: Decodable {
        let accessToken: String?
        enum CodingKeys: String, CodingKey { case accessToken = "access_token" }
    }
    let tokens: Tokens?
}

/// Reads the Codex CLI's OAuth access token from `$CODEX_HOME/auth.json` (default `~/.codex`).
/// TokenWatch never writes to this file -- Codex CLI owns and refreshes it.
public struct CodexAuthStore: Sendable {
    private let path: String

    public init(homeDirectory: String = NSHomeDirectory(), environment: [String: String] = ProcessInfo.processInfo.environment) {
        if let codexHome = environment["CODEX_HOME"], !codexHome.isEmpty {
            self.path = codexHome + "/auth.json"
        } else {
            self.path = homeDirectory + "/.codex/auth.json"
        }
    }

    public func accessToken() -> String? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        guard let file = try? JSONDecoder().decode(CodexAuthFile.self, from: data) else { return nil }
        return file.tokens?.accessToken
    }

    public func hasAuthFile() -> Bool {
        FileManager.default.fileExists(atPath: path)
    }
}
