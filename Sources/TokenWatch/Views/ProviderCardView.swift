import SwiftUI
import TokenWatchCore

/// Renders every `MetricLine` case generically. Every provider's UI comes from this one view --
/// no provider gets bespoke SwiftUI.
struct ProviderCardView: View {
    let snapshot: ProviderSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let error = snapshot.error {
                Label(error.displayMessage, systemImage: "exclamationmark.triangle")
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
        case let .badge(_, text, tone):
            Text(text)
                .font(.caption.weight(.medium))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(badgeColor(tone).opacity(0.15), in: Capsule())
                .foregroundStyle(badgeColor(tone))
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

    private func badgeColor(_ tone: BadgeTone) -> Color {
        switch tone {
        case .neutral: return .secondary
        case .warning: return .orange
        case .critical: return .red
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
