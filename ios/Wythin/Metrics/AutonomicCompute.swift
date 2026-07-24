import Foundation

// MARK: - Train State

enum TrainState: Equatable {
    case calibrating
    case ready
    case active
    case recover
}

// MARK: - Train Baseline

struct TrainBaseline {
    let hr:        Float
    let rmssd:     Float?
    let timestamp: Date
}

// MARK: - Polyvagal State

enum ANSState: Equatable {
    case ventralVagal   // parasympathetic dominant — vagal tone (PNS) high
    case sympathetic    // arousal dominant — vagal tone (PNS) low
    case dorsalVagal    // very low HRV + HR not elevated — shutdown warning
    case mixed          // transitioning
}

struct AutonomicIndices: Equatable {
    let sns:   Float           // 0–1 arousal / non-vagal share (= 1 − pns)
    let pns:   Float           // 0–1 vagal tone (RMSSD-based, breathing-robust)
    let state: ANSState
}

// MARK: - Autonomic Compute

enum AutonomicCompute {
    static func compute(tick: MetricsTick, baseline: TrainBaseline?) -> AutonomicIndices? {
        balance(rmssd: tick.rmssd, lf: tick.lfPower, hf: tick.hfPower,
                breathBPM: tick.breathBPM, meanBPM: tick.meanBPM,
                baselineRmssd: baseline?.rmssd)
    }

    /// Pure, testable core — breathing-aware autonomic balance.
    ///
    /// PNS (vagal tone) is driven by **RMSSD**, a time-domain vagal marker that
    /// is robust to breathing FREQUENCY: it reflects RSA magnitude regardless of
    /// which spectral band the breath lands in. This deliberately avoids the
    /// LF/HF trap — slow paced/resonance breathing (~6/min ≈ 0.1 Hz) pushes the
    /// vagal respiratory peak out of HF down into LF, so HF/(LF+HF) reads
    /// "sympathetic" during exactly the most vagally-activating breathing. LF/HF
    /// is therefore only a fallback, and only at normal breathing rates where it
    /// is valid.
    static func balance(rmssd: Float?, lf: Float?, hf: Float?,
                        breathBPM: Float?, meanBPM: Float?,
                        baselineRmssd: Float?) -> AutonomicIndices? {
        // HF band starts at 0.15 Hz ≈ 9 breaths/min; below ~10/min the vagal
        // respiratory peak drops below HF, inverting any LF/HF-based balance.
        let paced = (breathBPM ?? 99) < 10

        let pns: Float
        if let vagal = vagalIndex(rmssd: rmssd, baselineRmssd: baselineRmssd) {
            pns = vagal
        } else if !paced, let lf = lf, let hf = hf, lf + hf > 0 {
            pns = hf / (lf + hf)          // fallback: valid only at normal breathing rates
        } else {
            return nil
        }
        let sns = 1 - pns
        return AutonomicIndices(sns: sns, pns: pns,
                                state: classify(pns: pns, rmssd: rmssd, meanBPM: meanBPM, paced: paced))
    }

    /// Vagal index 0–1 from RMSSD. Relative to the session baseline when known
    /// (baseline RMSSD → 0.5, ≥2× → ~0.95); otherwise an absolute saturating map
    /// (RMSSD 40 ms → 0.5, 80 → 0.67, 120 → 0.75).
    private static func vagalIndex(rmssd: Float?, baselineRmssd: Float?) -> Float? {
        guard let rmssd = rmssd, rmssd > 0 else { return nil }
        if let b = baselineRmssd, b > 0 {
            return min(0.95, max(0.05, 0.5 * rmssd / b))
        }
        return min(0.95, max(0.05, rmssd / (rmssd + 40)))
    }

    /// Precondition: `sns == 1 − pns`.
    private static func classify(pns: Float, rmssd: Float?, meanBPM: Float?, paced: Bool) -> ANSState {
        // Dorsal shutdown: near-zero variability with a NON-elevated heart rate
        // (low RMSSD + high HR is exercise/sympathetic, not shutdown).
        if let rmssd = rmssd, rmssd < 8, (meanBPM ?? 99) < 65 { return .dorsalVagal }
        // Slow paced breathing is inherently vagal — never call it sympathetic.
        if paced { return pns >= 0.45 ? .ventralVagal : .mixed }
        if pns >= 0.55 { return .ventralVagal }
        if pns <= 0.35 { return .sympathetic }     // sns ≥ 0.65
        return .mixed
    }
}
