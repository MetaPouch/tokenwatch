import Foundation

enum GrokMapper {
    static func map(_ response: GrokBillingResponse) -> (lines: [MetricLine], plan: String?) {
        guard let config = response.config else { return ([], nil) }

        var percent = config.creditUsagePercent
        if percent == nil, let used = response.onDemandUsed?.val, let cap = response.onDemandCap?.val, cap > 0 {
            percent = used / cap * 100
        }

        guard let usedPercent = percent else { return ([], config.subscriptionTier) }

        let resetsAt = (config.currentPeriod?.end ?? config.billingPeriodEnd).flatMap(FlexibleISO8601.parse)
        let line = MetricLine.progress(id: "credits", label: "Credits", used: usedPercent, limit: 100, format: .percent, resetsAt: resetsAt, periodDurationMs: nil)
        return ([line], config.subscriptionTier)
    }
}
