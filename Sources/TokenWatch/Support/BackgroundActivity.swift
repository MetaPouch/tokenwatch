import Foundation

/// Runs `work` while explicitly telling macOS this activity should not be App Nap-throttled.
/// Measured directly: a local session-log scan this menu-bar (`LSUIElement`) app kicks off in
/// the background can take 10x+ longer here than the identical work in a normal foreground
/// process -- `Task.detached(priority: .userInitiated)` alone was not enough to avoid it, since
/// App Nap throttling applies at the process level, not per-task. Use for background work that
/// gates visible UI content a user is actively waiting on (a scan feeding a dashboard card),
/// not for the periodic provider-refresh loop, which is fine running at its own pace unobserved.
func withBackgroundActivity<T>(reason: String, _ work: () async -> T) async -> T {
    let activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated], reason: reason)
    defer { ProcessInfo.processInfo.endActivity(activity) }
    return await work()
}
