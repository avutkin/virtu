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

    // Nonlinear HRV
    let dfa1: Float?   // DFA α1 short-term scaling exponent (scales 4–16)

    // Signal quality
    let signalQuality: Float?

    /// RR artifact breakdown (fractions 0–1) — dropped-as-implausible vs
    /// interpolated missed/extra beats. Defaulted so preview/aggregate
    /// constructors need not supply them.
    var rrInvalidRate:   Float? = nil
    var rrCorrectedRate: Float? = nil

    /// ECG waveform quality (flatline/clipping check) — live-only, not persisted.
    let ecgQuality: ECGQualityResult?

    // Advanced nonlinear HRV (computed on slower cadence — needs 100–350 beats)
    let rcmse: Float?   // Refined Composite Multiscale Entropy mean (scales 1–5)
    let pip:   Float?   // HR Fragmentation: % inflection points (higher = more fragmented)
    let ials:  Float?   // HR Fragmentation: inverse avg segment length
    let dc:    Float?   // Deceleration Capacity in ms (Bauer 2006, PRSA)

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

        // --- DFA α1 ---
        let dfa = DFACompute.compute(rrMs: rrMs)

        // --- ECG waveform quality ---
        let ecgQuality = ECGQualityCompute.compute(ecg: snapshot.ecg)

        // --- Advanced nonlinear metrics (need 100–350 beats, more expensive) ---
        let rcmseResult = AdvancedHRVCompute.computeRCMSE(rrMs: rrMs)
        let hrfResult   = AdvancedHRVCompute.computeHRF(rrMs: rrMs)
        let dcResult    = AdvancedHRVCompute.computeDC(rrMs: rrMs)

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
            dfa1:           dfa?.alpha1,
            signalQuality:  hrv.map { 1 - $0.artifactRate },
            rrInvalidRate:   hrv?.invalidRate,
            rrCorrectedRate: hrv?.correctedRate,
            ecgQuality:     ecgQuality,
            rcmse:          rcmseResult?.meanEntropy,
            pip:            hrfResult?.pip,
            ials:           hrfResult?.ials,
            dc:             dcResult?.dc,
            breathPhases:   phases,
            psdFreqs:        hrv?.psdFreqs,
            psdValues:       hrv?.psdValues,
            coherenceFreqs:  coherence?.freqs,
            coherenceValues: coherence?.coherence
        )
    }
}
