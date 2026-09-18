import Foundation

/// Reads a GitHub Copilot OAuth token already saved on disk by another Copilot client (VS Code,
/// Neovim's copilot.vim, JetBrains, the Copilot CLI). No device-flow login in v1 -- GitHub's
/// device flow needs a registered OAuth client id this app cannot provision; if the user has no
/// other Copilot client installed, `hasLocalCredentials()` returns false.
public struct CopilotAuthStore: Sendable {
    private struct HostEntry: Decodable {
        let oauthToken: String
        enum CodingKeys: String, CodingKey { case oauthToken = "oauth_token" }
    }

    private let homeDirectory: String

    public init(homeDirectory: String = NSHomeDirectory()) {
        self.homeDirectory = homeDirectory
    }

    public func oauthToken() -> String? {
        let candidates = ["/.config/github-copilot/hosts.json", "/.config/github-copilot/apps.json"]
        for relativePath in candidates {
            let url = URL(fileURLWithPath: homeDirectory + relativePath)
            guard let data = try? Data(contentsOf: url) else { continue }
            guard let entries = try? JSONDecoder().decode([String: HostEntry].self, from: data) else { continue }
            if let token = entries.values.first?.oauthToken {
                return token
            }
        }
        return nil
    }
}
