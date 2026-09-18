import Foundation

enum AntigravityMapper {
    struct FlatBucket {
        let label: String
        let remainingFraction: Double
        let resetsAt: Date?
        let isFiveHour: Bool
    }

    static func map(_ response: AntigravityQuotaSummaryResponse) throws -> [MetricLine] {
        let buckets = (response.groups ?? [])
            .flatMap { $0.buckets ?? [] }
            .filter { $0.disabled != true }
            .compactMap { bucket -> FlatBucket? in
                guard let fraction = bucket.remainingFraction else { return nil }
                return FlatBucket(
                    label: bucket.displayName ?? bucket.bucketId ?? "Quota",
                    remainingFraction: fraction,
                    resetsAt: bucket.resetTime.flatMap(FlexibleISO8601.parse),
                    isFiveHour: (bucket.window ?? "").lowercased() == "5h"
                )
            }

        guard !buckets.isEmpty else {
            throw ProviderError.parse("no quota buckets in response")
        }

        let primary = buckets.first(where: { $0.isFiveHour }) ?? buckets.min { $0.remainingFraction < $1.remainingFraction }!
        var lines: [MetricLine] = [progressLine(id: "primary", bucket: primary)]

        if let secondary = buckets
            .filter({ $0.label != primary.label })
            .min(by: { $0.remainingFraction < $1.remainingFraction }) {
            lines.append(progressLine(id: "secondary", bucket: secondary))
        }

        return lines
    }

    private static func progressLine(id: String, bucket: FlatBucket) -> MetricLine {
        .progress(id: id, label: bucket.label, used: (1 - bucket.remainingFraction) * 100, limit: 100, format: .percent, resetsAt: bucket.resetsAt, periodDurationMs: nil)
    }
}
