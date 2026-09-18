import Foundation

/// Error surfaced by a provider's `refresh()` when it cannot produce a usable snapshot.
/// Every case is display-safe (no secrets embedded).
public enum ProviderError: Error, Sendable, Equatable, Codable {
    case notConfigured
    case credentialsMissing
    case network(String)
    case http(status: Int, message: String?)
    case parse(String)

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
        }
    }

    private enum CodingKeys: String, CodingKey {
        case kind, message, status
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

    public init(provider: ProviderID, plan: String? = nil, lines: [MetricLine] = [], fetchedAt: Date = Date(), error: ProviderError? = nil) {
        self.provider = provider
        self.plan = plan
        self.lines = lines
        self.fetchedAt = fetchedAt
        self.error = error
    }

    /// Convenience factory for a failed refresh.
    public static func error(provider: ProviderID, error: ProviderError) -> ProviderSnapshot {
        ProviderSnapshot(provider: provider, plan: nil, lines: [], fetchedAt: Date(), error: error)
    }

    public var isError: Bool { error != nil }
}
