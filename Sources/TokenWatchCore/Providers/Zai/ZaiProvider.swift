import Foundation

/// z.ai usage: primary + secondary Coding Plan token/credit quota windows.
public struct ZaiProvider: ProviderRuntime {
    public static let id: ProviderID = .zai
    public static let displayName = "z.ai"

    public let authStore: APIKeyAuthStore
    private let usageClient: ZaiUsageClient

    public init(authStore: APIKeyAuthStore = makeZaiAuthStore()) {
        self.authStore = authStore
        self.usageClient = ZaiUsageClient()
    }

    public func detect() -> ProviderDetection? {
        authStore.detect()
    }

    public func refresh() async -> ProviderSnapshot {
        guard let apiKey = authStore.currentAPIKey() else {
            return .error(provider: Self.id, error: .credentialsMissing)
        }
        do {
            let region = ZaiRegion.configured()
            let response = try await usageClient.fetchQuota(apiKey: apiKey, region: region)
            let (lines, plan) = try ZaiMapper.map(response)
            return ProviderSnapshot(provider: Self.id, plan: plan, lines: lines, fetchedAt: Date())
        } catch let error as ProviderError {
            return .error(provider: Self.id, error: error)
        } catch {
            return .error(provider: Self.id, error: .network(error.localizedDescription))
        }
    }
}
