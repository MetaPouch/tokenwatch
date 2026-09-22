import Foundation

/// Which pace-crossing condition a metric just tripped.
public enum QuotaAlertTrigger: String, Sendable, CaseIterable {
    /// Under 10% of the limit remaining, regardless of pace -- also fires for a balance with no
    /// reset window, where pace can't be projected at all.
    case almostOut = "Almost Out"
    /// Projected to finish the period with little cushion left (`MeterSeverity.onTrack`).
    case cuttingItClose = "Cutting It Close"
    /// Projected to run out before the window resets (`MeterSeverity.behind`).
    case willRunOut = "Will Run Out"
}

/// Which of the three triggers are enabled -- each is independently opt-in, default off.
public struct QuotaAlertSettings: Sendable {
    public var almostOut: Bool
    public var cuttingItClose: Bool
    public var willRunOut: Bool

    public init(almostOut: Bool = false, cuttingItClose: Bool = false, willRunOut: Bool = false) {
        self.almostOut = almostOut
        self.cuttingItClose = cuttingItClose
        self.willRunOut = willRunOut
    }

    func isEnabled(_ trigger: QuotaAlertTrigger) -> Bool {
        switch trigger {
        case .almostOut: return almostOut
        case .cuttingItClose: return cuttingItClose
        case .willRunOut: return willRunOut
        }
    }
}

/// One metric worth alerting about, identified stably across refreshes.
public struct QuotaAlertKey: Hashable, Sendable {
    public let provider: ProviderID
    public let metricID: String

    public init(provider: ProviderID, metricID: String) {
        self.provider = provider
        self.metricID = metricID
    }
}

/// A single fired alert, ready to hand to a notification center.
public struct QuotaAlert: Sendable, Equatable {
    public let trigger: QuotaAlertTrigger
    public let provider: ProviderID
    public let metricLabel: String
    public let body: String
}

/// Tracks which metrics have already alerted for their current condition so a refresh loop
/// doesn't re-fire the same notification every cycle. Dedup state is in-memory and per-launch: a
/// metric already in a bad state when the app starts establishes its baseline silently (matching
/// "don't alarm on startup for a pre-existing condition"), then only re-alerts on a genuinely new
/// crossing or a worsening trigger. A reset window rolling over (detected via `resetsAt` moving
/// forward) clears that metric's history so the next cycle can alert again.
public final class QuotaNotificationEvaluator {
    /// Severities at or above this rank both count as "already alerted, don't re-fire" for a
    /// worsening check -- .behind is strictly worse than .onTrack which is strictly worse than
    /// nothing.
    private enum Rank: Int, Comparable {
        case none = 0, cuttingItClose = 1, willRunOut = 2
        static func < (lhs: Rank, rhs: Rank) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    private struct State {
        var almostOutFired = false
        var paceRank: Rank = .none
        var lastResetsAt: Date?
    }

    private var state: [QuotaAlertKey: State] = [:]
    private var isFirstEvaluation: Set<QuotaAlertKey> = []

    public init() {}

    /// Evaluates one metric and returns any newly-tripped alerts (usually zero or one). Call
    /// once per metric per refresh; state persists across calls for the life of this evaluator.
    public func evaluate(
        provider: ProviderID,
        metricID: String,
        label: String,
        used: Double,
        limit: Double,
        resetsAt: Date?,
        periodDurationMs: Int?,
        settings: QuotaAlertSettings,
        now: Date = Date()
    ) -> [QuotaAlert] {
        guard limit > 0 else { return [] }
        let key = QuotaAlertKey(provider: provider, metricID: metricID)
        var current = state[key] ?? State()
        let isBaseline = state[key] == nil

        // A reset window that has visibly moved forward means a new period started -- past
        // alerts no longer describe the current state.
        if let resetsAt, let lastResetsAt = current.lastResetsAt, resetsAt != lastResetsAt {
            current = State()
        }
        current.lastResetsAt = resetsAt

        var alerts: [QuotaAlert] = []
        let remainingFraction = 1 - min(max(used / limit, 0), 1)

        if settings.almostOut, remainingFraction <= 0.10, !current.almostOutFired {
            if !isBaseline {
                alerts.append(QuotaAlert(trigger: .almostOut, provider: provider, metricLabel: label, body: "\(Int((remainingFraction * 100).rounded()))% remaining."))
            }
            current.almostOutFired = true
        } else if remainingFraction > 0.10 {
            current.almostOutFired = false
        }

        let severity = MeterPace.severity(used: used, limit: limit, resetsAt: resetsAt, periodDurationMs: periodDurationMs, now: now)
        let newRank: Rank
        switch severity {
        case .onTrack: newRank = .cuttingItClose
        case .behind, .spent: newRank = .willRunOut
        default: newRank = .none
        }

        if newRank > current.paceRank {
            if !isBaseline {
                if newRank == .cuttingItClose, settings.cuttingItClose {
                    alerts.append(QuotaAlert(trigger: .cuttingItClose, provider: provider, metricLabel: label, body: "Projected to finish close to the limit."))
                } else if newRank == .willRunOut, settings.willRunOut {
                    alerts.append(QuotaAlert(trigger: .willRunOut, provider: provider, metricLabel: label, body: "Projected to run out before it resets."))
                }
            }
            current.paceRank = newRank
        } else if newRank < current.paceRank {
            current.paceRank = newRank
        }

        state[key] = current
        return alerts
    }
}
