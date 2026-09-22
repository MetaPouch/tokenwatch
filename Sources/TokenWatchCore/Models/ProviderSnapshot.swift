import Foundation

/// Error surfaced by a provider's `refresh()` when it cannot produce a usable snapshot.
/// Every case is display-safe (no secrets embedded).
public enum ProviderError: Error, Sendable, Equatable, Codable {
    case notConfigured
    case credentialsMissing
    case network(String)
    case http(status: Int, message: String?)
    case parse(String)
    /// A credential was found and is structurally valid, but locally known (from its own expiry
    /// timestamps, no network call) to be temporarily unusable. `selfHeals` distinguishes "the
    /// CLI silently renews this on its next run, no action needed" from "the login itself has
    /// lapsed, sign in again" -- conflating the two as one generic error message would either
    /// alarm a user over a normal, self-correcting state, or under-inform one who genuinely needs
    /// to re-authenticate. `detail` is the full final user-facing message.
    case credentialLapsed(selfHeals: Bool, detail: String)

    /// Short human-readable summary suitable for a dashboard error badge.
    public var displayMessage: String {
        switch self {
        case .notConfigured:
            return "Not configured"
        case .credentialsMissing:
            return "Not signed in"
        case .network(let message):
            return "Network error: \(message)"
        case .http(let status, let message):
            if let message, !message.isEmpty {
                return "HTTP \(status): \(message)"
            }
            return "HTTP \(status)"
        case .parse(let message):
            return "Parse error: \(message)"
        case .credentialLapsed(_, let detail):
            return detail
        }
    }

    private enum CodingKeys: String, CodingKey {
        case kind, message, status, selfHeals
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(String.self, forKey: .kind)
        switch kind {
        case "notConfigured": self = .notConfigured
        case "credentialsMissing": self = .credentialsMissing
        case "network": self = .network(try c.decode(String.self, forKey: .message))
        case "http": self = .http(status: try c.decode(Int.self, forKey: .status), message: try c.decodeIfPresent(String.self, forKey: .message))
        case "parse": self = .parse(try c.decode(String.self, forKey: .message))
        case "credentialLapsed": self = .credentialLapsed(selfHeals: try c.decode(Bool.self, forKey: .selfHeals), detail: try c.decode(String.self, forKey: .message))
        default:
            throw DecodingError.dataCorruptedError(forKey: .kind, in: c, debugDescription: "Unknown ProviderError kind '\(kind)'")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .notConfigured:
            try c.encode("notConfigured", forKey: .kind)
        case .credentialsMissing:
            try c.encode("credentialsMissing", forKey: .kind)
        case .network(let message):
            try c.encode("network", forKey: .kind)
            try c.encode(message, forKey: .message)
        case .http(let status, let message):
            try c.encode("http", forKey: .kind)
            try c.encode(status, forKey: .status)
            try c.encodeIfPresent(message, forKey: .message)
        case .parse(let message):
            try c.encode("parse", forKey: .kind)
            try c.encode(message, forKey: .message)
        case .credentialLapsed(let selfHeals, let detail):
            try c.encode("credentialLapsed", forKey: .kind)
            try c.encode(selfHeals, forKey: .selfHeals)
            try c.encode(detail, forKey: .message)
        }
    }
}

/// The normalized result of polling one provider: either a set of metric lines or an error.
/// Codable so `WidgetDataStore` can persist the last-known snapshot for instant display.
public struct ProviderSnapshot: Sendable, Equatable, Codable {
    public let provider: ProviderID
    public let plan: String?
    public let lines: [MetricLine]
    public let fetchedAt: Date
    public let error: ProviderError?
    /// When a provider can determine it (currently: Claude, from local session transcripts),
    /// the timestamp of the most recent local activity -- the signal behind the menu bar's
    /// "last tool used" display. `nil` for providers with no such local signal.
    public let lastActivityAt: Date?
    /// A best-effort, human-glanceable label for whatever `lastActivityAt` refers to (currently:
    /// Claude's most-recently-touched project directory name) -- disambiguates which of
    /// possibly several concurrent sessions the activity timestamp and cache-temperature badge
    /// describe. `nil` when `lastActivityAt` is `nil`, or when a provider has an activity signal
    /// but no meaningful label for it.
    public let lastActivityLabel: String?

    public init(provider: ProviderID, plan: String? = nil, lines: [MetricLine] = [], fetchedAt: Date = Date(), error: ProviderError? = nil, lastActivityAt: Date? = nil, lastActivityLabel: String? = nil) {
        self.provider = provider
        self.plan = plan
        self.lines = lines
        self.fetchedAt = fetchedAt
        self.error = error
        self.lastActivityAt = lastActivityAt
        self.lastActivityLabel = lastActivityLabel
    }

    /// Convenience factory for a failed refresh.
    public static func error(provider: ProviderID, error: ProviderError) -> ProviderSnapshot {
        ProviderSnapshot(provider: provider, plan: nil, lines: [], fetchedAt: Date(), error: error)
    }

    public var isError: Bool { error != nil }

    /// The tone of the `cacheTemperature` badge line, if this snapshot has one.
    public var cacheTemperatureTone: BadgeTone? {
        for line in lines {
            if case let .badge(id, _, tone, _, _) = line, id == "cacheTemperature" {
                return tone
            }
        }
        return nil
    }
}
