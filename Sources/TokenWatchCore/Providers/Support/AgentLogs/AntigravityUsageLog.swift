import Foundation

/// The Antigravity CLI's transcripts: `~/.gemini/antigravity-cli/brain/<session>/
/// .system_generated/logs/transcript_full.jsonl`. The record shape isn't documented, so each
/// line's usage object (`usage`, `usage_metadata` or `usageMetadata`, at any depth up to 5) is read
/// under either spelling Gemini's API uses. Input includes cached tokens in both. Gemini's
/// `candidatesTokenCount` excludes thinking tokens (`thoughtsTokenCount`, billed as output), while
/// an OpenAI-style `output_tokens` already includes reasoning -- so thoughts are added only to the
/// former.
enum AntigravityUsageLog {
    static func turns(brainDirectory: String, modifiedSince cutoff: Date) -> [LocalUsageTurn] {
        guard !brainDirectory.isEmpty else { return [] }
        let sessions = (try? FileManager.default.contentsOfDirectory(atPath: brainDirectory)) ?? []
        let files = sessions.compactMap { TranscriptFiles.file(atPath: "\(brainDirectory)/\($0)/.system_generated/logs/transcript_full.jsonl") }
            .filter { $0.modified >= cutoff }
        return cache.items(for: files) { path in LooseJSON.lines(ofFileAtPath: path).compactMap(turn(line:)) }
    }

    private static let cache = ParsedFileCache<LocalUsageTurn>()

    static func turn<S: StringProtocol>(line: S) -> LocalUsageTurn? {
        guard let record = LooseJSON.parseObject(line), let usage = findUsage(record, depth: 0) else { return nil }
        func first(_ keys: [String]) -> (value: Int, key: String)? {
            for key in keys where usage[key] != nil { return (LooseJSON.int(usage[key]), key) }
            return nil
        }
        let prompt = first(["input_tokens", "inputTokens", "prompt_token_count", "promptTokenCount"])?.value ?? 0
        let cached = min(prompt, first(["cached_input_tokens", "cachedInputTokens", "cached_content_token_count", "cachedContentTokenCount"])?.value ?? 0)
        let outputField = first(["output_tokens", "outputTokens", "candidates_token_count", "candidatesTokenCount"])
        let thoughts = first(["reasoning_tokens", "reasoningTokens", "thoughts_token_count", "thoughtsTokenCount"])?.value ?? 0
        let thoughtsExcluded = outputField.map { $0.key.hasPrefix("candidates") } ?? true
        let output = (outputField?.value ?? 0) + (thoughtsExcluded ? thoughts : 0)
        guard prompt + output > 0 else { return nil }

        let rawTimestamp = record["created_at"] ?? record["timestamp"] ?? record["createdAt"] ?? usage["timestamp"]
        guard let timestamp = LooseJSON.string(rawTimestamp).flatMap(FlexibleISO8601.parse) ?? LooseJSON.epochDate(rawTimestamp) else { return nil }
        let modelValue = record["model"] ?? usage["model"] ?? record["model_id"]
        let model = LooseJSON.string(modelValue) ?? LooseJSON.string(LooseJSON.object(modelValue)?["id"]) ?? "antigravity"
        return LocalUsageTurn(
            timestamp: timestamp, source: .provider(.antigravity), model: model,
            input: prompt - cached, cacheRead: cached, cacheWrite: 0, output: output, costUSD: nil
        )
    }

    private static func findUsage(_ object: [String: Any], depth: Int) -> [String: Any]? {
        for key in ["usage", "usage_metadata", "usageMetadata"] {
            if let usage = LooseJSON.object(object[key]) { return usage }
        }
        guard depth < 5 else { return nil }
        for child in object.values {
            if let child = LooseJSON.object(child), let usage = findUsage(child, depth: depth + 1) { return usage }
        }
        return nil
    }
}
