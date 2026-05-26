import Accelerate
import Foundation

// MARK: - HRV Output

struct HRVMetrics {
    let meanBPM: Float
    let sdnn:    Float      // ms
    let rmssd:   Float      // ms
    let pnn50:   Float      // %
    let vti:     Float      // ln(RMSSD)

    // Frequency domain (nil when < 30 RR intervals)
    let ulfPower: Float?    // ms²  (< 0.003 Hz; meaningful only for long recordings)
    let vlfPower: Float?    // ms²  (0.003–0.04 Hz)
    let lfPower:  Float?    // ms²
    let hfPower:  Float?    // ms²
    let lfHF:     Float?    // ratio
    let lfNU:     Float?    // %
    let hfNU:     Float?    // %
    let psdFreqs: [Float]?
    let psdValues: [Float]?
}

// MARK: - Frequency Band Limits (matches metrics.py)

private enum Band {
    static let ulf: ClosedRange<Float> = 0.000...0.003
    static let vlf: ClosedRange<Float> = 0.003...0.04
    static let lf:  ClosedRange<Float> = 0.04...0.15
    static let hf:  ClosedRange<Float> = 0.15...0.40
}

// MARK: - HRVCompute

enum HRVCompute {

    // MARK: Constants

    private static let minRRTime = 10    // minimum clean RR intervals for time-domain
    private static let minRRFreq = 30    // minimum clean RR intervals for freq-domain
    static let rrFS: Float = 4.0         // tachogram interpolation rate (Hz)

    // MARK: Public

    /// Full HRV analysis from RR intervals in milliseconds.
    /// Returns nil if there are fewer than 10 clean RR intervals.
    static func compute(rrMs: [Int]) -> HRVMetrics? {
        let rr = cleanRR(rrMs)
        guard rr.count >= minRRTime else { return nil }

        // --- Time domain ---
        let mean    = vDSP.mean(rr)
        let sdnn    = standardDeviation(rr)
        let diffs   = differences(rr)
        let rmssd   = diffs.isEmpty ? 0 : sqrt(vDSP.meanSquare(diffs))
        let pnn50   = diffs.isEmpty ? 0 : Float(diffs.filter { abs($0) > 50 }.count) / Float(diffs.count) * 100
        let vti     = rmssd > 0 ? log(rmssd) : 0

        let meanBPM: Float = mean > 0 ? 60_000 / mean : 0

        // --- Frequency domain ---
        guard rr.count >= minRRFreq,
              let interp = interpTachogram(rr, fs: rrFS) else {
            return HRVMetrics(
                meanBPM: meanBPM, sdnn: sdnn, rmssd: rmssd, pnn50: pnn50, vti: vti,
                ulfPower: nil, vlfPower: nil, lfPower: nil, hfPower: nil,
                lfHF: nil, lfNU: nil, hfNU: nil,
                psdFreqs: nil, psdValues: nil
            )
        }

        let detrended = vDSP.subtract(interp, [Float](repeating: vDSP.mean(interp), count: interp.count))
        let (freqs, psd) = welchPSD(signal: detrended, fs: rrFS, nperseg: min(256, detrended.count))

        // LF/HF use standard Welch (good spectral smoothing).
        let lfP  = bandPower(freqs: freqs, psd: psd, band: Band.lf)  ?? 0
        let hfP  = bandPower(freqs: freqs, psd: psd, band: Band.hf)  ?? 0

        // VLF/ULF need maximum frequency resolution: standard Welch caps at 256 pts
        // → Δf = 0.016 Hz, leaving only 2 VLF bins and none for ULF.
        // Using the full signal as a single segment maximises resolution (Δf = fs/N).
        // VLF (0.003–0.04 Hz) becomes measurable once the recording is ~5 min long.
        let (freqsHR, psdHR) = welchPSD(signal: detrended, fs: rrFS, nperseg: detrended.count)
        let ulfP = bandPower(freqs: freqsHR, psd: psdHR, band: Band.ulf)
        let vlfP = bandPower(freqs: freqsHR, psd: psdHR, band: Band.vlf)
        let tp   = lfP + hfP

        return HRVMetrics(
            meanBPM: meanBPM, sdnn: sdnn, rmssd: rmssd, pnn50: pnn50, vti: vti,
            ulfPower: ulfP, vlfPower: vlfP,
            lfPower: lfP, hfPower: hfP,
            lfHF:  hfP > 0 ? lfP / hfP : 0,
            lfNU:  tp > 0 ? 100 * lfP / tp : 0,
            hfNU:  tp > 0 ? 100 * hfP / tp : 0,
            psdFreqs:  freqs,
            psdValues: psd
        )
    }

