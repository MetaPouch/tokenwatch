import Foundation

enum OpenRouterMapper {
    static func map(credits: OpenRouterCreditsResponse, key: OpenRouterKeyResponse) -> [MetricLine] {
        var lines: [MetricLine] = []

        if let limit = key.data.limit, limit > 0 {
            let used = key.data.usage ?? (key.data.limitRemaining.map { limit - $0 } ?? 0)
            lines.append(.progress(id: "keyLimit", label: "Key limit", used: used, limit: limit, format: .dollars, resetsAt: nil, periodDurationMs: nil))
        }

        if let totalCredits = credits.data.totalCredits {
            let totalUsage = credits.data.totalUsage ?? 0
            let balance = totalCredits - totalUsage
            lines.append(.values(id: "balance", label: "Balance", values: [
                MetricValue(number: balance, kind: "Remaining", unit: "USD")
            ]))
        }

        return lines
    }
}
