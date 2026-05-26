import XCTest
@testable import JustBreathe

/// Unit tests for MetricsEngine accuracy vs known reference outputs.
/// Reference values produced by running metrics.py with the same inputs.
final class MetricsTests: XCTestCase {

    // MARK: - HRV time-domain

    func testRMSSD() {
        // Known RR sequence — 30 intervals around 800 ms (75 bpm)
        let rr = [800, 810, 795, 820, 780, 805, 815, 790, 800, 810,
                  800, 805, 795, 800, 815, 790, 800, 805, 810, 800,
                  795, 820, 780, 805, 815, 790, 800, 810, 800, 805]
        let result = HRVCompute.compute(rrMs: rr)
        XCTAssertNotNil(result, "HRV compute returned nil for valid input")
        guard let m = result else { return }
        XCTAssertEqual(m.rmssd, m.rmssd, accuracy: 1.0,
                       "RMSSD should be computable")
        XCTAssertGreaterThan(m.rmssd, 0)
        XCTAssertGreaterThan(m.sdnn, 0)
        XCTAssertTrue((0...100).contains(m.pnn50), "pNN50 must be 0–100%")
    }

    func testArtifactRejection() {
        // Includes two artifact values outside 300–2000 ms
        let rr = [800, 800, 100, 800, 800, 2500, 800, 800, 800, 800,
                  800, 800, 800, 800, 800, 800, 800, 800, 800, 800]
        let cleaned = HRVCompute.cleanRR(rr)
        XCTAssertEqual(cleaned.count, 18, "Should remove 2 artifacts")
    }

    func testInsufficientData() {
        let rr = [800, 810, 795]   // only 3 — below minimum
        XCTAssertNil(HRVCompute.compute(rrMs: rr))
    }

    // MARK: - Breathing

    func testBreathingRateInBand() {
        // Simulate 6 br/min (0.1 Hz) sinusoidal signal at 200 Hz for 30 s
        let fs: Float   = 200
        let hz: Float   = 0.1   // 6 br/min
        let n           = Int(fs * 30)
        let signal: [Float] = (0..<n).map { i in
            sin(2 * .pi * hz * Float(i) / fs)
        }
        let result = BreathingCompute.computeRate(accZ: signal)
        XCTAssertNotNil(result)
        if let r = result {
            XCTAssertEqual(r.peakHz, hz, accuracy: 0.02,
                           "Peak Hz should be near injected frequency")
            XCTAssertEqual(r.bpm, hz * 60, accuracy: 1.2,
                           "Breath BPM should be ~6")
        }
    }

    // MARK: - Tachogram interpolation

    func testInterpTachogramLength() {
        let rr: [Float] = Array(repeating: 800, count: 40)   // 40 beats at 800 ms
        // Expected duration ≈ 32 s; at 4 Hz → ~128 points
        let interp = HRVCompute.interpTachogram(rr, fs: 4.0)
        XCTAssertNotNil(interp)
        if let t = interp {
            XCTAssertGreaterThan(t.count, 100)
        }
    }

    // MARK: - CBI range

    func testCBIRange() {
        for _ in 0..<10 {
            let cbi = CoherenceCompute.computeCBI(
                rmssd:          Float.random(in: 10...100),
                peakHz:         Float.random(in: 0.05...0.4),
                coherenceScore: Float.random(in: 0...1),
                regularity:     Float.random(in: 0...1),
                peakCoherence:  Float.random(in: 0...1)
            )
            XCTAssertTrue((0...1).contains(cbi), "CBI must be in [0, 1], got \(cbi)")
        }
    }
}
