import Foundation

/// Claude usage via OAuth: session (5h) + weekly (7d) percent, plus extra usage spend when
/// enabled, plus a best-effort cache-temperature badge read from local session transcripts (see
/// `ClaudeCacheTemperature`). Credentials: Claude CLI Keychain item `Claude Code-credentials`,
/// falling back to `~/.claude/.credentials.json`. Local `.jsonl` per-model cost scanning (Claude
/// Tracker's per-model breakdown) remains a stretch goal skipped in v1 -- see plan Phase 2 step 1.
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
            var lines = ClaudeMapper.map(response)
            let activity = ClaudeSessionScanner.mostRecentActivity()
            if let cacheLine = ClaudeCacheTemperature.evaluate(
                activity: activity,
                ttlSeconds: ClaudeCacheTemperature.resolveTTLSeconds()
            ) {
                lines.append(cacheLine)
            }
            return ProviderSnapshot(provider: Self.id, plan: nil, lines: lines, fetchedAt: Date(), lastActivityAt: activity?.timestamp, lastActivityLabel: activity?.sessionLabel)
        } catch let error as ProviderError {
            return .error(provider: Self.id, error: error)
        } catch {
            return .error(provider: Self.id, error: .network(error.localizedDescription))
        }
    }
}
