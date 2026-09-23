import Foundation

/// Compact token-count formatting (thousands/millions/billions), shared by every place a raw
/// token count needs to fit a small label: cache-temperature detail text, the Total Spend card's
/// Tokens mode and per-model breakdown, and the 7-day usage chart. Previously four
/// near-identical private copies, two different styles, and none of them handled a count past a
/// million -- a long enough local session history (or a high-volume account) genuinely crosses a
/// billion tokens, and used to just keep printing "1234.5M" instead of rolling over to "1.2B".
public enum TokenCountFormatter {
    public static func compact(_ tokens: Int) -> String {
        compact(Double(tokens))
    }

    public static func compact(_ tokens: Double) -> String {
        if tokens >= 1_000_000_000 { return String(format: "%.1fB", tokens / 1_000_000_000) }
        if tokens >= 1_000_000 { return String(format: "%.1fM", tokens / 1_000_000) }
        if tokens >= 1_000 { return String(format: "%.1fK", tokens / 1_000) }
        return String(Int(tokens))
    }
}
