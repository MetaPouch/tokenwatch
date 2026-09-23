import Foundation

/// Today's local usage across enabled providers. All buckets are disjoint; cache combines
/// reads and writes in the narrow menu bar, while the tooltip preserves both exact counts.
public struct MenuBarTokenCounts: Sendable, Equatable {
    public let providers: [ProviderID]
    public private(set) var input = 0
    public private(set) var output = 0
    public private(set) var cacheRead = 0
    public private(set) var cacheWrite = 0

    public var cache: Int { cacheRead + cacheWrite }

    public static func today(daysByProvider: [ProviderID: [UsageDay]], enabledProviders: Set<ProviderID>, now: Date = Date(), calendar: Calendar = .current) -> Self? {
        let providers = ProviderID.allCases.filter { enabledProviders.contains($0) && daysByProvider[$0] != nil }
        guard !providers.isEmpty else { return nil }
        var result = Self(providers: providers)
        for provider in providers {
            guard let day = daysByProvider[provider]?.first(where: { calendar.isDate($0.date, inSameDayAs: now) }) else { continue }
            result.input += day.inputTokens
            result.output += day.outputTokens
            result.cacheRead += day.cacheReadTokens
            result.cacheWrite += day.cacheWriteTokens
        }
        return result
    }

    public func compactText(showing values: Set<MenuBarValue>) -> String {
        var parts: [String] = []
        if values.contains(.inputTokens) { parts.append("In \(TokenCountFormatter.compact(input))") }
        if values.contains(.outputTokens) { parts.append("Out \(TokenCountFormatter.compact(output))") }
        if values.contains(.cacheTokens) { parts.append("Cache \(TokenCountFormatter.compact(cache))") }
        return parts.joined(separator: " ")
    }

    public func tooltip(showing values: Set<MenuBarValue>) -> String {
        var lines = ["Today's local tokens — \(providers.map(\.displayName).joined(separator: ", "))"]
        if values.contains(.inputTokens) { lines.append("Input (excluding cache): \(input.formatted())") }
        if values.contains(.outputTokens) { lines.append("Output: \(output.formatted())") }
        if values.contains(.cacheTokens) {
            lines.append("Cache read: \(cacheRead.formatted())")
            lines.append("Cache write: \(cacheWrite.formatted())")
        }
        lines.append("Counts update when usage is logged; these are totals, not tokens per second.")
        return lines.joined(separator: "\n")
    }
}
