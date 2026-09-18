import Foundation

/// Kimi Code usage: weekly request quota (membership tier) + current 5-hour rate limit.
public struct KimiProvider: ProviderRuntime {
    public static let id: ProviderID = .kimi
    public static let displayName = "Kimi"

    public let authStore: APIKeyAuthStore
    private let usageClient: KimiUsageClient

    public init(authStore: APIKeyAuthStore = makeKimiAuthStore()) {
        self.authStore = authStore
        self.usageClient = KimiUsageClient()
    }

    public func hasLocalCredentials() async -> Bool {
        authStore.currentAPIKey() != nil
    }

    public func refresh() async -> ProviderSnapshot {
        guard let apiKey = authStore.currentAPIKey() else {
            return .error(provider: Self.id, error: .credentialsMissing)
        }
        do {
            let response = try await usageClient.fetchUsages(apiKey: apiKey)
            let lines = KimiMapper.map(response)
            return ProviderSnapshot(provider: Self.id, plan: nil, lines: lines, fetchedAt: Date())
        } catch let error as ProviderError {
            return .error(provider: Self.id, error: error)
        } catch {
            return .error(provider: Self.id, error: .network(error.localizedDescription))
        }
    }
}
