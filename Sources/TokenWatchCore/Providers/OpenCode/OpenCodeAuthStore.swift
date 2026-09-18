import Foundation

/// OpenCode Go API key: Keychain (`opencode.apiKey`) or `OPENCODE_API_KEY` env fallback.
public func makeOpenCodeAuthStore() -> APIKeyAuthStore {
    APIKeyAuthStore(provider: .opencode, envVars: ["OPENCODE_API_KEY"])
}
