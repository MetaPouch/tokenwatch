import Foundation
import Combine
import TokenWatchCore

/// Shared cache of every provider's local spend history (`ClaudeUsageHistoryScanner`,
/// `CodexUsageHistoryScanner`) -- several views want the same 30-day window at once (the
/// cross-provider Total Spend card, each provider card's inline Today/Yesterday row, the 7-day
/// chart), and the scans are real disk I/O proportional to local session history. One shared
/// scan instead of one per observer.
@MainActor
public final class SpendHistoryStore: ObservableObject {
    /// Providers with a local usage-history scanner, in display order.
    public static let providers: [ProviderID] = [.claude, .codex]

    @Published public private(set) var daysByProvider: [ProviderID: [UsageDay]] = [:]
    /// True only until the first scan completes; later rescans keep showing the previous data.
    @Published public private(set) var isLoading = true
    /// When the latest scan finished; changes on every rescan, so layouts can re-measure.
    @Published public private(set) var lastLoadedAt: Date?

    /// A scan requested within this long of the last one is skipped (`loadIfNeeded`), so opening
    /// the popover repeatedly doesn't rescan every time.
    private static let staleAfter: TimeInterval = 60

    private var loadTask: Task<Void, Never>?

    public init() {}

    public func days(for provider: ProviderID) -> [UsageDay] {
        daysByProvider[provider] ?? []
    }

    public static func hasHistory(_ provider: ProviderID) -> Bool {
        providers.contains(provider)
    }

    /// Scans unless a scan is already running or finished within `staleAfter`. Called when the
    /// popover opens and from each view's `.task`.
    public func loadIfNeeded() {
        if let lastLoadedAt, Date().timeIntervalSince(lastLoadedAt) < Self.staleAfter { return }
        reload()
    }

    /// Scans now unless a scan is already running -- after each provider refresh cycle, so
    /// Today's figures stay current while the app keeps running.
    public func reload() {
        guard loadTask == nil else { return }
        loadTask = Task { [weak self] in
            let result = await withBackgroundActivity(reason: "Scanning local spend history") {
                await Task.detached(priority: .userInitiated) {
                    async let claude = ClaudeUsageHistoryScanner.dailyUsage(days: 30)
                    async let codex = CodexUsageHistoryScanner.dailyUsage(days: 30)
                    return [ProviderID.claude: await claude, .codex: await codex]
                }.value
            }
            guard let self else { return }
            daysByProvider = result
            isLoading = false
            lastLoadedAt = Date()
            loadTask = nil
        }
    }
}
