import Foundation

// MARK: - Signal Quality Tier

/// Shared three-level tier for both the RR-artifact and ECG-waveform quality checks.
/// Ordered so `.min()` over an array picks the worst tier.
enum SignalQualityTier: Int, Comparable {
    case poor = 0
    case okay = 1
    case good = 2

    static func < (lhs: SignalQualityTier, rhs: SignalQualityTier) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

// MARK: - ECG Quality Output

struct ECGQualityResult {
    let tier:   SignalQualityTier
    let reason: String   // "clean" | "clipping" | "lead-off"
}

// MARK: - Combined Output (RR-artifact + ECG-waveform)

struct CombinedSignalQuality {
    let tier:              SignalQualityTier
    let rrArtifactPercent: Int?     // nil if the RR side is unavailable
    let ecgReason:         String?  // nil if the ECG side is unavailable
}

// MARK: - ECGQualityCompute

/// Raw ECG waveform quality check: flatline/lead-off and clipping/saturation.
/// Deliberately relative to the window's own statistics rather than a hardcoded
/// hardware ADC rail constant (unverifiable from this codebase, and a hardcoded
/// universal threshold is exactly the kind of assumption that caused the RR
/// artifact-filter regression this indicator is meant to help catch).
enum ECGQualityCompute {

    /// Minimum samples needed to evaluate a window (~1 s at 130 Hz).
    static let minSamples = 130

    /// Below this population stddev (µV), treat the window as flatline/lead-off.
    /// Resting ECG is typically hundreds of µV peak-to-peak, so this cleanly
    /// separates "no real cardiac signal" from any real reading.
    private static let flatlineStddevThreshold: Float = 3.0

    static func compute(ecg: [Float]) -> ECGQualityResult? {
        guard ecg.count >= minSamples else { return nil }

        let mean = ecg.reduce(0, +) / Float(ecg.count)
        let variance = ecg.reduce(Float(0)) { $0 + ($1 - mean) * ($1 - mean) } / Float(ecg.count)
        let stddev = sqrt(variance)

        guard stddev >= flatlineStddevThreshold else {
            return ECGQualityResult(tier: .poor, reason: "lead-off")
        }

        return ECGQualityResult(tier: .good, reason: "clean")
    }
}
