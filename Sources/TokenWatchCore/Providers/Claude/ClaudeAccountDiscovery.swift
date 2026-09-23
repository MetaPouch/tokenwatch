import Foundation

/// One additional local Claude Code login beyond the default account `ClaudeAuthStore` resolves --
/// a profile directory a user pointed `CLAUDE_CONFIG_DIR` at for a second (work/personal/etc.)
/// subscription.
struct ClaudeAdditionalAccount: Equatable {
    let configDir: String
    /// `~`-relative label for display when no email is known.
    let sourceLabel: String
    let email: String?
    let credential: ClaudeCredential
}

/// Discovers additional local Claude Code logins beyond the default account, following the same
/// profile-directory convention github.com/superset-sh/superset's own multi-account reader
/// documents: candidates are dot-directories directly under `$HOME` plus directories under
/// `~/.config`, and a candidate counts as a Claude profile once it has produced a working login.
///
/// Scoped to the *file-based* credential only. Claude Code also files a per-profile Keychain item
/// under a service name hashed from the literal `CLAUDE_CONFIG_DIR` string used at login time
/// (several string spellings -- `~/x`, `$HOME/x`, the absolute path, with/without a trailing
/// slash -- need probing to reconstruct the exact hash), which this does not attempt to
/// replicate. A profile whose login only ever reached Keychain (never fell back to writing its
/// own `.credentials.json`, e.g. because Keychain was unlocked and reachable every time that
/// profile's `claude` ran) won't be discovered here. This still covers the common case on a
/// machine where the file fallback is genuinely in use for at least one profile.
enum ClaudeAccountDiscovery {
    /// Every profile directory with its own usable `.credentials.json`, excluding the two
    /// locations the default single-account resolution (`ClaudeAuthStore`) already covers.
    static func discoverAdditionalAccounts(homeDirectory: String = NSHomeDirectory()) -> [ClaudeAdditionalAccount] {
        let excluded: Set<String> = [homeDirectory + "/.claude", homeDirectory + "/.config/claude"]
        var accounts: [ClaudeAdditionalAccount] = []
        for candidate in candidateDirectories(homeDirectory: homeDirectory) {
            guard !excluded.contains(candidate) else { continue }
            guard let credential = readCredential(atConfigDir: candidate) else { continue }
            accounts.append(ClaudeAdditionalAccount(
                configDir: candidate,
                sourceLabel: tildeLabel(candidate, homeDirectory: homeDirectory),
                email: readIdentityEmail(configDir: candidate),
                credential: credential
            ))
        }
        return accounts
    }

    /// Dot-directories directly under `$HOME`, plus directories under `~/.config` -- bounded,
    /// never temp directories or project trees, matching the scan scope of the reference
    /// implementation this was ported from.
    static func candidateDirectories(homeDirectory: String) -> [String] {
        var results: [String] = []
        results.append(contentsOf: subdirectories(of: homeDirectory).filter { path in
            let name = (path as NSString).lastPathComponent
            return name.hasPrefix(".")
        })
        results.append(contentsOf: subdirectories(of: homeDirectory + "/.config"))
        return results.sorted()
    }

    /// Every Claude Code `projects/` directory whose transcripts count toward usage history: the
    /// two default config dirs, each entry of a comma-separated `CLAUDE_CONFIG_DIR`, and every
    /// profile directory (`candidateDirectories`) that is a Claude config dir -- it has a
    /// `projects/` folder and Claude's own `.claude.json` or `.credentials.json`. A profile keeps
    /// its transcripts inside itself, so without this a second account's usage never counts.
    /// Resolved through symlinks and deduplicated, since a profile that shares history links its
    /// `projects/` to `~/.claude/projects` and must not be counted twice.
    static func historyRoots(homeDirectory: String = NSHomeDirectory(), environment: [String: String] = ProcessInfo.processInfo.environment) -> [String] {
        let fileManager = FileManager.default
        var configDirs = [homeDirectory + "/.claude", homeDirectory + "/.config/claude"]
        configDirs += (environment["CLAUDE_CONFIG_DIR"] ?? "").split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { ($0 as NSString).expandingTildeInPath }
        configDirs += candidateDirectories(homeDirectory: homeDirectory).filter { dir in
            fileManager.fileExists(atPath: dir + "/.claude.json") || fileManager.fileExists(atPath: dir + "/.credentials.json")
        }
        return uniqueExistingDirectories(configDirs.map { $0 + "/projects" })
    }

    /// `paths` that exist as directories, resolved through symlinks, first occurrence kept.
    static func uniqueExistingDirectories(_ paths: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for path in paths {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else { continue }
            let resolved = (path as NSString).resolvingSymlinksInPath
            if seen.insert(resolved).inserted { result.append(resolved) }
        }
        return result
    }

    private static func subdirectories(of directory: String) -> [String] {
        let fileManager = FileManager.default
        guard let entries = try? fileManager.contentsOfDirectory(atPath: directory) else { return [] }
        return entries.compactMap { entry -> String? in
            let fullPath = directory + "/" + entry
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: fullPath, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }
            return fullPath
        }
    }

    private static func readCredential(atConfigDir configDir: String) -> ClaudeCredential? {
        guard let data = FileManager.default.contents(atPath: configDir + "/.credentials.json") else { return nil }
        return ClaudeAuthStore.parse(String(data: data, encoding: .utf8))
    }

    private struct ClaudeStateFile: Decodable {
        struct OauthAccount: Decodable { let emailAddress: String? }
        let oauthAccount: OauthAccount?
    }

    /// A custom config dir keeps its own identity state inside itself, at `<dir>/.claude.json`
    /// (unlike the default `~/.claude`, whose sibling identity file lives at `~/.claude.json`
    /// next to it instead).
    private static func readIdentityEmail(configDir: String) -> String? {
        guard let data = FileManager.default.contents(atPath: configDir + "/.claude.json") else { return nil }
        guard let state = try? JSONDecoder().decode(ClaudeStateFile.self, from: data) else { return nil }
        let email = state.oauthAccount?.emailAddress
        return (email?.isEmpty == false) ? email : nil
    }

    private static func tildeLabel(_ path: String, homeDirectory: String) -> String {
        path.hasPrefix(homeDirectory) ? "~" + path.dropFirst(homeDirectory.count) : path
    }
}
