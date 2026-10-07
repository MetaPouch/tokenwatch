import Foundation
import Combine

/// Aggregates every locally discovered account's quota data for the "Usage" dashboard tab: the
/// existing default-account snapshot each enabled provider already publishes to `WidgetDataStore`
/// (reused as-is -- no duplicate network call, so this respects the same rate-limit-friendly
/// polling cadence every other part of the app already uses), plus a fresh fetch for any
/// additional local accounts discovered for providers that support more than one login
/// (currently: Claude, Codex, Cursor -- see `ClaudeAccountDiscovery`/`CodexAccountDiscovery`/
/// `CursorAccountDiscovery`).
@MainActor
public final class MultiAccountUsageService: ObservableObject {
    @Published public private(set) var accounts: [ProviderAccount] = []
    @Published public private(set) var isRefreshing = false
    @Published public private(set) var lastRefreshedAt: Date?

    private let dataStore: WidgetDataStore
    private let enablementStore: ProviderEnablementStore

    public init(dataStore: WidgetDataStore, enablementStore: ProviderEnablementStore) {
        self.dataStore = dataStore
        self.enablementStore = enablementStore
    }

    /// Rebuilds `accounts` from whatever's already in `WidgetDataStore` -- no network call. Cheap
    /// enough to call whenever the tab appears or the underlying data store changes.
    public func refreshDefaultAccountsFromCache() {
        accounts = defaultAccountEntries()
    }

    /// Rebuilds the full list: default accounts from cache, plus a fresh fetch for every
    /// additional local account. The only path that makes new network calls.
    public func refreshAdditionalAccounts() async {
        isRefreshing = true
        defer { isRefreshing = false }

        var results = defaultAccountEntries()
        let enabled = enablementStore.enabledProviders

        if enabled.contains(.claude) {
            results.append(contentsOf: await Self.fetchAdditionalClaudeAccounts())
        }
        if enabled.contains(.codex) {
            results.append(contentsOf: await Self.fetchAdditionalCodexAccounts())
        }
        if enabled.contains(.cursor) {
            results.append(contentsOf: await Self.fetchAdditionalCursorAccounts())
        }

        accounts = results
        lastRefreshedAt = Date()
    }

    private func defaultAccountEntries() -> [ProviderAccount] {
        enablementStore.enabledProviders.compactMap { providerID -> ProviderAccount? in
            guard let snapshot = dataStore.snapshot(for: providerID) else { return nil }
            return ProviderAccount(
                id: "\(providerID.rawValue):default",
                providerID: providerID,
                label: snapshot.plan ?? "",
                isDefault: true,
                lines: snapshot.lines.filter(\.isQuotaMeter),
                error: snapshot.error,
                fetchedAt: snapshot.fetchedAt
            )
        }.sorted { $0.providerID.displayName < $1.providerID.displayName }
    }

    private static func fetchAdditionalClaudeAccounts() async -> [ProviderAccount] {
        var results: [ProviderAccount] = []
        for account in ClaudeAccountDiscovery.discoverAdditionalAccounts() {
            results.append(await fetchClaudeAccount(account))
        }
        return results
    }

    private static func fetchClaudeAccount(_ account: ClaudeAdditionalAccount) async -> ProviderAccount {
        let label = account.email ?? account.sourceLabel
        let id = "claude:\(account.configDir)"

        switch ClaudeAuthStore.classifyLapse(account.credential) {
        case .stale:
            return ProviderAccount(
                id: id, providerID: .claude, label: label, isDefault: false, lines: [],
                error: .credentialLapsed(selfHeals: true, detail: "Access token will refresh automatically next time you run CLAUDE_CONFIG_DIR=\(account.configDir) claude directly (not through a harness/wrapper) -- no action needed."),
                fetchedAt: Date()
            )
        case .expired:
            return ProviderAccount(
                id: id, providerID: .claude, label: label, isDefault: false, lines: [],
                error: .credentialLapsed(selfHeals: false, detail: "Sign-in expired. Run CLAUDE_CONFIG_DIR=\(account.configDir) claude in a terminal to sign in again."),
                fetchedAt: Date()
            )
        case .live:
            break
        }

        do {
            let response = try await ClaudeUsageClient().fetchUsage(accessToken: account.credential.accessToken)
            let lines = ClaudeMapper.map(response).filter(\.isQuotaMeter)
            return ProviderAccount(id: id, providerID: .claude, label: label, isDefault: false, lines: lines, error: nil, fetchedAt: Date())
        } catch let error as ProviderError {
            return ProviderAccount(id: id, providerID: .claude, label: label, isDefault: false, lines: [], error: error, fetchedAt: Date())
        } catch {
            return ProviderAccount(id: id, providerID: .claude, label: label, isDefault: false, lines: [], error: .network(error.localizedDescription), fetchedAt: Date())
        }
    }

