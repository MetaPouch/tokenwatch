import Foundation

enum OpenCodeMapper {
    static func map(_ response: OpenCodeUsageResponse, now: Date = Date()) -> [MetricLine] {
        var lines: [MetricLine] = [
            progressLine(id: "rolling", label: "Rolling (5h)", window: response.rollingUsage, now: now, periodDurationMs: 5 * 3600 * 1000)
        ]
        if let weekly = response.weeklyUsage {
            lines.append(progressLine(id: "weekly", label: "Weekly", window: weekly, now: now, periodDurationMs: 7 * 24 * 3600 * 1000))
        }
        return lines
    }

    private static func progressLine(id: String, label: String, window: OpenCodeUsageResponse.Window, now: Date, periodDurationMs: Int) -> MetricLine {
        let resetsAt = window.resetInSec.map { now.addingTimeInterval(TimeInterval($0)) }
        return .progress(id: id, label: label, used: window.usagePercent, limit: 100, format: .percent, resetsAt: resetsAt, periodDurationMs: periodDurationMs)
    }
}
