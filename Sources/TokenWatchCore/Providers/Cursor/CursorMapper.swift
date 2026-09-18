import Foundation

enum CursorMapper {
    static func map(_ summary: CursorUsageSummary, userInfo: CursorUserInfo?) -> [MetricLine] {
        var lines: [MetricLine] = []
        let resetsAt = summary.billingCycleEnd.flatMap(FlexibleISO8601.parse)

        if let plan = summary.individualUsage?.plan, let limitCents = plan.limit, limitCents > 0 {
            let used = Double(plan.used ?? 0) / 100
            let limit = Double(limitCents) / 100
            lines.append(.progress(id: "plan", label: "Included usage", used: used, limit: limit, format: .dollars, resetsAt: resetsAt, periodDurationMs: nil))
        }

        if let onDemand = summary.individualUsage?.onDemand, let used = onDemand.used, used > 0 {
            let usedDollars = Double(used) / 100
            if let limitCents = onDemand.limit, limitCents > 0 {
                let limitDollars = Double(limitCents) / 100
                lines.append(.progress(id: "onDemand", label: "On-demand usage", used: usedDollars, limit: limitDollars, format: .dollars, resetsAt: resetsAt, periodDurationMs: nil))
            } else {
                lines.append(.values(id: "onDemand", label: "On-demand usage", values: [MetricValue(number: usedDollars, kind: "Spent", unit: "USD")]))
            }
        }

        return lines
    }
}
