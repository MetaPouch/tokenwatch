import Foundation

/// OpenRouter API key: Keychain (`openrouter.apiKey`) or `OPENROUTER_API_KEY` env fallback.
public func makeOpenRouterAuthStore() -> APIKeyAuthStore {
    APIKeyAuthStore(provider: .openrouter, envVars: ["OPENROUTER_API_KEY"])
}
