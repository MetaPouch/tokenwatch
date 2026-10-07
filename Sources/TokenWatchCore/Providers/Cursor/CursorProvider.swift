import Foundation

/// Cursor usage via Cursor.app's local session token, else the Cursor CLI's saved sign-in, else a
/// Safari-imported cookie: included-plan usage + on-demand spend. When the CLI is signed in as a
/// *different* person than the app, that login gets its own extra card instead
/// (`CursorAccountDiscovery`, `MultiAccountUsageService`), so this card stays the app's account.
public struct CursorProvider: ProviderRuntime {
    public static let id: ProviderID = .cursor
    public static let displayName = "Cursor"

    private let authStore: CursorAuthStore
    private let cliAuth: CursorCLIAuth
    private let usageClient: CursorUsageClient

    public init(authStore: CursorAuthStore = CursorAuthStore()) {
        self.init(authStore: authStore, cliAuth: CursorCLIAuth())
    }

    init(authStore: CursorAuthStore, cliAuth: CursorCLIAuth) {
        self.authStore = authStore
        self.cliAuth = cliAuth
        self.usageClient = CursorUsageClient()
    }

    public func detect() -> ProviderDetection? {
        let approval = cliAuth.needsKeychainApproval()
        if authStore.hasSavedSignIn() {
            return ProviderDetection(source: "Signed in to the Cursor app", needsKeychainApproval: approval)
        }
        if cliAuth.hasSavedSignIn() {
            return ProviderDetection(source: "Signed in with the Cursor CLI", needsKeychainApproval: approval)
        }
        return nil
    }

    /// Cursor.app's token first, then the CLI's (only read when the app has none -- see
    /// `CursorAccountDiscovery`), then the Safari cookie.
    private func sessionToken() async -> String? {
        if let app = authStore.appSessionToken() { return app }
        if let cli = await cliAuth.credential(),
           let expiry = cli.expiresAt, expiry.timeIntervalSinceNow > 60,
           let cookie = CursorAuthStore.sessionCookieValue(forAccessToken: cli.accessToken) {
            return cookie
        }
        return authStore.safariCookieToken()
    }

    public func refresh() async -> ProviderSnapshot {
        guard let token = await sessionToken() else {
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
