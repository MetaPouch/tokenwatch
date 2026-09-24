import Foundation
import CryptoKit

/// One `PUT /v1/usage` row: a device's usage of one model, through one source, on one local day.
/// Token buckets are disjoint (`input` excludes cache reads and writes).
public struct LeaderboardUsageRow: Codable, Equatable, Sendable {
    public var date: String
    public var source: String
    public var model: String
    public var input: Int
    public var cacheRead: Int
    public var cacheWrite: Int
    public var output: Int
    public var costUSD: Double
    public var approximate: Bool

    public init(date: String, source: String, model: String, input: Int, cacheRead: Int, cacheWrite: Int, output: Int, costUSD: Double, approximate: Bool) {
        self.date = date
        self.source = source
        self.model = model
        self.input = input
        self.cacheRead = cacheRead
        self.cacheWrite = cacheWrite
        self.output = output
        self.costUSD = costUSD
        self.approximate = approximate
    }
}

/// A `PUT /v1/usage` body (the contract's `usage.v1`).
public struct LeaderboardUsageRequest: Codable, Equatable, Sendable {
    public enum Mode: String, Codable, Sendable {
        case incremental
        /// History, possibly split over several requests.
        case backfill
    }

    public struct Client: Codable, Equatable, Sendable {
        public let app: String
        public let version: String
    }

    public let schemaVersion: Int
    public let client: Client
    public let deviceId: String
    public let timeZone: String
    public let mode: Mode
    public let rows: [LeaderboardUsageRow]
}

/// Turns `UsageDay`s into the leaderboard's usage rows and request bodies. Pure: the Settings
/// preview and the sync service call the same functions, so the preview shows exactly the bytes
/// that go out.
public enum LeaderboardPayloadBuilder {
    public static let schemaVersion = 1
    public static let clientApp = "tokenwatch-macos"
    /// The API rejects rows past this index (`too_many_rows`).
    public static let maxRowsPerRequest = 2000
    /// Under the API's 1 MB body limit with room to spare.
    public static let maxBodyBytes = 900_000
    /// The API's `model` limit, in UTF-16 code units.
    static let maxModelLength = 128

    /// One row per (day, source, model) with any tokens or cost, sorted by day, source and model.
    /// `<synthetic>` (messages Claude Code made up locally) is skipped; a missing model id reads
    /// `unknown`. `dates` limits the rows to those local days (`yyyy-MM-dd`).
    public static func rows(from daysBySource: [SpendSource: [UsageDay]], dates: Set<String>? = nil) -> [LeaderboardUsageRow] {
        struct Key: Hashable {
            let date: String
            let source: SpendSource
            let model: String
        }
        var rows: [Key: LeaderboardUsageRow] = [:]
        for (source, days) in daysBySource {
            for day in days where !day.isEmpty && dates.map({ $0.contains(day.id) }) ?? true {
                for spend in day.modelBreakdown where spend.id != "<synthetic>" {
                    let model = modelID(spend.id)
                    let key = Key(date: day.id, source: source, model: model)
                    var row = rows[key] ?? LeaderboardUsageRow(date: day.id, source: source.id, model: model, input: 0, cacheRead: 0, cacheWrite: 0, output: 0, costUSD: 0, approximate: false)
                    row.input += spend.inputTokens
                    row.cacheRead += spend.cacheReadTokens
                    row.cacheWrite += spend.cacheWriteTokens
                    row.output += spend.outputTokens
                    if spend.costUSD.isFinite {
                        row.costUSD += spend.costUSD
                        row.approximate = row.approximate || spend.hasApproximateRate
                    } else {
                        row.approximate = true
                    }
                    rows[key] = row
                }
            }
        }
        return rows
            .filter { $0.value.input + $0.value.cacheRead + $0.value.cacheWrite + $0.value.output > 0 || $0.value.costUSD > 0 }
            .sorted { lhs, rhs in
                if lhs.key.date != rhs.key.date { return lhs.key.date < rhs.key.date }
                if lhs.key.source != rhs.key.source { return lhs.key.source < rhs.key.source }
                return lhs.key.model < rhs.key.model
            }
            .map(\.value)
    }

    /// The request for `rows` (at most `maxRowsPerRequest` of them).
    public static func request(rows: [LeaderboardUsageRow], mode: LeaderboardUsageRequest.Mode, deviceID: String, timeZone: String, clientVersion: String) -> LeaderboardUsageRequest {
        LeaderboardUsageRequest(
            schemaVersion: schemaVersion, client: .init(app: clientApp, version: clientVersion),
            deviceId: deviceID, timeZone: timeZone, mode: mode, rows: rows
        )
    }

    /// The body bytes: pretty-printed with sorted keys, so the preview is readable and identical
    /// to what's sent.
    public static func encode(_ request: LeaderboardUsageRequest) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        // Every field is a string, integer, finite double or bool: this can't fail.
        return (try? encoder.encode(request)) ?? Data()
    }

    /// How many of `rows`' leading rows fit one request: at most `maxRowsPerRequest`, and fewer
    /// if the body would pass `maxBodyBytes`. At least one.
    public static func leadingRowsPerRequest(_ rows: [LeaderboardUsageRow], mode: LeaderboardUsageRequest.Mode, deviceID: String, timeZone: String, clientVersion: String) -> Int {
        var count = min(rows.count, maxRowsPerRequest)
        while count > 1, encode(request(rows: Array(rows.prefix(count)), mode: mode, deviceID: deviceID, timeZone: timeZone, clientVersion: clientVersion)).count > maxBodyBytes {
            count /= 2
        }
        return max(count, 1)
    }

    /// A short digest of one day's rows, to tell whether the day changed since it was last sent.
    public static func fingerprint(_ rows: [LeaderboardUsageRow]) -> String {
        let text = rows
            .map { "\($0.source)|\($0.model)|\($0.input)|\($0.cacheRead)|\($0.cacheWrite)|\($0.output)|\($0.costUSD)|\($0.approximate)" }
            .sorted()
            .joined(separator: "\n")
        return SHA256.hash(data: Data(text.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    /// At most 128 UTF-16 code units, cut at a character boundary; `unknown` when empty.
    static func modelID(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "unknown" }
        guard trimmed.utf16.count > maxModelLength else { return trimmed }
        var cut = ""
        for character in trimmed {
            guard cut.utf16.count + character.utf16.count <= maxModelLength else { break }
            cut.append(character)
        }
        return cut
    }
}