    private static func fetchAdditionalCodexAccounts() async -> [ProviderAccount] {
        var results: [ProviderAccount] = []
        for account in CodexAccountDiscovery.discoverAdditionalAccounts() {
            results.append(await fetchCodexAccount(account))
        }
        return results
    }

    private static func fetchCodexAccount(_ account: CodexAdditionalAccount) async -> ProviderAccount {
        let id = "codex:\(account.home)"
        do {
            let response = try await CodexUsageClient().fetchUsage(accessToken: account.accessToken)
            let lines = CodexMapper.map(response).filter(\.isQuotaMeter)
            let label = response.email ?? account.sourceLabel
            return ProviderAccount(id: id, providerID: .codex, label: label, isDefault: false, lines: lines, error: nil, fetchedAt: Date())
        } catch let error as ProviderError {
            return ProviderAccount(id: id, providerID: .codex, label: account.sourceLabel, isDefault: false, lines: [], error: error, fetchedAt: Date())
        } catch {
            return ProviderAccount(id: id, providerID: .codex, label: account.sourceLabel, isDefault: false, lines: [], error: .network(error.localizedDescription), fetchedAt: Date())
        }
    }

    private static func fetchAdditionalCursorAccounts() async -> [ProviderAccount] {
        guard let account = await CursorAccountDiscovery.discoverAdditionalAccount() else { return [] }
        return [await fetchCursorAccount(account)]
    }

    private static func fetchCursorAccount(_ account: CursorAdditionalAccount) async -> ProviderAccount {
        let credential = account.credential
        let id = "cursor:cli:\(credential.userID)"
        let fallbackLabel = credential.email ?? account.sourceLabel
        func result(label: String, lines: [MetricLine] = [], error: ProviderError? = nil) -> ProviderAccount {
            ProviderAccount(id: id, providerID: .cursor, label: label, isDefault: false, lines: lines, error: error, fetchedAt: Date())
        }

        // Never refreshed from here (the CLI does that whenever it runs), so a lapse is just a wait.
        if let expiresAt = credential.expiresAt, expiresAt.timeIntervalSinceNow <= 60 {
            return result(label: fallbackLabel, error: .credentialLapsed(selfHeals: true, detail: "The Cursor CLI's access token has lapsed. It renews the next time you run `cursor-agent` directly -- no action needed."))
        }
        guard let sessionToken = CursorAuthStore.sessionCookieValue(forAccessToken: credential.accessToken) else {
            return result(label: fallbackLabel, error: .parse("The Cursor CLI's saved sign-in isn't a token TokenWatch can read."))
        }
        do {
            let client = CursorUsageClient()
            async let summaryTask = client.fetchUsageSummary(sessionToken: sessionToken)
            async let userInfoTask = try? client.fetchUserInfo(sessionToken: sessionToken)
            let summary = try await summaryTask
            let userInfo = await userInfoTask ?? nil
            let lines = CursorMapper.map(summary, userInfo: userInfo).filter(\.isQuotaMeter)
            return result(label: userInfo?.email ?? fallbackLabel, lines: lines)
        } catch let error as ProviderError {
            return result(label: fallbackLabel, error: error)
        } catch {
            return result(label: fallbackLabel, error: .network(error.localizedDescription))
        }
    }
}
