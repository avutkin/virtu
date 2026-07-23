import XCTest
@testable import Virtu

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

    func testRRTierBoundaries() {
        XCTAssertEqual(ECGQualityCompute.rrTier(fromSignalQuality: 0.97), .good)
        XCTAssertEqual(ECGQualityCompute.rrTier(fromSignalQuality: 0.95), .good)
        XCTAssertEqual(ECGQualityCompute.rrTier(fromSignalQuality: 0.85), .okay)
        XCTAssertEqual(ECGQualityCompute.rrTier(fromSignalQuality: 0.80), .okay)
        XCTAssertEqual(ECGQualityCompute.rrTier(fromSignalQuality: 0.50), .poor)
    }

    func testCombinedTierNilWhenNoData() {
        XCTAssertNil(ECGQualityCompute.combinedTier(rrSignalQuality: nil, ecgResult: nil))
    }

    func testCombinedTierTakesWorseOfTwo() {
        let ecgGood = ECGQualityResult(tier: .good, reason: "clean")
        let combined = ECGQualityCompute.combinedTier(rrSignalQuality: 0.50, ecgResult: ecgGood)
        XCTAssertEqual(combined?.tier, .poor)     // RR side is worse (50% artifacts)
        XCTAssertEqual(combined?.rrArtifactPercent, 50)
        XCTAssertEqual(combined?.ecgReason, "clean")
    }

    func testCombinedTierUsesOnlyAvailableSide() {
        let combined = ECGQualityCompute.combinedTier(rrSignalQuality: 0.97, ecgResult: nil)
        XCTAssertEqual(combined?.tier, .good)
        XCTAssertNil(combined?.ecgReason)
    }

    func testCombinedTierTakesWorseOfTwoWhenECGIsWorse() {
        let ecgPoor = ECGQualityResult(tier: .poor, reason: "lead-off")
        let combined = ECGQualityCompute.combinedTier(rrSignalQuality: 0.97, ecgResult: ecgPoor)
        XCTAssertEqual(combined?.tier, .poor)     // ECG side is worse (lead-off)
        XCTAssertEqual(combined?.ecgReason, "lead-off")
    }

    func testCombinedTierUsesOnlyAvailableSideECGOnly() {
        let ecgGood = ECGQualityResult(tier: .good, reason: "clean")
        let combined = ECGQualityCompute.combinedTier(rrSignalQuality: nil, ecgResult: ecgGood)
        XCTAssertEqual(combined?.tier, .good)
        XCTAssertNil(combined?.rrArtifactPercent)
        XCTAssertEqual(combined?.ecgReason, "clean")
    }

    func testClipMinRunLengthBoundaryCountsAsClipping() {
        var ecg: [Float] = (0..<200).map { i in Float(i % 37) * 17.3 - 300 }
        let railValue: Float = 1000
        for i in 50..<55 { ecg[i] = railValue }   // exactly 5 consecutive — the clipMinRunLength boundary
        let result = ECGQualityCompute.compute(ecg: ecg)
        XCTAssertEqual(result?.tier, .okay)   // 5/200 = 2.5%, well under the 10% Poor threshold
        XCTAssertEqual(result?.reason, "clipping")
    }

    func testClipPoorFractionBoundaryTipsIntoPoor() {
        var ecg: [Float] = (0..<200).map { i in Float(i % 37) * 17.3 - 300 }
        let railValue: Float = 1000
        for i in 50..<70 { ecg[i] = railValue }   // exactly 20 consecutive (10% of window) — the clipPoorFraction boundary
        let result = ECGQualityCompute.compute(ecg: ecg)
        XCTAssertEqual(result?.tier, .poor)
        XCTAssertEqual(result?.reason, "clipping")
    }
}
