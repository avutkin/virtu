import XCTest
@testable import Virtu

final class LiveStateTrendComputeTests: XCTestCase {

    /// Builds `count` points spaced 2s apart, ending at `now`, with the given
    /// HR values in chronological order (oldest first).
    private func points(count: Int, hrValues: [Float], now: Date = Date()) -> [MetricsHistoryPoint] {
        (0..<count).map { i in
            MetricsHistoryPoint(
                timestamp: now.addingTimeInterval(-Double(count - i) * 2),
                meanBPM: hrValues[i]
            )
        }
    }

    func testReturnsNilBelowMinimumPoints() {
        let history = points(count: 30, hrValues: Array(repeating: 70, count: 30))
        XCTAssertNil(LiveStateTrendCompute.summarize(history, windowMinutes: 10))
    }

    func testComputesStartEndMinMaxMean() {
        let values: [Float] = (0..<60).map { Float(60 + $0) }   // 60...119, ascending
        let history = points(count: 60, hrValues: values)
        let result = LiveStateTrendCompute.summarize(history, windowMinutes: 10)
        let hr = result?["hr"]
        XCTAssertEqual(hr?.start, 60)
        XCTAssertEqual(hr?.end, 119)
        XCTAssertEqual(hr?.min, 60)
        XCTAssertEqual(hr?.max, 119)
        XCTAssertEqual(hr?.mean ?? 0, 89.5, accuracy: 0.01)
    }

    func testDetectsRisingDirection() {
        let values = [Float](repeating: 60, count: 30) + [Float](repeating: 80, count: 30)
        let history = points(count: 60, hrValues: values)
        let result = LiveStateTrendCompute.summarize(history, windowMinutes: 10)
        XCTAssertEqual(result?["hr"]?.direction, "rising")
    }

    func testDetectsFallingDirection() {
        let values = [Float](repeating: 80, count: 30) + [Float](repeating: 60, count: 30)
        let history = points(count: 60, hrValues: values)
        let result = LiveStateTrendCompute.summarize(history, windowMinutes: 10)
        XCTAssertEqual(result?["hr"]?.direction, "falling")
    }

    func testDetectsStableDirection() {
        let values = [Float](repeating: 70, count: 60)
        let history = points(count: 60, hrValues: values)
        let result = LiveStateTrendCompute.summarize(history, windowMinutes: 10)
        XCTAssertEqual(result?["hr"]?.direction, "stable")
    }

    func testOmitsMetricWithNoValuesInWindow() {
        let history = points(count: 60, hrValues: Array(repeating: 70, count: 60))
        let result = LiveStateTrendCompute.summarize(history, windowMinutes: 10)
        XCTAssertNotNil(result?["hr"])
        XCTAssertNil(result?["rsa"])
    }

    func testExcludesPointsOutsideWindow() {
        let now = Date()
        // 60 points 20 minutes old (outside a 10-min window) + 60 recent points.
        let old = (0..<60).map { i in
            MetricsHistoryPoint(timestamp: now.addingTimeInterval(-1200 - Double(60 - i) * 2), meanBPM: 40)
        }
        let recent = (0..<60).map { i in
            MetricsHistoryPoint(timestamp: now.addingTimeInterval(-Double(60 - i) * 2), meanBPM: 70)
        }
        let result = LiveStateTrendCompute.summarize(old + recent, windowMinutes: 10, now: now)
        XCTAssertEqual(result?["hr"]?.mean, 70)
    }
}
