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
    case badge(id: String, text: String, tone: BadgeTone)
    case chart(id: String, label: String, points: [DatedPoint])
    case text(id: String, value: String)

    public var id: String {
        switch self {
        case .progress(let id, _, _, _, _, _, _): return id
        case .values(let id, _, _): return id
        case .badge(let id, _, _): return id
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


    private enum CodingKeys: String, CodingKey {
        case kind, id, label, used, limit, format, resetsAt, periodDurationMs, values, text, tone, points, value
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
                tone: try c.decode(BadgeTone.self, forKey: .tone)
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
        case let .badge(id, text, tone):
            try c.encode("badge", forKey: .kind)
            try c.encode(id, forKey: .id)
            try c.encode(text, forKey: .text)
            try c.encode(tone, forKey: .tone)
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
