import Foundation

/// Tolerant ISO-8601 parsing for providers whose timestamps don't fit
/// `ISO8601DateFormatter`'s default expectations (e.g. Kimi's 9-digit fractional seconds).
public enum FlexibleISO8601 {
    private static let withFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let withoutFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    /// Parses an ISO-8601 timestamp, truncating any fractional-second component to at most 3
    /// digits (milliseconds) before handing off to `ISO8601DateFormatter`, which otherwise
    /// rejects longer (nano/microsecond) fractions some APIs emit.
    public static func parse(_ string: String) -> Date? {
        let trimmed = string.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }

        if let date = withoutFractional.date(from: trimmed) {
            return date
        }
        if let date = withFractional.date(from: trimmed) {
            return date
        }

        guard let dotIndex = trimmed.firstIndex(of: ".") else { return nil }
        let fractionStart = trimmed.index(after: dotIndex)
        guard let fractionEnd = trimmed[fractionStart...].firstIndex(where: { !$0.isNumber }) else { return nil }
        let fraction = trimmed[fractionStart..<fractionEnd]
        let truncated = String(fraction.prefix(3))
        let normalized = trimmed.replacingCharacters(in: fractionStart..<fractionEnd, with: truncated)
        return withFractional.date(from: normalized)
    }
}
