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
            // A cost the log itself carries (what the tool that made the call computed) wins over
            // re-pricing its tokens here, same as OpenUsage/ccusage "auto" cost mode.
            let approximate = turn.carriedCostUSD == nil && ModelPricing.rate(provider: .claude, model: model).approximate
            let cost = turn.carriedCostUSD ?? ModelPricing.costUSD(provider: .claude, model: model, inputTokens: input, cacheReadTokens: cacheRead, cacheWriteTokens: cacheWrite, cacheWrite1hTokens: turn.cacheWrite1h, outputTokens: output)
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

        // Path-sorted so dedup's keep-first is deterministic across runs.
        let codeTurns = transcriptPaths(roots: claudeRoots, modifiedSince: cutoff).sorted()
            .flatMap { claudeCodeTurns(inFileAtPath: $0) }
        for turn in dedup(codeTurns) where turn.timestamp >= cutoff {
            record(turn)
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
        /// The cost the log line itself recorded, used instead of re-pricing the tokens.
        var carriedCostUSD: Double? = nil
        /// Identify the API response this usage belongs to, for `dedup`. A turn with no message
        /// id is always counted, never collapsed into another.
        var messageID: String? = nil
        var requestID: String? = nil
        var isSidechain = false

        var totalTokens: Int { input + cacheRead + cacheWrite + output }
    }

    /// Counts each Claude Code API response once. Claude Code writes one line per content block of
    /// a response (thinking, text, each tool call), each repeating the full usage -- summing every
    /// line overcounted ~1.8x on real logs -- and a resumed session copies earlier messages into
    /// its new file. Ported from OpenUsage's `ClaudeLogUsageScanner.dedup` (itself ccusage's rule):
    /// key on `(message.id, requestId)`, plus a `message.id`-only match whenever a sidechain
    /// (subagent) log is involved, since those replay a parent message under a new request id. On
    /// a collision the main-chain turn wins, then the larger token total; otherwise keep-first.
    private static func dedup(_ turns: [Turn]) -> [Turn] {
        var kept: [Turn] = []
        var exactIndex: [String: Int] = [:]
        var messageIndex: [String: [Int]] = [:]
        func exactKey(_ turn: Turn, _ messageID: String) -> String { "\(messageID)|\(turn.requestID ?? "")" }

        for turn in turns {
            guard let messageID = turn.messageID else {
                kept.append(turn)
                continue
            }
            let key = exactKey(turn, messageID)
            let collision = exactIndex[key] ?? messageIndex[messageID]?.first { turn.isSidechain || kept[$0].isSidechain }
            if let index = collision {
                let existing = kept[index]
                let replace = existing.isSidechain != turn.isSidechain ? existing.isSidechain : turn.totalTokens > existing.totalTokens
                if replace {
                    exactIndex.removeValue(forKey: exactKey(existing, messageID))
                    kept[index] = turn
                    exactIndex[key] = index
                }
                continue
            }
            exactIndex[key] = kept.count
            messageIndex[messageID, default: []].append(kept.count)
            kept.append(turn)
        }
        return kept
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
            /// A response's usage. `iterations` nests further usage objects of the same shape (with
            /// their own `type`/`model`) for work done inside the response, e.g. an advisor model.
            struct Usage: Decodable {
                let inputTokens: Int?
                let cacheReadInputTokens: Int?
                let cacheCreationInputTokens: Int?
                let cacheCreation: ClaudeCacheCreation?
                let outputTokens: Int?
                let type: String?
                let model: String?
                let iterations: [Usage]?
                enum CodingKeys: String, CodingKey {
                    case inputTokens = "input_tokens"
                    case cacheReadInputTokens = "cache_read_input_tokens"
                    case cacheCreationInputTokens = "cache_creation_input_tokens"
                    case cacheCreation = "cache_creation"
                    case outputTokens = "output_tokens"
                    case type, model, iterations
                }
            }
            let id: String?
            let usage: Usage?
            let model: String?
        }
        let type: String?
        let timestamp: String?
        let requestId: String?
        let isSidechain: Bool?
        let costUSD: Double?
        let message: Message?
    }

    private static func claudeCodeTurns(inFileAtPath path: String) -> [Turn] {
        guard let data = FileManager.default.contents(atPath: path), let text = String(data: data, encoding: .utf8) else { return [] }
        var turns: [Turn] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let lineData = line.data(using: .utf8), let entry = try? JSONDecoder().decode(ClaudeCodeLine.self, from: lineData) else { continue }
            guard entry.type == "assistant", let message = entry.message, let usage = message.usage, let timestampString = entry.timestamp,
                  let timestamp = FlexibleISO8601.parse(timestampString)
            else { continue }
            func turn(_ usage: ClaudeCodeLine.Message.Usage, model: String, messageID: String?, carriedCostUSD: Double?) -> Turn {
                let write1h = usage.cacheCreation?.ephemeral1h ?? 0
                let splitTotal = (usage.cacheCreation?.ephemeral5m ?? 0) + write1h
                return Turn(
                    timestamp: timestamp, model: model,
                    input: usage.inputTokens ?? 0, cacheRead: usage.cacheReadInputTokens ?? 0,
                    cacheWrite: usage.cacheCreationInputTokens ?? splitTotal, output: usage.outputTokens ?? 0,
                    cacheWrite1h: write1h, carriedCostUSD: carriedCostUSD,
                    messageID: messageID, requestID: entry.requestId, isSidechain: entry.isSidechain ?? false
                )
            }
            turns.append(turn(usage, model: message.model ?? "", messageID: message.id, carriedCostUSD: entry.costUSD))
            // An advisor model consulted inside this response is billed separately under its own
            // model, so it's its own turn. Other iteration types are already in the parent total.
            var advisorIndex = 0
            for iteration in usage.iterations ?? [] where iteration.type == "advisor_message" {
                guard let model = iteration.model, !model.isEmpty, iteration.inputTokens != nil, iteration.outputTokens != nil else { continue }
                turns.append(turn(iteration, model: model, messageID: message.id.map { "\($0):advisor:\(advisorIndex)" }, carriedCostUSD: nil))
                advisorIndex += 1
            }
        }
        return turns
    }

    private struct OmpLine: Decodable {
        struct Message: Decodable {
            struct Usage: Decodable {
                struct CacheTTL: Decodable {
                    let ephemeral1h: Int?
                }
                struct Cost: Decodable {
                    let total: Double?
                }
                let input: Int?
                let cacheRead: Int?
                let cacheWrite: Int?
                let output: Int?
                /// omp's per-TTL split of the cache writes.
                let cttl: CacheTTL?
                /// omp's own per-turn cost in USD, computed at call time.
                let cost: Cost?
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
                cacheWrite: usage.cacheWrite ?? 0, output: usage.output ?? 0,
                cacheWrite1h: usage.cttl?.ephemeral1h ?? 0, carriedCostUSD: usage.cost?.total
            ))
        }
        return turns
    }
}
