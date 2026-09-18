import Foundation

/// GitHub Copilot usage: premium interaction quota, reusing a sign-in already saved by another
/// Copilot client. No reset date is provided by this endpoint.
public struct CopilotProvider: ProviderRuntime {
    public static let id: ProviderID = .copilot
    public static let displayName = "GitHub Copilot"

    private let authStore: CopilotAuthStore
    private let usageClient: CopilotUsageClient

    public init(authStore: CopilotAuthStore = CopilotAuthStore()) {
        self.authStore = authStore
        self.usageClient = CopilotUsageClient()
    }

    public func hasLocalCredentials() async -> Bool {
        authStore.oauthToken() != nil
    }

    public func refresh() async -> ProviderSnapshot {
        guard let token = authStore.oauthToken() else {
            return .error(provider: Self.id, error: .credentialsMissing)
        }
        do {
            let response = try await usageClient.fetchUser(oauthToken: token)
            let (lines, plan) = CopilotMapper.map(response)
            return ProviderSnapshot(provider: Self.id, plan: plan, lines: lines, fetchedAt: Date())
        } catch let error as ProviderError {
            return .error(provider: Self.id, error: error)
        } catch {
            return .error(provider: Self.id, error: .network(error.localizedDescription))
        }
    }
}
