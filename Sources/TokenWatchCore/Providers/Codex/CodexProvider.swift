import Foundation

/// Codex/ChatGPT usage: session (5h) + weekly percent, plus a best-effort cache-temperature
/// badge per locally active session (see `CodexCacheTemperature`) -- the most recently touched
/// session is the headline badge (id `cacheTemperature`, also driving `lastActivityAt`/
/// `lastActivityLabel`), any other sessions touched within the last 5 hours each get their own
/// additional badge, mirroring `ClaudeProvider`. Primary path reads `~/.codex/auth.json` and
/// calls the OAuth usage endpoint (field names confirmed against a real API response quoted in
/// github.com/openai/codex#26370). Fallback: `codex app-server` JSON-RPC subprocess when
/// `auth.json` is missing/expired -- see `CodexAppServerClient` for its bounded-risk scope note.
public struct CodexProvider: ProviderRuntime {
    public static let id: ProviderID = .codex
    public static let displayName = "Codex"

    private let authStore: CodexAuthStore
    private let usageClient: CodexUsageClient
    private let appServerClient: CodexAppServerClient

    public init(authStore: CodexAuthStore = CodexAuthStore()) {
        self.authStore = authStore
        self.usageClient = CodexUsageClient()
        self.appServerClient = CodexAppServerClient()
    }

    public func detect() -> ProviderDetection? {
        authStore.hasAuthFile() ? ProviderDetection(source: "Signed in with the Codex CLI") : nil
    }

    public func refresh() async -> ProviderSnapshot {
        if let token = authStore.accessToken() {
            do {
                let response = try await usageClient.fetchUsage(accessToken: token)
                let lines = CodexMapper.map(response)
                return Self.appendingCacheTemperature(to: lines, plan: response.planType)
            } catch let error as ProviderError {
                return .error(provider: Self.id, error: error)
            } catch {
                return .error(provider: Self.id, error: .network(error.localizedDescription))
            }
        }

        do {
            let result = try await appServerClient.fetchRateLimits()
            var lines: [MetricLine] = []
            if let primary = result.primary {
                lines.append(.progress(id: "session", label: "Session", used: primary.usedPercent ?? 0, limit: 100, format: .percent, resetsAt: primary.resetsAt.flatMap(FlexibleISO8601.parse), periodDurationMs: primary.windowMinutes.map { $0 * 60_000 }))
            }
            if let secondary = result.secondary {
                lines.append(.progress(id: "weekly", label: "Weekly", used: secondary.usedPercent ?? 0, limit: 100, format: .percent, resetsAt: secondary.resetsAt.flatMap(FlexibleISO8601.parse), periodDurationMs: secondary.windowMinutes.map { $0 * 60_000 }))
            }
            guard !lines.isEmpty else {
                return .error(provider: Self.id, error: .credentialsMissing)
            }
            return Self.appendingCacheTemperature(to: lines, plan: nil)
        } catch let error as ProviderError {
            return .error(provider: Self.id, error: error)
        } catch {
            return .error(provider: Self.id, error: .network(error.localizedDescription))
        }
    }

    /// Scans local Codex activity (best-effort, non-fatal on any failure) and appends a
    /// cache-temperature badge per active session on top of the usage `lines` already fetched from
    /// the API -- shared by both the primary and app-server-fallback refresh paths so
    /// cache-temperature works regardless of which credential source produced the usage %. Merges
    /// two sources, like `ClaudeProvider`: Codex CLI rollouts (`CodexSessionScanner`) and Codex used
    /// through omp (`OmpSessionScanner`), which calls the API itself and never writes a rollout.
    /// `plan` is the usage endpoint's own `plan_type` when the primary path produced it -- the
    /// app-server fallback has no equivalent field, so it always passes `nil`.
    private static func appendingCacheTemperature(to usageLines: [MetricLine], plan: String?) -> ProviderSnapshot {
        var lines = usageLines
        let activity = [CodexSessionScanner.mostRecentActivity(), OmpSessionScanner.mostRecentActivity(provider: id).map(CodexSessionActivity.init(omp:))]
            .compactMap { $0 }
            .max { $0.timestamp < $1.timestamp }
        if let cacheLine = CodexCacheTemperature.evaluate(activity: activity) {
            lines.append(cacheLine)
        }

        let otherActiveSessions = (CodexSessionScanner.allRecentActivity() + OmpSessionScanner.allRecentActivity(provider: id).map(CodexSessionActivity.init(omp:)))
            .filter { $0.filePath != activity?.filePath }
            .sorted { $0.timestamp > $1.timestamp }
        for (index, session) in otherActiveSessions.enumerated() {
            if let line = CodexCacheTemperature.evaluate(activity: session, badgeID: "cacheTemperature-other-\(index)") {
                lines.append(line)
            }
        }

        return ProviderSnapshot(provider: Self.id, plan: plan, lines: lines, fetchedAt: Date(), lastActivityAt: activity?.timestamp, lastActivityLabel: activity?.sessionLabel)
    }
}

extension CodexSessionActivity {
    /// A Codex turn from omp's log. omp keeps cache reads/writes out of `input`; OpenAI's shape
    /// (and `CodexCacheTemperature`'s hit ratio) counts cached tokens inside it.
    init(omp activity: ClaudeSessionActivity) {
        self.init(
            filePath: activity.filePath,
            timestamp: activity.timestamp,
            inputTokens: activity.inputTokens + activity.cacheReadTokens + activity.cacheCreationTokens,
            cachedInputTokens: activity.cacheReadTokens,
            sessionLabel: activity.sessionLabel
        )
    }
}
