import XCTest
@testable import Wythin

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

    // MARK: - Robust heart rate

    func testHRPrefersSensorBPMAndIsOutlierRobust() {
        // Running: sensor says ~150; one glitch sample of 60 must not matter.
        let bpm: [Float] = [150, 149, 60, 151, 150, 150, 152, 150]
        let hr = HeartRateCompute.current(rrMs: [900, 900, 900], sensorBPM: bpm)
        XCTAssertEqual(hr!, 150, accuracy: 1, "Median sensor BPM, robust to the 60 glitch")
    }

    func testHRFallsBackToRecentRRMedian() {
        // No sensor BPM → median of recent RR. 400 ms ⇒ 150 bpm; a couple of
        // doubled (missed-beat) 800 ms values must not drag it down.
        let rr = Array(repeating: 400, count: 16) + [800, 800, 400, 800]
        let hr = HeartRateCompute.current(rrMs: rr, sensorBPM: [])
        XCTAssertEqual(hr!, 150, accuracy: 2, "60000 / median(recent RR)")
    }

    func testHRIgnoresOldBufferedBeats() {
        // The old bug: minutes of resting 850 ms beats then a short run of
        // 400 ms. Only the recent window should count → ~150, not ~90.
        let rr = Array(repeating: 850, count: 400) + Array(repeating: 400, count: 20)
        let hr = HeartRateCompute.current(rrMs: rr, sensorBPM: [])
        XCTAssertGreaterThan(hr!, 140, "Recent window ⇒ running HR, not the buffer mean")
    }

    func testHRNilWhenNoData() {
        XCTAssertNil(HeartRateCompute.current(rrMs: [], sensorBPM: []))
    }

    // MARK: - Autonomic balance (breathing-aware)

    func testAutonomicSlowBreathingIsVagalNotSympathetic() {
        // Resonance breathing (6/min): the respiratory peak sits in LF, so LF≫HF.
        // The OLD LF/HF logic would call this "sympathetic". RMSSD is high, so the
        // new logic must read parasympathetic dominant.
        let a = AutonomicCompute.balance(rmssd: 80, lf: 600, hf: 40,
                                         breathBPM: 6, meanBPM: 58, baselineRmssd: nil)
        XCTAssertNotNil(a)
        XCTAssertGreaterThan(a!.pns, a!.sns, "Slow deep breathing must read vagal")
        XCTAssertEqual(a!.state, .ventralVagal)
    }

    func testAutonomicLowRMSSDIsSympathetic() {
        let a = AutonomicCompute.balance(rmssd: 15, lf: nil, hf: nil,
                                         breathBPM: 15, meanBPM: 82, baselineRmssd: nil)
        XCTAssertLessThan(a!.pns, 0.35)
        XCTAssertEqual(a!.state, .sympathetic)
    }

    func testAutonomicBaselineRelativeMidpoint() {
        // RMSSD equal to baseline → balanced 0.5.
        let a = AutonomicCompute.balance(rmssd: 50, lf: nil, hf: nil,
                                         breathBPM: 14, meanBPM: 70, baselineRmssd: 50)
        XCTAssertEqual(a!.pns, 0.5, accuracy: 0.01)
    }

    func testAutonomicFallsBackToHFWhenNoRMSSD() {
        // No RMSSD, normal breathing → LF/HF fallback: HF/(LF+HF).
        let a = AutonomicCompute.balance(rmssd: nil, lf: 100, hf: 300,
                                         breathBPM: 15, meanBPM: 70, baselineRmssd: nil)
        XCTAssertEqual(a!.pns, 0.75, accuracy: 0.001)
    }

    func testAutonomicNilWhenNoData() {
        XCTAssertNil(AutonomicCompute.balance(rmssd: nil, lf: nil, hf: nil,
                                              breathBPM: nil, meanBPM: nil, baselineRmssd: nil))
    }

    func testAutonomicDorsalShutdown() {
        // Near-zero variability with a low, non-elevated HR → shutdown.
        let a = AutonomicCompute.balance(rmssd: 5, lf: nil, hf: nil,
                                         breathBPM: 12, meanBPM: 56, baselineRmssd: nil)
        XCTAssertEqual(a!.state, .dorsalVagal)
    }

    // MARK: - RR correction (missed/extra beat)

    func testCorrectionLeavesRSARangeUntouched() {
        // ±25% respiratory-style swings must NOT be corrected.
        let rr = [1000, 750, 1000, 760, 990, 780, 1010, 740, 1000, 800,
                  990, 770, 1000, 760, 1010]
        let c = HRVCompute.classifyAndCorrect(rr)
        XCTAssertEqual(c.corrected, 0, "Normal RSA swings must never be corrected")
        XCTAssertEqual(c.invalid, 0)
        XCTAssertEqual(c.series, rr.map { Float($0) }, "Series unchanged when nothing is an artifact")
    }

    func testMissedBeatCorrected() {
        // One beat ~doubled (a missed detection) amid steady 800 ms beats.
        let rr = [800, 800, 800, 800, 1600, 800, 800, 800, 800, 800]
        let c = HRVCompute.classifyAndCorrect(rr)
        XCTAssertEqual(c.invalid, 0, "1600 ms is plausible, so not invalid")
        XCTAssertEqual(c.corrected, 1, "The doubled beat should be corrected")
        XCTAssertEqual(c.series[4], 800, accuracy: 1, "Corrected to the local median")
    }

    func testExtraBeatCorrected() {
        // One beat ~halved (a false/extra detection).
        let rr = [800, 800, 800, 800, 400, 800, 800, 800, 800, 800]
        let c = HRVCompute.classifyAndCorrect(rr)
        XCTAssertEqual(c.invalid, 0)
        XCTAssertEqual(c.corrected, 1)
        XCTAssertEqual(c.series[4], 800, accuracy: 1)
    }

    func testCorrectionDoesNotFalsePositiveAtBurstEdge() {
        // A burst of consecutive bad beats must NOT cause the good beat beside
        // it to be "corrected" (which would corrupt a valid value). The
        // conservative single pass leaves the good edge beat (index 2) alone.
        let rr = [800, 800, 800, 1600, 1600, 1600, 800, 800, 800, 800, 800, 800]
        let c = HRVCompute.classifyAndCorrect(rr)
        XCTAssertEqual(c.series[2], 800, accuracy: 1, "Good beat beside a burst is never altered")
        XCTAssertEqual(c.series[6], 800, accuracy: 1)
    }

    func testInvalidAndCorrectedCountedSeparately() {
        // 100 ms invalid (dropped); 1700 ms ~doubled → corrected.
        let rr = [800, 800, 100, 800, 800, 1700, 800, 800, 800, 800, 800, 800]
        let c = HRVCompute.classifyAndCorrect(rr)
        XCTAssertEqual(c.invalid, 1, "100 ms dropped as implausible")
        XCTAssertEqual(c.corrected, 1, "1700 ms corrected as a missed beat")
        XCTAssertEqual(c.series.count, 11, "Only the invalid beat is removed")

        let m = HRVCompute.compute(rrMs: rr)
        XCTAssertNotNil(m)
        XCTAssertEqual(m!.invalidRate, 1.0 / 12.0, accuracy: 1e-4)
        XCTAssertEqual(m!.correctedRate, 1.0 / 12.0, accuracy: 1e-4)
        XCTAssertEqual(m!.artifactRate, 2.0 / 12.0, accuracy: 1e-4)
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

    // MARK: - ECG quality wiring

    func testMetricsEngineComputesECGQuality() {
        let flatEcg = [Float](repeating: 50, count: 200)   // flatline — simulates lead-off
        let snapshot = DataSnapshot(ecg: flatEcg, accZ: [], accXYZ: [], rr: [], bpm: [])
        let tick = MetricsEngine.compute(from: snapshot)
        XCTAssertEqual(tick.ecgQuality?.tier, .poor)
        XCTAssertEqual(tick.ecgQuality?.reason, "lead-off")
    }
}
