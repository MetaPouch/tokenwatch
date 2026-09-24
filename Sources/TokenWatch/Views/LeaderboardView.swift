import SwiftUI
import AppKit
import TokenWatchCore

/// The Leaderboard screen: the opt-in leaderboard's home, opened from the footer menu or the
/// dashboard's top-right badge. Not joined, it explains what would be shared and offers Join with
/// GitHub; joined, it shows the account, the sync status and the controls to preview, pause,
/// resync, sign out or delete.
struct LeaderboardView: View {
    @ObservedObject var service: LeaderboardService
    let authenticator: LeaderboardWebAuthenticating

    @Environment(\.appDensity) private var density
    @State private var preview: LeaderboardPreview?

    var body: some View {
        MeasuredScrollView(maxHeight: 640, refreshID: layoutID) {
            VStack(alignment: .leading, spacing: density == .compact ? 10 : 14) {
                if let account = service.account {
                    joined(account)
                } else {
                    notJoined
                }
                links
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .reportPanelHeight(for: .leaderboard)
        .sheet(item: $preview) { preview in
            LeaderboardPreviewSheet(json: preview.json)
        }
    }

    /// Re-measures the page whenever what it shows changes shape.
    private var layoutID: String {
        "\(service.account?.login ?? "-")-\(service.notice?.rawValue ?? "-")-\(service.signInState)-\(service.isPaused)-\(density)"
    }

    // MARK: - Not joined

    @ViewBuilder
    private var notJoined: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: "trophy.fill")
                .font(.system(size: 26))
                .foregroundStyle(.yellow)
            Text("Join the Leaderboard")
                .font(.headline)
            Text("Put your daily token usage on the public leaderboard at tokenwat.ch.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        if service.notice == .disconnected {
            Label(LeaderboardNotice.disconnected.message, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        }
        SettingsSection("What's Shared") {
            point("arrow.up.circle", "Daily token counts and estimated cost per provider and model.")
            point("lock", "Never your prompts, code, project names, file paths or API keys.")
            point("globe", "Everything uploaded is public on your tokenwat.ch profile.")
            point("pause.circle", "Pause, sign out or delete your account at any time.")
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
            .frame(minHeight: 28)
        case let .failed(error):
            joinButton
            Text(error.message)
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        case .idle:
            joinButton
        }
    }

    private var joinButton: some View {
        Button {
            Task { await service.signIn(with: authenticator) }
        } label: {
            Text(service.notice == .disconnected ? "Sign In Again with GitHub" : "Join with GitHub")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .help("Opens tokenwat.ch to sign in with GitHub. Nothing is sent until you approve.")
    }

    private func point(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol)
                .frame(width: 14)
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    // MARK: - Joined

    @ViewBuilder
    private func joined(_ account: LeaderboardAccount) -> some View {
        HStack(spacing: 12) {
            LeaderboardAvatar(data: service.avatar, login: account.login, size: density == .compact ? 36 : 44)
            VStack(alignment: .leading, spacing: 3) {
                Text("@\(account.login)")
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                TimelineView(.everyMinute) { context in
                    status(now: context.date)
                }
            }
            Spacer(minLength: 4)
        }
        Button {
            NSWorkspace.shared.open(account.profileURL)
        } label: {
            Label("View Profile", systemImage: "arrow.up.right.square")
                .frame(maxWidth: .infinity)
        }
        .controlSize(.large)
        .help("Opens your public profile on tokenwat.ch.")

        SettingsSection("Syncing") {
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
        }

        SettingsSection("Account") {
            HStack {
                Button("Sign Out") { Task { await service.signOut() } }
                    .help("Signs this Mac out of the leaderboard. Uploaded history stays on your profile.")
                Button("Delete Account…") { NSWorkspace.shared.open(service.endpoints.account) }
                    .help("Opens tokenwat.ch, where you can delete your leaderboard account and everything uploaded.")
            }
        }
    }

    /// One line: what's wrong, else what's happening, else when it last synced.
    @ViewBuilder
    private func status(now: Date) -> some View {
        if service.notice == .updateRequired {
            statusText(LeaderboardNotice.updateRequired.message, symbol: "exclamationmark.triangle.fill", warning: true)
        } else if service.isPaused {
            statusText("Paused. Nothing is sent until you resume.", symbol: "pause.circle.fill")
        } else if service.isPausedOnWeb {
            statusText("Paused on tokenwat.ch.", symbol: "pause.circle.fill")
        } else if let issue = service.syncIssue {
            statusText(issue.message, symbol: "exclamationmark.triangle.fill", warning: true)
        } else if let history = service.history {
            statusText(historyText(history), symbol: "arrow.triangle.2.circlepath")
        } else if let lastSync = service.lastSyncAt {
            statusText("Synced \(Self.relative(lastSync, now: now)).", symbol: "checkmark.circle.fill")
        } else {
            statusText("Not synced yet.", symbol: "clock")
        }
    }

    private func statusText(_ text: String, symbol: String, warning: Bool = false) -> some View {
        Label(text, systemImage: symbol)
            .font(.caption)
            .foregroundStyle(warning ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
            .fixedSize(horizontal: false, vertical: true)
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

    // MARK: - Links

    private var links: some View {
        HStack(spacing: 12) {
            Link("Privacy", destination: service.endpoints.privacy)
            Link("Methodology", destination: service.endpoints.methodology)
        }
        .font(.caption)
        .frame(maxWidth: .infinity, alignment: .center)
    }
}

/// The dashboard's top-right leaderboard button: "Join Leaderboard" until joined, then the
/// account's avatar and `@login`. A dot marks a pause (gray) or a stop that needs the user
/// (orange); a 401/403/410 sign-out shows "Sign In Again". Clicking opens the Leaderboard screen.
struct LeaderboardBadgeButton: View {
    @ObservedObject var service: LeaderboardService
    let action: () -> Void

    var body: some View {
        let badge = service.badge
        Button(action: action) {
            label(badge)
                .font(.caption.weight(.medium))
                .lineLimit(1)
                .padding(.leading, isJoined(badge) ? 2 : 8)
                .padding(.trailing, 8)
                .frame(height: 24)
                .background(background(badge), in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(help(badge))
        .accessibilityLabel(help(badge))
    }

    @ViewBuilder
    private func label(_ badge: LeaderboardBadge) -> some View {
        switch badge {
        case .join:
            Label("Join Leaderboard", systemImage: "trophy.fill")
                .labelStyle(BadgeLabelStyle())
                .foregroundStyle(Color.accentColor)
        case .signInAgain:
            Label("Sign In Again", systemImage: "exclamationmark.triangle.fill")
                .labelStyle(BadgeLabelStyle())
                .foregroundStyle(.orange)
        case let .joined(login, status):
            HStack(spacing: 5) {
                LeaderboardAvatar(data: service.avatar, login: login, size: 20)
                    .overlay(alignment: .bottomTrailing) { statusDot(status) }
                Text("@\(login)")
                    .truncationMode(.middle)
                    .frame(maxWidth: 110, alignment: .leading)
                    .fixedSize(horizontal: true, vertical: false)
                    .foregroundStyle(status == .paused ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
            }
        }
    }

    @ViewBuilder
    private func statusDot(_ status: LeaderboardBadge.Status) -> some View {
        switch status {
        case .syncing:
            EmptyView()
        case .paused:
            Image(systemName: "pause.circle.fill")
                .font(.system(size: 9))
                .foregroundStyle(.white, .gray)
                .offset(x: 3, y: 3)
        case .needsAttention:
            Circle()
                .fill(.orange)
                .frame(width: 8, height: 8)
                .overlay(Circle().strokeBorder(.background, lineWidth: 1.5))
                .offset(x: 2, y: 2)
        }
    }

    private func background(_ badge: LeaderboardBadge) -> AnyShapeStyle {
        switch badge {
        case .join: return AnyShapeStyle(Color.accentColor.opacity(0.15))
        case .signInAgain: return AnyShapeStyle(Color.orange.opacity(0.15))
        case .joined: return AnyShapeStyle(.quaternary.opacity(0.5))
        }
    }

    private func isJoined(_ badge: LeaderboardBadge) -> Bool {
        if case .joined = badge { return true }
        return false
    }

    private func help(_ badge: LeaderboardBadge) -> String {
        switch badge {
        case .join: return "Join the tokenwat.ch leaderboard"
        case .signInAgain: return "Leaderboard: disconnected, sign in again"
        case let .joined(login, .syncing): return "Leaderboard: @\(login)"
        case let .joined(login, .paused): return "Leaderboard: @\(login), paused"
        case let .joined(login, .needsAttention): return "Leaderboard: @\(login), \(LeaderboardNotice.updateRequired.message)"
        }
    }
}

/// Icon and title close together, the icon a touch smaller than the text.
private struct BadgeLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon.imageScale(.small)
            configuration.title
        }
    }
}

/// A round avatar from `LeaderboardService.avatar`'s bytes, or the login's initial when there are
/// none (not downloaded yet, or no allowed avatar URL). Never loads anything itself.
struct LeaderboardAvatar: View {
    let data: Data?
    let login: String
    let size: CGFloat

    var body: some View {
        Group {
            if let data, let image = NSImage(data: data) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Circle()
                    .fill(Color.accentColor.opacity(0.25))
                    .overlay {
                        Text(login.first.map { String($0).uppercased() } ?? "?")
                            .font(.system(size: size * 0.45, weight: .semibold, design: .rounded))
                            .foregroundStyle(Color.accentColor)
                    }
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .accessibilityHidden(true)
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
