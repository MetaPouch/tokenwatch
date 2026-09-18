import Foundation

enum ZaiMapper {
    /// unit -> minutes-per-unit (1=day, 3=hour, 5=minute, 6=week), matching CodexBar's zai.js.
    private static let unitMinuteMultipliers: [Int: Int] = [1: 1440, 3: 60, 5: 1, 6: 10080]

    struct ParsedLimit {
        let raw: ZaiQuotaResponse.DataBody.Limit
        let percent: Double
        let windowMinutes: Int?
        let resetsAt: Date?
    }

    static func map(_ response: ZaiQuotaResponse) throws -> (lines: [MetricLine], plan: String?) {
        guard response.success, response.code == 200, let data = response.data else {
            throw ProviderError.parse(response.msg ?? "invalid z.ai quota response")
        }

        let parsed = data.limits.compactMap(parseLimit)
        let tokenLimits = parsed
            .filter { $0.raw.type == "TOKENS_LIMIT" || $0.raw.type == "CREDIT_LIMIT" }
            .sorted { ($0.windowMinutes ?? .max) < ($1.windowMinutes ?? .max) }

        var lines: [MetricLine] = []
        if let primary = tokenLimits.first {
            lines.append(progressLine(id: "primary", label: primary.raw.type == "CREDIT_LIMIT" ? "Credit quota" : "Token quota", limit: primary))
        }
        if tokenLimits.count >= 2, let secondary = tokenLimits.last {
            lines.append(progressLine(id: "secondary", label: secondary.raw.type == "CREDIT_LIMIT" ? "Session credit quota" : "Session token quota", limit: secondary))
        }

        let plan = [data.planName, data.plan, data.planType, data.packageName, data.level]
            .compactMap { $0 }
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }

        return (lines, plan)
    }

    private static func progressLine(id: String, label: String, limit: ParsedLimit) -> MetricLine {
        let periodMs = limit.windowMinutes.map { $0 * 60_000 }
        return .progress(id: id, label: label, used: limit.percent, limit: 100, format: .percent, resetsAt: limit.resetsAt, periodDurationMs: periodMs)
    }

    private static func parseLimit(_ raw: ZaiQuotaResponse.DataBody.Limit) -> ParsedLimit? {
        guard raw.type == "TOKENS_LIMIT" || raw.type == "TIME_LIMIT" || raw.type == "CREDIT_LIMIT" else { return nil }

        var percent = Double(raw.percentage)
        if let usage = raw.usage, usage > 0 {
            var used: Int?
            if let remaining = raw.remaining {
                used = max(usage - remaining, raw.currentValue ?? (usage - remaining))
            } else if let currentValue = raw.currentValue {
                used = currentValue
            }
            if let used {
                percent = Double(max(0, min(usage, used))) / Double(usage) * 100
            }
        }
        percent = max(0, min(100, percent))

        let windowMinutes = (raw.number > 0 ? unitMinuteMultipliers[raw.unit] : nil).map { $0 * raw.number }
        let resetsAt = raw.nextResetTime.map { Date(timeIntervalSince1970: Double($0) / 1000) }

        return ParsedLimit(raw: raw, percent: percent, windowMinutes: windowMinutes, resetsAt: resetsAt)
    }
}
