import UserNotifications
import TokenWatchCore

/// Bridges `QuotaNotificationEvaluator`'s pure pace-crossing logic to real macOS notifications.
/// Requests permission the first time any trigger is turned on (never eagerly at launch) and
/// tracks whether permission was denied so Settings can surface a warning + a way to open System
/// Settings, matching the documented permission flow.
@MainActor
final class QuotaNotificationService: ObservableObject {
    private let evaluator = QuotaNotificationEvaluator()
    private let settingsStore: NotificationSettingsStore
    @Published private(set) var permissionDenied = false

    init(settingsStore: NotificationSettingsStore) {
        self.settingsStore = settingsStore
    }

    func requestPermissionIfNeeded() {
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
            switch settings.authorizationStatus {
            case .notDetermined:
                UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
                    Task { @MainActor [weak self] in self?.permissionDenied = !granted }
                }
            case .denied:
                Task { @MainActor [weak self] in self?.permissionDenied = true }
            default:
                Task { @MainActor [weak self] in self?.permissionDenied = false }
            }
        }
    }

    /// Runs every bounded metric in `snapshots` through the evaluator and delivers any newly-
    /// tripped alerts. Call once per refresh cycle -- the evaluator's own dedup means calling
    /// this redundantly is harmless (no-op), never a duplicate notification.
    func evaluate(snapshots: [ProviderID: ProviderSnapshot]) {
        guard settingsStore.anyEnabled else { return }
        let settings = settingsStore.settings
        for (provider, snapshot) in snapshots {
            for line in snapshot.lines {
                guard case let .progress(id, label, used, limit, _, resetsAt, periodDurationMs) = line else { continue }
                let alerts = evaluator.evaluate(provider: provider, metricID: id, label: label, used: used, limit: limit, resetsAt: resetsAt, periodDurationMs: periodDurationMs, settings: settings)
                for alert in alerts { deliver(alert) }
            }
        }
    }

    private func deliver(_ alert: QuotaAlert) {
        let content = UNMutableNotificationContent()
        content.title = alert.trigger.rawValue
        content.subtitle = "\(alert.provider.displayName) — \(alert.metricLabel)"
        content.body = alert.body
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
