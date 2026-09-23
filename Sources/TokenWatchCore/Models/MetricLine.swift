import Foundation

/// How a numeric metric value should be rendered.
public enum MetricFormat: Sendable, Equatable, Codable {
    case percent
    case dollars
    case count(suffix: String)
}

/// Visual urgency for a badge-style metric line.
public enum BadgeTone: String, Sendable, Codable {
    case neutral
    case warning
    case critical
}

/// Which dashboard tab a `MetricLine` belongs under -- see `MetricLine.category`.
public enum MetricCategory: Sendable, Equatable {
    case limits
    case usage
}

/// One labeled numeric value inside a `.values` metric line.
public struct MetricValue: Sendable, Equatable, Codable {
    public let number: Double
    public let kind: String
    public let unit: String?

    public init(number: Double, kind: String, unit: String? = nil) {
        self.number = number
        self.kind = kind
        self.unit = unit
    }
}

/// A single dated sample inside a `.chart` sparkline.
public struct DatedPoint: Sendable, Equatable, Codable {
    public let date: Date
    public let value: Double

    public init(date: Date, value: Double) {
        self.date = date
        self.value = value
    }
}

/// One renderable row inside a provider's dashboard card. `ProviderCardView` renders every
/// case generically -- no provider gets bespoke SwiftUI.
public enum MetricLine: Sendable, Identifiable, Equatable, Codable {
    case progress(id: String, label: String, used: Double, limit: Double, format: MetricFormat, resetsAt: Date?, periodDurationMs: Int?)
    case values(id: String, label: String, values: [MetricValue])
    /// `icon` (an SF Symbol name) and `detail` (a short secondary line) are optional enrichment
    /// -- omit both for a plain single-line badge; a provider that has both a glanceable primary
    /// signal (e.g. a project name) and supporting detail (e.g. a hit ratio) can supply an icon
    /// to color-code it and a detail line without inventing a new `MetricLine` case.
    case badge(id: String, text: String, tone: BadgeTone, icon: String? = nil, detail: String? = nil)
    case chart(id: String, label: String, points: [DatedPoint])
    case text(id: String, value: String)

    public var id: String {
        switch self {
        case .progress(let id, _, _, _, _, _, _): return id
        case .values(let id, _, _): return id
        case .badge(let id, _, _, _, _): return id
        case .chart(let id, _, _): return id
        case .text(let id, _): return id
        }
    }
    /// Fraction used, 0...1, for `.progress` lines only. `nil` for every other case or a
    /// non-positive limit.
    public var progressRatio: Double? {
        guard case let .progress(_, _, used, limit, _, _, _) = self, limit > 0 else { return nil }
        return max(0, min(used / limit, 1))
    }

    /// Which dashboard tab a line belongs under: **Limits** answers "how close am I to a wall"
    /// (quota bars, remaining credit/balance); **Usage** answers "what have I actually spent or
    /// done" (cache temperature, spend figures, cost/token history). `.progress` is always a
    /// limit by construction (it's a used-vs-limit ratio); `.badge` (cache temperature today) is
    /// always usage/activity info, never a hard quota. `.values` is the one ambiguous case --
    /// "credits"/"balance" read as remaining capacity (a limit), while every other id (e.g.
    /// "spend", "onDemand") is money already spent (usage).
    public var category: MetricCategory {
        switch self {
        case .progress: return .limits
        case .badge: return .usage
        case .chart: return .usage
        case .text: return .usage
        case .values(let id, _, _):
            return ["credits", "balance"].contains(id) ? .limits : .usage
        }
    }


    private enum CodingKeys: String, CodingKey {
        case kind, id, label, used, limit, format, resetsAt, periodDurationMs, values, text, tone, icon, detail, points, value
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(String.self, forKey: .kind)
        switch kind {
        case "progress":
            self = .progress(
                id: try c.decode(String.self, forKey: .id),
                label: try c.decode(String.self, forKey: .label),
                used: try c.decode(Double.self, forKey: .used),
                limit: try c.decode(Double.self, forKey: .limit),
                format: try c.decode(MetricFormat.self, forKey: .format),
                resetsAt: try c.decodeIfPresent(Date.self, forKey: .resetsAt),
                periodDurationMs: try c.decodeIfPresent(Int.self, forKey: .periodDurationMs)
            )
        case "values":
            self = .values(
                id: try c.decode(String.self, forKey: .id),
                label: try c.decode(String.self, forKey: .label),
                values: try c.decode([MetricValue].self, forKey: .values)
            )
        case "badge":
            self = .badge(
                id: try c.decode(String.self, forKey: .id),
                text: try c.decode(String.self, forKey: .text),
                tone: try c.decode(BadgeTone.self, forKey: .tone),
                icon: try c.decodeIfPresent(String.self, forKey: .icon),
                detail: try c.decodeIfPresent(String.self, forKey: .detail)
            )
        case "chart":
            self = .chart(
                id: try c.decode(String.self, forKey: .id),
                label: try c.decode(String.self, forKey: .label),
                points: try c.decode([DatedPoint].self, forKey: .points)
            )
        case "text":
            self = .text(
                id: try c.decode(String.self, forKey: .id),
                value: try c.decode(String.self, forKey: .value)
            )
        default:
            throw DecodingError.dataCorruptedError(forKey: .kind, in: c, debugDescription: "Unknown MetricLine kind '\(kind)'")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .progress(id, label, used, limit, format, resetsAt, periodDurationMs):
            try c.encode("progress", forKey: .kind)
            try c.encode(id, forKey: .id)
            try c.encode(label, forKey: .label)
            try c.encode(used, forKey: .used)
            try c.encode(limit, forKey: .limit)
            try c.encode(format, forKey: .format)
            try c.encodeIfPresent(resetsAt, forKey: .resetsAt)
            try c.encodeIfPresent(periodDurationMs, forKey: .periodDurationMs)
        case let .values(id, label, values):
            try c.encode("values", forKey: .kind)
            try c.encode(id, forKey: .id)
            try c.encode(label, forKey: .label)
            try c.encode(values, forKey: .values)
        case let .badge(id, text, tone, icon, detail):
            try c.encode("badge", forKey: .kind)
            try c.encode(id, forKey: .id)
            try c.encode(text, forKey: .text)
            try c.encode(tone, forKey: .tone)
            try c.encodeIfPresent(icon, forKey: .icon)
            try c.encodeIfPresent(detail, forKey: .detail)
        case let .chart(id, label, points):
            try c.encode("chart", forKey: .kind)
            try c.encode(id, forKey: .id)
            try c.encode(label, forKey: .label)
            try c.encode(points, forKey: .points)
        case let .text(id, value):
            try c.encode("text", forKey: .kind)
            try c.encode(id, forKey: .id)
            try c.encode(value, forKey: .value)
        }
    }
}
