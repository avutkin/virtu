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
}
