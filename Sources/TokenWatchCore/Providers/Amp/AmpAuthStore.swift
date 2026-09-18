import Foundation

/// Amp access token: Keychain (`amp.apiKey`) or `AMP_API_KEY` env fallback. Used only for the
/// `ampcode.com` API fallback; the primary path is the `amp` CLI when installed.
public func makeAmpAuthStore() -> APIKeyAuthStore {
    APIKeyAuthStore(provider: .amp, envVars: ["AMP_API_KEY"])
}
