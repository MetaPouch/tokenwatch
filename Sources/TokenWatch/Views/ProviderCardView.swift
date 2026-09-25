import SwiftUI
import TokenWatchCore

/// Renders every `MetricLine` case generically. Every provider's UI comes from this one view --
/// no provider gets bespoke SwiftUI.
struct ProviderCardView: View {
    let snapshot: ProviderSnapshot
    /// Which lines to render, in order. Defaults to every line in `snapshot`; callers doing
    /// progressive disclosure (always-visible vs. on-demand) pass a filtered subset instead.
    var lines: [MetricLine]?
    @ObservedObject var displayStore: MeterDisplayStore
    /// When non-nil, rows get a right-click context menu (Hide / Star for menu bar / Refresh /
    /// Customize) backed by this store, keyed by `snapshot.provider`. `nil` for read-only
    /// contexts like `DashboardView.additionalAccountCard`'s per-account history cards, where
    /// several accounts share one `ProviderID` and would collide on the same `LayoutStore` keys.
    var layoutStore: LayoutStore?
    var onRefreshProvider: (() -> Void)?
    var onCustomizeMetric: ((String) -> Void)?
    var timeFormat: TimeFormatPreference = .auto
    var now: Date = Date()

    @Environment(\.appDensity) private var density

    private var effectiveLines: [MetricLine] { lines ?? snapshot.lines }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let error = snapshot.error {
                Label(errorMessage(error, provider: snapshot.provider), systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else if effectiveLines.isEmpty {
                Text("No usage data")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(effectiveLines) { line in
                    lineView(line)
                }
            }
        }
    }

    /// Provider-specific guidance for the credential-shaped errors -- "Not signed in" or a raw
    /// "HTTP 401: ..." alone left no next step. A 401/403 means the credential TokenWatch found
    /// was once valid and no longer is (expired/revoked token, not "never configured"), so it
    /// gets the same source hint as `.credentialsMissing` with wording that doesn't imply this
    /// is a first-time setup. Every other error (network/other http/parse) keeps its generic
    /// message, since those aren't about what credential to go set up.
    private func errorMessage(_ error: ProviderError, provider: ProviderID) -> String {
        switch error {
        case .credentialsMissing: return provider.credentialSourceHint
        case .notConfigured: return provider.notConfiguredHint ?? error.displayMessage
        case let .http(status, _) where status == 401 || status == 403:
            return "Credentials expired or revoked. \(provider.credentialSourceHint)"
        default: return error.displayMessage
        }
    }

