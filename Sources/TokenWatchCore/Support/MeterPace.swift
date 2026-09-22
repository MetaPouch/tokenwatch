import Foundation

/// Burn-rate verdict for a bounded `.progress` metric. Color describes whether the CURRENT pace
/// will exhaust the limit before the window resets -- not just the raw percentage used, which is
/// what a comparable competitor's menu-bar tracker (openusage) settled on and what this ports:
/// a half-full bar burning too fast reads as urgent immediately; a nearly-drained bar that's
/// about to reset reads as calm. A metric with no reset window, or too little elapsed window
/// time to trust an extrapolation, falls back to coloring by the raw level instead.
public enum MeterSeverity: Equatable, Sendable {
    /// On course to land with at least 10% of the limit to spare at reset.
    case ahead(spareFraction: Double)
    /// Projected to land inside the last 10%, with some cushion left (`spareFraction` > 0).
    case onTrack(spareFraction: Double)
    /// Projected to run out before reset (or land with nothing left).
    case behind(runOutAt: Date?)
    /// Already effectively at or over the limit right now.
    case spent
    /// No reset window, or not enough elapsed window time yet to trust a projection -- colored
    /// by the raw fraction used instead of a pace projection.
    case level(usedFraction: Double)

    /// Ahead / on-track / behind read as a semantic 3-color scale regardless of which case
    /// produced them, for callers that just need a `Color`.
    public enum Tone: Sendable { case good, caution, urgent }

    public var tone: Tone {
        switch self {
        case .ahead: return .good
        case .onTrack: return .caution
        case .behind, .spent: return .urgent
        case let .level(usedFraction):
            if usedFraction >= 0.9 { return .urgent }
            if usedFraction >= 0.8 { return .caution }
            return .good
        }
    }

    /// Whether this severity was derived from an actual pace projection (as opposed to falling
    /// back to a raw-level read) -- callers use this to decide whether a pacing note/tick is
    /// meaningful to show at all.
    public var isProjected: Bool {
        switch self {
        case .ahead, .onTrack, .behind: return true
        case .spent, .level: return false
        }
    }
}

public enum MeterPace {
    /// Below this fraction of the window elapsed, a linear extrapolation from usage-so-far is
    /// noisier than just reading the raw level -- a metric that reset five minutes ago hasn't
    /// generated a trustworthy rate yet.
    private static let minProjectableElapsedFraction = 0.05
    /// Spare-at-reset fraction at or above which pace reads as comfortably ahead rather than
    /// merely on track.
    private static let comfortableSpareFraction = 0.10
    /// A projected cushion never displays as truly zero -- "~0% spare" reads as already gone.
    private static let minDisplayableSpareFraction = 0.01

    /// The pace verdict for one bounded metric. `used`/`limit` in the same units; `resetsAt` and
    /// `periodDurationMs` together locate the window's start (`resetsAt - periodDurationMs`).
    public static func severity(used: Double, limit: Double, resetsAt: Date?, periodDurationMs: Int?, now: Date = Date()) -> MeterSeverity {
        guard limit > 0 else { return .level(usedFraction: 0) }
        let usedFraction = max(used / limit, 0)

        guard usedFraction < 1 else { return .spent }

        guard let elapsed = elapsedSeconds(resetsAt: resetsAt, periodDurationMs: periodDurationMs, now: now),
              let periodSeconds = periodDurationMs.map({ Double($0) / 1000 }), periodSeconds > 0 else {
            return .level(usedFraction: usedFraction)
        }

        let elapsedFraction = min(elapsed / periodSeconds, 1)
        guard elapsedFraction >= minProjectableElapsedFraction, usedFraction > 0 else {
            return .level(usedFraction: usedFraction)
        }

        let projectedFraction = usedFraction / elapsedFraction
        let spare = 1 - projectedFraction

        if spare >= comfortableSpareFraction {
            return .ahead(spareFraction: spare)
        } else if spare > 0 {
            return .onTrack(spareFraction: max(spare, minDisplayableSpareFraction))
        } else {
            let rate = usedFraction / elapsed
            guard rate > 0 else { return .behind(runOutAt: nil) }
            let secondsToLimit = (1 - usedFraction) / rate
            guard secondsToLimit.isFinite, secondsToLimit > 0 else { return .behind(runOutAt: nil) }
            return .behind(runOutAt: now.addingTimeInterval(secondsToLimit))
        }
    }

    /// The fraction along the bar (0...1) where the elapsed-time tick mark sits -- how far
    /// through the reset window "now" is. `nil` when there's no reset window to place it against.
    public static func tickFraction(resetsAt: Date?, periodDurationMs: Int?, now: Date = Date()) -> Double? {
        guard let elapsed = elapsedSeconds(resetsAt: resetsAt, periodDurationMs: periodDurationMs, now: now),
              let periodSeconds = periodDurationMs.map({ Double($0) / 1000 }), periodSeconds > 0 else {
            return nil
        }
        return min(elapsed / periodSeconds, 1)
    }

    private static func elapsedSeconds(resetsAt: Date?, periodDurationMs: Int?, now: Date) -> Double? {
        guard let resetsAt, let periodDurationMs, periodDurationMs > 0 else { return nil }
        let periodSeconds = Double(periodDurationMs) / 1000
        let windowStart = resetsAt.addingTimeInterval(-periodSeconds)
        let elapsed = now.timeIntervalSince(windowStart)
        return elapsed > 0 ? elapsed : nil
    }
}
