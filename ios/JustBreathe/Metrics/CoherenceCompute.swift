import Accelerate
import Foundation

// MARK: - Coherence Output

struct CoherenceMetrics {
    let freqs:         [Float]
    let coherence:     [Float]
    let score:         Float   // band-average coherence 0.1–0.5 Hz
    let peakCoherence: Float   // coherence at breathing peak ±0.02 Hz
}

// MARK: - CoherenceCompute

/// Spectral coherence between RR tachogram and ACC Z breathing signal.
/// Mirrors `compute_coherence` in metrics.py.
enum CoherenceCompute {

    private static let rrFS:  Float = HRVCompute.rrFS           // 4 Hz
    private static let accFS: Float = Float(PolarH10Profile.accSampleRate)  // 200 Hz
    private static let breathBand: ClosedRange<Float> = 0.10...0.50

    /// - Parameters:
    ///   - rrMs:    RR intervals in milliseconds.
    ///   - accZ:    ACC Z-axis samples at 200 Hz.
    ///   - peakHz:  Breathing frequency from BreathingCompute (for precise peak coherence).
    static func compute(rrMs: [Int], accZ: [Float], peakHz: Float? = nil) -> CoherenceMetrics? {
        guard rrMs.count >= 20, accZ.count >= Int(accFS * 15) else { return nil }

        let rr = HRVCompute.cleanRR(rrMs)
        guard let interp = HRVCompute.interpTachogram(rr, fs: rrFS),
              interp.count >= 16 else { return nil }

        // Downsample ACC 200 Hz → 4 Hz: take every 50th sample
        let step     = max(1, Int(accFS / rrFS))
        let accDown  = stride(from: 0, to: accZ.count, by: step).map { accZ[$0] }

        let n = min(interp.count, accDown.count)
        guard n >= 16 else { return nil }

        let rrSeg  = normalise(Array(interp.suffix(n)))
        let acSeg  = normalise(Array(accDown.suffix(n)))

        // Welch coherence: estimate cross-PSD and auto-PSD, then coherence = |Sxy|² / (Sxx·Syy)
        let nperseg = max(8, min(n / 10, 64))
        let (freqs, coh) = welchCoherence(x: rrSeg, y: acSeg, fs: rrFS, nperseg: nperseg)

        let bandMask = zip(freqs, coh).filter { breathBand.contains($0.0) }
        let score: Float = bandMask.isEmpty ? 0 :
            bandMask.map { $0.1 }.reduce(0, +) / Float(bandMask.count)

        let peakCoherence: Float
        if let hz = peakHz {
            let window = 0.02 as Float
            let near = bandMask.filter { abs($0.0 - hz) <= window }
            peakCoherence = near.isEmpty ? score : near.map { $0.1 }.reduce(0, +) / Float(near.count)
        } else {
            peakCoherence = score
        }

        return CoherenceMetrics(freqs: freqs, coherence: coh, score: score,
                                peakCoherence: peakCoherence)
    }

    // MARK: CBI

    /// Conscious Breathing Index (0–1). Mirrors `compute_cbi` in metrics.py.
    static func computeCBI(rmssd: Float?, peakHz: Float?, coherenceScore: Float,
                           regularity: Float = 0, peakCoherence: Float? = nil) -> Float {
        // Frequency: Gaussian centred at 0.10 Hz (6 br/min), σ = 0.05
        let freqScore: Float
        if let hz = peakHz {
            let z = (hz - 0.10) / 0.05
            freqScore = exp(-0.5 * z * z)
        } else {
            freqScore = 0
        }

        // RMSSD: sigmoid centred at 40 ms
        let rmssdScore: Float
        if let r = rmssd, r > 0 {
            rmssdScore = 1.0 / (1.0 + exp(-0.05 * (r - 40)))
        } else {
            rmssdScore = 0
        }

        let cohScore = peakCoherence ?? coherenceScore

        return (0.35 * cohScore + 0.25 * regularity + 0.25 * freqScore + 0.15 * rmssdScore)
            .clamped(to: 0...1)
    }

    // MARK: Welch Coherence

    private static func welchCoherence(x: [Float], y: [Float], fs: Float,
                                        nperseg: Int) -> ([Float], [Float]) {
        let n   = min(x.count, y.count)
        let seg = min(nperseg, n)
        guard seg >= 2 else { return ([], []) }

        // Derive power-of-2 FFT length so window and accumulators agree with fftMagnitudes.
        let log2n   = Int(floor(log2(Float(seg))))
        let fftLen  = 1 << log2n          // actual FFT size (≤ seg)
        let halfLen = fftLen / 2 + 1

        let overlap = fftLen / 2
        let step    = fftLen - overlap
        guard step > 0 else { return ([], []) }

        var window = [Float](repeating: 0, count: fftLen)
        vDSP_hann_window(&window, vDSP_Length(fftLen), Int32(vDSP_HANN_NORM))

        var sxx  = [Float](repeating: 0, count: halfLen)
        var syy  = [Float](repeating: 0, count: halfLen)
        var sxyR = [Float](repeating: 0, count: halfLen)
        var count = 0

        var start = 0
        while start + fftLen <= n {
            let xSeg = vDSP.multiply(Array(x[start..<start + fftLen]), window)
            let ySeg = vDSP.multiply(Array(y[start..<start + fftLen]), window)

            let xMags = HRVCompute.fftMagnitudes(xSeg, fftLen: fftLen)
            let yMags = HRVCompute.fftMagnitudes(ySeg, fftLen: fftLen)

            let bins = min(min(xMags.count, yMags.count), halfLen)
            for i in 0..<bins {
                sxx[i]  += xMags[i] * xMags[i]
                syy[i]  += yMags[i] * yMags[i]
                // Approximate cross-PSD magnitude (phase discarded — gives upper bound on coherence)
                sxyR[i] += xMags[i] * yMags[i] 
            }
            count += 1
            start += step
        }

        guard count > 0 else { return ([], []) }

        let freqStep = fs / Float(fftLen)
        let freqs = (0..<halfLen).map { Float($0) * freqStep }
        var coh = [Float](repeating: 0, count: halfLen)
        for i in 0..<halfLen {
            let denom = sxx[i] * syy[i]
            coh[i] = denom > 0 ? min(1, (sxyR[i] * sxyR[i]) / denom) : 0
        }
        return (freqs, coh)
    }

    // MARK: Helpers

    private static func normalise(_ v: [Float]) -> [Float] {
        let m = vDSP.mean(v)
        return vDSP.subtract(v, [Float](repeating: m, count: v.count))
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
