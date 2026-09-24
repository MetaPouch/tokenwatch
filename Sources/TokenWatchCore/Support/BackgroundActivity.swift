import Foundation

/// Runs `work` while explicitly telling macOS this activity should not be App Nap-throttled.
/// Measured directly: a local session-log scan this menu-bar (`LSUIElement`) app kicks off in
/// the background can take 10x+ longer here than the identical work in a normal foreground
/// process -- `Task.detached(priority: .userInitiated)` alone was not enough to avoid it, since
/// App Nap throttling applies at the process level, not per-task. Used for local history scans
/// (filesystem events, visible UI, the leaderboard's history backfill), not for the
/// independently scheduled remote quota loop.
public func withBackgroundActivity<T>(reason: String, _ work: () async throws -> T) async rethrows -> T {
    let activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated], reason: reason)
    defer { ProcessInfo.processInfo.endActivity(activity) }
    return try await work()
}
