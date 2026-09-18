import Foundation

enum CopilotMapper {
    static func map(_ response: CopilotUserResponse) -> (lines: [MetricLine], plan: String?) {
        let snapshot = response.quotaSnapshots?.premiumInteractions ?? response.quotaSnapshots?.chat
        var lines: [MetricLine] = []
        if let percentRemaining = snapshot?.percentRemaining {
            lines.append(.progress(
                id: "quota",
                label: "Premium interactions",
                used: 100 - percentRemaining,
                limit: 100,
                format: .percent,
                resetsAt: nil,
                periodDurationMs: nil
            ))
        }
        return (lines, response.copilotPlan)
    }
}
