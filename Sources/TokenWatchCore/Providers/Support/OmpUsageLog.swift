import Foundation

/// Every assistant turn in omp's session logs (`~/.omp/agent/sessions/**/*.jsonl`, including
/// subagent transcripts), whatever model provider served it. omp is a coding-agent harness that
/// calls model APIs directly, so its usage never shows up in Claude Code's or the Codex CLI's
/// own logs -- and one omp session can switch providers turn to turn. Each history scanner takes
/// the turns for its own provider (`ompProvider(for:)`); the files are parsed once for all of
/// them and cached by size and modification date.
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
        cache.items(for: TranscriptFiles.recursive(roots: roots, modifiedSince: modifiedSince), parse: turns(inFileAtPath:))
    }

    private static let cache = ParsedFileCache<Turn>()

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
        }
        let type: String?
        let timestamp: String?
        let message: Message?
    }

    private static func turns(inFileAtPath path: String) -> [Turn] {
        guard let data = FileManager.default.contents(atPath: path), let text = String(data: data, encoding: .utf8) else { return [] }
        var turns: [Turn] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let lineData = line.data(using: .utf8), let entry = try? JSONDecoder().decode(Line.self, from: lineData) else { continue }
            guard entry.type == "message", let message = entry.message, message.role == "assistant", let provider = message.provider,
                  let usage = message.usage, let timestampString = entry.timestamp, let timestamp = FlexibleISO8601.parse(timestampString)
            else { continue }
            turns.append(Turn(
                timestamp: timestamp, provider: provider, model: message.model ?? "",
                input: usage.input ?? 0, cacheRead: usage.cacheRead ?? 0,
                cacheWrite: usage.cacheWrite ?? 0, output: usage.output ?? 0,
                cacheWrite1h: usage.cttl?.ephemeral1h ?? 0, costUSD: usage.cost?.total
            ))
        }
        return turns
    }
}
