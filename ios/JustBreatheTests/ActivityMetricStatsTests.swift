import XCTest
@testable import JustBreathe

final class ActivityMetricStatsTests: XCTestCase {
    // during window is [start, end) = offset [0, 1000); after is offset >= 1000.
    private let start = Date(timeIntervalSince1970: 1000)
    private let end   = Date(timeIntervalSince1970: 2000)

    private func v(_ offset: TimeInterval, _ value: Double) -> (date: Date, value: Double) {
        (start.addingTimeInterval(offset), value)
    }

    func testHigherBetterPeakAndAvgUplift() {
        // before 40; during mean 50 (+25%), peak 60 (+50%)
        let s = ActivityMetricStats(
            values: [v(-200, 40), v(-100, 40), v(100, 40), v(500, 60), v(900, 50)],
            direction: .higher, startedAt: start, endedAt: end)
        XCTAssertEqual(s.baseline!, 40, accuracy: 0.001)
        XCTAssertEqual(s.peakValue!, 60, accuracy: 0.001)
        XCTAssertEqual(s.peakUpliftPct!, 50, accuracy: 0.001)
        XCTAssertEqual(s.avgUpliftPct!, 25, accuracy: 0.001)
    }

    func testLowerBetterDropReadsAsPositiveUplift() {
        // HR-like: before 60, during trough 48 → +20% improvement; peak = lowest
        let s = ActivityMetricStats(
            values: [v(-100, 60), v(100, 60), v(500, 48), v(900, 54)],
            direction: .lower, startedAt: start, endedAt: end)
        XCTAssertEqual(s.peakValue!, 48, accuracy: 0.001)
        XCTAssertEqual(s.peakUpliftPct!, 20, accuracy: 0.001)
        XCTAssertGreaterThan(s.avgUpliftPct!, 0)
    }

    func testTargetGettingCloserIsPositive() {
        // DFA target 1.0: before 0.7 (gap .3), best 0.95 (gap .05) → +83.3%
        let s = ActivityMetricStats(
            values: [v(-100, 0.7), v(500, 0.95), v(900, 0.85)],
            direction: .target(1.0), startedAt: start, endedAt: end)
        XCTAssertEqual(s.peakValue!, 0.95, accuracy: 0.001)
        XCTAssertEqual(s.peakUpliftPct!, 83.333, accuracy: 0.01)
    }

    func testTargetBaselineAtTargetYieldsNilNotCrash() {
        let s = ActivityMetricStats(
            values: [v(-100, 1.0), v(500, 0.9)],
            direction: .target(1.0), startedAt: start, endedAt: end)
        XCTAssertNil(s.peakUpliftPct)
    }

    func testRetentionHalfDecay() {
        // before 40, peak 60 (gain 20), after mean 50 → retained 50%
        let s = ActivityMetricStats(
            values: [v(-100, 40), v(500, 60), v(1100, 50), v(1500, 50)],
            direction: .higher, startedAt: start, endedAt: end)
        XCTAssertEqual(s.retainedPct!, 50, accuracy: 0.001)
    }

    func testTimeToBaselineReturn() {
        // gain 20, threshold 2 → first after value <= 42 returns. v(1300)=41.
        let s = ActivityMetricStats(
            values: [v(-100, 40), v(500, 60), v(1100, 55), v(1300, 41)],
            direction: .higher, startedAt: start, endedAt: end)
        XCTAssertEqual(s.timeToBaselineSeconds!, 300, accuracy: 0.001)
    }

    func testWorsenedMetricHasNoRetentionOrReturn() {
        // during peak (55) worse than baseline (60): gain <= 0
        let s = ActivityMetricStats(
            values: [v(-100, 60), v(500, 55), v(1100, 58)],
            direction: .higher, startedAt: start, endedAt: end)
        XCTAssertNil(s.retainedPct)
        XCTAssertNil(s.timeToBaselineSeconds)
    }

    func testEmptyInputsAreNil() {
        let s = ActivityMetricStats(values: [], direction: .higher, startedAt: start, endedAt: end)
        XCTAssertNil(s.baseline)
        XCTAssertNil(s.peakValue)
        XCTAssertNil(s.peakUpliftPct)
        XCTAssertNil(s.retainedPct)
        XCTAssertNil(s.timeToBaselineSeconds)
    }

    func testNoBeforeYieldsNilUplift() {
        let s = ActivityMetricStats(values: [v(500, 60)], direction: .higher, startedAt: start, endedAt: end)
        XCTAssertNotNil(s.peakValue)
        XCTAssertNil(s.peakUpliftPct)
    }
}
