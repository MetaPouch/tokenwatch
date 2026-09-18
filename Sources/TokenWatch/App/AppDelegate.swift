import AppKit

/// Menu-bar agent app: no Dock icon, no main window. `applicationDidFinishLaunching` creates the
/// status item and starts the refresh loop.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var container: AppContainer!
    private var statusItemController: StatusItemController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let container = AppContainer()
        self.container = container
        self.statusItemController = StatusItemController(container: container)
        container.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        container.refreshScheduler.stop()
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }
}
