import SwiftUI
import TokenWatchCore

/// Reports observed local records, independently of the selected spend period and quota polling.
struct LiveUsageStatusView: View {
    @ObservedObject var store: SpendHistoryStore
    let providers: [ProviderID]

    var body: some View {
        let now = Date()
        let transitions = providers.flatMap { store.activityByProvider[$0]?.transitionDates(after: now) ?? [] }
        TimelineView(.explicit([now] + Set(transitions).sorted())) { context in
            VStack(alignment: .leading, spacing: 4) {
                Text("Recent local usage")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                ForEach(providers) { provider in
                    LiveUsageStatusRow(
                        provider: provider,
                        activity: store.activityByProvider[provider] ?? LiveUsageActivity(),
                        now: context.date
                    )
                }
            }
        }
    }
}

struct LiveUsageStatusRow: View {
    let provider: ProviderID
    let activity: LiveUsageActivity
    let now: Date

    var body: some View {
        let active = activity.isActive(at: now)
        let rate = activity.outputTokensPerSecond(at: now)
        HStack(spacing: 5) {
            Circle()
                .fill(active ? Color.green : Color.secondary.opacity(0.45))
                .frame(width: 5, height: 5)
                .accessibilityHidden(true)
            Text(provider.displayName)
            Text(active ? "Active" : "Idle")
                .foregroundStyle(active ? Color.green : Color.secondary)
                .help("Active means new local usage was observed in the last 8 seconds. It does not mean a model is currently streaming. Startup and old imported history do not count as live activity.")
            Spacer(minLength: 4)
            if let rate {
                Text("\(active ? "" : "Last ")≈ \(rate.formatted(.number.precision(.fractionLength(0...1)))) output tok/s")
                    .monospacedDigit()
                    .foregroundStyle(active ? .primary : .secondary)
                    .help("Output tokens divided by their recorded response duration, currently available for timed omp responses. Includes first-token wait and request overhead, not just token generation. Untimed responses are excluded. Last rates clear after 3 minutes; refresh timing is never used.")
            } else if active {
                Text("Timing unavailable")
                    .foregroundStyle(.secondary)
                    .help("Usage was recorded, but no matched output-token and response-duration sample is available. No token rate is estimated from refresh intervals.")
            }
        }
        .font(.caption2)
        .accessibilityElement(children: .combine)
    }
}