    // MARK: Helpers

    /// Remove physiologically implausible RR values (< 300 ms or > 2000 ms).
    static func cleanRR(_ rrMs: [Int]) -> [Float] {
        rrMs.compactMap { v in
            let f = Float(v)
            return (f >= 300 && f <= 2000) ? f : nil
        }
    }

    /// Interpolate irregular RR series onto a uniform grid at `fs` Hz.
    static func interpTachogram(_ rr: [Float], fs: Float) -> [Float]? {
        guard rr.count >= 4 else { return nil }
        // Cumulative time in seconds
        var cum = [Float](repeating: 0, count: rr.count)
        var running: Float = 0
        for (i, v) in rr.enumerated() {
            running += v / 1000.0
            cum[i] = running
        }
        let tStart = cum[0]
        let tEnd   = cum[cum.count - 1]
        let step   = 1.0 / fs
        var t = tStart
        var grid: [Float] = []
        while t < tEnd {
            grid.append(t)
            t += step
        }
        guard grid.count >= 8 else { return nil }

        // Linear interpolation: for each grid point find surrounding cum indices
        return grid.map { tq in linearInterp(x: cum, y: rr, xq: tq) }
    }

    // MARK: DSP primitives

    /// Population standard deviation via vDSP.
    static func standardDeviation(_ v: [Float]) -> Float {
        guard v.count > 1 else { return 0 }
        var mean: Float = 0
        var stddev: Float = 0
        vDSP_normalize(v, 1, nil, 1, &mean, &stddev, vDSP_Length(v.count))
        // vDSP_normalize returns stddev as the scale factor (biased)
        let m = vDSP.mean(v)
        let diff = vDSP.subtract(v, [Float](repeating: m, count: v.count))
        let sq = vDSP.multiply(diff, diff)
        return sqrt(vDSP.mean(sq))
    }

    /// Successive differences.
    static func differences(_ v: [Float]) -> [Float] {
        guard v.count > 1 else { return [] }
        var out = [Float](repeating: 0, count: v.count - 1)
        for i in 0..<out.count {
            out[i] = v[i + 1] - v[i]
        }
        return out
    }

    /// Welch's PSD via overlapping Hann-windowed FFT segments.
    /// Returns (frequencies, power spectral density).
    static func welchPSD(signal: [Float], fs: Float, nperseg: Int) -> ([Float], [Float]) {
        let n   = signal.count
        let seg = min(nperseg, n)
        guard seg >= 2 else { return ([], []) }

        // Derive the power-of-2 FFT length up front so window, psdAcc, and freqs
        // all agree — fftMagnitudes floors to this same size internally.
        let log2n   = Int(floor(log2(Float(seg))))
        let fftLen  = 1 << log2n          // actual power-of-2 FFT size
        let halfLen = fftLen / 2 + 1

        let overlap = fftLen / 2
        let step    = fftLen - overlap
        guard step > 0 else { return ([], []) }

        // Hann window sized to fftLen
        var window = [Float](repeating: 0, count: fftLen)
        vDSP_hann_window(&window, vDSP_Length(fftLen), Int32(vDSP_HANN_NORM))
        let wScale = vDSP.sum(vDSP.multiply(window, window))

        var psdAcc = [Float](repeating: 0, count: halfLen)
        var count  = 0

        var start = 0
        while start + fftLen <= n {
            let segment  = Array(signal[start..<start + fftLen])
            let windowed = vDSP.multiply(segment, window)

            let magnitudes = fftMagnitudes(windowed, fftLen: fftLen)
            let bins = min(magnitudes.count, halfLen)
            for i in 0..<bins {
                let power: Float = (i == 0 || i == bins - 1)
                    ? magnitudes[i] * magnitudes[i]
                    : 2 * magnitudes[i] * magnitudes[i]
                psdAcc[i] += power
            }
            count += 1
            start += step
        }

        guard count > 0 else { return ([], []) }

        let scale    = 1.0 / (wScale * fs * Float(count))
        let psd      = psdAcc.map { $0 * scale }
        let freqStep = fs / Float(fftLen)
        let freqs    = (0..<halfLen).map { Float($0) * freqStep }

        return (freqs, psd)
    }

