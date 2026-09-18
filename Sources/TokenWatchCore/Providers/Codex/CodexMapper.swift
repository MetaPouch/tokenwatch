import Foundation

enum CodexMapper {
    static func map(_ response: CodexUsageResponse, now: Date = Date()) -> [MetricLine] {
        var lines: [MetricLine] = []
        if let primary = response.rateLimit?.primaryWindow {
            lines.append(windowLine(id: "session", label: "Session", window: primary, now: now))
        }
        if let secondary = response.rateLimit?.secondaryWindow {
            lines.append(windowLine(id: "weekly", label: "Weekly", window: secondary, now: now))
        }
        return lines
    }

    private static func windowLine(id: String, label: String, window: CodexUsageResponse.Window, now: Date) -> MetricLine {
        let resetsAt = window.resetsAt.flatMap(FlexibleISO8601.parse)
            ?? window.resetAfterSeconds.map { now.addingTimeInterval(TimeInterval($0)) }
        let periodMs = window.windowMinutes.map { $0 * 60_000 }
        return .progress(id: id, label: label, used: window.usedPercent ?? 0, limit: 100, format: .percent, resetsAt: resetsAt, periodDurationMs: periodMs)
    }
}
