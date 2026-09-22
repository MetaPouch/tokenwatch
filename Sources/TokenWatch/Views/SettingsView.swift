import SwiftUI
import AppKit
import TokenWatchCore

/// Lists every `ProviderID` with an enable/disable toggle; `APIKeyManaging` providers get a
/// secure text field wired to `saveAPIKey`/`deleteAPIKey`; a stepper controls the refresh
/// interval.
struct SettingsView: View {
    @ObservedObject var enablementStore: ProviderEnablementStore
    let apiKeyManagers: [ProviderID: any APIKeyManaging]
    @ObservedObject var displayStore: MeterDisplayStore
    @ObservedObject var appearanceStore: AppearanceStore
    let toggleDashboardPanel: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var apiKeyDrafts: [ProviderID: String] = [:]
    @State private var launchAtLoginEnabled = LaunchAtLogin.isEnabled
    @State private var shortcutCombo = KeyCombo.loadPersisted()

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Settings").font(.title3.weight(.semibold))
                Spacer()
                Button("Done") { dismiss() }
            }
            .padding(14)
            Divider()

            Form {
                Section("General") {
                    Toggle("Show Total Spend", isOn: $displayStore.showTotalSpend)
                        .help("Whether the cross-provider Total Spend card shows at the top of the dashboard.")
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

                Section("Appearance") {
                    Picker("Icon Style", selection: $appearanceStore.iconStyle) {
                        ForEach(MenuBarIconStyle.allCases) { Text($0.rawValue).tag($0) }
                    }
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
                }

                Section("Refresh interval") {
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


                Section("Providers") {
                    ForEach(ProviderID.allCases) { provider in
                        providerRow(provider)
                    }
                }
            }
            .formStyle(.grouped)
        }
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
            Text(provider.credentialSourceHint)
                .font(.caption2)
                .foregroundStyle(.secondary)

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
                try? manager.saveAPIKey(key)
                apiKeyDrafts[provider] = ""
            }
            if manager.keyStatus() != .notSet {
                Button("Clear") {
                    try? manager.deleteAPIKey()
                    apiKeyDrafts[provider] = ""
                }
            }
        }
        Text(statusText(manager.keyStatus()))
            .font(.caption2)
            .foregroundStyle(.secondary)
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
