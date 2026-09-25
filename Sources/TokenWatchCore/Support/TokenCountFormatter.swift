import Foundation

/// Compact token-count formatting (thousands/millions/billions), shared by every place a raw
/// token count needs to fit a small label: cache-temperature detail text, the Total Spend card's
/// Tokens mode and per-model breakdown, and the 7-day usage chart. Previously four
/// near-identical private copies, two different styles, and none of them handled a count past a
/// million -- a long enough local session history (or a high-volume account) genuinely crosses a
/// billion tokens, and used to just keep printing "1234.5M" instead of rolling over to "1.23B".
public enum TokenCountFormatter {
    public static func compact(_ tokens: Int) -> String {
        compact(Double(tokens))
    }

    private static func rounded(_ value: Double, decimals: Int) -> Double {
        let factor = pow(10.0, Double(decimals))
        return (value * factor).rounded() / factor
    }

    /// Checks the *rounded* value at each tier against that tier's own rollover point (1000),
    /// not the raw value -- a raw count like 999,996 divides to "1000.0K" if you just format in
    /// place, when what it should show is "1.00M". Escalating based on the rounded value instead
    /// of the raw one means a count that's about to round up into the next unit always gets
    /// checked against that next unit.
    public static func compact(_ tokens: Double) -> String {
        if tokens < 1000 { return String(Int(tokens)) }
        let thousands = rounded(tokens / 1_000, decimals: 1)
        if thousands < 1000 { return String(format: "%.1fK", thousands) }
        let millions = rounded(tokens / 1_000_000, decimals: 2)
        if millions < 1000 { return String(format: "%.2fM", millions) }
        let billions = rounded(tokens / 1_000_000_000, decimals: 2)
        return String(format: "%.2fB", billions)
    }

    /// Same tiering as `compact`, but as a (number, spelled-out unit word) pair for a two-line
    /// display like the Total Spend card's donut center -- "0.35" / "million" instead of one
    /// "350.0K" string. Below 1,000 the unit is "tokens" and the number has no fractional part.
    public static func spelledOutTier(_ tokens: Double) -> (value: String, unit: String) {
        if tokens < 1000 { return (String(Int(tokens)), "tokens") }
        let thousands = rounded(tokens / 1_000, decimals: 2)
        if thousands < 1000 { return (String(format: "%.2f", thousands), "thousand") }
        let millions = rounded(tokens / 1_000_000, decimals: 2)
        if millions < 1000 { return (String(format: "%.2f", millions), "million") }
        let billions = rounded(tokens / 1_000_000_000, decimals: 2)
        return (String(format: "%.2f", billions), "billion")
    }
}
