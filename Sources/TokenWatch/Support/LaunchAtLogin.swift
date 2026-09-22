import ServiceManagement

/// Registers/unregisters TokenWatch as a login item via `SMAppService` (first-party
/// `ServiceManagement`, macOS 13+) -- the modern replacement for the old `SMLoginItemSetEnabled`/
/// LaunchAgent approach. No external dependency; the system's login-item registry is the source
/// of truth (`isEnabled` always reflects it directly, never a locally cached guess).
enum LaunchAtLogin {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Best-effort: `register()`/`unregister()` can throw (e.g. running from outside
    /// `/Applications`, or a `swift run` dev build with no login-item plist entry to register).
    /// There's nothing actionable to surface to the user beyond the toggle simply not taking
    /// effect, which `isEnabled` already reflects on the next read.
    static func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            // Best-effort; see doc comment above.
        }
    }
}
