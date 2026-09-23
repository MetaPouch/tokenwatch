import Foundation

/// Every assistant turn in omp's session logs (`~/.omp/agent/sessions/**/*.jsonl`, including
/// subagent transcripts), whatever model provider served it. omp is a coding-agent harness that
/// calls model APIs directly, so its usage never shows up in Claude Code's or the Codex CLI's
/// own logs -- and one omp session can switch providers turn to turn. Each history scanner takes
/// the turns for its own provider (`ompProvider(for:)`); the files are parsed once for all of
/// them, retaining parsed history and incrementally reading appended records.
///
/// omp normalizes every provider's usage to disjoint buckets -- `input` excludes cache reads and
/// writes, and the four add up to `totalTokens` -- and records its own per-turn cost.
enum OmpUsageLog {
    struct Turn: Sendable {
        let timestamp: Date
        /// omp's provider name: `anthropic`, `openai-codex`, ...
        let provider: String
        let model: String
        let input: Int, cacheRead: Int, cacheWrite: Int, output: Int
        /// The part of `cacheWrite` written with a 1-hour TTL (Anthropic only).
        let cacheWrite1h: Int
        /// omp's own cost for the turn, in USD.
        let costUSD: Double?
        let completedAt: Date?
        let durationMs: Double?
    }

    static func roots(homeDirectory: String = NSHomeDirectory()) -> [String] {
        [homeDirectory + "/.omp/agent/sessions"]
    }

    /// The omp provider name whose turns belong to a TokenWatch provider: Anthropic API calls are
    /// Claude usage; `openai-codex` (a ChatGPT sign-in, the same quota the Codex CLI uses) is Codex.
    static func ompProvider(for provider: ProviderID) -> String? {
        switch provider {
        case .claude: return "anthropic"
        case .codex: return "openai-codex"
        default: return nil
        }
    }

    static func turns(roots: [String] = roots(), modifiedSince: Date) -> [Turn] {
        cache.items(for: TranscriptFiles.recursive(roots: roots, modifiedSince: modifiedSince))
    }

    private static let cache = ParsedFileCache<Turn, Void>(makeState: { () }) { _, data in
        turns(in: data)
    }

    /// Timing is optional metadata: a malformed value must not discard the response's usage.
    private struct TimingNumber: Decodable {
        let value: Double?

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            value = try? container.decode(Double.self)
        }
    }

    private struct Line: Decodable {
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
                let cttl: CacheTTL?
                let cost: Cost?
            }
            let role: String?
            let provider: String?
            let model: String?
            let usage: Usage?
            let duration: TimingNumber?
            let completedAt: TimingNumber?
        }
        let type: String?
        let timestamp: String?
        let message: Message?
    }

    private static func turns(in data: Data) -> [Turn] {
        var turns: [Turn] = []
        for line in data.split(separator: 0x0A) {
            guard let entry = try? JSONDecoder().decode(Line.self, from: line) else { continue }
            guard entry.type == "message", let message = entry.message, message.role == "assistant", let provider = message.provider,
                  let usage = message.usage, let timestampString = entry.timestamp, let timestamp = FlexibleISO8601.parse(timestampString)
            else { continue }
            // omp v18.2.11 packages/ai/src/types.ts: request duration is milliseconds,
            // completedAt is stream completion in epoch milliseconds. Provider implementations
            // measure the whole request (including TTFT/retries), not just token decoding.
            // https://github.com/can1357/oh-my-pi/blob/v18.2.11/packages/ai/src/types.ts
            let completedAt = message.completedAt?.value.flatMap {
                $0.isFinite && $0 > 0 ? Date(timeIntervalSince1970: $0 / 1_000) : nil
            }
            let durationMs = message.duration?.value.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
            turns.append(Turn(
                timestamp: timestamp, provider: provider, model: message.model ?? "",
                input: usage.input ?? 0, cacheRead: usage.cacheRead ?? 0,
                cacheWrite: usage.cacheWrite ?? 0, output: usage.output ?? 0,
                cacheWrite1h: usage.cttl?.ephemeral1h ?? 0, costUSD: usage.cost?.total,
                completedAt: completedAt, durationMs: durationMs
            ))
        }
        return turns
    }
}
