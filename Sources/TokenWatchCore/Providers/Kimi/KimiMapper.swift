import Foundation

enum KimiMapper {
    static func map(_ response: KimiUsagesResponse) -> [MetricLine] {
        var lines: [MetricLine] = []

        lines.append(.progress(
            id: "weekly",
            label: "Weekly",
            used: response.usage.used.value,
            limit: response.usage.limit.value,
            format: .count(suffix: " req"),
            resetsAt: response.usage.resetTime.flatMap(FlexibleISO8601.parse),
            periodDurationMs: nil
        ))

        if let session = response.limits?.first {
            let periodMs = session.window.timeUnit == "TIME_UNIT_MINUTE" ? session.window.duration * 60_000 : nil
            lines.append(.progress(
                id: "session",
                label: "Session (5h)",
                used: session.detail.used.value,
                limit: session.detail.limit.value,
                format: .count(suffix: " req"),
                resetsAt: session.detail.resetTime.flatMap(FlexibleISO8601.parse),
                periodDurationMs: periodMs
            ))
        }

        return lines
    }
}
