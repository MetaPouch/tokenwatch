import Foundation

/// OpenCode's assistant messages. Since v1 every session lives in `<data>/opencode/opencode.db`
/// (a non-release channel build writes `opencode-<channel>.db` beside it), one JSON `data` column
/// per message; older installs left one JSON file per message under
/// `storage/message/<session>/`, which OpenCode migrates into the database -- so the tree is only
/// read when no database exists, or it would count twice.
///
/// OpenCode normalizes usage itself: `tokens.input` excludes cache reads and writes, and
/// `tokens.output` excludes `tokens.reasoning`, which it bills at the output rate. `cost` is
/// what OpenCode computed for the call, 0 for a subscription sign-in -- re-priced then.
///
/// Each message names the provider that served it (`providerID`), attributed like omp's
/// (`HarnessUsageLog.source`). `openai` is ambiguous in OpenCode: an API key, or a ChatGPT
/// sign-in -- the Codex quota -- so its `auth.json` decides.
enum OpenCodeUsageLog {
    static func turns(dataDirectory: String, modifiedSince cutoff: Date) -> [LocalUsageTurn] {
        guard !dataDirectory.isEmpty else { return [] }
        let openAIIsChatGPT = openAISignInIsOAuth(dataDirectory: dataDirectory)
        let databases = databasePaths(dataDirectory: dataDirectory).compactMap(TranscriptFiles.database(atPath:))
        let messages: [Message]
        if databases.isEmpty {
            let files = TranscriptFiles.recursive(roots: [dataDirectory + "/storage/message"], modifiedSince: cutoff) { $0.hasSuffix(".json") }
            messages = legacyCache.items(for: files) { path in
                guard let data = FileManager.default.contents(atPath: path), let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return [] }
                return Message(object).map { [$0] } ?? []
            }
        } else {
            // Cached per database signature; a cache hit from an earlier, wider cutoff is a
            // superset, which the caller's cutoff filter trims.
            messages = databaseCache.items(for: databases) { path in
                SQLiteReader.rows(
                    databasePath: path, sql: "SELECT data FROM message WHERE time_created >= ?",
                    bindings: [.integer(Int64(cutoff.timeIntervalSince1970 * 1000))]
                ) { statement in
                    SQLiteReader.text(statement, 0).flatMap(LooseJSON.parseObject).flatMap(Message.init)
                } ?? []
            }
        }
        return messages.map { $0.turn(openAIIsChatGPT: openAIIsChatGPT) }
    }

    private static let databaseCache = ParsedFileCache<Message>()
    private static let legacyCache = ParsedFileCache<Message>()

    private static func databasePaths(dataDirectory: String) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dataDirectory)) ?? []
        return names.filter { $0 == "opencode.db" || ($0.hasPrefix("opencode-") && $0.hasSuffix(".db")) }
            .sorted().map { dataDirectory + "/" + $0 }
    }

    /// Whether OpenCode's `openai` credential is a ChatGPT sign-in (`"type": "oauth"`) rather than
    /// an API key. Only the type is read.
    static func openAISignInIsOAuth(dataDirectory: String) -> Bool {
        guard let data = FileManager.default.contents(atPath: dataDirectory + "/auth.json"),
              let auth = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return false }
        return LooseJSON.object(auth["openai"])?["type"] as? String == "oauth"
    }

    struct Message: Sendable {
        let timestamp: Date
        let provider: String
        let model: String
        let input: Int, cacheRead: Int, cacheWrite: Int, output: Int
        let cost: Double

        init?(_ object: [String: Any]) {
            guard object["role"] as? String == "assistant", let tokens = LooseJSON.object(object["tokens"]) else { return nil }
            let time = LooseJSON.object(object["time"])
            guard let timestamp = LooseJSON.epochDate(time?["completed"] ?? time?["created"]) else { return nil }
            let cache = LooseJSON.object(tokens["cache"])
            input = LooseJSON.int(tokens["input"])
            cacheRead = LooseJSON.int(cache?["read"])
            cacheWrite = LooseJSON.int(cache?["write"])
            output = LooseJSON.int(tokens["output"]) + LooseJSON.int(tokens["reasoning"])
            guard input + cacheRead + cacheWrite + output > 0 else { return nil }
            self.timestamp = timestamp
            provider = LooseJSON.string(object["providerID"]) ?? ""
            model = LooseJSON.string(object["modelID"]) ?? "unknown"
            cost = LooseJSON.double(object["cost"]) ?? 0
        }

        func turn(openAIIsChatGPT: Bool) -> LocalUsageTurn {
            let source = provider == "openai" && openAIIsChatGPT ? .provider(.codex) : HarnessUsageLog.source(forHarnessProvider: provider)
            return LocalUsageTurn(
                timestamp: timestamp, source: source, model: model,
                input: input, cacheRead: cacheRead, cacheWrite: cacheWrite, output: output,
                costUSD: cost > 0 ? cost : nil
            )
        }
    }
}