    @ViewBuilder
    private func lineView(_ line: MetricLine) -> some View {
        switch line {
        case let .progress(id, label, used, limit, format, resetsAt, periodDurationMs):
            let severity = MeterPace.severity(used: used, limit: limit, resetsAt: resetsAt, periodDurationMs: periodDurationMs, now: now)
            let showPacing = severity.isProjected || (displayStore.alwaysShowPacing && resetsAt != nil)
            let tick = showPacing ? MeterPace.tickFraction(resetsAt: resetsAt, periodDurationMs: periodDurationMs, now: now) : nil

            VStack(alignment: .leading, spacing: Density.rowSpacing(density)) {
                HStack {
                    Text(label).font(Density.labelFont(density))
                    Spacer()
                    if showPacing, let note = paceNote(severity: severity) {
                        Text(note)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                ThresholdProgressBar(fraction: limit > 0 ? used / limit : 0, tint: color(for: severity.tone), tickFraction: tick)
                HStack {
                    headlineButton(id: id, used: used, limit: limit, format: format)
                    Spacer()
                    if let resetsAt {
                        resetButton(resetsAt: resetsAt)
                    }
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }
            .contextMenu { rowContextMenu(metricID: id) }
        case let .values(id, label, values):
            VStack(alignment: .leading, spacing: Density.rowSpacing(density)) {
                Text(label).font(Density.labelFont(density))
                ForEach(Array(values.enumerated()), id: \.offset) { _, value in
                    HStack {
                        Text(value.kind).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Text(valueText(value)).font(.caption.monospacedDigit())
                    }
                }
            }
            .contextMenu { rowContextMenu(metricID: id) }
        case let .badge(id, text, tone, icon, detail):
            HStack(spacing: Density.groupSpacing(density)) {
                if let icon {
                    Image(systemName: icon)
                        .font(.caption)
                        .foregroundStyle(badgeAccentColor(icon: icon, tone: tone))
                }
                // One line per session row: a long project name shortens in the middle (keeping
                // distinguishing prefixes/suffixes like worktree hashes) rather than wrapping,
                // and the hit/expiry detail keeps priority since that's the part being read.
                Text(text)
                    .font(Density.valueFont(density).weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let detail {
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .layoutPriority(1)
                }
                Spacer(minLength: 0)
            }
            .contextMenu { rowContextMenu(metricID: id) }
        case let .chart(id, label, points):
            VStack(alignment: .leading, spacing: Density.rowSpacing(density)) {
                Text(label).font(Density.labelFont(density))
                Sparkline(points: points)
                    .frame(height: 28)
            }
            // No `limit`/bounded value to show a fill-fraction for -- "Star for menu bar" would
            // toggle state that never actually renders anywhere (see `StatusItemController`'s
            // `pinText`/`barsFractions`, which only understand `.progress`/`.values`/`.badge`).
            .contextMenu { rowContextMenu(metricID: id, allowStar: false) }
        case let .text(_, value):
            Text(value).font(.callout)
        }
    }

    /// The row's "48% used" / "52% left" (or dollar/count equivalent) headline -- clicking it
    /// flips the app-wide reading mode. Inert (plain text, no button chrome) for an unbounded
    /// line (`limit <= 0`), since "left" has no meaning without a limit.
    @ViewBuilder
    private func headlineButton(id: String, used: Double, limit: Double, format: MetricFormat) -> some View {
        let text = headlineText(used: used, limit: limit, format: format)
        if limit > 0 {
            Button(action: { displayStore.toggleReadingMode() }) {
                Text(text).monospacedDigit()
            }
            .buttonStyle(.plain)
            .help(displayStore.readingMode == .used ? "Click to show remaining" : "Click to show used")
        } else {
            Text(text).monospacedDigit()
        }
    }

    private func headlineText(used: Double, limit: Double, format: MetricFormat) -> String {
        guard limit > 0 else { return formatted(used, format: format) }
        switch displayStore.readingMode {
        case .used: return "\(formatted(used, format: format)) used"
        case .left: return "\(formatted(max(limit - used, 0), format: format)) left"
        }
    }

    /// The row's reset label -- clicking it flips between a countdown and an exact time.
    private func resetButton(resetsAt: Date) -> some View {
        Button(action: { displayStore.toggleResetDisplayMode() }) {
            Text(resetText(resetsAt))
        }
        .buttonStyle(.plain)
        .help(displayStore.resetDisplayMode == .countdown ? "Click to show exact time" : "Click to show countdown")
    }

    private func resetText(_ resetsAt: Date) -> String {
        switch displayStore.resetDisplayMode {
        case .countdown: return "Resets \(relativeShort(resetsAt))"
        case .exact: return "Resets \(exactTimeText(resetsAt, includeDate: true))"
        }
    }

    /// The quiet projection note next to a metric's label: what pace implies about where it'll
    /// land at reset, phrased differently per severity to match how urgent it is.
    private func paceNote(severity: MeterSeverity) -> String? {
        switch severity {
        case let .ahead(spare):
            return "~\(Int((spare * 100).rounded()))% left at reset"
        case let .onTrack(spare):
            return "~\(Int((spare * 100).rounded()))% spare"
        case let .behind(runOutAt):
            guard let runOutAt else { return "Approaching limit" }
            switch displayStore.resetDisplayMode {
            case .countdown: return "Limit \(relativeShort(runOutAt))"
            case .exact: return "Limit \(exactTimeText(runOutAt, includeDate: false))"
            }
        case .spent:
            return "Limit reached"
        case .level:
            return nil
        }
    }

    /// An exact clock time, honoring the Appearance "Time Format" preference (Auto follows the
    /// system 12/24-hour setting; the other two options force one regardless of it).
    private func exactTimeText(_ date: Date, includeDate: Bool) -> String {
        switch timeFormat {
        case .auto:
            return includeDate ? date.formatted(date: .abbreviated, time: .shortened) : date.formatted(date: .omitted, time: .shortened)
        case .twelveHour, .twentyFourHour:
            let formatter = DateFormatter()
            formatter.dateFormat = includeDate ? (timeFormat == .twelveHour ? "MMM d, h:mm a" : "MMM d, HH:mm") : (timeFormat == .twelveHour ? "h:mm a" : "HH:mm")
            return formatter.string(from: date)
        }
    }

    /// `Text(date, style: .relative)` can't be embedded in a plain `String` interpolation, so
    /// the countdown-mode pace note formats its own short relative string instead.
    private func relativeShort(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: now)
    }

    @ViewBuilder
    private func rowContextMenu(metricID: String, allowStar: Bool = true) -> some View {
        if let layoutStore {
            if allowStar {
                let starred = layoutStore.layout(for: snapshot.provider, metricID: metricID).starred
                Button(starred ? "Unstar" : "Star for menu bar") {
                    layoutStore.toggleStar(provider: snapshot.provider, metricID: metricID)
                }
            }
            Button("Hide") {
                layoutStore.setHidden(true, provider: snapshot.provider, metricID: metricID)
            }
            Divider()
        }
        if let onRefreshProvider {
            Button("Refresh \(snapshot.provider.displayName)") { onRefreshProvider() }
        }
        if let onCustomizeMetric {
            Button("Customize…") { onCustomizeMetric(metricID) }
        }
    }

    private func formatted(_ used: Double, format: MetricFormat) -> String {
        switch format {
        case .percent:
            return "\(Int(used.rounded()))%"
        case .dollars:
            return String(format: "$%.2f", used)
        case .count(let suffix):
            return "\(Int(used.rounded()))\(suffix)"
        }
    }

    private func valueText(_ value: MetricValue) -> String {
        let numberText = value.number.truncatingRemainder(dividingBy: 1) == 0
            ? String(Int(value.number))
            : String(format: "%.2f", value.number)
        if let unit = value.unit {
            return "\(numberText) \(unit)"
        }
        return numberText
    }

    /// Blue/amber/red reads as a pace verdict (on course / tight / behind), not a raw-level
    /// threshold -- a half-full bar burning too fast is already red, a nearly-drained bar
    /// coasting to reset stays blue. Matches the system-palette convention of comparable
    /// menu-bar usage trackers, and blue/amber/red is more color-blindness-safe than
    /// green/amber/red.
    private func color(for tone: MeterSeverity.Tone) -> Color {
        switch tone {
        case .good: return .blue
        case .caution: return .orange
        case .urgent: return .red
        }
    }

    private func badgeColor(_ tone: BadgeTone) -> Color {
        switch tone {
        case .neutral: return .secondary
        case .warning: return .orange
        case .critical: return .red
        }
    }

    /// Cache-temperature badges get the same green (warm)/blue (cold) language as the status
    /// item's flame/snowflake icon, for one consistent color vocabulary across menu bar and
    /// dashboard. Any other badge (no recognized icon) falls back to its tone's color.
    private func badgeAccentColor(icon: String, tone: BadgeTone) -> Color {
        switch icon {
        case "flame.fill": return .green
        case "snowflake": return .blue
        default: return badgeColor(tone)
        }
    }
}

private struct Sparkline: View {
    let points: [DatedPoint]

    var body: some View {
        GeometryReader { proxy in
            if points.count > 1, let minValue = points.map(\.value).min(), let maxValue = points.map(\.value).max() {
                let range = max(maxValue - minValue, 0.0001)
                Path { path in
                    for (index, point) in points.enumerated() {
                        let x = proxy.size.width * CGFloat(index) / CGFloat(points.count - 1)
                        let normalized = (point.value - minValue) / range
                        let y = proxy.size.height * (1 - CGFloat(normalized))
                        if index == 0 {
                            path.move(to: CGPoint(x: x, y: y))
                        } else {
                            path.addLine(to: CGPoint(x: x, y: y))
                        }
                    }
                }
                .stroke(Color.accentColor, lineWidth: 1.5)
            }
        }
    }
}

/// macOS's `ProgressView` linear style ignores both `.tint()` and an explicit
/// `LinearProgressViewStyle(tint:)` -- confirmed via isolated render test, not a hunch. Draw the
/// bar by hand so the pace-verdict coloring actually shows up on screen, and so a pace-projection
/// tick mark can be overlaid on top of it.
private struct ThresholdProgressBar: View {
    let fraction: Double
    let tint: Color
    /// Where along the bar (0...1) to draw the elapsed-time tick mark. `nil` draws no tick.
    var tickFraction: Double?

    private let barHeight: CGFloat = 6
    private let tickWidth: CGFloat = 2
    private let tickOverhang: CGFloat = 4

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.25))
                Capsule().fill(tint).frame(width: proxy.size.width * CGFloat(max(0, min(fraction, 1))))
            }
            .overlay(alignment: .leading) {
                if let tickFraction {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Color.primary.opacity(0.55))
                        .frame(width: tickWidth, height: barHeight + tickOverhang)
                        .offset(x: proxy.size.width * CGFloat(max(0, min(tickFraction, 1))) - tickWidth / 2)
                }
            }
        }
        .frame(height: barHeight)
    }
}
