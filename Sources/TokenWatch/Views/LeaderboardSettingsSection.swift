import SwiftUI
import AppKit
import TokenWatchCore

/// Settings' Leaderboard section: the only way into the opt-in leaderboard. Not joined, it
/// explains what would be shared and offers Join with GitHub; joined, it shows the account, the
/// sync status and the controls to preview, pause, resync, sign out or delete.
struct LeaderboardSettingsSection: View {
    @ObservedObject var service: LeaderboardService
    let authenticator: LeaderboardWebAuthenticating

    @State private var preview: LeaderboardPreview?

    var body: some View {
        if let account = service.account {
            joined(account)
        } else {
            notJoined
        }
    }

    // MARK: - Not joined

    @ViewBuilder
    private var notJoined: some View {
        Text("Put your daily token usage on the public leaderboard at tokenwat.ch.")
            .font(.caption)
        VStack(alignment: .leading, spacing: 4) {
            point("arrow.up.circle", "Uploads daily token counts and estimated cost per provider and model.")
            point("lock", "Never your prompts, code, project names, file paths or API keys.")
            point("globe", "Everything uploaded is public on your tokenwat.ch profile.")
        }
        HStack(spacing: 12) {
            Link("Privacy", destination: service.endpoints.privacy)
            Link("Methodology", destination: service.endpoints.methodology)
        }
        .font(.caption)
        if service.notice == .disconnected {
            Label(LeaderboardNotice.disconnected.message, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
        }
        switch service.signInState {
        case .inProgress:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Waiting for tokenwat.ch…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { service.cancelSignIn() }
            }
        case let .failed(error):
            joinButton
            Text(error.message)
                .font(.caption)
                .foregroundStyle(.orange)
        case .idle:
            joinButton
        }
    }

    private var joinButton: some View {
        Button("Join with GitHub") {
            Task { await service.signIn(with: authenticator) }
        }
    }

    private func point(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: symbol)
                .frame(width: 14)
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }

    // MARK: - Joined

    @ViewBuilder
    private func joined(_ account: LeaderboardAccount) -> some View {
        HStack(spacing: 10) {
            AsyncImage(url: account.avatarURL) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                Image(systemName: "person.crop.circle.fill")
                    .resizable()
                    .foregroundStyle(.secondary)
            }
            .frame(width: 28, height: 28)
            .clipShape(Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text("@\(account.login)")
                    .font(.subheadline.weight(.semibold))
                TimelineView(.everyMinute) { context in
                    status(now: context.date)
                }
            }
            Spacer(minLength: 4)
            Button("View Profile") { NSWorkspace.shared.open(account.profileURL) }
        }
        Toggle("Pause Syncing", isOn: Binding(get: { service.isPaused }, set: { service.setPaused($0) }))
            .help("While paused, TokenWatch sends nothing to tokenwat.ch.")
        HStack {
            Button("Preview Upload…") {
                preview = LeaderboardPreview(json: service.nextUploadPreview())
            }
            .help("The exact JSON TokenWatch sends next.")
            Button("Resync All History") { service.resyncAllHistory() }
                .help("Uploads every day of local history again.")
                .disabled(service.isPaused || service.history != nil || service.notice == .updateRequired)
        }
        HStack {
            Button("Sign Out") { Task { await service.signOut() } }
                .help("Signs this Mac out of the leaderboard. Uploaded history stays on your profile.")
            Button("Delete Account…") { NSWorkspace.shared.open(service.endpoints.account) }
                .help("Opens tokenwat.ch, where you can delete your leaderboard account and everything uploaded.")
        }
        .sheet(item: $preview) { preview in
            LeaderboardPreviewSheet(json: preview.json)
        }
    }

    /// One line: what's wrong, else what's happening, else when it last synced.
    @ViewBuilder
    private func status(now: Date) -> some View {
        if service.notice == .updateRequired {
            statusText(LeaderboardNotice.updateRequired.message, warning: true)
        } else if service.isPaused {
            statusText("Paused. Nothing is sent until you resume.")
        } else if service.isPausedOnWeb {
            statusText("Paused on tokenwat.ch.")
        } else if let issue = service.syncIssue {
            statusText(issue.message, warning: true)
        } else if let history = service.history {
            statusText(historyText(history))
        } else if let lastSync = service.lastSyncAt {
            statusText("Synced \(Self.relative(lastSync, now: now)).")
        } else {
            statusText("Not synced yet.")
        }
    }

    private func statusText(_ text: String, warning: Bool = false) -> some View {
        Text(text)
            .font(.caption2)
            .foregroundStyle(warning ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
    }

    private func historyText(_ progress: LeaderboardHistoryProgress) -> String {
        switch progress {
        case .waiting: return "History upload pending…"
        case .reading: return "Reading local history…"
        case let .uploading(month): return "Uploading history: \(Self.monthName(month))…"
        }
    }

    /// `2026-03` as "Mar 2026".
    private static func monthName(_ month: String) -> String {
        let parts = month.split(separator: "-").compactMap { Int($0) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        guard parts.count == 2, let date = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: 1)) else { return month }
        return date.formatted(.dateTime.month(.abbreviated).year())
    }

    private static func relative(_ date: Date, now: Date) -> String {
        guard now.timeIntervalSince(date) >= 60 else { return "just now" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: now)
    }
}

/// The preview's JSON, captured when the sheet opens.
private struct LeaderboardPreview: Identifiable {
    let id = UUID()
    let json: String?
}

/// The next upload's exact body, pretty-printed and copyable.
private struct LeaderboardPreviewSheet: View {
    let json: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Next Upload")
                .font(.headline)
            Text("Exactly what TokenWatch sends to tokenwat.ch next. History uploads use the same rows with \"mode\": \"backfill\".")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let json {
                ScrollView {
                    Text(json)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .frame(height: 320)
                .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 6))
            } else {
                Text("Nothing to upload yet: no usage in the last three days.")
                    .font(.caption)
                    .frame(maxWidth: .infinity, minHeight: 80)
            }
            HStack {
                Spacer()
                Button("Copy") {
                    guard let json else { return }
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(json, forType: .string)
                }
                .disabled(json == nil)
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 460)
    }
}
