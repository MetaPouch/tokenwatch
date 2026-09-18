import Foundation

enum AmpMapper {
    /// Parses the `displayText` free-form string into metric lines: Amp Free daily percent
    /// (`.progress`) plus individual/workspace credit balances (`.values`). Any pattern that
    /// doesn't match is simply omitted -- a format change degrades to fewer rows, not a crash.
    static func map(displayText: String) -> [MetricLine] {
        var lines: [MetricLine] = []

        if let freeMatch = firstMatch(in: displayText, pattern: #"Amp Free:\s*\$([\d.]+)/\$([\d.]+) remaining"#),
           let remaining = Double(freeMatch[1]), let total = Double(freeMatch[2]), total > 0 {
            let used = max(0, total - remaining)
            lines.append(.progress(id: "ampFree", label: "Amp Free", used: used, limit: total, format: .dollars, resetsAt: nil, periodDurationMs: 24 * 3600 * 1000))
        }

        var balances: [MetricValue] = []
        if let individual = firstMatch(in: displayText, pattern: #"Individual credits:\s*\$([\d.]+) remaining"#),
           let value = Double(individual[1]) {
            balances.append(MetricValue(number: value, kind: "Individual", unit: "USD"))
        }
        if let workspace = firstMatch(in: displayText, pattern: #"Workspace credits:\s*\$([\d.]+) remaining"#),
           let value = Double(workspace[1]) {
            balances.append(MetricValue(number: value, kind: "Workspace", unit: "USD"))
        }
        if !balances.isEmpty {
            lines.append(.values(id: "credits", label: "Credit balance", values: balances))
        }

        return lines
    }

    private static func firstMatch(in text: String, pattern: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range) else { return nil }
        var groups: [String] = []
        for index in 0..<match.numberOfRanges {
            guard let r = Range(match.range(at: index), in: text) else { groups.append(""); continue }
            groups.append(String(text[r]))
        }
        return groups
    }
}
