import Foundation

/// Grok usage via `~/.grok/auth.json` -> CLI-proxy billing credits. No ACP JSON-RPC (`grok agent
/// stdio`) and no grok.com gRPC-web/protobuf fallback in v1 -- bounded decision: the JSON-RPC
/// path is presently broken upstream on current Grok CLI releases, and the protobuf fallback
/// needs a browser-held key-exchange handshake this app cannot reproduce reliably.
public struct GrokProvider: ProviderRuntime {
    public static let id: ProviderID = .grok
    public static let displayName = "Grok"

    private let authStore: GrokAuthStore
    private let usageClient: GrokUsageClient

    public init(authStore: GrokAuthStore = GrokAuthStore()) {
        self.authStore = authStore
        self.usageClient = GrokUsageClient()
    }

    public func detect() -> ProviderDetection? {
        authStore.hasAuthFile() ? ProviderDetection(source: "Signed in with the Grok CLI") : nil
    }

    public func refresh() async -> ProviderSnapshot {
        guard let token = authStore.validAccessToken() else {
            return .error(provider: Self.id, error: .credentialsMissing)
        }
        do {
            let response = try await usageClient.fetchBilling(accessToken: token)
            let (lines, plan) = GrokMapper.map(response)
            return ProviderSnapshot(provider: Self.id, plan: plan, lines: lines, fetchedAt: Date())
        } catch let error as ProviderError {
            return .error(provider: Self.id, error: error)
        } catch {
            return .error(provider: Self.id, error: .network(error.localizedDescription))
        }
    }
}
