import Foundation

// MARK: - Aggregated Tick Output

/// All metrics computed from one DataSnapshot. Produced every ~2 s.
struct MetricsTick {
    let timestamp: Date

    // Time-domain HRV
    let meanBPM: Float?
    let sdnn:    Float?
    let rmssd:   Float?
    let pnn50:   Float?
    let vti:     Float?

    // Frequency-domain HRV
    let ulfPower: Float?
    let vlfPower: Float?
    let lfPower:  Float?
    let hfPower:  Float?
    let lfHF:     Float?

    // RSA
    let rsaMs:  Float?
    let rsaIdx: Float?

    // Breathing
    let breathBPM:    Float?
    let breathHz:     Float?
    let regularity:   Float?

    // Coherence & CBI
    let coherenceScore: Float?
    let cbi:            Float?

    // Phase info (for UI breathing ring)
    let breathPhases: BreathPhases?

    // PSD for chart display
    let psdFreqs:  [Float]?
    let psdValues: [Float]?

    // RR–Breathing coherence spectrum
    let coherenceFreqs:  [Float]?
    let coherenceValues: [Float]?
}

// MARK: - MetricsEngine

/// Coordinates all metric computation from a DataSnapshot.
/// Designed to run on a background task (not MainActor).
enum MetricsEngine {

    /// Compute a full MetricsTick from a data snapshot.
    /// Heavy: runs Welch PSD, FFT, biquad filters. Call from a background Task.
    static func compute(from snapshot: DataSnapshot) -> MetricsTick {
        let rrMs = snapshot.rr

        // --- Time-domain HRV ---
        let hrv = HRVCompute.compute(rrMs: rrMs)

        // --- Breathing from ACC Z ---
        let breathing = BreathingCompute.computeRate(accZ: snapshot.accZ)
        let phases    = BreathingCompute.computePhases(accZ: snapshot.accZ)

        // --- RSA ---
        // Use only the most recent 90 RR intervals (~90 s at 60 bpm) so RSA is stable
        // against transient fluctuations while still reflecting current autonomic state.
        let rrForRSA = rrMs.count > 90 ? Array(rrMs.suffix(90)) : rrMs
        let rsa = RSACompute.compute(rrMs: rrForRSA, breathHz: breathing?.peakHz)

        // --- Coherence ---
        let coherence = CoherenceCompute.compute(
            rrMs: rrMs, accZ: snapshot.accZ, peakHz: breathing?.peakHz)

        // --- CBI ---
        let cbi: Float? = coherence.map {
            CoherenceCompute.computeCBI(
                rmssd:           hrv?.rmssd,
                peakHz:          breathing?.peakHz,
                coherenceScore:  $0.score,
                regularity:      breathing?.regularity ?? 0,
                peakCoherence:   $0.peakCoherence
            )
        }

        return MetricsTick(
            timestamp:      Date(),
            meanBPM:        hrv?.meanBPM,
            sdnn:           hrv?.sdnn,
            rmssd:          hrv?.rmssd,
            pnn50:          hrv?.pnn50,
            vti:            hrv?.vti,
            ulfPower:       hrv?.ulfPower,
            vlfPower:       hrv?.vlfPower,
            lfPower:        hrv?.lfPower,
            hfPower:        hrv?.hfPower,
            lfHF:           hrv?.lfHF,
            rsaMs:          rsa?.rsaMs,
            rsaIdx:         rsa?.rsaIdx,
            breathBPM:      breathing?.bpm,
            breathHz:       breathing?.peakHz,
            regularity:     breathing?.regularity,
            coherenceScore: coherence?.score,
            cbi:            cbi,
            breathPhases:   phases,
            psdFreqs:        hrv?.psdFreqs,
            psdValues:       hrv?.psdValues,
            coherenceFreqs:  coherence?.freqs,
            coherenceValues: coherence?.coherence
        )
    }
}
