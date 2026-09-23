import Foundation

/// Antigravity usage via its own CLI's OAuth token file plus the same Code Assist backend the
/// `agy` CLI itself calls (`loadCodeAssist` -> `retrieveUserQuotaSummary`). This reads the token
/// directly instead of shelling out to `agy -p /usage --output-format json` -- that subcommand's
/// JSON shape is documented but not independently confirmed, while this file path and API shape
/// are confirmed via a real third-party reader (github.com/wakamex/agy-usage). No token refresh,
/// no PTY spawning, no CSRF/socket handling in v1 -- same bounded scope as the Gemini provider.
public struct AntigravityProvider: ProviderRuntime {
    public static let id: ProviderID = .antigravity
    public static let displayName = "Antigravity"

    private let authStore: AntigravityAuthStore
    private let usageClient: AntigravityUsageClient

    public init(authStore: AntigravityAuthStore = AntigravityAuthStore()) {
        self.authStore = authStore
        self.usageClient = AntigravityUsageClient()
    }

    public func detect() -> ProviderDetection? {
        authStore.hasTokenFile() ? ProviderDetection(source: "Signed in with Antigravity") : nil
    }

    public func refresh() async -> ProviderSnapshot {
        guard let token = authStore.validAccessToken() else {
            return .error(provider: Self.id, error: .credentialsMissing)
        }
        do {
            let loadResponse = try await usageClient.loadCodeAssist(accessToken: token)
            guard let project = loadResponse.cloudaicompanionProject else {
                return .error(provider: Self.id, error: .parse("no Code Assist project returned"))
            }
            let summary = try await usageClient.retrieveUserQuotaSummary(accessToken: token, project: project)
            let lines = try AntigravityMapper.map(summary)
            return ProviderSnapshot(provider: Self.id, plan: nil, lines: lines, fetchedAt: Date())
        } catch let error as ProviderError {
            return .error(provider: Self.id, error: error)
        } catch {
            return .error(provider: Self.id, error: .network(error.localizedDescription))
        }
    }
}
