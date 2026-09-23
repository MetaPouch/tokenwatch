import Foundation

/// Scans every local Claude transcript -- both the real `claude` CLI's own session logs
/// (`ClaudeSessionScanner`) and a coding-agent harness's own transcripts (`OmpSessionScanner`) --
/// for a bounded trailing window, summing *every* turn's token usage per calendar day and
/// pricing it at API list rates. Unlike those two scanners (which only care about the single
/// newest turn per file, for cache-temperature), this reads every qualifying line of every file
/// modified within the window, so it's real disk I/O proportional to the window and the
/// machine's session history -- callers should run it off the main actor. Every read is
/// defensive: a missing/unreadable file, or one that doesn't parse, is skipped, never thrown.
public enum ClaudeUsageHistoryScanner {
    public static func dailyUsage(days: Int, now: Date = Date(), calendar: Calendar = .current, claudeRoots: [String]? = nil, ompRoots: [String]? = nil) -> [UsageDay] {
        let claudeRoots = claudeRoots ?? ClaudeSessionScanner.projectRoots()
        let ompRoots = ompRoots ?? OmpSessionScanner.projectRoots()
        var accumulator = UsageDayAccumulator(days: days, now: now, calendar: calendar)
        let cutoff = accumulator.cutoff

        func record(_ turn: Turn) {
            // A cost the log itself carries (what the tool that made the call computed) wins over
            // re-pricing its tokens here, same as OpenUsage/ccusage "auto" cost mode.
            let approximate = turn.carriedCostUSD == nil && ModelPricing.rate(provider: .claude, model: turn.model).approximate
            let cost = turn.carriedCostUSD ?? ModelPricing.costUSD(provider: .claude, model: turn.model, inputTokens: turn.input, cacheReadTokens: turn.cacheRead, cacheWriteTokens: turn.cacheWrite, cacheWrite1hTokens: turn.cacheWrite1h, outputTokens: turn.output)
            accumulator.add(timestamp: turn.timestamp, model: turn.model, input: turn.input, cacheRead: turn.cacheRead, cacheWrite: turn.cacheWrite, output: turn.output, costUSD: cost, approximate: approximate)
        }

        // Path-sorted so dedup's keep-first is deterministic across runs.
        let codeFiles = transcriptFiles(roots: claudeRoots, modifiedSince: cutoff).sorted { $0.path < $1.path }
        for turn in dedup(claudeCodeCache.turns(for: codeFiles, parse: claudeCodeTurns)) where turn.timestamp >= cutoff {
            record(turn)
        }
        for turn in ompCache.turns(for: transcriptFiles(roots: ompRoots, modifiedSince: cutoff), parse: ompTurns) where turn.timestamp >= cutoff {
            record(turn)
        }
        return accumulator.build()
    }

    /// Parsed turns of each transcript, reused across scans while its size and modification date
    /// are unchanged (as OpenUsage does) -- a rescan then only parses files that changed, instead
    /// of seconds of re-decoding a month of untouched history on every refresh cycle. Holds only
    /// the files of the latest scan, so it never grows past the scan window.
    private final class TurnCache: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [String: (size: Int, modified: Date, turns: [Turn])] = [:]

        func turns(for files: [TranscriptFile], parse: (String) -> [Turn]) -> [Turn] {
            lock.lock()
            defer { lock.unlock() }
            var next: [String: (size: Int, modified: Date, turns: [Turn])] = [:]
            var all: [Turn] = []
            for file in files {
                let turns: [Turn]
                if let cached = entries[file.path], cached.size == file.size, cached.modified == file.modified {
                    turns = cached.turns
                } else {
                    turns = parse(file.path)
                }
                next[file.path] = (file.size, file.modified, turns)
                all += turns
            }
            entries = next
            return all
        }
    }

    private static let claudeCodeCache = TurnCache()
    private static let ompCache = TurnCache()

    private struct TranscriptFile {
        let path: String
        let size: Int
        let modified: Date
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

    /// Every `.jsonl` under `roots`, recursively, modified at or after `modifiedSince` -- the
    /// same bounded-recursion shape `ClaudeSessionScanner`/`OmpSessionScanner` use, duplicated
    /// here rather than shared since each scanner's file-selection rules differ slightly.
    private static func transcriptFiles(roots: [String], modifiedSince: Date) -> [TranscriptFile] {
        let fileManager = FileManager.default
        var results: [TranscriptFile] = []
        for root in roots {
            guard let enumerator = fileManager.enumerator(atPath: root) else { continue }
            for case let relativePath as String in enumerator {
                guard relativePath.hasSuffix(".jsonl") else { continue }
                let fullPath = root + "/" + relativePath
                guard let attributes = try? fileManager.attributesOfItem(atPath: fullPath),
                      let modified = attributes[.modificationDate] as? Date,
                      modified >= modifiedSince
                else { continue }
                results.append(TranscriptFile(path: fullPath, size: (attributes[.size] as? Int) ?? -1, modified: modified))
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
            // `<synthetic>` marks a message Claude Code generated locally, not an API call: $0.
            let model = message.model ?? ""
            turns.append(turn(usage, model: model, messageID: message.id, carriedCostUSD: model == "<synthetic>" ? 0 : entry.costUSD))
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
