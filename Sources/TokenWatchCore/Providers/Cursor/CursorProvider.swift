import Foundation

/// Cursor usage via Cursor.app's local session token, falling back to a Safari-imported cookie
/// when the local token is missing/expired (`CursorAuthStore.resolvedSessionToken()`):
/// included-plan usage + on-demand spend.
public struct CursorProvider: ProviderRuntime {
    public static let id: ProviderID = .cursor
    public static let displayName = "Cursor"

    private let authStore: CursorAuthStore
    private let usageClient: CursorUsageClient

    public init(authStore: CursorAuthStore = CursorAuthStore()) {
        self.authStore = authStore
        self.usageClient = CursorUsageClient()
    }

    public func detect() -> ProviderDetection? {
        authStore.hasSavedSignIn() ? ProviderDetection(source: "Signed in to the Cursor app") : nil
    }

    public func refresh() async -> ProviderSnapshot {
        guard let token = authStore.resolvedSessionToken() else {
            return .error(provider: Self.id, error: .credentialsMissing)
        }
        do {
            async let summaryTask = usageClient.fetchUsageSummary(sessionToken: token)
            async let userInfoTask = try? usageClient.fetchUserInfo(sessionToken: token)
            let summary = try await summaryTask
            let userInfo = await userInfoTask
            let lines = CursorMapper.map(summary, userInfo: userInfo ?? nil)
            return ProviderSnapshot(provider: Self.id, plan: summary.membershipType, lines: lines, fetchedAt: Date())
        } catch let error as ProviderError {
            return .error(provider: Self.id, error: error)
        } catch {
            return .error(provider: Self.id, error: .network(error.localizedDescription))
        }
    }
}
