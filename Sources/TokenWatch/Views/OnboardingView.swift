import SwiftUI
import TokenWatchCore

/// What a user sees while no provider is enabled -- on a fresh install, that's the first screen.
/// Lists the AI tools found on this Mac (`ProviderDetectionStore`), all pre-selected, so getting
/// started is one click; anything not found is a disclosure away, with the way to add an API key.
struct OnboardingView: View {
    @ObservedObject var detectionStore: ProviderDetectionStore
    @ObservedObject var enablementStore: ProviderEnablementStore
    let openSettings: () -> Void

    /// Providers the user wants to track; seeded with everything detected once a scan lands.
    @State private var selection: Set<ProviderID> = []
    @State private var showNotFound = false

    private var detected: [ProviderID] { detectionStore.detectedProviders }
    private var notFound: [ProviderID] { ProviderID.allCases.filter { detectionStore.detections[$0] == nil } }

    var body: some View {
        MeasuredScrollView(maxHeight: 640, refreshID: "\(detectionStore.hasScanned)-\(detected)-\(selection.sorted { $0.rawValue < $1.rawValue })-\(showNotFound)") {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Welcome to TokenWatch")
                        .font(.headline)
                    Text("Your AI limits, spend, and cache status in the menu bar. Nothing you track leaves this Mac.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if !detectionStore.hasScanned {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Looking for AI tools on this Mac…").font(.caption).foregroundStyle(.secondary)
                    }
                } else if detected.isEmpty {
                    nothingFound
                } else {
                    foundList
                }

                if detectionStore.hasScanned {
                    notFoundSection
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task { detectionStore.scan() }
        .onChange(of: detectionStore.detections, initial: true) { _, detections in
            selection = Set(detections.keys)
        }
    }

    private var foundList: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Found \(detected.count) on this Mac")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            VStack(spacing: 2) {
                ForEach(detected) { provider in
                    detectedRow(provider)
                }
            }
            .padding(6)
            .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))

            let approvals = detected.filter { selection.contains($0) && detectionStore.detections[$0]?.needsKeychainApproval == true }
            if !approvals.isEmpty {
                Label {
                    Text("macOS will ask once to let TokenWatch read \(approvals.map(\.displayName).joined(separator: " and "))'s saved sign-in. Choose **Always Allow** so it doesn't ask again.")
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "key.fill").foregroundStyle(.secondary)
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }

            Button {
                enablementStore.enable(selection)
            } label: {
                Text(selection.isEmpty ? "Select a provider to track" : "Track \(selection.count) provider\(selection.count == 1 ? "" : "s")")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .disabled(selection.isEmpty)
        }
    }

    private func detectedRow(_ provider: ProviderID) -> some View {
        let isSelected = selection.contains(provider)
        return Button {
            if isSelected { selection.remove(provider) } else { selection.insert(provider) }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                ProviderIcon(provider: provider, size: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(provider.displayName).font(.callout.weight(.medium))
                    if let source = detectionStore.detections[provider]?.source {
                        Text(source).font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var nothingFound: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("No signed-in AI tools found yet", systemImage: "magnifyingglass")
                .font(.callout.weight(.medium))
            Text("TokenWatch uses the sign-ins your tools already saved: Claude Code, Codex, Cursor, GitHub Copilot, Gemini, Antigravity, Grok, and Amp. Sign in to one and scan again, or add an API key in Settings.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Scan Again") { detectionStore.scan() }
                Button("Open Settings", action: openSettings)
            }
            .controlSize(.small)
        }
    }

    @ViewBuilder
    private var notFoundSection: some View {
        if !detected.isEmpty, !notFound.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Button {
                    showNotFound.toggle()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: showNotFound ? "chevron.down" : "chevron.right")
                            .font(.system(size: 8))
                        Text("Not found on this Mac (\(notFound.count))")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if showNotFound {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(notFound) { provider in
                            HStack(spacing: 8) {
                                ProviderIcon(provider: provider, size: 14)
                                    .opacity(0.6)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(provider.displayName).font(.caption)
                                    Text(provider.credentialSourceHint)
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                        HStack {
                            Button("Scan Again") { detectionStore.scan() }
                            Button("Add an API Key…", action: openSettings)
                        }
                        .controlSize(.small)
                        .padding(.top, 2)
                    }
                    .padding(.leading, 12)
                }
            }
        }
    }
}
