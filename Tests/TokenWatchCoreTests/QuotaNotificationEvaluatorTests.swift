import XCTest
@testable import TokenWatchCore

final class QuotaNotificationEvaluatorTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let allEnabled = QuotaAlertSettings(almostOut: true, cuttingItClose: true, willRunOut: true)

    func testFirstEvaluationEverEstablishesBaselineWithoutAlerting() {
        // A metric already at 95% used the moment the evaluator sees it for the first time
        // (e.g. right after app launch) must not alarm -- only a *new* crossing alerts.
        let evaluator = QuotaNotificationEvaluator()
        let alerts = evaluator.evaluate(provider: .claude, metricID: "session", label: "Session", used: 95, limit: 100, resetsAt: nil, periodDurationMs: nil, settings: allEnabled, now: now)
        XCTAssertTrue(alerts.isEmpty)
    }

    func testAlmostOutFiresOnceCrossingBelowTenPercentRemaining() {
        let evaluator = QuotaNotificationEvaluator()
        _ = evaluator.evaluate(provider: .claude, metricID: "session", label: "Session", used: 50, limit: 100, resetsAt: nil, periodDurationMs: nil, settings: allEnabled, now: now)
        let alerts = evaluator.evaluate(provider: .claude, metricID: "session", label: "Session", used: 92, limit: 100, resetsAt: nil, periodDurationMs: nil, settings: allEnabled, now: now)
        XCTAssertEqual(alerts.map(\.trigger), [.almostOut])
    }

    func testAlmostOutDoesNotReFireWhileStillBelowTenPercentRemaining() {
        let evaluator = QuotaNotificationEvaluator()
        _ = evaluator.evaluate(provider: .claude, metricID: "session", label: "Session", used: 50, limit: 100, resetsAt: nil, periodDurationMs: nil, settings: allEnabled, now: now)
        _ = evaluator.evaluate(provider: .claude, metricID: "session", label: "Session", used: 92, limit: 100, resetsAt: nil, periodDurationMs: nil, settings: allEnabled, now: now)
        let secondAlerts = evaluator.evaluate(provider: .claude, metricID: "session", label: "Session", used: 95, limit: 100, resetsAt: nil, periodDurationMs: nil, settings: allEnabled, now: now)
        XCTAssertTrue(secondAlerts.isEmpty)
    }

    func testAlmostOutReArmsAfterRecoveringThenCrossingAgain() {
        let evaluator = QuotaNotificationEvaluator()
        _ = evaluator.evaluate(provider: .claude, metricID: "session", label: "Session", used: 50, limit: 100, resetsAt: nil, periodDurationMs: nil, settings: allEnabled, now: now)
        _ = evaluator.evaluate(provider: .claude, metricID: "session", label: "Session", used: 92, limit: 100, resetsAt: nil, periodDurationMs: nil, settings: allEnabled, now: now)
        // Recovers (e.g. limit increased, or this is a rolling balance) below the threshold.
        _ = evaluator.evaluate(provider: .claude, metricID: "session", label: "Session", used: 50, limit: 100, resetsAt: nil, periodDurationMs: nil, settings: allEnabled, now: now)
        let alerts = evaluator.evaluate(provider: .claude, metricID: "session", label: "Session", used: 91, limit: 100, resetsAt: nil, periodDurationMs: nil, settings: allEnabled, now: now)
        XCTAssertEqual(alerts.map(\.trigger), [.almostOut])
    }

    func testDisabledTriggerNeverFiresEvenWhenConditionIsMet() {
        let evaluator = QuotaNotificationEvaluator()
        let settings = QuotaAlertSettings(almostOut: false, cuttingItClose: true, willRunOut: true)
        _ = evaluator.evaluate(provider: .claude, metricID: "session", label: "Session", used: 50, limit: 100, resetsAt: nil, periodDurationMs: nil, settings: settings, now: now)
        let alerts = evaluator.evaluate(provider: .claude, metricID: "session", label: "Session", used: 95, limit: 100, resetsAt: nil, periodDurationMs: nil, settings: settings, now: now)
        XCTAssertTrue(alerts.isEmpty)
    }

    func testWillRunOutFiresWhenPaceProjectsPastTheLimit() {
        let evaluator = QuotaNotificationEvaluator()
        let resetsAt = now.addingTimeInterval(60 * 60)
        let periodMs = 100 * 60 * 1000
        // Baseline while healthy.
        _ = evaluator.evaluate(provider: .codex, metricID: "weekly", label: "Weekly", used: 5, limit: 100, resetsAt: resetsAt, periodDurationMs: periodMs, settings: allEnabled, now: now)
        // 60% used after 40% elapsed -> projects to 150% -> .behind.
        let alerts = evaluator.evaluate(provider: .codex, metricID: "weekly", label: "Weekly", used: 60, limit: 100, resetsAt: resetsAt, periodDurationMs: periodMs, settings: allEnabled, now: now)
        XCTAssertEqual(alerts.map(\.trigger), [.willRunOut])
    }

    func testWillRunOutDoesNotReFireOnAnEvenWorsePaceReading() {
        let evaluator = QuotaNotificationEvaluator()
        let resetsAt = now.addingTimeInterval(60 * 60)
        let periodMs = 100 * 60 * 1000
        _ = evaluator.evaluate(provider: .codex, metricID: "weekly", label: "Weekly", used: 5, limit: 100, resetsAt: resetsAt, periodDurationMs: periodMs, settings: allEnabled, now: now)
        _ = evaluator.evaluate(provider: .codex, metricID: "weekly", label: "Weekly", used: 60, limit: 100, resetsAt: resetsAt, periodDurationMs: periodMs, settings: allEnabled, now: now)
        let secondAlerts = evaluator.evaluate(provider: .codex, metricID: "weekly", label: "Weekly", used: 80, limit: 100, resetsAt: resetsAt, periodDurationMs: periodMs, settings: allEnabled, now: now)
        XCTAssertTrue(secondAlerts.isEmpty)
    }

    func testCuttingItCloseThenWorseningToWillRunOutFiresBoth() {
        let evaluator = QuotaNotificationEvaluator()
        let resetsAt = now.addingTimeInterval(60 * 60)
        let periodMs = 100 * 60 * 1000
        _ = evaluator.evaluate(provider: .codex, metricID: "weekly", label: "Weekly", used: 5, limit: 100, resetsAt: resetsAt, periodDurationMs: periodMs, settings: allEnabled, now: now)
        // 37% used after 40% elapsed -> projects ~92.5% -> .onTrack ("cutting it close").
        let first = evaluator.evaluate(provider: .codex, metricID: "weekly", label: "Weekly", used: 37, limit: 100, resetsAt: resetsAt, periodDurationMs: periodMs, settings: allEnabled, now: now)
        XCTAssertEqual(first.map(\.trigger), [.cuttingItClose])
        // Then worsens into .behind -- a strictly worse trigger, must re-fire as willRunOut.
        let second = evaluator.evaluate(provider: .codex, metricID: "weekly", label: "Weekly", used: 60, limit: 100, resetsAt: resetsAt, periodDurationMs: periodMs, settings: allEnabled, now: now)
        XCTAssertEqual(second.map(\.trigger), [.willRunOut])
    }

    func testResetWindowRollingOverClearsHistoryAndAllowsReAlerting() {
        let evaluator = QuotaNotificationEvaluator()
        let firstReset = now.addingTimeInterval(60 * 60)
        let periodMs = 100 * 60 * 1000
        _ = evaluator.evaluate(provider: .codex, metricID: "weekly", label: "Weekly", used: 5, limit: 100, resetsAt: firstReset, periodDurationMs: periodMs, settings: allEnabled, now: now)
        _ = evaluator.evaluate(provider: .codex, metricID: "weekly", label: "Weekly", used: 60, limit: 100, resetsAt: firstReset, periodDurationMs: periodMs, settings: allEnabled, now: now)

        // A new period starts -- resetsAt moves forward. The very next read after rollover
        // becomes the new baseline (silent), even if it's already in a bad state.
        let secondReset = firstReset.addingTimeInterval(7 * 24 * 3600)
        let laterNow = now.addingTimeInterval(2 * 3600)
        let afterRollover = evaluator.evaluate(provider: .codex, metricID: "weekly", label: "Weekly", used: 60, limit: 100, resetsAt: secondReset, periodDurationMs: periodMs, settings: allEnabled, now: laterNow)
        XCTAssertTrue(afterRollover.isEmpty)
    }

    func testUnboundedLimitNeverAlerts() {
        let evaluator = QuotaNotificationEvaluator()
        let alerts = evaluator.evaluate(provider: .claude, metricID: "credits", label: "Credits", used: 100, limit: 0, resetsAt: nil, periodDurationMs: nil, settings: allEnabled, now: now)
        XCTAssertTrue(alerts.isEmpty)
    }
}
