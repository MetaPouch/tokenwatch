import SwiftUI
import AppKit
import TokenWatchCore

/// Popover root: one panel, three screens (Dashboard / Customize / Settings) that slide
/// horizontally within it -- a shared top bar and footer stay fixed while the middle content
/// slides, and the panel resizes to fit whichever screen is currently showing (see
/// `TokenWatchPanel.setContentHeight` and `PanelHeightPreferenceKey`). Every enabled provider
/// renders stacked in one scrollable list on the Dashboard screen, in `LayoutStore` order.
struct DashboardView: View {
    @ObservedObject var dataStore: WidgetDataStore
    @ObservedObject var enablementStore: ProviderEnablementStore
    @ObservedObject var refreshScheduler: RefreshScheduler
    let apiKeyManagers: [ProviderID: any APIKeyManaging]
    @ObservedObject var usageService: MultiAccountUsageService
    @ObservedObject var layoutStore: LayoutStore
    @ObservedObject var displayStore: MeterDisplayStore
    @ObservedObject var appearanceStore: AppearanceStore
    @ObservedObject var notificationSettingsStore: NotificationSettingsStore
    let notificationService: QuotaNotificationService
    let toggleDashboardPanel: () -> Void
    /// Reports this view's total natural height (top bar + current screen + footer) so the
    /// hosting `TokenWatchPanel` can resize to fit it.
    let onHeightChange: (CGFloat) -> Void

    @State private var currentScreen: DashboardScreen = .dashboard
    @State private var customizeDetailProvider: ProviderID?
    @State private var selectedTab: DashboardTab = .provider
    @State private var screenHeights: [DashboardScreen: CGFloat] = [:]

    private enum DashboardTab: Hashable {
        case provider, usage
    }

    private let topBarHeight: CGFloat = 44
    private let footerHeight: CGFloat = 30
    private let maxContentHeight: CGFloat = 640

