import Foundation
import Combine
import TokenWatchCore

/// Shared cache of all spend history -- Claude (`ClaudeUsageHistoryScanner`), Codex
/// (`CodexUsageHistoryScanner`), every other local agent log (`LocalUsageHistoryScanner`), and
/// Cursor's account usage (`CursorUsageHistory`, while the Cursor provider is enabled) -- keyed by
/// `SpendSource`. Several views want the same 30-day window at once (the Total Spend card with its
/// 7-day chart, each provider card's inline Today/Yesterday row), and the scans are real disk I/O
/// proportional to local session history. One shared scan instead of one per observer.
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
    /// Cursor's usage is a network fetch, so it's refreshed at most this often.
    private static let cursorStaleAfter: TimeInterval = 5 * 60

    private let includeCursor: () -> Bool
    private var loadTask: Task<Void, Never>?
    private var cursorDays: [UsageDay]?
    private var cursorFetchedAt: Date?

    /// `includeCursor` says whether to fetch Cursor's account usage (the Cursor provider is on).
    public init(includeCursor: @escaping () -> Bool = { false }) {
        self.includeCursor = includeCursor
    }

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
        let cursorEnabled = includeCursor()
        if !cursorEnabled { (cursorDays, cursorFetchedAt) = (nil, nil) }
        let fetchCursor = cursorEnabled && cursorFetchedAt.map { Date().timeIntervalSince($0) >= Self.cursorStaleAfter } ?? cursorEnabled
        loadTask = Task { [weak self] in
            let (local, fetchedCursor) = await withBackgroundActivity(reason: "Scanning local spend history") {
                await Task.detached(priority: .userInitiated) { () -> ([SpendSource: [UsageDay]], [UsageDay]?) in
                    async let claude = ClaudeUsageHistoryScanner.dailyUsage(days: 30)
                    async let codex = CodexUsageHistoryScanner.dailyUsage(days: 30)
                    async let others = LocalUsageHistoryScanner.dailyUsage(days: 30)
                    async let cursor = fetchCursor ? CursorUsageHistory.dailyUsage(days: 30) : nil
                    var result = await others
                    result[.provider(.claude)] = await claude
                    result[.provider(.codex)] = await codex
                    return (result, await cursor)
                }.value
            }
            guard let self else { return }
            if fetchCursor {
                cursorFetchedAt = Date()
                // A failed fetch keeps the last good history.
                if let fetchedCursor { cursorDays = fetchedCursor }
            }
            var result = local
            // Cursor's account history covers every client signed into it, omp's `cursor`
            // provider included, so it replaces any locally logged Cursor turns rather than
            // adding to them.
            if let cursorDays { result[.provider(.cursor)] = cursorDays }
            daysBySource = result
            isLoading = false
            lastLoadedAt = Date()
            loadTask = nil
        }
    }
}
