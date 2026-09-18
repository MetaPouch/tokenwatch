import Foundation

/// OpenCode Go usage: rolling 5-hour usage + optional weekly usage. No browser-cookie web
/// dashboard fallback in v1 (bounded decision -- OpenCode's cookie path uses undocumented
/// regex-parsed `text/javascript` RPC responses, too fragile to prioritize).
public struct OpenCodeProvider: ProviderRuntime {
    public static let id: ProviderID = .opencode
    public static let displayName = "OpenCode"

    public let authStore: APIKeyAuthStore
    private let usageClient: OpenCodeUsageClient

    public init(authStore: APIKeyAuthStore = makeOpenCodeAuthStore()) {
        self.authStore = authStore
        self.usageClient = OpenCodeUsageClient()
    }

    public func hasLocalCredentials() async -> Bool {
        authStore.currentAPIKey() != nil
    }

    public func refresh() async -> ProviderSnapshot {
        guard let apiKey = authStore.currentAPIKey() else {
            return .error(provider: Self.id, error: .credentialsMissing)
        }
        do {
            let response = try await usageClient.fetchUsage(apiKey: apiKey)
            let lines = OpenCodeMapper.map(response)
            return ProviderSnapshot(provider: Self.id, plan: nil, lines: lines, fetchedAt: Date())
        } catch let error as ProviderError {
            return .error(provider: Self.id, error: error)
        } catch {
            return .error(provider: Self.id, error: .network(error.localizedDescription))
        }
    }
}
