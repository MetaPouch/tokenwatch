import Foundation
import Combine
import TokenWatchCore

/// Shared, load-once cache of Claude's local spend history (`ClaudeUsageHistoryScanner`) --
/// several views want the same 30-day window at once (the cross-provider Total Spend card, and
/// each Claude provider card's own inline Today/Yesterday spend row), and the scan itself is real
/// disk I/O proportional to local session history. One shared load instead of one per observer.
@MainActor
public final class ClaudeSpendHistoryStore: ObservableObject {
    @Published public private(set) var days: [ClaudeUsageDay] = []
    @Published public private(set) var isLoading = true

    private var loadTask: Task<Void, Never>?

    public init() {}

    /// Kicks off the scan at most once; subsequent calls while loading or after completion are
    /// no-ops, so every observer can call this unconditionally from its own `.task`.
    public func loadIfNeeded() {
        guard loadTask == nil else { return }
        loadTask = Task { [weak self] in
            let result = await withBackgroundActivity(reason: "Scanning local Claude spend history") {
                await Task.detached(priority: .userInitiated) {
                    ClaudeUsageHistoryScanner.dailyUsage(days: 30)
                }.value
            }
            self?.days = result
            self?.isLoading = false
        }
    }
}
