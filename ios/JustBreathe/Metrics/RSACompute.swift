import Accelerate
import Foundation

// MARK: - RSA Output

struct RSAMetrics {
    let rsaMs:  Float   // amplitude (ms) — peak-to-trough of RR oscillation at breathing frequency
    let rsaIdx: Float   // ln(band power) — Porges index
    let method: String  // "bandpass" or "hf-band"
}

// MARK: - RSACompute

enum RSACompute {

    /// Respiratory Sinus Arrhythmia amplitude and index.
    /// Mirrors `compute_rsa` in metrics.py.
    ///
    /// - Parameters:
    ///   - rrMs:      Clean or raw RR intervals in milliseconds.
    ///   - breathHz:  Detected breathing peak frequency from BreathingCompute.
    ///                When nil, falls back to full HF band (0.15–0.40 Hz).
    static func compute(rrMs: [Int], breathHz: Float? = nil) -> RSAMetrics? {
        let rr = HRVCompute.cleanRR(rrMs)
        guard rr.count >= 30 else { return nil }

        // Flat-tachogram guard: if RMSSD < 1 ms, RR intervals are nearly identical
        // (common when BLE reconnects and the device sends repeated constant values).
        // A flat tachogram → all-zero PSD → hfP = 0 → rsaMs = 0.0 (not nil), which
        // the chart plots as a misleading flat zero line. Return nil so it shows a gap.
        let rrDiffs = HRVCompute.differences(rr)
        let rrRMSSD = rrDiffs.isEmpty ? 0.0 : sqrt(vDSP.meanSquare(rrDiffs))
        guard rrRMSSD >= 1.0 else { return nil }

        guard let interp = HRVCompute.interpTachogram(rr, fs: HRVCompute.rrFS),
              interp.count >= 16 else { return nil }

        let mean      = vDSP.mean(interp)
        let detrended = vDSP.subtract(interp, [Float](repeating: mean, count: interp.count))
        let (freqs, psd) = HRVCompute.welchPSD(
            signal: detrended, fs: HRVCompute.rrFS, nperseg: min(256, detrended.count))

        let rsaMs:    Float
        let method:   String
        let bandMask: [Bool]

        // Always compute HF-band RSA as a floor — the narrow bandpass can produce
        // near-zero output when breathing is irregular or the detected frequency
        // doesn't align with the dominant HRV oscillation.
        let hfMask = freqs.map { $0 >= 0.15 && $0 <= 0.40 }
        let hfP    = bandPowerFromMask(freqs: freqs, psd: psd, mask: hfMask)
        let hfRsa  = hfP > 0 ? sqrt(2.0 * hfP) : 0

        if let hz = breathHz, (0.05...0.50).contains(hz) {
            let fLo = max(0.04, hz - 0.08)
            let fHi = min(0.60, hz + 0.08)
            // Bandpass filter RR tachogram around breathing frequency
            if let filtered = BreathingCompute.bandpassFilter(
                detrended, lowHz: fLo, highHz: fHi, fs: HRVCompute.rrFS) {
                let bpRsa = 2.0 * sqrt(vDSP.meanSquare(filtered))
                rsaMs = max(bpRsa, hfRsa)   // HF-band as floor when bandpass is low
            } else {
                rsaMs = hfRsa
            }
            bandMask = zip(freqs, freqs).map { f, _ in f >= fLo && f <= fHi }
            method = "bandpass"
        } else {
            // HF-band fallback
            bandMask = hfMask
            rsaMs    = hfRsa
            method   = "hf-band"
        }

        let bandPow = bandPowerFromMask(freqs: freqs, psd: psd, mask: bandMask)
        let rsaIdx  = bandPow > 0 ? log(bandPow) : 0

        // If the computed amplitude is exactly zero (e.g., HF band PSD is all zeros
        // despite passing the RMSSD guard), treat as unmeasurable — gap > zero line.
        guard rsaMs > 0 else { return nil }

        return RSAMetrics(rsaMs: rsaMs, rsaIdx: rsaIdx, method: method)
    }

    // MARK: Private

    private static func bandPowerFromMask(freqs: [Float], psd: [Float], mask: [Bool]) -> Float {
        let pairs = zip(zip(freqs, psd), mask).filter { $0.1 }.map { $0.0 }
        guard pairs.count >= 2 else { return 0 }
        var sum: Float = 0
        for i in 0..<pairs.count - 1 {
            sum += (pairs[i + 1].0 - pairs[i].0) * (pairs[i].1 + pairs[i + 1].1) / 2
        }
        return max(0, sum)
    }
}
