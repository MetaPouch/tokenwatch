import Foundation
import Combine
import TokenWatchCore

/// Shared cache of all local spend history -- Claude (`ClaudeUsageHistoryScanner`), Codex
/// (`CodexUsageHistoryScanner`), and whatever else the omp/pi harnesses called
/// (`HarnessUsageHistoryScanner`) -- keyed by `SpendSource`. Several views want the same 30-day
/// window at once (the Total Spend card with its 7-day chart, each provider card's inline
/// Today/Yesterday row), and the scans are real disk I/O proportional to local session history.
/// One shared scan instead of one per observer.
@MainActor
public final class SpendHistoryStore: ObservableObject {
    @Published public private(set) var daysBySource: [SpendSource: [UsageDay]] = [:]
    /// True only until the first scan completes; later rescans keep showing the previous data.
    @Published public private(set) var isLoading = true
    /// When the latest scan finished; changes on every rescan, so layouts can re-measure.
    @Published public private(set) var lastLoadedAt: Date?

    /// A scan requested within this long of the last one is skipped (`loadIfNeeded`), so opening
    /// the popover repeatedly doesn't rescan every time.
    private static let staleAfter: TimeInterval = 60

    private var loadTask: Task<Void, Never>?

    public init() {}

    public func days(for source: SpendSource) -> [UsageDay] {
        daysBySource[source] ?? []
    }

    public func days(for provider: ProviderID) -> [UsageDay] {
        days(for: .provider(provider))
    }

    /// Every source with any local usage in the scanned window, `ProviderID` order then Other.
    public var sources: [SpendSource] {
        daysBySource.filter { $0.value.contains { $0.totalTokens > 0 } }.keys.sorted()
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
                    async let harness = HarnessUsageHistoryScanner.dailyUsage(days: 30)
                    var result = await harness
                    result[.provider(.claude)] = await claude
                    result[.provider(.codex)] = await codex
                    return result
                }.value
            }
            guard let self else { return }
            daysBySource = result
            isLoading = false
            lastLoadedAt = Date()
            loadTask = nil
        }
    }
}
