import XCTest
@testable import Virtu

final class PayloadBuilderTests: XCTestCase {

    func testMetricTrendPayloadMapsAllFields() {
        let trend = MetricTrend(start: 60, end: 70, min: 55, max: 75, mean: 65, direction: "rising")
        let payload = MetricTrendPayload(from: trend)
        XCTAssertEqual(payload.start, 60)
        XCTAssertEqual(payload.end, 70)
        XCTAssertEqual(payload.min, 55)
        XCTAssertEqual(payload.max, 75)
        XCTAssertEqual(payload.mean, 65)
        XCTAssertEqual(payload.direction, "rising")
    }

    func testLiveStateInsightPayloadMapsModeWindowAndMetrics() {
        let trends: [String: MetricTrend] = [
            "hr": MetricTrend(start: 60, end: 70, min: 55, max: 75, mean: 65, direction: "rising")
        ]
        let payload = LiveStateInsightPayload(windowMinutes: 10, trends: trends)
        XCTAssertEqual(payload.mode, "live_state")
        XCTAssertEqual(payload.windowMinutes, 10)
        XCTAssertEqual(payload.metrics["hr"]?.direction, "rising")
        XCTAssertEqual(payload.metrics["hr"]?.mean, 65)
    }
}
