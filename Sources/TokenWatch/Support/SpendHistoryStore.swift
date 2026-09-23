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
    nonisolated public static let providers: [ProviderID] = [.claude, .codex]

    @Published public private(set) var daysByProvider: [ProviderID: [UsageDay]] = [:]
    @Published public private(set) var activityByProvider: [ProviderID: LiveUsageActivity] = [:]
    /// True only until the first scan completes; later rescans keep showing the previous data.
    @Published public private(set) var isLoading = true
    /// When the latest scan finished; changes on every rescan, so layouts can re-measure.
    @Published public private(set) var lastLoadedAt: Date?

    /// A scan requested within this long of the last one is skipped (`loadIfNeeded`), so opening
    /// the popover repeatedly doesn't rescan every time.
    private static let staleAfter: TimeInterval = 60

    private var loadTask: Task<Void, Never>?
    private var pendingProviders: Set<ProviderID> = []
    private var watcher: LocalUsageWatcher?

    public init() {}

    /// Start before the initial scan so writes during that scan cannot be missed.
    public func startWatching() {
        guard watcher == nil else { return }
        let watcher = LocalUsageWatcher { [weak self] providers in self?.reload(providers: providers) }
        self.watcher = watcher
        watcher.start()
        reload()
    }

    public func stopWatching() {
        watcher?.stop()
        watcher = nil
        loadTask?.cancel()
        loadTask = nil
        pendingProviders = []
        activityByProvider = [:]
    }

    public func days(for provider: ProviderID) -> [UsageDay] {
        daysByProvider[provider] ?? []
    }

    public static func hasHistory(_ provider: ProviderID) -> Bool {
        providers.contains(provider)
    }

    /// Scans unless a scan is already running or finished within `staleAfter`. Called when the
    /// popover opens and from each view's `.task`.
    public func loadIfNeeded() {
        guard loadTask == nil else { return }
        if let lastLoadedAt, Date().timeIntervalSince(lastLoadedAt) < Self.staleAfter { return }
        reload()
    }

    /// Changes coalesce by provider, including writes arriving during a scan. Shared omp logs
    /// target both providers; a native Claude or Codex log leaves the other provider untouched.
    public func reload(providers: Set<ProviderID> = Set(SpendHistoryStore.providers)) {
        pendingProviders.formUnion(providers.intersection(Self.providers))
        guard loadTask == nil, !pendingProviders.isEmpty else { return }
        let requested = Self.providers.filter { pendingProviders.contains($0) }
        pendingProviders = []
        loadTask = Task { [weak self] in
            let result = await withBackgroundActivity(reason: "Scanning local spend history") {
                await Task.detached(priority: .userInitiated) {
                    var result: [ProviderID: [UsageDay]] = [:]
                    for provider in requested {
                        switch provider {
                        case .claude: result[provider] = ClaudeUsageHistoryScanner.dailyUsage(days: 30)
                        case .codex: result[provider] = CodexUsageHistoryScanner.dailyUsage(days: 30)
                        default: break
                        }
                    }
                    return result
                }.value
            }
            guard let self, !Task.isCancelled else { return }
            let now = Date()
            var activities = activityByProvider
            var updatedDays = daysByProvider
            for (provider, days) in result {
                updatedDays[provider] = days
                var activity = activities[provider] ?? LiveUsageActivity()
                activity.observe(days.last, now: now)
                activities[provider] = activity
            }
            daysByProvider = updatedDays
            activityByProvider = activities
            isLoading = false
            lastLoadedAt = now
            loadTask = nil
            if !pendingProviders.isEmpty { reload(providers: []) }
        }
    }
}
