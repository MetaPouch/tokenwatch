import Foundation

/// The Grok CLI's usage. Its per-session transcripts carry no token counts; the only local record
/// is the CLI's unified log, `<home>/logs/unified.jsonl`, whose `shell.turn.inference_done`
/// events hold each turn's usage keyed by session id. xAI's usage is OpenAI-shaped:
/// `prompt_tokens` includes `cached_prompt_tokens`, and `completion_tokens` includes reasoning.
/// The model comes from the session's `<home>/sessions/<encoded-cwd>/<sid>/summary.json`.
enum GrokCLIUsageLog {
    private static let logSuffix = "/logs/unified.jsonl"

    static func turns(homes: [String], modifiedSince cutoff: Date) -> [LocalUsageTurn] {
        let logs = homes.filter { !$0.isEmpty }.compactMap { TranscriptFiles.file(atPath: $0 + logSuffix) }.filter { $0.modified >= cutoff }
        let entries = cache.items(for: logs, parse: parse)
        var models: [String: [String: String]] = [:]
        for home in Set(entries.map(\.home)) {
            models[home] = sessionModels(home: home, wanted: Set(entries.lazy.filter { $0.home == home }.map(\.sid)))
        }
        return entries.map { entry in
            LocalUsageTurn(
                timestamp: entry.timestamp, source: .provider(.grok), model: models[entry.home]?[entry.sid] ?? "grok",
                input: entry.input, cacheRead: entry.cacheRead, cacheWrite: 0, output: entry.output, costUSD: nil
            )
        }
    }

    struct Entry: Sendable {
        let home: String
        let sid: String
        let timestamp: Date
        let input: Int, cacheRead: Int, output: Int
    }

    private static let cache = ParsedFileCache<Entry>()

    private static func parse(_ path: String) -> [Entry] {
        let home = String(path.dropLast(logSuffix.count))
        let fileModified = TranscriptFiles.file(atPath: path)?.modified ?? Date()
        return LooseJSON.lines(ofFileAtPath: path).compactMap { line in
            guard line.contains("\"shell.turn.inference_done\""), let object = LooseJSON.parseObject(line),
                  object["msg"] as? String == "shell.turn.inference_done",
                  let sid = LooseJSON.string(object["sid"]), let context = LooseJSON.object(object["ctx"])
            else { return nil }
            let prompt = LooseJSON.int(context["prompt_tokens"])
            let cached = min(prompt, LooseJSON.int(context["cached_prompt_tokens"]))
            let output = LooseJSON.int(context["completion_tokens"])
            guard prompt + output > 0 else { return nil }
            let timestamp = LooseJSON.string(object["ts"]).flatMap(FlexibleISO8601.parse) ?? fileModified
            return Entry(home: home, sid: sid, timestamp: timestamp, input: prompt - cached, cacheRead: cached, output: output)
        }
    }

    /// `current_model_id` from each wanted session's `summary.json`. Bounded, so one enormous or
    /// corrupt sessions tree can't stall a scan.
    private static func sessionModels(home: String, wanted: Set<String>) -> [String: String] {
        var models: [String: String] = [:]
        let fileManager = FileManager.default
        let sessions = home + "/sessions"
        var visited = 0
        for group in (try? fileManager.contentsOfDirectory(atPath: sessions)) ?? [] {
            for sid in (try? fileManager.contentsOfDirectory(atPath: sessions + "/" + group)) ?? [] {
                visited += 1
                if visited > 4096 { return models }
                guard wanted.contains(sid), models[sid] == nil,
                      let data = fileManager.contents(atPath: "\(sessions)/\(group)/\(sid)/summary.json"),
                      let summary = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                      let model = LooseJSON.string(summary["current_model_id"])
                else { continue }
                models[sid] = model
            }
        }
        return models
    }
}
