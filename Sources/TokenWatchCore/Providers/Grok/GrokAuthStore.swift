import Foundation

/// `~/.grok/auth.json` shape: top-level keys are OIDC scope URLs, each holding a credential
/// entry. TokenWatch prefers the SuperGrok entry (`https://auth.x.ai::<client-id>`), falling back
/// to the legacy session (`https://accounts.x.ai/sign-in`).
struct GrokAuthEntry: Decodable {
    let key: String?
    let expiresAt: GrokFlexibleDate?

    enum CodingKeys: String, CodingKey {
        case key
        case expiresAt = "expires_at"
    }
}

/// `expires_at` may be an ISO-8601 string or a Unix epoch number depending on Grok CLI version;
/// this decodes either shape.
struct GrokFlexibleDate: Decodable {
    let date: Date?

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self) {
            date = FlexibleISO8601.parse(string)
        } else if let epoch = try? container.decode(Double.self) {
            date = Date(timeIntervalSince1970: epoch)
        } else {
            date = nil
        }
    }
}

public struct GrokAuthStore: Sendable {
    private let path: String

    public init(homeDirectory: String = NSHomeDirectory(), environment: [String: String] = ProcessInfo.processInfo.environment) {
        if let grokHome = environment["GROK_HOME"], !grokHome.isEmpty {
            self.path = grokHome + "/auth.json"
        } else {
            self.path = homeDirectory + "/.grok/auth.json"
        }
    }

    public func hasAuthFile() -> Bool {
        FileManager.default.fileExists(atPath: path)
    }

    /// A non-expired bearer token, preferring the SuperGrok OAuth entry.
    public func validAccessToken() -> String? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        guard let entries = try? JSONDecoder().decode([String: GrokAuthEntry].self, from: data) else { return nil }

        let preferredKey = entries.keys.first { $0.hasPrefix("https://auth.x.ai::") }
            ?? entries.keys.first { $0 == "https://accounts.x.ai/sign-in" }

        guard let key = preferredKey, let entry = entries[key], let token = entry.key, !token.isEmpty else {
            return nil
        }
        if let expiry = entry.expiresAt?.date, expiry <= Date() {
            return nil
        }
        return token
    }
}
