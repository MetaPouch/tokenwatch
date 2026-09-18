import SwiftUI
import AppKit
import TokenWatchCore

/// Popover content: one `ProviderCardView` section per enabled provider, grouped under its
/// display name, plus a manual refresh button.
struct DashboardView: View {
    @ObservedObject var dataStore: WidgetDataStore
    @ObservedObject var enablementStore: ProviderEnablementStore
    let refreshScheduler: RefreshScheduler
    let apiKeyManagers: [ProviderID: any APIKeyManaging]

    @State private var showingSettings = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if enabledProviders.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(enabledProviders, id: \.self) { provider in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(provider.displayName)
                                    .font(.headline)
                                if let snapshot = dataStore.snapshot(for: provider) {
                                    ProviderCardView(snapshot: snapshot)
                                } else {
                                    Text("Loading…")
                                        .font(.callout)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .padding(14)
                }
            }
        }
        .frame(width: 360, height: 420)
        .background(.regularMaterial)
        .sheet(isPresented: $showingSettings) {
            SettingsView(enablementStore: enablementStore, apiKeyManagers: apiKeyManagers)
                .frame(width: 380, height: 420)
        }
    }

    private var enabledProviders: [ProviderID] {
        ProviderID.allCases.filter { enablementStore.isEnabled($0) }
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
