import Foundation

/// Kimi Code API key: Keychain (`kimi.apiKey`) or `KIMI_CODE_API_KEY` env fallback.
public func makeKimiAuthStore() -> APIKeyAuthStore {
    APIKeyAuthStore(provider: .kimi, envVars: ["KIMI_CODE_API_KEY"])
}
