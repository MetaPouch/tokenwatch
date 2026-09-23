import Foundation

/// Every assistant turn in the session logs of the coding-agent harnesses omp and pi (omp is a pi
/// fork with the same format): `~/.omp/agent/sessions/**/*.jsonl` and `~/.pi/agent/sessions/...`,
/// subagent transcripts included. A harness calls model APIs directly, so its usage never shows
/// up in Claude Code's or the Codex CLI's own logs -- and one session can switch model providers
/// turn to turn. Each turn is attributed to a `SpendSource` by the provider that served it
/// (`source(forHarnessProvider:)`); the files are parsed once for every consumer and cached by size
/// and modification date.
///
/// The harness normalizes every provider's usage to disjoint buckets -- `input` excludes cache
/// reads and writes, and the four add up to `totalTokens` -- and records its own per-turn cost.
enum HarnessUsageLog {
    /// omp's and pi's session directories. pi honors `PI_CODING_AGENT_SESSION_DIR`, else
    /// `PI_CODING_AGENT_DIR/sessions`, else `~/.pi/agent/sessions`.
    static func roots(homeDirectory: String = NSHomeDirectory(), environment: [String: String] = ProcessInfo.processInfo.environment) -> [String] {
        let pi: String
        if let dir = environment["PI_CODING_AGENT_SESSION_DIR"]?.trimmingCharacters(in: .whitespaces), !dir.isEmpty {
            pi = dir
        } else if let dir = environment["PI_CODING_AGENT_DIR"]?.trimmingCharacters(in: .whitespaces), !dir.isEmpty {
            pi = dir + "/sessions"
        } else {
            pi = homeDirectory + "/.pi/agent/sessions"
        }
        return [homeDirectory + "/.omp/agent/sessions", pi]
    }

    /// Which `SpendSource` a provider's usage belongs to -- the service it's billed through -- by
    /// the provider ids omp/pi and OpenCode use. A provider with no TokenWatch counterpart
    /// (DeepSeek, Mistral, Bedrock, Vertex, Groq, ...) is `other`: still counted, just not on a
    /// provider's card.
    static func source(forHarnessProvider provider: String) -> SpendSource {
        switch provider.lowercased() {
        case "anthropic": return .provider(.claude)
        case "openai-codex": return .provider(.codex)
        case "openai": return .provider(.openai)
        case "google", "google-gemini-cli": return .provider(.gemini)
        case "google-antigravity": return .provider(.antigravity)
        case "github-copilot": return .provider(.copilot)
        case "cursor": return .provider(.cursor)
        case "openrouter": return .provider(.openrouter)
        case "zai", "zai-coding-plan", "zhipuai", "zhipuai-coding-plan": return .provider(.zai)
        case "moonshot", "moonshotai", "moonshotai-cn", "kimi", "kimi-coding", "kimi-for-coding": return .provider(.kimi)
        case "xai": return .provider(.grok)
        case "opencode": return .provider(.opencode)
        case "amp": return .provider(.amp)
        default: return .other
        }
    }

    static func turns(roots: [String] = roots(), modifiedSince: Date) -> [LocalUsageTurn] {
        cache.items(for: TranscriptFiles.recursive(roots: roots, modifiedSince: modifiedSince), parse: turns(inFileAtPath:))
    }

    private static let cache = ParsedFileCache<LocalUsageTurn>()

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

    private static func turns(inFileAtPath path: String) -> [LocalUsageTurn] {
        guard let data = FileManager.default.contents(atPath: path), let text = String(data: data, encoding: .utf8) else { return [] }
        var turns: [LocalUsageTurn] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let lineData = line.data(using: .utf8), let entry = try? JSONDecoder().decode(Line.self, from: lineData) else { continue }
            guard entry.type == "message", let message = entry.message, message.role == "assistant", let provider = message.provider,
                  let usage = message.usage, let timestampString = entry.timestamp, let timestamp = FlexibleISO8601.parse(timestampString)
            else { continue }
            turns.append(LocalUsageTurn(
                timestamp: timestamp, source: source(forHarnessProvider: provider), model: message.model ?? "",
                input: usage.input ?? 0, cacheRead: usage.cacheRead ?? 0,
                cacheWrite: usage.cacheWrite ?? 0, output: usage.output ?? 0,
                cacheWrite1h: usage.cttl?.ephemeral1h ?? 0, costUSD: usage.cost?.total
            ))
        }
        return turns
    }
}
