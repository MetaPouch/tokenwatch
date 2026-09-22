import Foundation

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
        func record(timestamp: Date, model: String, input: Int, cacheRead: Int, cacheWrite: Int, output: Int) {
            guard timestamp >= cutoff else { return }
            let dayStart = calendar.startOfDay(for: timestamp)
            let key = dayKey(dayStart)
            let (_, approximate) = ModelPricing.rate(provider: .claude, model: model)
            let cost = ModelPricing.costUSD(provider: .claude, model: model, inputTokens: input, cacheReadTokens: cacheRead, cacheWriteTokens: cacheWrite, outputTokens: output)
            var bucket = buckets[key] ?? Bucket(date: dayStart)
            bucket.input += input
            bucket.cacheRead += cacheRead
            bucket.cacheWrite += cacheWrite
            bucket.output += output
            bucket.cost += cost
            bucket.approximate = bucket.approximate || approximate
            buckets[key] = bucket
        }

        for path in transcriptPaths(roots: claudeRoots, modifiedSince: cutoff) {
            for turn in claudeCodeTurns(inFileAtPath: path) where turn.timestamp >= cutoff {
                record(timestamp: turn.timestamp, model: turn.model, input: turn.input, cacheRead: turn.cacheRead, cacheWrite: turn.cacheWrite, output: turn.output)
            }
        }
        for path in transcriptPaths(roots: ompRoots, modifiedSince: cutoff) {
            for turn in ompTurns(inFileAtPath: path) where turn.timestamp >= cutoff {
                record(timestamp: turn.timestamp, model: turn.model, input: turn.input, cacheRead: turn.cacheRead, cacheWrite: turn.cacheWrite, output: turn.output)
            }
        }

        var days: [ClaudeUsageDay] = []
        var cursor = cutoff
        var previousCursor: Date?
        while cursor <= todayStart {
            let key = dayKey(cursor)
            let bucket = buckets[key]
            days.append(ClaudeUsageDay(
                id: key, date: cursor,
                inputTokens: bucket?.input ?? 0, cacheReadTokens: bucket?.cacheRead ?? 0,
                cacheWriteTokens: bucket?.cacheWrite ?? 0, outputTokens: bucket?.output ?? 0,
                estimatedCostUSD: bucket?.cost ?? 0, hasApproximateRate: bucket?.approximate ?? false
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
    }

    private struct Turn {
        let timestamp: Date
        let model: String
        let input: Int, cacheRead: Int, cacheWrite: Int, output: Int
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
                let inputTokens: Int?
                let cacheReadInputTokens: Int?
                let cacheCreationInputTokens: Int?
                let outputTokens: Int?
                enum CodingKeys: String, CodingKey {
                    case inputTokens = "input_tokens"
                    case cacheReadInputTokens = "cache_read_input_tokens"
                    case cacheCreationInputTokens = "cache_creation_input_tokens"
                    case outputTokens = "output_tokens"
                }
            }
            let usage: Usage?
            let model: String?
        }
        let type: String?
        let timestamp: String?
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
            turns.append(Turn(
                timestamp: timestamp, model: entry.message?.model ?? "",
                input: usage.inputTokens ?? 0, cacheRead: usage.cacheReadInputTokens ?? 0,
                cacheWrite: usage.cacheCreationInputTokens ?? 0, output: usage.outputTokens ?? 0
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
