import Foundation

/// Amp usage: `amp usage` CLI when installed (best-effort text/JSON parse), else the
/// `ampcode.com` internal balance API via a saved token. No browser-cookie fallback in v1
/// (bounded decision -- CLI or token covers the no-browser-needed paths). The CLI's exact output
/// format could not be confirmed during implementation (no `amp` install available); a parse
/// failure there falls through to the token path rather than guessing.
public struct AmpProvider: ProviderRuntime {
    public static let id: ProviderID = .amp
    public static let displayName = "Amp"

    public let authStore: APIKeyAuthStore
    private let usageClient: AmpUsageClient

    public init(authStore: APIKeyAuthStore = makeAmpAuthStore()) {
        self.authStore = authStore
        self.usageClient = AmpUsageClient()
    }

    public func detect() -> ProviderDetection? {
        if BoundedSubprocess.resolveOnPath(["amp"]) != nil { return ProviderDetection(source: "Amp CLI installed") }
        return authStore.detect()
    }

    public func refresh() async -> ProviderSnapshot {
        if let cliLines = await refreshViaCLI() {
            return ProviderSnapshot(provider: Self.id, plan: nil, lines: cliLines, fetchedAt: Date())
        }

        guard let apiKey = authStore.currentAPIKey() else {
            return .error(provider: Self.id, error: .credentialsMissing)
        }
        do {
            let response = try await usageClient.fetchBalance(apiKey: apiKey)
            guard let displayText = response.displayText else {
                return .error(provider: Self.id, error: .parse("missing displayText"))
            }
            let lines = AmpMapper.map(displayText: displayText)
            return ProviderSnapshot(provider: Self.id, plan: nil, lines: lines, fetchedAt: Date())
        } catch let error as ProviderError {
            return .error(provider: Self.id, error: error)
        } catch {
            return .error(provider: Self.id, error: .network(error.localizedDescription))
        }
    }

    /// Best-effort: runs `amp usage`, tries a JSON `displayText` field first, then the same
    /// regex parser used for the API fallback. Returns `nil` (not an error) on any failure so
    /// `refresh()` falls through to the token-based API.
    private func refreshViaCLI() async -> [MetricLine]? {
        guard let executable = BoundedSubprocess.resolveOnPath(["amp"]) else { return nil }
        guard let result = await BoundedSubprocess.run(executablePath: executable, arguments: ["usage"], timeout: 20), result.exitCode == 0 else {
            return nil
        }
        guard let text = String(data: result.stdout, encoding: .utf8), !text.isEmpty else { return nil }

        if let jsonData = text.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(AmpBalanceResponse.self, from: jsonData),
           let displayText = decoded.displayText {
            let lines = AmpMapper.map(displayText: displayText)
            return lines.isEmpty ? nil : lines
        }

        let lines = AmpMapper.map(displayText: text)
        return lines.isEmpty ? nil : lines
    }
}
