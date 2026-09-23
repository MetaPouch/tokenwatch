import Foundation

/// OpenRouter usage: key spending-cap progress (when the key has a limit) + credit balance.
public struct OpenRouterProvider: ProviderRuntime {
    public static let id: ProviderID = .openrouter
    public static let displayName = "OpenRouter"

    public let authStore: APIKeyAuthStore
    private let usageClient: OpenRouterUsageClient

    public init(authStore: APIKeyAuthStore = makeOpenRouterAuthStore()) {
        self.authStore = authStore
        self.usageClient = OpenRouterUsageClient()
    }

    public func detect() -> ProviderDetection? {
        authStore.detect()
    }

    public func refresh() async -> ProviderSnapshot {
        guard let apiKey = authStore.currentAPIKey() else {
            return .error(provider: Self.id, error: .credentialsMissing)
        }
        do {
            async let creditsTask = usageClient.fetchCredits(apiKey: apiKey)
            async let keyTask = usageClient.fetchKey(apiKey: apiKey)
            let credits = try await creditsTask
            let key = try await keyTask
            let lines = OpenRouterMapper.map(credits: credits, key: key)
            return ProviderSnapshot(provider: Self.id, plan: nil, lines: lines, fetchedAt: Date())
        } catch let error as ProviderError {
            return .error(provider: Self.id, error: error)
        } catch {
            return .error(provider: Self.id, error: .network(error.localizedDescription))
        }
    }
}
