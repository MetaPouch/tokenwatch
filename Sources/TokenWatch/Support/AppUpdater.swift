import Sparkle
import UserNotifications

/// Wraps Sparkle's `SPUStandardUpdaterController`: a scheduled background check against
/// `SUFeedURL` (see `Info.plist`) plus Sparkle's own built-in UI for "update available",
/// download progress, and restart-to-install -- no custom UI here. Checking never installs
/// anything without an explicit click; `SUEnableSystemProfiling` is left unset (defaults off),
/// so the check request carries no system-profile data, matching the app's no-telemetry stance
/// (see SECURITY.md).
///
/// One-time setup before this can actually serve an update: `DISTRIBUTION.md`'s "Auto-update
/// (Sparkle)" section -- an EdDSA keypair and a populated `docs/appcast.xml`. Without those,
/// `SPUStandardUpdaterController` starts but every check silently finds nothing (invalid/missing
/// public key disables verification, and a 404 feed just means "no update"), so shipping this
/// before that setup is safe, not just inert.
///
/// Also implements Sparkle's gentle-reminder delegate (`SPUStandardUserDriverDelegate`): as an
/// `LSUIElement` menu-bar agent with no Dock icon, a scheduled background check that finds an
/// update would otherwise show Sparkle's alert window off-screen behind everything with no
/// visible cue (Sparkle logs a warning about exactly this if a background app doesn't opt in --
/// see https://sparkle-project.org/documentation/gentle-reminders). `pendingUpdate` lets
/// `DashboardView` swap the ⋯ menu's "Check for Updates…" item for "Update Available…" so it's
/// noticeable without stealing focus or adding a Dock icon; a local notification is posted too,
/// but only if notification permission was already granted for some other reason (quota alerts)
/// -- this never requests permission on its own, matching the project's "ask only when a toggle
/// is explicitly turned on" stance (see `QuotaNotificationService`).
@MainActor
public final class AppUpdater: NSObject, ObservableObject {
    static let updateNotificationIdentifier = "dev.tokenwatch.updateAvailable"

    private var controller: SPUStandardUpdaterController!

    /// Mirrors `SPUUpdater.automaticallyChecksForUpdates` (backed by the `SUEnableAutomaticChecks`
    /// user default) so `SettingsView` can bind a `Toggle` without holding a reference to Sparkle
    /// types directly.
    @Published public var automaticallyChecksForUpdates: Bool = false {
        didSet {
            controller.updater.automaticallyChecksForUpdates = automaticallyChecksForUpdates
        }
    }

    /// Non-nil while a scheduled (non-user-initiated) check found an update that Sparkle is
    /// deferring to us to announce gently, per `standardUserDriverWillHandleShowingUpdate`
    /// below. Cleared once the user brings it into focus or the update session ends.
    @Published public private(set) var pendingUpdate: SUAppcastItem?

    public override init() {
        super.init()
        // `controller` is an implicitly-unwrapped optional specifically so it can default to
        // nil during phase-1 init -- `self` (needed below as `userDriverDelegate`) isn't usable
        // until `super.init()` has run, and `controller` is the property that needs it.
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: self)
        automaticallyChecksForUpdates = controller.updater.automaticallyChecksForUpdates
    }

    /// Wired to the "Check for Updates…" / "Update Available…" menu item -- always
    /// user-initiated, shows Sparkle's standard progress/result UI regardless of the
    /// automatic-checks setting above. If `pendingUpdate` is already set, this brings that same
    /// alert into focus rather than starting a redundant check.
    public func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}

extension AppUpdater: @preconcurrency SPUStandardUserDriverDelegate {
    public var supportsGentleScheduledUpdateReminders: Bool { true }

    /// Let Sparkle handle it normally only when it proposes immediate, utmost focus (e.g. an
    /// update found shortly after launch); everything else -- the common case for a background
    /// agent whose scheduled check runs while nothing is watching -- we announce gently instead.
    public func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
        immediateFocus
    }

    public func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        guard !handleShowingUpdate else { return }
        pendingUpdate = update

        let identifier = Self.updateNotificationIdentifier
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized else { return }
            let content = UNMutableNotificationContent()
            content.title = "TokenWatch Update Available"
            content.body = "Version \(update.displayVersionString) is ready to install."
            content.sound = .default
            let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
            UNUserNotificationCenter.current().add(request)
        }
    }

    public func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        pendingUpdate = nil
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [AppUpdater.updateNotificationIdentifier])
    }

    public func standardUserDriverWillFinishUpdateSession() {
        pendingUpdate = nil
    }
}
