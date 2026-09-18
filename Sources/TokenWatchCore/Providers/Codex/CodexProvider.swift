import Foundation

/// Codex/ChatGPT usage: session (5h) + weekly percent. Primary path reads `~/.codex/auth.json`
/// and calls the OAuth usage endpoint (field names confirmed against a real API response quoted
/// in github.com/openai/codex#26370). Fallback: `codex app-server` JSON-RPC subprocess when
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

    public func hasLocalCredentials() async -> Bool {
        authStore.hasAuthFile()
    }

    public func refresh() async -> ProviderSnapshot {
        if let token = authStore.accessToken() {
            do {
                let response = try await usageClient.fetchUsage(accessToken: token)
                let lines = CodexMapper.map(response)
                return ProviderSnapshot(provider: Self.id, plan: nil, lines: lines, fetchedAt: Date())
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
            return ProviderSnapshot(provider: Self.id, plan: nil, lines: lines, fetchedAt: Date())
        } catch let error as ProviderError {
            return .error(provider: Self.id, error: error)
        } catch {
            return .error(provider: Self.id, error: .network(error.localizedDescription))
        }
    }
}
