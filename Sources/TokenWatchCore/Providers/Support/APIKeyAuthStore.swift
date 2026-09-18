import Foundation

/// Shared `APIKeyManaging` implementation reused by every provider authenticated with a plain
/// bearer/API key (OpenRouter, z.ai, Kimi, OpenCode Go, OpenAI, Amp). Keychain takes priority
/// over the environment-variable fallback.
public final class APIKeyAuthStore: APIKeyManaging, @unchecked Sendable {
    private let account: String
    private let envVars: [String]
    private let keychain: KeychainStore

    public init(provider: ProviderID, keyName: String = "apiKey", envVars: [String], keychain: KeychainStore = KeychainStore()) {
        self.account = "\(provider.rawValue).\(keyName)"
        self.envVars = envVars
        self.keychain = keychain
    }

    public func keyStatus() -> APIKeyStatus {
        if keychain.get(account: account) != nil {
            return .saved
        }
        if environmentValue() != nil {
            return .fromEnvironment
        }
        return .notSet
    }

    public func currentAPIKey() -> String? {
        keychain.get(account: account) ?? environmentValue()
    }

    public func saveAPIKey(_ key: String) throws {
        try keychain.set(account: account, value: key)
    }

    public func deleteAPIKey() throws {
        try keychain.delete(account: account)
    }

    private func environmentValue() -> String? {
        for name in envVars {
            if let value = ProcessInfo.processInfo.environment[name], !value.isEmpty {
                return value
            }
        }
        return nil
    }
}
