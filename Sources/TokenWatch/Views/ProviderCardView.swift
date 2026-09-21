import SwiftUI
import TokenWatchCore

/// Renders every `MetricLine` case generically. Every provider's UI comes from this one view --
/// no provider gets bespoke SwiftUI.
struct ProviderCardView: View {
    let snapshot: ProviderSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let error = snapshot.error {
                Label(errorMessage(error, provider: snapshot.provider), systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else if snapshot.lines.isEmpty {
                Text("No usage data")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(snapshot.lines) { line in
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
        case let .progress(_, label, used, limit, format, resetsAt, _):
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(label).font(.subheadline)
                    Spacer()
                    Text(formatted(used, format: format))
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                ProgressView(value: limit > 0 ? min(used / limit, 1) : 0)
                    .tint(progressColor(used: used, limit: limit))
                if let resetsAt {
                    Text("Resets \(resetsAt, style: .relative)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        case let .values(_, label, values):
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.subheadline)
                ForEach(Array(values.enumerated()), id: \.offset) { _, value in
                    HStack {
                        Text(value.kind).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Text(valueText(value)).font(.caption.monospacedDigit())
                    }
                }
            }
        case let .badge(_, text, tone, icon, detail):
            HStack(spacing: 6) {
                if let icon {
                    Image(systemName: icon)
                        .font(.caption)
                        .foregroundStyle(badgeAccentColor(icon: icon, tone: tone))
                }
                Text(text)
                    .font(.caption.weight(.semibold))
                if let detail {
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
        case let .chart(_, label, points):
            VStack(alignment: .leading, spacing: 3) {
                Text(label).font(.subheadline)
                Sparkline(points: points)
                    .frame(height: 28)
            }
        case let .text(_, value):
            Text(value).font(.callout)
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

    /// Green under 70% used, amber 70-90%, red above -- matches the same thresholds the status
    /// item uses for its own ring/label coloring.
    private func progressColor(used: Double, limit: Double) -> Color {
        guard limit > 0 else { return .secondary }
        let ratio = used / limit
        if ratio >= 0.9 { return .red }
        if ratio >= 0.7 { return .orange }
        return .green
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
