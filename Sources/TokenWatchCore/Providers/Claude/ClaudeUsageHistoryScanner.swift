import Foundation

/// One model's share of a day's (or aggregated period's) spend, ranked for the hover breakdown.
public struct ModelSpend: Sendable, Equatable, Identifiable {
    public let id: String
    public let costUSD: Double
    public let tokens: Int

    public init(id: String, costUSD: Double, tokens: Int) {
        self.id = id
        self.costUSD = costUSD
        self.tokens = tokens
    }
}

/// One local calendar day's worth of Claude token usage, aggregated across every local
/// transcript and priced at API list rates via `ModelPricing`.
public struct ClaudeUsageDay: Sendable, Equatable, Identifiable {
    public let id: String
    public let date: Date
    public let inputTokens: Int
    public let cacheReadTokens: Int
    public let cacheWriteTokens: Int
    public let outputTokens: Int
    public let estimatedCostUSD: Double
    /// True when at least one turn priced into this day used a model not in `ModelPricing`'s
    /// table (fell back to the cheapest known rate) -- the day's total is a rougher estimate
    /// than usual.
    public let hasApproximateRate: Bool
    /// Per-model spend within this day, largest first. Empty for a day with no activity.
    public let modelBreakdown: [ModelSpend]

    public init(id: String, date: Date, inputTokens: Int, cacheReadTokens: Int, cacheWriteTokens: Int, outputTokens: Int, estimatedCostUSD: Double, hasApproximateRate: Bool, modelBreakdown: [ModelSpend] = []) {
        self.id = id
        self.date = date
        self.inputTokens = inputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheWriteTokens = cacheWriteTokens
        self.outputTokens = outputTokens
        self.estimatedCostUSD = estimatedCostUSD
        self.hasApproximateRate = hasApproximateRate
        self.modelBreakdown = modelBreakdown
    }

    public var totalTokens: Int { inputTokens + cacheReadTokens + cacheWriteTokens + outputTokens }
}

