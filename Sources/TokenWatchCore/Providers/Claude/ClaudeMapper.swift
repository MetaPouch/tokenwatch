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

        if let sevenDaySonnet = response.sevenDaySonnet, let utilization = sevenDaySonnet.utilization {
            lines.append(.progress(
                id: "weekly_sonnet",
                label: "Weekly · Sonnet",
                used: utilization,
                limit: 100,
                format: .percent,
                resetsAt: sevenDaySonnet.resetsAt.flatMap(FlexibleISO8601.parse),
                periodDurationMs: 7 * 24 * 3600 * 1000
            ))
        }

        var seenLabels = Set(lines.compactMap { line -> String? in
            if case let .progress(_, label, _, _, _, _, _) = line { return label }
            return nil
        })
        for limit in response.limits ?? [] {
            guard limit.kind == "weekly_scoped", let percent = limit.percent,
                  let modelName = limit.scope?.model?.displayName
            else { continue }
            let label = "Weekly · \(modelName)"
            guard !seenLabels.contains(label) else { continue }
            seenLabels.insert(label)
            lines.append(.progress(
                id: "weekly_scoped:\(modelName)",
                label: label,
                used: percent,
                limit: 100,
                format: .percent,
                resetsAt: limit.resetsAt.flatMap(FlexibleISO8601.parse),
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
