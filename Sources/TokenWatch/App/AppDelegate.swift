import AppKit

/// Menu-bar agent app: no Dock icon, no main window. `applicationDidFinishLaunching` creates the
/// status item and starts the refresh loop.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let hasLaunchedBeforeKey = "dev.tokenwatch.hasLaunchedBefore"

    private var container: AppContainer!
    private var statusItemController: StatusItemController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let container = AppContainer()
        self.container = container
        self.statusItemController = StatusItemController(container: container)
        container.start()
        container.toggleDashboardPanel = { [weak statusItemController] in statusItemController?.togglePanel() }

        if let combo = KeyCombo.loadPersisted() {
            GlobalHotKeyManager.shared.register(combo: combo) { [weak statusItemController] in
                statusItemController?.togglePanel()
            }
        }

        // First launch ever: the status item alone (a bare, low-key ring with nothing enabled
        // yet to show) is easy for a brand-new install to miss entirely -- surface the panel
        // once, unprompted, so "nothing happened when I opened the app" isn't the first
        // impression. Every later launch leaves discovery to the status item, same as today.
        let defaults = UserDefaults.standard
        if !defaults.bool(forKey: Self.hasLaunchedBeforeKey) {
            defaults.set(true, forKey: Self.hasLaunchedBeforeKey)
            statusItemController.showPanel()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        container.refreshScheduler.stop()
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }
}
