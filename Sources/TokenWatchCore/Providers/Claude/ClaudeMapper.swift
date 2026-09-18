import Foundation

enum ClaudeMapper {
    static func map(_ response: ClaudeUsageResponse) -> [MetricLine] {
        var lines: [MetricLine] = []

        if let fiveHour = response.fiveHour, let utilization = fiveHour.utilization {
            lines.append(.progress(
                id: "session",
                label: "Session (5h)",
                used: utilization,
                limit: 100,
                format: .percent,
                resetsAt: fiveHour.resetsAt.flatMap(FlexibleISO8601.parse),
                periodDurationMs: 5 * 3600 * 1000
            ))
        }

        if let sevenDay = response.sevenDay, let utilization = sevenDay.utilization {
            lines.append(.progress(
                id: "weekly",
                label: "Weekly",
                used: utilization,
                limit: 100,
                format: .percent,
                resetsAt: sevenDay.resetsAt.flatMap(FlexibleISO8601.parse),
                periodDurationMs: 7 * 24 * 3600 * 1000
            ))
        }

        if let extra = response.extraUsage, extra.isEnabled, let monthlyLimit = extra.monthlyLimit {
            let usedCredits = extra.usedCredits ?? 0
            lines.append(.progress(
                id: "extraUsage",
                label: "Extra usage",
                used: usedCredits / 100,
                limit: monthlyLimit / 100,
                format: .dollars,
                resetsAt: nil,
                periodDurationMs: nil
            ))
        }

        return lines
    }
}