    var body: some View {
        VStack(spacing: 0) {
            topBar
                .frame(height: topBarHeight)
            Divider()
            pager
            Divider()
            footer
                .frame(height: footerHeight)
        }
        .frame(width: TokenWatchPanel.width)
        .background(appearanceStore.increaseTransparency && !NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency ? AnyShapeStyle(.ultraThinMaterial) : AnyShapeStyle(.regularMaterial))
        .preferredColorScheme(appearanceStore.theme.colorScheme)
        .environment(\.appDensity, appearanceStore.density)
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.escape) {
            handleEscape()
            return .handled
        }
        .onKeyPress(.return) {
            handleReturn()
            return .handled
        }
        .onKeyPress("r", phases: .down) { press in
            guard press.modifiers == .command else { return .ignored }
            refreshScheduler.refreshNow()
            return .handled
        }
        .onKeyPress(",", phases: .down) { press in
            guard press.modifiers == .command else { return .ignored }
            currentScreen = currentScreen == .settings ? .dashboard : .settings
            return .handled
        }
        .onKeyPress("z", phases: .down) { press in
            guard press.modifiers == .command else { return .ignored }
            layoutStore.undo()
            return .handled
        }
        .onChange(of: currentScreen) { _, newScreen in
            reportTotalHeight(for: newScreen)
        }
    }

    // MARK: - Pager

    private var pager: some View {
        HStack(alignment: .top, spacing: 0) {
            dashboardScreenContent.frame(width: TokenWatchPanel.width, alignment: .top)
            customizeScreenContent.frame(width: TokenWatchPanel.width, alignment: .top)
            settingsScreenContent.frame(width: TokenWatchPanel.width, alignment: .top)
        }
        .offset(x: -CGFloat(currentScreen.rawValue) * TokenWatchPanel.width)
        .animation(appearanceStore.reduceAnimations ? nil : .spring(response: 0.35, dampingFraction: 0.88), value: currentScreen)
        .frame(width: TokenWatchPanel.width, height: screenHeights[currentScreen] ?? 300, alignment: .topLeading)
        .clipped()
        .onPreferenceChange(PanelHeightPreferenceKey.self) { heights in
            screenHeights = heights
            reportTotalHeight(for: currentScreen)
        }
    }

    private var dashboardScreenContent: some View {
        Group {
            if orderedEnabledProviders.isEmpty {
                emptyState
            } else {
                VStack(spacing: 0) {
                    tabSwitcher
                    Divider()
                    switch selectedTab {
                    case .provider:
                        providerList
                    case .usage:
                        UsageTabView(usageService: usageService, displayStore: displayStore, maxContentHeight: maxContentHeight)
                    }
                }
            }
        }
        .reportPanelHeight(for: .dashboard)
    }

    private var customizeScreenContent: some View {
        CustomizeView(enablementStore: enablementStore, layoutStore: layoutStore, dataStore: dataStore, detailProvider: $customizeDetailProvider)
    }

    private var settingsScreenContent: some View {
        SettingsView(enablementStore: enablementStore, apiKeyManagers: apiKeyManagers, displayStore: displayStore, appearanceStore: appearanceStore, notificationSettingsStore: notificationSettingsStore, notificationService: notificationService, toggleDashboardPanel: toggleDashboardPanel)
    }

    private func reportTotalHeight(for screen: DashboardScreen) {
        let contentHeight = screenHeights[screen] ?? 300
        // top bar + divider + content + divider + footer, matching the hairline dividers'
        // actual rendered thickness (~1pt each) so the panel doesn't over/under-shoot by a hair.
        onHeightChange(topBarHeight + 1 + contentHeight + 1 + footerHeight)
    }

    // MARK: - Top bar (shared chrome; content depends on `currentScreen`)

    private var topBar: some View {
        HStack {
            if currentScreen != .dashboard {
                Button(action: goBack) {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(.plain)
            }
            Text(topBarTitle)
                .font(.title3.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer()
            switch currentScreen {
            case .dashboard:
                Button(action: { refreshScheduler.refreshNow() }) {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .disabled(dataStore.isRefreshing)
            case .customize:
                if customizeDetailProvider != nil {
                    Button("Reset") { layoutStore.resetProvider(customizeDetailProvider!) }
                        .font(.caption)
                } else {
                    Button("Reset All", role: .destructive) { layoutStore.resetAll() }
                        .font(.caption)
                }
            case .settings:
                EmptyView()
            }
        }
        .padding(.horizontal, 14)
    }

    private var topBarTitle: String {
        switch currentScreen {
        case .dashboard: return "TokenWatch"
        case .customize: return customizeDetailProvider?.displayName ?? "Customize"
        case .settings: return "Settings"
        }
    }

    /// One level back: Customize's detail returns to its provider list; the provider list or
    /// Settings returns to the dashboard. Matches the documented Esc/Return semantics.
    private func goBack() {
        switch currentScreen {
        case .dashboard:
            break
        case .customize:
            if customizeDetailProvider != nil {
                customizeDetailProvider = nil
            } else {
                currentScreen = .dashboard
            }
        case .settings:
            currentScreen = .dashboard
        }
    }

    private func handleEscape() {
        if currentScreen == .dashboard {
            toggleDashboardPanel()
        } else {
            goBack()
        }
    }

    private func handleReturn() {
        if currentScreen == .dashboard {
            customizeDetailProvider = nil
            currentScreen = .customize
        } else {
            goBack()
        }
    }

    // MARK: - Footer (shared chrome: version + next-refresh countdown, Options menu)

    private var footer: some View {
        HStack(spacing: 6) {
            Button(action: { refreshScheduler.refreshNow() }) {
                HStack(spacing: 4) {
                    Text("TokenWatch \(AppVersion.displayString)")
                    if let nextRefreshAt = refreshScheduler.nextRefreshAt {
                        Text("·").foregroundStyle(.tertiary)
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            Text("Next update in \(Self.countdownText(until: nextRefreshAt, now: context.date))")
                        }
                    }
                }
            }
            .buttonStyle(.plain)
            .help("Click to refresh now (⌘R)")
            Spacer()
            Menu {
                Button("Customize") { customizeDetailProvider = nil; currentScreen = .customize }
                Button("Settings") { currentScreen = .settings }
                if !orderedEnabledProviders.isEmpty {
                    Menu("Share Screenshot") {
                        ForEach(orderedEnabledProviders) { provider in
                            Button(provider.displayName) { shareScreenshot(provider) }
                        }
                    }
                }
                Divider()
                Button("About TokenWatch") { NSApp.orderFrontStandardAboutPanel(nil) }
                Divider()
                Button("Quit TokenWatch") { NSApplication.shared.terminate(nil) }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
    }

    private func shareScreenshot(_ provider: ProviderID) {
        guard let snapshot = dataStore.snapshot(for: provider) else { return }
        ProviderScreenshot.share(provider: provider, snapshot: snapshot, displayStore: displayStore, density: appearanceStore.density, timeFormat: appearanceStore.timeFormat)
    }

    private static func countdownText(until date: Date, now: Date) -> String {
        let remaining = max(0, date.timeIntervalSince(now))
        if remaining < 60 { return "\(Int(remaining))s" }
        let minutes = Int(remaining / 60)
        let seconds = Int(remaining.truncatingRemainder(dividingBy: 60))
        return seconds > 0 ? "\(minutes)m \(seconds)s" : "\(minutes)m"
    }

    // MARK: - Dashboard screen content

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
        MeasuredScrollView(maxHeight: maxContentHeight, refreshID: "\(orderedEnabledProviders.count)-\(dataStore.snapshots.count)") {
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
                        onCustomizeProvider: { customizeDetailProvider = provider; currentScreen = .customize }
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
        }
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
            Button("Open Settings") { currentScreen = .settings }
            Spacer()
        }
        .frame(maxWidth: .infinity, minHeight: 260)
        .reportPanelHeight(for: .dashboard)
    }
}
