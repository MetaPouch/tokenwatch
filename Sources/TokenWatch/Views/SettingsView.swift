import SwiftUI
import AppKit
import TokenWatchCore

/// Lists every `ProviderID` with an enable/disable toggle; `APIKeyManaging` providers get a
/// secure text field wired to `saveAPIKey`/`deleteAPIKey`; a stepper controls the refresh
/// interval. The leaderboard has its own screen (`LeaderboardView`).
struct SettingsView: View {
    @ObservedObject var enablementStore: ProviderEnablementStore
    @ObservedObject var detectionStore: ProviderDetectionStore
    let apiKeyManagers: [ProviderID: any APIKeyManaging]
    @ObservedObject var displayStore: MeterDisplayStore
    @ObservedObject var appearanceStore: AppearanceStore
    @ObservedObject var notificationSettingsStore: NotificationSettingsStore
    let notificationService: QuotaNotificationService
    let toggleDashboardPanel: () -> Void

    @State private var apiKeyDrafts: [ProviderID: String] = [:]
    @State private var apiKeyErrors: [ProviderID: String] = [:]
    @State private var launchAtLoginEnabled = LaunchAtLogin.isEnabled
    @State private var shortcutCombo = KeyCombo.loadPersisted()

    var body: some View {
        MeasuredScrollView(maxHeight: 640, refreshID: detectionStore.detections.count) {
            VStack(alignment: .leading, spacing: 14) {
                SettingsSection("General") {
                    Toggle("Show Total Spend", isOn: $displayStore.showTotalSpend)
                        .help("Whether the Total Spend card, with its last-7-days chart, shows at the top of the Usage tab.")
                    Toggle("Launch at Login", isOn: Binding(
                        get: { launchAtLoginEnabled },
                        set: { newValue in
                            LaunchAtLogin.setEnabled(newValue)
                            launchAtLoginEnabled = LaunchAtLogin.isEnabled
                        }
                    ))
                    HStack {
                        Text("Global Shortcut")
                        Spacer()
                        ShortcutRecorderField(combo: $shortcutCombo) { newCombo in
                            KeyCombo.persist(newCombo)
                            GlobalHotKeyManager.shared.unregister()
                            if let newCombo {
                                GlobalHotKeyManager.shared.register(combo: newCombo, action: toggleDashboardPanel)
                            }
                        }
                    }
                    .help("A global shortcut that toggles the popover from anywhere.")
                }

                SettingsSection("Menu Bar") {
                    Picker("Icon Style", selection: $appearanceStore.iconStyle) {
                        ForEach(MenuBarIconStyle.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .help("Bars needs at least one bounded metric starred for the menu bar (right-click a row -> Star for menu bar) -- with nothing starred, Bars looks identical to Text.")
                    ForEach(MenuBarValue.allCases) { value in
                        Toggle(value.title, isOn: Binding(
                            get: { appearanceStore.menuBarValues.contains(value) },
                            set: { selected in
                                if selected { appearanceStore.menuBarValues.insert(value) }
                                else { appearanceStore.menuBarValues.remove(value) }
                            }
                        ))
                        .toggleStyle(.checkbox)
                        .help(value.help)
                    }
                    Text("Choose any combination. With nothing selected, only the app icon is shown.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                SettingsSection("Appearance") {
                    Picker("Theme", selection: $appearanceStore.theme) {
                        ForEach(AppTheme.allCases) { Text($0.rawValue).tag($0) }
                    }
                    Picker("Density", selection: $appearanceStore.density) {
                        ForEach(AppDensity.allCases) { Text($0.rawValue).tag($0) }
                    }
                    Picker("Time Format", selection: $appearanceStore.timeFormat) {
                        ForEach(TimeFormatPreference.allCases) { Text($0.rawValue).tag($0) }
                    }
                    Toggle("Reduce Animations", isOn: $appearanceStore.reduceAnimations)
                    Toggle("Increase Transparency", isOn: $appearanceStore.increaseTransparency)
                        .disabled(NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency)
                        .help(NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency ? "Disabled while macOS's own Reduce Transparency setting is on." : "")
                    Toggle("Hide From Screen Share", isOn: $appearanceStore.hideFromScreenShare)
                        .help("Excludes the popover from screen recordings and screen sharing.")
                }

                SettingsSection("Notifications") {
                    Toggle("Almost Out", isOn: notificationToggle(\.almostOut))
                        .help("Alerts when a metric crosses under 10% remaining.")
                    Toggle("Cutting It Close", isOn: notificationToggle(\.cuttingItClose))
                        .help("Alerts when a metric is projected to finish the period with little left.")
                    Toggle("Will Run Out", isOn: notificationToggle(\.willRunOut))
                        .help("Alerts when a metric is projected to run out before it resets.")
                    if notificationService.permissionDenied {
                        HStack {
                            Label("Notifications are blocked in System Settings", systemImage: "exclamationmark.triangle.fill")
                                .font(.caption)
                                .foregroundStyle(.orange)
                            Spacer()
                            Button("Open System Settings") {
                                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") {
                                    NSWorkspace.shared.open(url)
                                }
                            }
                            .font(.caption)
                        }
                    }
                }

                SettingsSection("Refresh Interval") {
                    Stepper(
                        "\(enablementStore.refreshIntervalSeconds) seconds",
                        value: Binding(
                            get: { enablementStore.refreshIntervalSeconds },
                            set: { enablementStore.setRefreshIntervalSeconds($0) }
                        ),
                        in: 60...1800,
                        step: 30
                    )
                }

                SettingsSection("Providers") {
                    ForEach(ProviderID.allCases) { provider in
                        providerRow(provider)
                        if provider != ProviderID.allCases.last {
                            Divider()
                        }
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .reportPanelHeight(for: .settings)
    }

    private func notificationToggle(_ keyPath: ReferenceWritableKeyPath<NotificationSettingsStore, Bool>) -> Binding<Bool> {
        Binding(
            get: { notificationSettingsStore[keyPath: keyPath] },
            set: { newValue in
                notificationSettingsStore[keyPath: keyPath] = newValue
                if newValue { notificationService.requestPermissionIfNeeded() }
            }
        )
    }

    @ViewBuilder
    private func providerRow(_ provider: ProviderID) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(
                provider.displayName,
                isOn: Binding(
                    get: { enablementStore.isEnabled(provider) },
                    set: { enablementStore.setEnabled(provider, $0) }
                )
            )
            if let detection = detectionStore.detections[provider] {
                Label("Found on this Mac · \(detection.source)", systemImage: "checkmark.circle.fill")
                    .font(.caption2)
                    .foregroundStyle(.green)
            } else {
                Text(provider.credentialSourceHint)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if let manager = apiKeyManagers[provider] {
                apiKeyField(provider: provider, manager: manager)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func apiKeyField(provider: ProviderID, manager: any APIKeyManaging) -> some View {
        HStack {
            SecureField("API key", text: draftBinding(for: provider))
                .textFieldStyle(.roundedBorder)
            Button("Save") {
                guard let key = apiKeyDrafts[provider], !key.isEmpty else { return }
                do {
                    try manager.saveAPIKey(key)
                    apiKeyDrafts[provider] = ""
                    apiKeyErrors[provider] = nil
                } catch {
                    apiKeyErrors[provider] = "Couldn't save: \(error.localizedDescription)"
                }
            }
            if manager.keyStatus() != .notSet {
                Button("Clear") {
                    do {
                        try manager.deleteAPIKey()
                        apiKeyDrafts[provider] = ""
                        apiKeyErrors[provider] = nil
                    } catch {
                        apiKeyErrors[provider] = "Couldn't clear: \(error.localizedDescription)"
                    }
                }
            }
        }
        Text(statusText(manager.keyStatus()))
            .font(.caption2)
            .foregroundStyle(.secondary)
        if let error = apiKeyErrors[provider] {
            Text(error)
                .font(.caption2)
                .foregroundStyle(.red)
        }
    }

    private func draftBinding(for provider: ProviderID) -> Binding<String> {
        Binding(
            get: { apiKeyDrafts[provider] ?? "" },
            set: { apiKeyDrafts[provider] = $0 }
        )
    }

    private func statusText(_ status: APIKeyStatus) -> String {
        switch status {
        case .notSet: return "Not set"
        case .fromEnvironment: return "Using environment variable"
        case .saved: return "Saved in Keychain"
        }
    }
}

/// A titled card: an uppercase caption over a softly filled rounded box. Settings' sections and
/// the Leaderboard screen's groups.
struct SettingsSection<Content: View>: View {
    let title: String
    let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            VStack(alignment: .leading, spacing: 10) {
                content
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
        }
    }
}
