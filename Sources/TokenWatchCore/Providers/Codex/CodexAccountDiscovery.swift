import Foundation

/// One additional local Codex login beyond the default `~/.codex` (or `CODEX_HOME`-overridden)
/// home -- a `CODEX_HOME` directory a user pointed a second `codex login` at.
struct CodexAdditionalAccount: Equatable {
    let home: String
    let sourceLabel: String
    let accessToken: String
}

/// Discovers additional local Codex logins beyond the default home: every `~/.codex*`
/// dot-directory (the common multi-account convention -- one `CODEX_HOME` per account) that
/// carries its own `auth.json` with a usable token, other than the default home itself. Codex's
/// `auth.json` carries no identity field of its own (unlike Claude's sibling `.claude.json`); an
/// account's email surfaces later, from the usage endpoint's own response, once fetched.
enum CodexAccountDiscovery {
    static func discoverAdditionalAccounts(homeDirectory: String = NSHomeDirectory(), environment: [String: String] = ProcessInfo.processInfo.environment) -> [CodexAdditionalAccount] {
        let defaultHome: String
        if let codexHome = environment["CODEX_HOME"], !codexHome.isEmpty {
            defaultHome = codexHome
        } else {
            defaultHome = homeDirectory + "/.codex"
        }

        let fileManager = FileManager.default
        guard let entries = try? fileManager.contentsOfDirectory(atPath: homeDirectory) else { return [] }

        var accounts: [CodexAdditionalAccount] = []
        for entry in entries.sorted() where entry.hasPrefix(".codex") {
            let fullPath = homeDirectory + "/" + entry
            guard fullPath != defaultHome else { continue }
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: fullPath, isDirectory: &isDirectory), isDirectory.boolValue else { continue }
            guard let token = readAccessToken(codexHome: fullPath) else { continue }
            accounts.append(CodexAdditionalAccount(home: fullPath, sourceLabel: tildeLabel(fullPath, homeDirectory: homeDirectory), accessToken: token))
        }
        return accounts
    }

    /// Every rollout directory whose sessions count toward usage history: `sessions/` and
    /// `archived_sessions/` of the default home (`CODEX_HOME`, else `~/.codex`) and of every other
    /// `~/.codex*` home -- one per account by convention, each keeping its own rollouts. Resolved
    /// through symlinks and deduplicated so a linked home isn't scanned twice.
    static func historyRoots(homeDirectory: String = NSHomeDirectory(), environment: [String: String] = ProcessInfo.processInfo.environment) -> [String] {
        var homes = [environment["CODEX_HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? homeDirectory + "/.codex"]
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: homeDirectory)) ?? []
        homes += entries.sorted().filter { $0.hasPrefix(".codex") }.map { homeDirectory + "/" + $0 }
        return ClaudeAccountDiscovery.uniqueExistingDirectories(homes.flatMap { [$0 + "/sessions", $0 + "/archived_sessions"] })
    }

    private static func readAccessToken(codexHome: String) -> String? {
        guard let data = FileManager.default.contents(atPath: codexHome + "/auth.json") else { return nil }
        guard let file = try? JSONDecoder().decode(CodexAuthFile.self, from: data) else { return nil }
        return file.tokens?.accessToken
    }

    private static func tildeLabel(_ path: String, homeDirectory: String) -> String {
        path.hasPrefix(homeDirectory) ? "~" + path.dropFirst(homeDirectory.count) : path
    }
}