/// Scans every local Claude transcript -- both the real `claude` CLI's own session logs
/// (`ClaudeSessionScanner`) and a coding-agent harness's own transcripts (`OmpSessionScanner`) --
/// for a bounded trailing window, summing *every* turn's token usage per calendar day and
/// pricing it at API list rates. Unlike those two scanners (which only care about the single
/// newest turn per file, for cache-temperature), this reads every qualifying line of every file
/// modified within the window, so it's real disk I/O proportional to the window and the
/// machine's session history -- callers should run it off the main actor. Every read is
/// defensive: a missing/unreadable file, or one that doesn't parse, is skipped, never thrown.
public enum ClaudeUsageHistoryScanner {
    public static func dailyUsage(days: Int, now: Date = Date(), calendar: Calendar = .current, claudeRoots: [String]? = nil, ompRoots: [String]? = nil) -> [ClaudeUsageDay] {
        let claudeRoots = claudeRoots ?? ClaudeSessionScanner.projectRoots()
        let ompRoots = ompRoots ?? OmpSessionScanner.projectRoots()
        let todayStart = calendar.startOfDay(for: now)
        let cutoff = calendar.date(byAdding: .day, value: -(days - 1), to: todayStart) ?? todayStart

        var buckets: [String: Bucket] = [:]
        func record(_ turn: Turn) {
            let (timestamp, model, input, cacheRead, cacheWrite, output) = (turn.timestamp, turn.model, turn.input, turn.cacheRead, turn.cacheWrite, turn.output)
            guard timestamp >= cutoff else { return }
            let dayStart = calendar.startOfDay(for: timestamp)
            let key = dayKey(dayStart)
            let (_, approximate) = ModelPricing.rate(provider: .claude, model: model)
            let cost = ModelPricing.costUSD(provider: .claude, model: model, inputTokens: input, cacheReadTokens: cacheRead, cacheWriteTokens: cacheWrite, cacheWrite1hTokens: turn.cacheWrite1h, outputTokens: output)
            var bucket = buckets[key] ?? Bucket(date: dayStart)
            bucket.input += input
            bucket.cacheRead += cacheRead
            bucket.cacheWrite += cacheWrite
            bucket.output += output
            bucket.cost += cost
            bucket.approximate = bucket.approximate || approximate
            var modelBucket = bucket.byModel[model] ?? ModelBucket()
            modelBucket.cost += cost
            modelBucket.tokens += input + cacheRead + cacheWrite + output
            bucket.byModel[model] = modelBucket
            buckets[key] = bucket
        }

        // Claude Code writes one transcript line per content block of a response (thinking,
        // text, each tool call), and every one repeats that response's full `usage` -- summing
        // them all counted real usage ~1.8x over. A resumed session also copies earlier messages
        // into its new file. So count each (message id, request id) once, across all files.
        var seenResponses = Set<String>()
        for path in transcriptPaths(roots: claudeRoots, modifiedSince: cutoff) {
            for turn in claudeCodeTurns(inFileAtPath: path) where turn.timestamp >= cutoff {
                if let key = turn.responseKey, !seenResponses.insert(key).inserted { continue }
                record(turn)
            }
        }
        for path in transcriptPaths(roots: ompRoots, modifiedSince: cutoff) {
            for turn in ompTurns(inFileAtPath: path) where turn.timestamp >= cutoff {
                record(turn)
            }
        }

        var days: [ClaudeUsageDay] = []
        var cursor = cutoff
        var previousCursor: Date?
        while cursor <= todayStart {
            let key = dayKey(cursor)
            let bucket = buckets[key]
            let breakdown = (bucket?.byModel ?? [:])
                .map { ModelSpend(id: $0.key, costUSD: $0.value.cost, tokens: $0.value.tokens) }
                .sorted { $0.costUSD > $1.costUSD }
            days.append(ClaudeUsageDay(
                id: key, date: cursor,
                inputTokens: bucket?.input ?? 0, cacheReadTokens: bucket?.cacheRead ?? 0,
                cacheWriteTokens: bucket?.cacheWrite ?? 0, outputTokens: bucket?.output ?? 0,
                estimatedCostUSD: bucket?.cost ?? 0, hasApproximateRate: bucket?.approximate ?? false,
                modelBreakdown: breakdown
            ))
            let next = calendar.date(byAdding: .day, value: 1, to: cursor) ?? cursor.addingTimeInterval(86400)
            // Defensive: guarantee forward progress even if `calendar` misbehaves, rather than
            // trusting `Calendar.date(byAdding:)` never returns a non-advancing date.
            guard next > cursor, previousCursor != next else { break }
            previousCursor = cursor
            cursor = next
        }
        return days
    }

    private struct Bucket {
        let date: Date
        var input = 0, cacheRead = 0, cacheWrite = 0, output = 0
        var cost = 0.0
        var approximate = false
        var byModel: [String: ModelBucket] = [:]
    }

    private struct ModelBucket {
        var cost = 0.0
        var tokens = 0
    }

    private struct Turn {
        let timestamp: Date
        let model: String
        let input: Int, cacheRead: Int, cacheWrite: Int, output: Int
        /// The part of `cacheWrite` written with a 1-hour TTL (priced at 2x input, not 1.25x).
        var cacheWrite1h = 0
        /// Identifies the API response this turn's usage belongs to, for de-duplication; `nil`
        /// when the line carries no message id (counted as-is, never collapsed together).
        var responseKey: String? = nil
    }


    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static func dayKey(_ dayStart: Date) -> String { dayFormatter.string(from: dayStart) }

    /// Every `.jsonl` under `roots`, recursively, modified at or after `modifiedSince` -- the
    /// same bounded-recursion shape `ClaudeSessionScanner`/`OmpSessionScanner` use, duplicated
    /// here rather than shared since each scanner's file-selection rules differ slightly.
    private static func transcriptPaths(roots: [String], modifiedSince: Date) -> [String] {
        let fileManager = FileManager.default
        var results: [String] = []
        for root in roots {
            guard let enumerator = fileManager.enumerator(atPath: root) else { continue }
            for case let relativePath as String in enumerator {
                guard relativePath.hasSuffix(".jsonl") else { continue }
                let fullPath = root + "/" + relativePath
                guard let attributes = try? fileManager.attributesOfItem(atPath: fullPath),
                      let modified = attributes[.modificationDate] as? Date,
                      modified >= modifiedSince
                else { continue }
                results.append(fullPath)
            }
        }
        return results
    }