    /// Compute one-sided FFT magnitudes for a real signal using vDSP.
    ///
    /// vDSP requires a power-of-2 FFT length.  We derive it by taking the
    /// floor of log2(fftLen) so the actual FFT size is always ≤ fftLen and
    /// we never read past the end of the stack-allocated split-complex arrays.
    static func fftMagnitudes(_ signal: [Float], fftLen: Int) -> [Float] {
        guard fftLen >= 2 else { return [] }
        // Floor — never rounds up, guarantees pow2Len ≤ fftLen
        let log2n   = vDSP_Length(floor(log2(Float(fftLen))))
        let pow2Len = 1 << Int(log2n)           // actual FFT size (power of 2)
        let halfLen = pow2Len / 2

        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(FFT_RADIX2)) else {
            return [Float](repeating: 0, count: halfLen + 1)
        }
        defer { vDSP_destroy_fftsetup(setup) }

        // Arrays must be exactly pow2Len — zero-pad or truncate signal
        var real = [Float](repeating: 0, count: pow2Len)
        var imag = [Float](repeating: 0, count: pow2Len)
        let copyLen = min(pow2Len, signal.count)
        real.withUnsafeMutableBufferPointer { dst in
            signal.withUnsafeBufferPointer { src in
                dst.baseAddress!.update(from: src.baseAddress!, count: copyLen)
            }
        }

        // Pin both arrays so their pointers remain valid across the FFT call.
        var mags = [Float](repeating: 0, count: halfLen + 1)
        real.withUnsafeMutableBufferPointer { realBuf in
            imag.withUnsafeMutableBufferPointer { imagBuf in
                var split = DSPSplitComplex(realp: realBuf.baseAddress!,
                                            imagp: imagBuf.baseAddress!)
                vDSP_fft_zip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvabs(&split, 1, &mags, 1, vDSP_Length(halfLen + 1))
            }
        }
        var scale = 1.0 / Float(pow2Len)
        vDSP_vsmul(mags, 1, &scale, &mags, 1, vDSP_Length(halfLen + 1))
        return mags
    }

    /// Trapezoidal integration of PSD over a frequency band.
    /// Returns nil when fewer than 2 frequency bins fall inside the band
    /// (indicates insufficient frequency resolution — caller should treat as unavailable).
    static func bandPower(freqs: [Float], psd: [Float], band: ClosedRange<Float>) -> Float? {
        let pairs = zip(freqs, psd).filter { band.contains($0.0) }
        guard pairs.count >= 2 else { return nil }
        let fx = pairs.map { $0.0 }
        let fy = pairs.map { $0.1 }
        var sum: Float = 0
        for i in 0..<fx.count - 1 {
            sum += (fx[i + 1] - fx[i]) * (fy[i] + fy[i + 1]) / 2
        }
        return max(0, sum)
    }

    /// Linear interpolation at a single query point.
    private static func linearInterp(x: [Float], y: [Float], xq: Float) -> Float {
        // Binary search for bracket
        var lo = 0, hi = x.count - 1
        if xq <= x[lo] { return y[lo] }
        if xq >= x[hi] { return y[hi] }
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if x[mid] <= xq { lo = mid } else { hi = mid }
        }
        let t = (xq - x[lo]) / (x[hi] - x[lo])
        return y[lo] + t * (y[hi] - y[lo])
    }
}
