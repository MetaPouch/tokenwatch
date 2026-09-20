import Foundation

/// Token usage from the most recent assistant turn in a local Claude Code session transcript --
/// the raw material for cache-temperature (see `ClaudeCacheTemperature`).
struct ClaudeSessionActivity: Equatable {
    /// Absolute path of the transcript this activity was read from -- used to dedupe when a
    /// session already surfaced as the headline "most recent activity" shouldn't also be
    /// repeated in the "other active sessions" list.
    let filePath: String
    let timestamp: Date
    let inputTokens: Int
    let cacheReadTokens: Int
    let cacheCreationTokens: Int
    /// Best-effort, human-glanceable identifier for which project/session this activity came
    /// from -- disambiguates concurrent sessions, since a user may have several Claude Code
    /// windows open and this always reflects whichever one was touched most recently. Prefers
    /// the real working directory Claude Code stamped on the matching transcript line (see
    /// `TranscriptLine.cwd`), reduced to its last path component; falls back to
    /// `sessionLabel(forTranscriptPath:)` only when that field is absent. Never `nil` in
    /// practice, but not a guaranteed exact project name.
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
        return lastAssistantActivity(inFileAtPath: newestFile, fallbackSessionLabel: sessionLabel(forTranscriptPath: newestFile))
    }

    /// Window used by `allRecentActivity` to decide whether a session still counts as "active"
    /// for listing purposes -- matches Anthropic's own 5-hour session-limit window, since that's
    /// already a boundary this app surfaces (the "Session (5h)" progress line) rather than an
    /// arbitrary new one.
    static let activeSessionWindowSeconds: TimeInterval = 5 * 3600

    /// Every distinct local session transcript modified within `windowSeconds` of `now`, newest
    /// first. Unlike `mostRecentActivity` (unbounded, always returns the single newest file no
    /// matter its age), this is the "what do I currently have open" list shown per-session in
    /// the dashboard -- bounded so a user's entire multi-year history isn't scanned or shown.
    static func allRecentActivity(roots: [String] = projectRoots(), now: Date = Date(), windowSeconds: TimeInterval = activeSessionWindowSeconds) -> [ClaudeSessionActivity] {
        let cutoff = now.addingTimeInterval(-windowSeconds)
        let files = transcriptFiles(roots: roots, modifiedSince: cutoff)
        let activities = files.compactMap { file in
            lastAssistantActivity(inFileAtPath: file.path, fallbackSessionLabel: sessionLabel(forTranscriptPath: file.path))
        }
        return activities.sorted { $0.timestamp > $1.timestamp }
    }

    /// Fallback label for the project a transcript belongs to, used only when the transcript's
    /// own lines don't carry a `cwd` field (see `lastAssistantActivity`, which prefers that real
    /// path when present). Claude Code names each project directory after the absolute
    /// working-directory path with every `/` rewritten to `-` (e.g. `/Users/alice/app` ->
    /// `-Users-alice-app`) -- lossy to reverse exactly, since a literal `-` in a real directory
    /// name is indistinguishable from an encoded `/`. Rather than guess wrong, this strips the
    /// one prefix it can verify (the current user's home directory, encoded the same way) and
    /// shows the informative tail, truncated for a menu/tooltip. This is why the real `cwd`
    /// field is strongly preferred where available: for a worktree-per-branch or
    /// worktree-per-task setup, the encoded directory name is the *entire* nested path since
    /// home (parent org/client/tool directories included), not just the project or worktree
    /// leaf name.
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
        return truncated(label)
    }

    /// Caps a session label at a length sane for a menu/tooltip row, keeping the tail (the more
    /// specific end of a path-derived name) rather than the head.
    private static func truncated(_ label: String) -> String {
        let maxLength = 32
        guard label.count > maxLength else { return label }
        return "…" + label.suffix(maxLength - 1)
    }

    /// Every `.jsonl` transcript under `roots` modified at or after `modifiedSince`, with its
    /// modification date. Shared enumeration logic behind both `newestTranscriptFile` (unbounded,
    /// `modifiedSince: .distantPast`) and `allRecentActivity` (bounded to the active window).
    private static func transcriptFiles(roots: [String], modifiedSince: Date) -> [(path: String, modified: Date)] {
        let fileManager = FileManager.default
        var results: [(path: String, modified: Date)] = []

        for root in roots {
            guard let enumerator = fileManager.enumerator(atPath: root) else { continue }
            for case let relativePath as String in enumerator {
                guard relativePath.hasSuffix(".jsonl") else { continue }
                let fullPath = root + "/" + relativePath
                guard let attributes = try? fileManager.attributesOfItem(atPath: fullPath),
                      let modified = attributes[.modificationDate] as? Date,
                      modified >= modifiedSince
                else { continue }
                results.append((fullPath, modified))
            }
        }
        return results
    }

    private static func newestTranscriptFile(roots: [String]) -> String? {
        transcriptFiles(roots: roots, modifiedSince: .distantPast).max { $0.modified < $1.modified }?.path
    }

    /// Scans `path` from the end for the last `type: "assistant"` line carrying a
    /// `message.usage` object, matching the shape CodexBar's local cost-usage scanner documents
    /// for these transcripts (verified against a live session file during implementation).
    /// Claude Code also stamps most lines (including this one) with the real, unencoded working
    /// directory as `cwd` -- reduced to its last path component, that's an exact project/worktree
    /// leaf name with none of the ambiguity `sessionLabel(forTranscriptPath:)` has to work around,
    /// so it's preferred whenever present; `fallbackSessionLabel` only applies to older/malformed
    /// transcripts that predate the `cwd` field.
    private static func lastAssistantActivity(inFileAtPath path: String, fallbackSessionLabel: String) -> ClaudeSessionActivity? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        guard let text = String(data: data, encoding: .utf8) else { return nil }

        for line in text.split(separator: "\n", omittingEmptySubsequences: true).reversed() {
            guard let lineData = line.data(using: .utf8) else { continue }
            guard let entry = try? JSONDecoder().decode(TranscriptLine.self, from: lineData) else { continue }
            guard entry.type == "assistant", let usage = entry.message?.usage, let timestampString = entry.timestamp else { continue }
            guard let timestamp = FlexibleISO8601.parse(timestampString) else { continue }
            let cwdLeaf = entry.cwd.flatMap { cwd -> String? in
                let leaf = (cwd as NSString).lastPathComponent
                return leaf.isEmpty ? nil : leaf
            }
            return ClaudeSessionActivity(
                filePath: path,
                timestamp: timestamp,
                inputTokens: usage.inputTokens ?? 0,
                cacheReadTokens: usage.cacheReadInputTokens ?? 0,
                cacheCreationTokens: usage.cacheCreationInputTokens ?? 0,
                sessionLabel: cwdLeaf.map(truncated) ?? fallbackSessionLabel
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
        let cwd: String?
    }
}