    private struct ClaudeCodeLine: Decodable {
        struct Message: Decodable {
            struct Usage: Decodable {
                struct CacheCreation: Decodable {
                    let ephemeral5m: Int?
                    let ephemeral1h: Int?
                    enum CodingKeys: String, CodingKey {
                        case ephemeral5m = "ephemeral_5m_input_tokens"
                        case ephemeral1h = "ephemeral_1h_input_tokens"
                    }
                }
                let inputTokens: Int?
                let cacheReadInputTokens: Int?
                let cacheCreationInputTokens: Int?
                /// Per-TTL split of the cache writes, in current Claude Code logs.
                let cacheCreation: CacheCreation?
                let outputTokens: Int?
                enum CodingKeys: String, CodingKey {
                    case inputTokens = "input_tokens"
                    case cacheReadInputTokens = "cache_read_input_tokens"
                    case cacheCreationInputTokens = "cache_creation_input_tokens"
                    case cacheCreation = "cache_creation"
                    case outputTokens = "output_tokens"
                }
            }
            let id: String?
            let usage: Usage?
            let model: String?
        }
        let type: String?
        let timestamp: String?
        let requestId: String?
        let message: Message?
    }

    private static func claudeCodeTurns(inFileAtPath path: String) -> [Turn] {
        guard let data = FileManager.default.contents(atPath: path), let text = String(data: data, encoding: .utf8) else { return [] }
        var turns: [Turn] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let lineData = line.data(using: .utf8), let entry = try? JSONDecoder().decode(ClaudeCodeLine.self, from: lineData) else { continue }
            guard entry.type == "assistant", let usage = entry.message?.usage, let timestampString = entry.timestamp,
                  let timestamp = FlexibleISO8601.parse(timestampString)
            else { continue }
            let write1h = usage.cacheCreation?.ephemeral1h ?? 0
            let splitTotal = (usage.cacheCreation?.ephemeral5m ?? 0) + write1h
            turns.append(Turn(
                timestamp: timestamp, model: entry.message?.model ?? "",
                input: usage.inputTokens ?? 0, cacheRead: usage.cacheReadInputTokens ?? 0,
                cacheWrite: usage.cacheCreationInputTokens ?? splitTotal, output: usage.outputTokens ?? 0,
                cacheWrite1h: write1h,
                responseKey: entry.message?.id.map { "\($0)|\(entry.requestId ?? "")" }
            ))
        }
        return turns
    }

    private struct OmpLine: Decodable {
        struct Message: Decodable {
            struct Usage: Decodable {
                let input: Int?
                let cacheRead: Int?
                let cacheWrite: Int?
                let output: Int?
            }
            let role: String?
            let provider: String?
            let model: String?
            let usage: Usage?
        }
        let type: String?
        let timestamp: String?
        let message: Message?
    }

    private static func ompTurns(inFileAtPath path: String) -> [Turn] {
        guard let data = FileManager.default.contents(atPath: path), let text = String(data: data, encoding: .utf8) else { return [] }
        var turns: [Turn] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let lineData = line.data(using: .utf8), let entry = try? JSONDecoder().decode(OmpLine.self, from: lineData) else { continue }
            guard entry.type == "message", let message = entry.message, message.role == "assistant", message.provider == "anthropic",
                  let usage = message.usage, let timestampString = entry.timestamp, let timestamp = FlexibleISO8601.parse(timestampString)
            else { continue }
            turns.append(Turn(
                timestamp: timestamp, model: message.model ?? "",
                input: usage.input ?? 0, cacheRead: usage.cacheRead ?? 0,
                cacheWrite: usage.cacheWrite ?? 0, output: usage.output ?? 0
            ))
        }
        return turns
    }
}
