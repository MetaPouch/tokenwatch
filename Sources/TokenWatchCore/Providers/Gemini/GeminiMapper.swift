import Foundation

enum GeminiMapper {
    struct ModelQuota {
        let modelId: String
        let percentLeft: Double
        let resetsAt: Date?
    }

    static func map(_ response: GeminiQuotaResponse) throws -> [MetricLine] {
        guard let buckets = response.buckets, !buckets.isEmpty else {
            throw ProviderError.parse("no quota buckets in response")
        }

        var lowestPerModel: [String: (fraction: Double, resetTime: String?)] = [:]
        for bucket in buckets {
            guard let modelId = bucket.modelId, let fraction = bucket.remainingFraction else { continue }
            if let existing = lowestPerModel[modelId], existing.fraction <= fraction {
                continue
            }
            lowestPerModel[modelId] = (fraction, bucket.resetTime)
        }

        let quotas = lowestPerModel.map { modelId, info in
            ModelQuota(modelId: modelId, percentLeft: info.fraction * 100, resetsAt: info.resetTime.flatMap(FlexibleISO8601.parse))
        }

        let lower: [(String, ModelQuota)] = quotas.map { ($0.modelId.lowercased(), $0) }
        let proMin = lower.filter { isProModel($0.0) }.min { $0.1.percentLeft < $1.1.percentLeft }
        let flashMin = lower.filter { isFlashModel($0.0) }.min { $0.1.percentLeft < $1.1.percentLeft }

        var lines: [MetricLine] = []
        if let pro = proMin?.1 {
            lines.append(progressLine(id: "pro", label: "Pro", quota: pro))
        }
        if let flash = flashMin?.1 {
            lines.append(progressLine(id: "flash", label: "Flash", quota: flash))
        }
        return lines
    }

    private static func progressLine(id: String, label: String, quota: ModelQuota) -> MetricLine {
        .progress(id: id, label: label, used: 100 - quota.percentLeft, limit: 100, format: .percent, resetsAt: quota.resetsAt, periodDurationMs: 24 * 3600 * 1000)
    }

    private static func isFlashModel(_ id: String) -> Bool {
        id.contains("flash")
    }

    private static func isProModel(_ id: String) -> Bool {
        id.contains("pro")
    }
}
