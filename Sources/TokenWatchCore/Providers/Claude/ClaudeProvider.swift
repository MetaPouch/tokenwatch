import Foundation

/// Claude usage via OAuth: session (5h) + weekly (7d) percent, plus extra usage spend when
/// enabled. Credentials: Claude CLI Keychain item `Claude Code-credentials`, falling back to
/// `~/.claude/.credentials.json`. Local `.jsonl` per-model cost scanning (Claude Tracker's
/// per-model breakdown) is a stretch goal skipped in v1 to keep the core session/weekly numbers
/// simple -- see plan Phase 2 step 1.
public struct ClaudeProvider: ProviderRuntime {
    public static let id: ProviderID = .claude
    public static let displayName = "Claude"

    private let authStore: ClaudeAuthStore
    private let usageClient: ClaudeUsageClient

    public init(authStore: ClaudeAuthStore = ClaudeAuthStore()) {
        self.authStore = authStore
        self.usageClient = ClaudeUsageClient()
    }

    public func hasLocalCredentials() async -> Bool {
        authStore.accessToken() != nil
    }

    public func refresh() async -> ProviderSnapshot {
        guard let token = authStore.accessToken() else {
            return .error(provider: Self.id, error: .credentialsMissing)
        }
        do {
            let response = try await usageClient.fetchUsage(accessToken: token)
            let lines = ClaudeMapper.map(response)
            return ProviderSnapshot(provider: Self.id, plan: nil, lines: lines, fetchedAt: Date())
        } catch let error as ProviderError {
            return .error(provider: Self.id, error: error)
        } catch {
            return .error(provider: Self.id, error: .network(error.localizedDescription))
        }
    }
}
