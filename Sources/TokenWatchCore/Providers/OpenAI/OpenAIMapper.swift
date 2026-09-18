import Foundation

enum OpenAIMapper {
    static func totalSpend(_ response: OpenAICostsResponse) -> Double {
        response.data.reduce(0) { total, bucket in
            total + bucket.results.reduce(0) { $0 + ($1.amount?.value ?? 0) }
        }
    }

    static func map(today: OpenAICostsResponse, last7Days: OpenAICostsResponse) -> [MetricLine] {
        [
            .values(id: "spend", label: "Spend", values: [
                MetricValue(number: totalSpend(today), kind: "Today", unit: "USD"),
                MetricValue(number: totalSpend(last7Days), kind: "Last 7 days", unit: "USD")
            ])
        ]
    }
}
