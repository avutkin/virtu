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

        let clippedFraction = clippedSampleFraction(ecg)
        if clippedFraction >= clipPoorFraction {
            return ECGQualityResult(tier: .poor, reason: "clipping")
        } else if clippedFraction > 0 {
            return ECGQualityResult(tier: .okay, reason: "clipping")
        }
        return ECGQualityResult(tier: .good, reason: "clean")
    }

    /// Tiers the existing RR-artifact-based `MetricsTick.signalQuality`
    /// (`1 - artifactRate`, already computed by `HRVCompute`).
    static func rrTier(fromSignalQuality q: Float) -> SignalQualityTier {
        if q >= 0.95 { return .good }
        if q >= 0.80 { return .okay }
        return .poor
    }

    /// Combines the RR-artifact tier and the ECG-waveform tier into one
    /// overall tier — the worse of the two, since either signal alone being
    /// bad means the reading can't be fully trusted.
    static func combinedTier(rrSignalQuality: Float?, ecgResult: ECGQualityResult?) -> CombinedSignalQuality? {
        let rr  = rrSignalQuality.map(rrTier(fromSignalQuality:))
        let ecg = ecgResult?.tier
        guard let overall = [rr, ecg].compactMap({ $0 }).min() else { return nil }
        return CombinedSignalQuality(
            tier: overall,
            rrArtifactPercent: rrSignalQuality.map { Int(((1 - $0) * 100).rounded()) },
            ecgReason: ecgResult?.reason
        )
    }

    /// A run of `clipMinRunLength`+ consecutive samples within `clipRunTolerance`
    /// of the window's own min or max counts as "pinned" (saturated at a rail).
    /// Short runs are ignored — a real QRS peak can briefly touch the window max
    /// without that being clipping.
    private static let clipRunTolerance: Float = 0.5
    private static let clipMinRunLength: Int   = 5
    private static let clipPoorFraction: Float = 0.10

    private static func clippedSampleFraction(_ ecg: [Float]) -> Float {
        guard let maxVal = ecg.max(), let minVal = ecg.min() else { return 0 }

        func pinnedCount(near rail: Float) -> Int {
            var total = 0
            var runLength = 0
            for v in ecg {
                if abs(v - rail) <= clipRunTolerance {
                    runLength += 1
                } else {
                    if runLength >= clipMinRunLength { total += runLength }
                    runLength = 0
                }
            }
            if runLength >= clipMinRunLength { total += runLength }
            return total
        }

        let pinned = pinnedCount(near: maxVal) + pinnedCount(near: minVal)
        return Float(pinned) / Float(ecg.count)
    }
}
