import SwiftUI
import AppKit
import TokenWatchCore

/// Popover content: every enabled provider stacked in one scrollable list (in `LayoutStore`
/// order), each rendered by `ProviderSectionView`, instead of a picker showing one at a time.
struct DashboardView: View {
    @ObservedObject var dataStore: WidgetDataStore
    @ObservedObject var enablementStore: ProviderEnablementStore
    let refreshScheduler: RefreshScheduler
    let apiKeyManagers: [ProviderID: any APIKeyManaging]
    @ObservedObject var usageService: MultiAccountUsageService
    @ObservedObject var layoutStore: LayoutStore
    @ObservedObject var displayStore: MeterDisplayStore
    @ObservedObject var appearanceStore: AppearanceStore
    @ObservedObject var notificationSettingsStore: NotificationSettingsStore
    let notificationService: QuotaNotificationService
    let toggleDashboardPanel: () -> Void

    @State private var showingSettings = false
    @State private var showingCustomize = false
    @State private var customizeInitialProvider: ProviderID?
    @State private var selectedTab: DashboardTab = .provider

    private enum DashboardTab: Hashable {
        case provider, usage
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if orderedEnabledProviders.isEmpty {
                emptyState
            } else {
                tabSwitcher
                Divider()
                switch selectedTab {
                case .provider:
                    providerList
                case .usage:
                    UsageTabView(usageService: usageService, displayStore: displayStore)
                }
            }
        }
        .frame(width: 360, height: 480)
        .background(appearanceStore.increaseTransparency && !NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency ? AnyShapeStyle(.ultraThinMaterial) : AnyShapeStyle(.regularMaterial))
        .preferredColorScheme(appearanceStore.theme.colorScheme)
        .environment(\.appDensity, appearanceStore.density)
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.escape) {
            if showingSettings { showingSettings = false; return .handled }
            if showingCustomize { showingCustomize = false; return .handled }
            toggleDashboardPanel()
            return .handled
        }
        .onKeyPress(.return) {
            guard !showingSettings, !showingCustomize else { return .ignored }
            customizeInitialProvider = nil
            showingCustomize = true
            return .handled
        }
        .onKeyPress("r", phases: .down) { press in
            guard press.modifiers == .command, !showingSettings, !showingCustomize else { return .ignored }
            refreshScheduler.refreshNow()
            return .handled
        }
        .onKeyPress(",", phases: .down) { press in
            guard press.modifiers == .command, !showingCustomize else { return .ignored }
            showingSettings.toggle()
            return .handled
        }
        .onKeyPress("z", phases: .down) { press in
            guard press.modifiers == .command else { return .ignored }
            layoutStore.undo()
            return .handled
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView(enablementStore: enablementStore, apiKeyManagers: apiKeyManagers, displayStore: displayStore, appearanceStore: appearanceStore, notificationSettingsStore: notificationSettingsStore, notificationService: notificationService, toggleDashboardPanel: toggleDashboardPanel)
                .frame(width: 380, height: 460)
        }
        .sheet(isPresented: $showingCustomize) {
            CustomizeView(initialProvider: customizeInitialProvider, enablementStore: enablementStore, layoutStore: layoutStore, dataStore: dataStore)
                .frame(width: 380, height: 460)
        }
    }

    private var tabSwitcher: some View {
        Picker("", selection: $selectedTab) {
            Text("Provider").tag(DashboardTab.provider)
            Text("Usage").tag(DashboardTab.usage)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .padding(.bottom, 2)
    }

    private var orderedEnabledProviders: [ProviderID] {
        layoutStore.orderedProviders(enabled: enablementStore.enabledProviders)
    }

    private var providerList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                TotalSpendCard(dataStore: dataStore, enablementStore: enablementStore, displayStore: displayStore)
                ForEach(orderedEnabledProviders) { provider in
                    ProviderSectionView(
                        provider: provider,
                        snapshot: dataStore.snapshot(for: provider),
                        layoutStore: layoutStore,
                        displayStore: displayStore,
                        refreshIntervalSeconds: enablementStore.refreshIntervalSeconds,
                        timeFormat: appearanceStore.timeFormat,
                        onRefresh: { refreshScheduler.refreshProvider(provider) },
                        onHideProvider: { enablementStore.setEnabled(provider, false) },
                        onCustomizeProvider: { customizeInitialProvider = provider; showingCustomize = true }
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
        }
    }

    private var header: some View {
        HStack {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text("TokenWatch").font(.title3.weight(.semibold))
                Text("v\(AppVersion.displayString)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .help("TokenWatch \(AppVersion.displayString)")
            }
            Spacer()
            Button {
                refreshScheduler.refreshNow()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.plain)
            .disabled(dataStore.isRefreshing)
            Button {
                showingSettings = true
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.plain)
            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.plain)
            .font(.caption)
        }
        .padding(14)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "tray")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("No providers enabled")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button("Open Settings") { showingSettings = true }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}
