import Foundation

/// OpenAI Admin API key: Keychain (`openai.apiKey`) or `OPENAI_ADMIN_KEY`/`OPENAI_API_KEY` env
/// fallback. The Usage API requires an Admin key (`sk-admin-...`); a regular project key gets a
/// 403, surfaced by the provider as `.notConfigured` with guidance.
public func makeOpenAIAuthStore() -> APIKeyAuthStore {
    APIKeyAuthStore(provider: .openai, envVars: ["OPENAI_ADMIN_KEY", "OPENAI_API_KEY"])
}
