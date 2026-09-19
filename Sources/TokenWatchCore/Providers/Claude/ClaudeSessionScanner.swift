import Foundation

/// Token usage from the most recent assistant turn in a local Claude Code session transcript --
/// the raw material for cache-temperature (see `ClaudeCacheTemperature`).
struct ClaudeSessionActivity: Equatable {
    let timestamp: Date
    let inputTokens: Int
    let cacheReadTokens: Int
    let cacheCreationTokens: Int
    /// Best-effort, human-glanceable identifier for which project/session this activity came
    /// from -- disambiguates concurrent sessions, since a user may have several Claude Code
    /// windows open and this always reflects whichever one was touched most recently. Derived
    /// from the transcript's containing directory name (see `sessionLabel(forTranscriptPath:)`);
    /// never `nil` in practice, but not a reliable exact path reconstruction.
    let sessionLabel: String
}

/// Finds the single most recently written line across every local Claude Code session
/// transcript and extracts its token usage. Read-only, best-effort: any I/O or parse failure
/// yields `nil` rather than throwing -- this is enrichment, never a reason to fail a refresh.
enum ClaudeSessionScanner {
    /// Project roots Claude Code writes session transcripts under, in the same precedence as
    /// the local cost-usage scan documented for the Claude provider: an explicit
    /// `CLAUDE_CONFIG_DIR` selects one directory; otherwise both common install locations are
    /// checked (some setups use `~/.config/claude`, most use `~/.claude`).
    static func projectRoots(homeDirectory: String = NSHomeDirectory(), environment: [String: String] = ProcessInfo.processInfo.environment) -> [String] {
        if let configDir = environment["CLAUDE_CONFIG_DIR"], !configDir.isEmpty {
            return [configDir + "/projects"]
        }
        return [homeDirectory + "/.config/claude/projects", homeDirectory + "/.claude/projects"]
    }

    /// The most recent assistant-turn usage across every `.jsonl` transcript under the project
    /// roots, or `nil` if no roots exist, none contain a transcript, or none contain a parseable
    /// assistant usage line.
    static func mostRecentActivity(roots: [String] = projectRoots()) -> ClaudeSessionActivity? {
        guard let newestFile = newestTranscriptFile(roots: roots) else { return nil }
        return lastAssistantActivity(inFileAtPath: newestFile, sessionLabel: sessionLabel(forTranscriptPath: newestFile))
    }

    /// Best-effort label for the project a transcript belongs to. Claude Code names each
    /// project directory after the absolute working-directory path with every `/` rewritten to
    /// `-` (e.g. `/Users/alice/app` -> `-Users-alice-app`) -- lossy to reverse exactly, since a
    /// literal `-` in a real directory name is indistinguishable from an encoded `/`. Rather than
    /// guess wrong, this strips the one prefix it can verify (the current user's home directory,
    /// encoded the same way) and shows the informative tail, truncated for a menu/tooltip.
    static func sessionLabel(forTranscriptPath path: String, homeDirectory: String = NSHomeDirectory()) -> String {
        let projectDirectoryName = ((path as NSString).deletingLastPathComponent as NSString).lastPathComponent
        let encodedHome = homeDirectory.replacingOccurrences(of: "/", with: "-")

        var label = projectDirectoryName
        if label.hasPrefix(encodedHome) {
            label = String(label.dropFirst(encodedHome.count))
        }
        label = label.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        if label.isEmpty {
            label = projectDirectoryName
        }

        let maxLength = 32
        if label.count > maxLength {
            label = "…" + label.suffix(maxLength - 1)
        }
        return label
    }

    private static func newestTranscriptFile(roots: [String]) -> String? {
        let fileManager = FileManager.default
        var newestPath: String?
        var newestModified = Date.distantPast

        for root in roots {
            guard let enumerator = fileManager.enumerator(atPath: root) else { continue }
            for case let relativePath as String in enumerator {
                guard relativePath.hasSuffix(".jsonl") else { continue }
                let fullPath = root + "/" + relativePath
                guard let attributes = try? fileManager.attributesOfItem(atPath: fullPath),
                      let modified = attributes[.modificationDate] as? Date
                else { continue }
                if modified > newestModified {
                    newestModified = modified
                    newestPath = fullPath
                }
            }
        }
        return newestPath
    }

    /// Scans `path` from the end for the last `type: "assistant"` line carrying a
    /// `message.usage` object, matching the shape CodexBar's local cost-usage scanner documents
    /// for these transcripts (verified against a live session file during implementation).
    private static func lastAssistantActivity(inFileAtPath path: String, sessionLabel: String) -> ClaudeSessionActivity? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        guard let text = String(data: data, encoding: .utf8) else { return nil }

        for line in text.split(separator: "\n", omittingEmptySubsequences: true).reversed() {
            guard let lineData = line.data(using: .utf8) else { continue }
            guard let entry = try? JSONDecoder().decode(TranscriptLine.self, from: lineData) else { continue }
            guard entry.type == "assistant", let usage = entry.message?.usage, let timestampString = entry.timestamp else { continue }
            guard let timestamp = FlexibleISO8601.parse(timestampString) else { continue }
            return ClaudeSessionActivity(
                timestamp: timestamp,
                inputTokens: usage.inputTokens ?? 0,
                cacheReadTokens: usage.cacheReadInputTokens ?? 0,
                cacheCreationTokens: usage.cacheCreationInputTokens ?? 0,
                sessionLabel: sessionLabel
            )
        }
        return nil
    }

    private struct TranscriptLine: Decodable {
        struct Message: Decodable {
            struct Usage: Decodable {
                let inputTokens: Int?
                let cacheReadInputTokens: Int?
                let cacheCreationInputTokens: Int?

                enum CodingKeys: String, CodingKey {
                    case inputTokens = "input_tokens"
                    case cacheReadInputTokens = "cache_read_input_tokens"
                    case cacheCreationInputTokens = "cache_creation_input_tokens"
                }
            }
            let usage: Usage?
        }
        let type: String?
        let timestamp: String?
        let message: Message?
    }
}
