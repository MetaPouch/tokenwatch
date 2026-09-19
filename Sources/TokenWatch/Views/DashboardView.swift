import SwiftUI
import AppKit
import TokenWatchCore

/// Popover content: a provider picker (icon + name, all enabled providers) plus the selected
/// provider's `ProviderCardView`, instead of every enabled provider stacked at once. Claude's
/// snapshot may carry several `cacheTemperature*`-id badges -- one per locally active session --
/// which the generic card renderer already shows as one row each, so picking Claude lists every
/// session in play, not just the newest.
struct DashboardView: View {
    @ObservedObject var dataStore: WidgetDataStore
    @ObservedObject var enablementStore: ProviderEnablementStore
    let refreshScheduler: RefreshScheduler
    let apiKeyManagers: [ProviderID: any APIKeyManaging]

    @State private var showingSettings = false
    @State private var selectedProvider: ProviderID?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if enabledProviders.isEmpty {
                emptyState
            } else {
                providerPicker
                Divider()
                detail
            }
        }
        .frame(width: 360, height: 420)
        .background(.regularMaterial)
        .onAppear { ensureValidSelection() }
        .onChange(of: enabledProviders) { _, _ in ensureValidSelection() }
        .sheet(isPresented: $showingSettings) {
            SettingsView(enablementStore: enablementStore, apiKeyManagers: apiKeyManagers)
                .frame(width: 380, height: 420)
        }
    }

    private var enabledProviders: [ProviderID] {
        ProviderID.allCases.filter { enablementStore.isEnabled($0) }
    }

    /// Keeps `selectedProvider` valid as providers get enabled/disabled: leaves an already-valid
    /// selection alone, otherwise falls back to `PreferredProviderSelector`.
    private func ensureValidSelection() {
        if let selectedProvider, enabledProviders.contains(selectedProvider) { return }
        selectedProvider = PreferredProviderSelector.select(enabledProviders: enabledProviders, snapshots: dataStore.snapshots)
    }

    private var providerPicker: some View {
        HStack {
            Menu {
                ForEach(enabledProviders) { provider in
                    Button {
                        selectedProvider = provider
                    } label: {
                        Label(provider.displayName, systemImage: provider.symbolName)
                    }
                }
            } label: {
                Label(
                    selectedProvider?.displayName ?? "Select a provider",
                    systemImage: selectedProvider?.symbolName ?? "questionmark.circle"
                )
                .font(.subheadline.weight(.semibold))
            }
            .fixedSize()

            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 4)
    }

    private var detail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                if let selectedProvider {
                    if let snapshot = dataStore.snapshot(for: selectedProvider) {
                        ProviderCardView(snapshot: snapshot)
                    } else {
                        Text("Loading…")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
        }
    }

    private var header: some View {
        HStack {
            Text("TokenWatch").font(.title3.weight(.semibold))
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
