import Foundation

/// Gemini usage via Gemini CLI OAuth credentials: lowest-remaining Pro-family quota as primary,
/// lowest-remaining Flash-family quota as secondary. `api-key`/`vertex-ai` auth types are
/// unsupported (`.notConfigured`); an expired token is not refreshed by TokenWatch (that needs
/// extracting the Gemini CLI's bundled OAuth client id/secret) -- it surfaces as
/// `.credentialsMissing` asking the user to re-run `gemini`.
public struct GeminiProvider: ProviderRuntime {
    public static let id: ProviderID = .gemini
    public static let displayName = "Gemini"

    private let authStore: GeminiAuthStore
    private let usageClient: GeminiUsageClient

    public init(authStore: GeminiAuthStore = GeminiAuthStore()) {
        self.authStore = authStore
        self.usageClient = GeminiUsageClient()
    }

    public func detect() -> ProviderDetection? {
        authStore.hasUsableSignIn() ? ProviderDetection(source: "Signed in with the Gemini CLI") : nil
    }

    public func refresh() async -> ProviderSnapshot {
        switch authStore.currentAuthType() {
        case .apiKey, .vertexAI:
            return .error(provider: Self.id, error: .notConfigured)
        case .oauthPersonal, .unknown:
            break
        }

        guard let token = authStore.validAccessToken() else {
            return .error(provider: Self.id, error: .credentialsMissing)
        }

        do {
            let project = try? await usageClient.loadCodeAssist(accessToken: token).cloudaicompanionProject
            let quota = try await usageClient.retrieveUserQuota(accessToken: token, project: project)
            let lines = try GeminiMapper.map(quota)
            return ProviderSnapshot(provider: Self.id, plan: nil, lines: lines, fetchedAt: Date())
        } catch let error as ProviderError {
            return .error(provider: Self.id, error: error)
        } catch {
            return .error(provider: Self.id, error: .network(error.localizedDescription))
        }
    }
}
