import Foundation

/// Cursor's per-request usage history. Cursor keeps no token counts on disk, but its dashboard
/// RPC `DashboardService/GetFilteredUsageEvents` returns every request on the account -- the
/// app's, the `cursor-agent` CLI's, and any other client signed into it -- with exact token splits
/// and cost, authorized by Cursor.app's saved sign-in (`CursorAuthStore.validAccessToken`, a local
/// file read). Only fetched while the Cursor provider is enabled; that's the same account and
/// network destination the provider's own refresh already uses.
///
/// `inputTokens` excludes cache reads and writes, which have their own fields. `totalCents` is the
/// request's cost at the model's token rates -- comparable with the API-rate estimates elsewhere --
/// where `chargedCents` includes Cursor's own fee and is only the fallback.
public enum CursorUsageHistory {
    private static let endpoint = URL(string: "https://api2.cursor.sh/aiserver.v1.DashboardService/GetFilteredUsageEvents")!
    private static let pageSize = 300
    /// A bound on pagination: 12,000 requests in the window is far past heavy use.
    private static let maxPages = 40

    /// The window's days, or `nil` when there's no usable Cursor.app sign-in or the fetch fails --
    /// the caller then keeps what it had.
    public static func dailyUsage(days: Int, now: Date = Date(), calendar: Calendar = .current, authStore: CursorAuthStore = CursorAuthStore(), httpClient: HTTPClient = .shared) async -> [UsageDay]? {
        guard let token = authStore.validAccessToken() else { return nil }
        var accumulator = UsageDayAccumulator(days: days, now: now, calendar: calendar)
        guard let events = try? await fetchEvents(token: token, since: accumulator.cutoff, until: now, httpClient: httpClient) else { return nil }
        for turn in turns(events) where turn.timestamp >= accumulator.cutoff {
            let repriced = ModelPricing.listCostUSD(
                model: turn.model, inputTokens: turn.input, cacheReadTokens: turn.cacheRead,
                cacheWriteTokens: turn.cacheWrite, cacheWrite1hTokens: 0, outputTokens: turn.output
            )
            accumulator.add(
                timestamp: turn.timestamp, model: turn.model,
                input: turn.input, cacheRead: turn.cacheRead, cacheWrite: turn.cacheWrite, output: turn.output,
                costUSD: turn.costUSD ?? repriced.cost, approximate: turn.costUSD == nil && repriced.approximate
            )
        }
        return accumulator.build()
    }

    struct Page: Decodable {
        let totalUsageEventsCount: LenientNumber?
        let usageEventsDisplay: [Event]?
    }

    struct Event: Decodable {
        struct TokenUsage: Decodable {
            let inputTokens: LenientNumber?
            let outputTokens: LenientNumber?
            let cacheReadTokens: LenientNumber?
            let cacheWriteTokens: LenientNumber?
            let totalCents: LenientNumber?
        }
        let timestamp: LenientNumber?
        let model: String?
        let tokenUsage: TokenUsage?
        let chargedCents: LenientNumber?
    }

    /// A JSON number, or a number in a string (proto3 JSON writes 64-bit integers that way).
    struct LenientNumber: Decodable {
        let value: Double

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let number = try? container.decode(Double.self) {
                value = number
            } else if let string = try? container.decode(String.self), let number = Double(string) {
                value = number
            } else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Not a number")
            }
        }

        var int: Int { max(0, Int(value)) }
    }

    static func turns(_ events: [Event]) -> [LocalUsageTurn] {
        events.compactMap { event in
            guard let usage = event.tokenUsage, let milliseconds = event.timestamp?.value, milliseconds > 0 else { return nil }
            let input = usage.inputTokens?.int ?? 0, output = usage.outputTokens?.int ?? 0
            let cacheRead = usage.cacheReadTokens?.int ?? 0, cacheWrite = usage.cacheWriteTokens?.int ?? 0
            guard input + output + cacheRead + cacheWrite > 0 else { return nil }
            let cents = [usage.totalCents?.value, event.chargedCents?.value].lazy.compactMap { $0 }.first { $0 > 0 }
            return LocalUsageTurn(
                timestamp: Date(timeIntervalSince1970: milliseconds / 1000), source: .provider(.cursor),
                model: event.model.flatMap { $0.isEmpty ? nil : $0 } ?? "unknown",
                input: input, cacheRead: cacheRead, cacheWrite: cacheWrite, output: output,
                costUSD: cents.map { $0 / 100 }
            )
        }
    }

    private static func fetchEvents(token: String, since: Date, until: Date, httpClient: HTTPClient) async throws -> [Event] {
        var events: [Event] = []
        for page in 1...maxPages {
            let body: [String: Any] = [
                "teamId": 0,
                "startDate": String(Int64(since.timeIntervalSince1970 * 1000)),
                "endDate": String(Int64(until.timeIntervalSince1970 * 1000)),
                "page": page,
                "pageSize": pageSize,
            ]
            let response: Page = try await httpClient.post(
                endpoint,
                headers: ["Authorization": "Bearer \(token)", "Content-Type": "application/json"],
                body: try JSONSerialization.data(withJSONObject: body)
            )
            let pageEvents = response.usageEventsDisplay ?? []
            events += pageEvents
            // A short page ends the scan; the reported total ends it early only when present.
            if pageEvents.count < pageSize { break }
            if let total = response.totalUsageEventsCount?.int, total > 0, events.count >= total { break }
        }
        return events
    }
}
