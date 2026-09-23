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
    @ObservedObject var spendHistoryStore: SpendHistoryStore
    @ObservedObject var hintStore: HintStore
    let notificationService: QuotaNotificationService
    let toggleDashboardPanel: () -> Void
    /// Reports this view's total natural height (top bar + current screen + footer) so the
    /// hosting `TokenWatchPanel` can resize to fit it.
    let onHeightChange: (CGFloat) -> Void

    @Environment(\.colorScheme) private var systemColorScheme

    @State private var currentScreen: DashboardScreen = .dashboard
    @State private var customizeDetailProvider: ProviderID?
    @State private var selectedTab: DashboardTab = .limits
    @State private var screenHeights: [DashboardScreen: CGFloat] = [:]
    @State private var draggingProvider: ProviderID?

    private enum DashboardTab: Hashable {
        case limits, usage
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
        .background {
            let reduceTransparency = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
            if reduceTransparency {
                Color(nsColor: .windowBackgroundColor)
            } else {
                // A fixed black/white tint (not `NSColor.windowBackgroundColor`, which resolves
                // unpredictably light when read from inside a `Glass.tint()` closure rather than
                // a live-rendered view) darkens/lightens the glass to match whichever appearance
                // the popover is actually rendering in, confirmed by direct screenshot.
                let effectiveScheme = appearanceStore.theme.colorScheme ?? systemColorScheme
                let tintColor: Color = effectiveScheme == .light ? .white : .black
                let tintOpacity = appearanceStore.increaseTransparency ? 0.35 : 0.72
                Rectangle().glassEffect(.regular.tint(tintColor.opacity(tintOpacity)), in: .rect)
            }
        }
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
                    if !hintStore.providerDetectionDismissed {
                        providerDetectionHint
                    }
                    tabSwitcher
                    Divider()
                    switch selectedTab {
                    case .limits:
                        limitsList
                    case .usage:
                        usageList
                    }
                }
            }
        }
        .reportPanelHeight(for: .dashboard)
    }

    /// Shown once, the first time providers are enabled -- dismissed permanently via `HintStore`.
    private var providerDetectionHint: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 2) {
                Text("Found \(orderedEnabledProviders.count) provider\(orderedEnabledProviders.count == 1 ? "" : "s") on this Mac")
                    .font(.caption.weight(.semibold))
                Text("Drag to reorder, or open Customize to pick which metrics show.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Button(action: hintStore.dismissProviderDetection) {
                Image(systemName: "xmark")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(10)
        .background(Color.green.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 14)
        .padding(.top, 10)
    }

    private var customizeScreenContent: some View {
        CustomizeView(enablementStore: enablementStore, layoutStore: layoutStore, dataStore: dataStore, detailProvider: $customizeDetailProvider, hintStore: hintStore)
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
            Text("Limits").tag(DashboardTab.limits)
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

    /// Every enabled provider's quota bars (session, weekly, credit balance/remaining) -- "how
    /// close am I to a wall" -- plus any additional locally discovered account (Claude, Codex)
    /// for the same question about a second login. Spend, cache temperature, and cost history
    /// live on the Usage tab instead; see `MetricLine.category`.
    private var limitsList: some View {
        MeasuredScrollView(maxHeight: maxContentHeight, refreshID: "\(orderedEnabledProviders.count)-\(dataStore.snapshots.count)-\(usageService.accounts.count)") {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(orderedEnabledProviders) { provider in
                    ProviderSectionView(
                        provider: provider,
                        snapshot: dataStore.snapshot(for: provider),
                        layoutStore: layoutStore,
                        displayStore: displayStore,
                        refreshIntervalSeconds: enablementStore.refreshIntervalSeconds,
                        timeFormat: appearanceStore.timeFormat,
                        category: .limits,
                        onRefresh: { refreshScheduler.refreshProvider(provider) },
                        onHideProvider: { enablementStore.setEnabled(provider, false) },
                        onCustomizeProvider: { customizeDetailProvider = provider; currentScreen = .customize }
                    )
                    .opacity(draggingProvider == provider ? 0.4 : 1)
                    .onDrag {
                        draggingProvider = provider
                        return NSItemProvider(object: provider.rawValue as NSString)
                    }
                    .onDrop(of: [.text], delegate: ProviderDropDelegate(
                        target: provider,
                        draggingProvider: $draggingProvider,
                        enabled: enablementStore.enabledProviders,
                        layoutStore: layoutStore
                    ))
                }
                ForEach(additionalAccounts) { account in
                    additionalAccountCard(account)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
        }
        .task {
            // Cheap cache read first (no network wait), then look for additional local accounts
            // -- the only part of this tab that makes a fresh call.
            usageService.refreshDefaultAccountsFromCache()
            await usageService.refreshAdditionalAccounts()
        }
    }

    /// Every locally discovered login beyond each provider's default one (currently Claude and
    /// Codex, via a second `CLAUDE_CONFIG_DIR`/`CODEX_HOME` profile) -- `ProviderAccount.lines`
    /// is quota-meter-only by construction, so no category filtering is needed here.
    private var additionalAccounts: [ProviderAccount] {
        usageService.accounts.filter { !$0.isDefault }
    }

    private func additionalAccountCard(_ account: ProviderAccount) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                ProviderIcon(provider: account.providerID, size: 16)
                Text(account.providerID.displayName).font(.subheadline.weight(.semibold))
                if !account.label.isEmpty {
                    Text(account.label)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
            }
            ProviderCardView(snapshot: ProviderSnapshot(
                provider: account.providerID,
                plan: nil,
                lines: account.lines,
                fetchedAt: account.fetchedAt,
                error: account.error
            ), displayStore: displayStore)
        }
        .padding(Density.cardPadding(appearanceStore.density))
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
    }

    /// Spend, cache activity, and 7-day cost history -- "what have I actually spent or done,"
    /// never a quota bar (those live on Limits; see `MetricLine.category`). Only a provider with
    /// something to show here gets a card -- most providers have no usage-category data today.
    private var usageList: some View {
        MeasuredScrollView(maxHeight: maxContentHeight, refreshID: "\(usageProviders)-\(spendHistoryStore.lastLoadedAt?.timeIntervalSince1970 ?? 0)") {
            VStack(alignment: .leading, spacing: 10) {
                TotalSpendCard(dataStore: dataStore, enablementStore: enablementStore, displayStore: displayStore, spendHistoryStore: spendHistoryStore)
                ForEach(usageProviders) { provider in
                    ProviderSectionView(
                        provider: provider,
                        snapshot: dataStore.snapshot(for: provider),
                        layoutStore: layoutStore,
                        displayStore: displayStore,
                        refreshIntervalSeconds: enablementStore.refreshIntervalSeconds,
                        timeFormat: appearanceStore.timeFormat,
                        category: .usage,
                        isDraggable: false,
                        spendHistoryStore: SpendHistoryStore.hasHistory(provider) ? spendHistoryStore : nil,
                        onRefresh: { refreshScheduler.refreshProvider(provider) },
                        onHideProvider: { enablementStore.setEnabled(provider, false) },
                        onCustomizeProvider: { customizeDetailProvider = provider; currentScreen = .customize }
                    )
                }
                UsageHistoryView(store: spendHistoryStore, providers: SpendHistoryStore.providers.filter { enablementStore.isEnabled($0) })
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
        }
    }

    /// Enabled providers with at least one `.usage`-category line to show (cache temperature,
    /// spend values, or local spend history) -- skips a header-only card for the rest.
    private var usageProviders: [ProviderID] {
        orderedEnabledProviders.filter { provider in
            ProviderSectionView.hasContent(
                snapshot: dataStore.snapshot(for: provider),
                category: .usage,
                layoutStore: layoutStore,
                provider: provider,
                spendHistoryStore: SpendHistoryStore.hasHistory(provider) ? spendHistoryStore : nil
            )
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
