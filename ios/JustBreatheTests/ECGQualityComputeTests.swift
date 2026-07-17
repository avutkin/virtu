import XCTest
@testable import JustBreathe

final class ECGQualityComputeTests: XCTestCase {

    func testInsufficientSamplesReturnsNil() {
        let ecg: [Float] = Array(repeating: 0, count: 50)   // below the 130-sample (~1s) minimum
        XCTAssertNil(ECGQualityCompute.compute(ecg: ecg))
    }

    func testFlatlineDetected() {
        // Constant signal — no cardiac variability, simulates lead-off/no contact
        let ecg: [Float] = Array(repeating: 120, count: 200)
        let result = ECGQualityCompute.compute(ecg: ecg)
        XCTAssertEqual(result?.tier, .poor)
        XCTAssertEqual(result?.reason, "lead-off")
    }

    func testCleanSignalIsGood() {
        // Deterministic non-repeating pattern — no two consecutive samples are
        // ever within clipping tolerance of each other, so no run can form.
        let ecg: [Float] = (0..<200).map { i in Float(i % 37) * 17.3 - 300 }
        let result = ECGQualityCompute.compute(ecg: ecg)
        XCTAssertEqual(result?.tier, .good)
        XCTAssertEqual(result?.reason, "clean")
    }

    func testSustainedClippingDetectedAsPoor() {
        var ecg: [Float] = (0..<200).map { i in Float(i % 37) * 17.3 - 300 }
        let railValue: Float = 1000   // clearly outside the base signal's own range
        for i in 50..<90 { ecg[i] = railValue }   // 40 consecutive pinned samples (20% of window)
        let result = ECGQualityCompute.compute(ecg: ecg)
        XCTAssertEqual(result?.tier, .poor)
        XCTAssertEqual(result?.reason, "clipping")
    }

    func testBriefClippingDetectedAsOkay() {
        var ecg: [Float] = (0..<200).map { i in Float(i % 37) * 17.3 - 300 }
        let railValue: Float = 1000
        for i in 50..<56 { ecg[i] = railValue }   // 6 consecutive pinned samples (3% of window)
        let result = ECGQualityCompute.compute(ecg: ecg)
        XCTAssertEqual(result?.tier, .okay)
        XCTAssertEqual(result?.reason, "clipping")
    }

    func testShortPinnedRunIsIgnored() {
        var ecg: [Float] = (0..<200).map { i in Float(i % 37) * 17.3 - 300 }
        let railValue: Float = 1000
        for i in 50..<53 { ecg[i] = railValue }   // only 3 consecutive — below the run-length gate
        let result = ECGQualityCompute.compute(ecg: ecg)
        XCTAssertEqual(result?.tier, .good)
        XCTAssertEqual(result?.reason, "clean")
    }
}
