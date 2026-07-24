import XCTest
@testable import Wythin

final class ActivityImpactTests: XCTestCase {

    // MARK: score

    func testScoreAllNeutralIsFifty() {
        XCTAssertEqual(ActivityImpact.score(uplifts: [0, 0, 0]), 50)
    }

    func testScoreAllFullMarksIsHundred() {
        XCTAssertEqual(ActivityImpact.score(uplifts: [18, 18, 18], fullMarks: 18), 100)
    }

    func testScoreAllFullNegativeIsZero() {
        XCTAssertEqual(ActivityImpact.score(uplifts: [-18, -18], fullMarks: 18), 0)
    }

    func testScoreSaturatesBeyondFullMarks() {
        // +300% can't push past 100 for that metric.
        XCTAssertEqual(ActivityImpact.score(uplifts: [300], fullMarks: 18), 100)
    }

    func testScoreMixedAverages() {
        // +18 → g=1, -18 → g=0, 0 → g=0.5 → mean 0.5 → 50.
        XCTAssertEqual(ActivityImpact.score(uplifts: [18, -18, 0], fullMarks: 18), 50)
        // +9 → g=0.75, -9 → g=0.25 → mean 0.5 → 50.
        XCTAssertEqual(ActivityImpact.score(uplifts: [9, -9], fullMarks: 18), 50)
    }

    func testScoreEmptyIsNil() {
        XCTAssertNil(ActivityImpact.score(uplifts: []))
    }

    // MARK: breakdown

    func testBreakdownDeadZone() {
        let b = ActivityImpact.breakdown(uplifts: [12, 1, -1, -8, 0, 3], deadZone: 2)
        XCTAssertEqual(b.improved, 2)   // 12, 3
        XCTAssertEqual(b.held, 3)       // 1, -1, 0
        XCTAssertEqual(b.dipped, 1)     // -8
    }

    // MARK: recommendations

    func testRecommendationsSurfaceTopImproversAndTrend() {
        let moves = [
            MetricMovement(name: "RSA", uplift: 12, vs2mo: 5),
            MetricMovement(name: "HRV", uplift: 15, vs2mo: 6),
            MetricMovement(name: "Stress Balance", uplift: -7, vs2mo: -23),
            MetricMovement(name: "VTI", uplift: 1, vs2mo: -1),
        ]
        let recs = ActivityImpact.recommendations(moves)
        XCTAssertTrue(recs.contains { $0.kind == .keep })
        XCTAssertTrue(recs.contains { $0.kind == .watch })
        XCTAssertTrue(recs.contains { $0.kind == .trend })
        // keep names the two strongest (HRV then RSA).
        let keep = recs.first { $0.kind == .keep }!
        XCTAssertTrue(keep.text.contains("HRV"))
        XCTAssertTrue(keep.text.contains("RSA"))
        // watch names the biggest drop.
        XCTAssertTrue(recs.first { $0.kind == .watch }!.text.contains("Stress Balance"))
        // trend: 2 of 4 beat the 2-month norm (RSA, HRV).
        XCTAssertTrue(recs.first { $0.kind == .trend }!.text.contains("2 of 4"))
    }

    func testRecommendationsEmptyWhenNothingMoves() {
        let moves = [MetricMovement(name: "RSA", uplift: nil, vs2mo: nil)]
        XCTAssertTrue(ActivityImpact.recommendations(moves).isEmpty)
    }
}
