import Foundation
import Combine
import TokenWatchCore

/// Shared 30-day history for every local spend source and optional Cursor account usage.
/// Filesystem updates target native providers; full refreshes reconcile every source and retain
/// Cursor's independently throttled network history. Views all observe the same source cache.
@MainActor
public final class SpendHistoryStore: ObservableObject {
    @Published public private(set) var daysBySource: [SpendSource: [UsageDay]] = [:]
    @Published public private(set) var activityByProvider: [ProviderID: LiveUsageActivity] = [:]
    @Published public private(set) var isLoading = true
    @Published public private(set) var lastLoadedAt: Date?

    private static let staleAfter: TimeInterval = 60
    private static let cursorStaleAfter: TimeInterval = 5 * 60

    private let includeCursor: () -> Bool
    private var loadTask: Task<Void, Never>?
    private var pendingProviders: Set<ProviderID> = []
    private var fullReloadPending = false
    private var watcher: LocalUsageWatcher?
    private var cursorDays: [UsageDay]?
    private var cursorFetchedAt: Date?

    public init(includeCursor: @escaping () -> Bool = { false }) {
        self.includeCursor = includeCursor
    }

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
        fullReloadPending = false
        activityByProvider = [:]
    }

    public func days(for source: SpendSource) -> [UsageDay] {
        daysBySource[source] ?? []
    }

    public func days(for provider: ProviderID) -> [UsageDay] {
        days(for: .provider(provider))
    }

    public var sources: [SpendSource] {
        daysBySource.filter { $0.value.contains { $0.totalTokens > 0 } }.keys.sorted()
    }

    public func loadIfNeeded() {
        guard loadTask == nil else { return }
        if let lastLoadedAt, Date().timeIntervalSince(lastLoadedAt) < Self.staleAfter { return }
        reload()
    }

    /// nil requests a full reconciliation. Targeted local events never fetch Cursor's API.
    /// Pending requests union, and a full request takes precedence over any targeted requests.
    public func reload(providers: Set<ProviderID>? = nil) {
        if let providers { pendingProviders.formUnion(providers) }
        else { fullReloadPending = true }
        guard loadTask == nil, fullReloadPending || !pendingProviders.isEmpty else { return }
        let full = fullReloadPending
        let requested = full ? Set(ProviderID.allCases) : pendingProviders
        let refreshOthers = requested.contains { $0 != .claude && $0 != .codex }
        pendingProviders = []
        fullReloadPending = false
        let cursorEnabled = includeCursor()
        if !cursorEnabled { (cursorDays, cursorFetchedAt) = (nil, nil) }
        let fetchCursor = full && cursorEnabled && (cursorFetchedAt.map { Date().timeIntervalSince($0) >= Self.cursorStaleAfter } ?? true)
        loadTask = Task { [weak self] in
            let (local, fetchedCursor) = await withBackgroundActivity(reason: "Scanning local spend history") {
                await Task.detached(priority: .userInitiated) { () -> ([SpendSource: [UsageDay]], [UsageDay]?) in
                    var result: [SpendSource: [UsageDay]] = [:]
                    if requested.contains(.claude) { result[.provider(.claude)] = ClaudeUsageHistoryScanner.dailyUsage(days: 30) }
                    if requested.contains(.codex) { result[.provider(.codex)] = CodexUsageHistoryScanner.dailyUsage(days: 30) }
                    if refreshOthers { result.merge(LocalUsageHistoryScanner.dailyUsage(days: 30)) { _, new in new } }
                    let cursor = fetchCursor ? await CursorUsageHistory.dailyUsage(days: 30) : nil
                    return (result, cursor)
                }.value
            }
            guard let self, !Task.isCancelled else { return }
            let now = Date()
            if fetchCursor {
                cursorFetchedAt = now
                if let fetchedCursor { cursorDays = fetchedCursor }
            }
            var result = daysBySource
            if refreshOthers {
                // The other-source scanner returns only sources that still have history. Remove
                // deleted logs/services too, while leaving untargeted Claude/Codex data intact.
                result = result.filter { $0.key == .provider(.claude) || $0.key == .provider(.codex) }
            }
            result.merge(local) { _, new in new }
            // Cursor's account history already includes locally logged Cursor calls.
            if let cursorDays { result[.provider(.cursor)] = cursorDays }
            var activities = activityByProvider
            for provider in ProviderID.allCases {
                var activity = activities[provider] ?? LiveUsageActivity()
                activity.observe(result[.provider(provider)]?.last, now: now)
                activities[provider] = activity
            }
            daysBySource = result
            activityByProvider = activities
            isLoading = false
            lastLoadedAt = now
            loadTask = nil
            if fullReloadPending || !pendingProviders.isEmpty { reload(providers: []) }
        }
    }
}
