import Accelerate
import Foundation

// MARK: - Breathing Output

struct BreathingMetrics {
    let peakHz:     Float   // dominant breathing frequency
    let bpm:        Float   // breaths per minute
    let regularity: Float   // 0–1 (peak prominence ratio / 6)
    let psdFreqs:   [Float]
    let psdValues:  [Float]
}

struct BreathPhases {
    struct Breath {
        let inhaleDur:    Float   // seconds
        let exhaleDur:    Float   // seconds
        let depth:        Float   // filtered signal amplitude
        let ieRatio:      Float   // exhale/inhale
        let tInhaleStart: Float   // seconds relative to now (negative = past)
        let tInhaleEnd:   Float
        let tExhaleEnd:   Float
    }

    let breaths:     [Breath]
    let meanIE:      Float
    let meanInhale:  Float
    let meanExhale:  Float
    let meanDepth:   Float
    let nBreaths:    Int
    let filtered:    [Float]
    let filteredT:   [Float]
}

// MARK: - BreathingCompute

enum BreathingCompute {

    private static let accFS:         Float = Float(PolarH10Profile.accSampleRate)  // 200 Hz
    private static let breathBand:    ClosedRange<Float> = 0.10...0.50              // 6–30 br/min
    private static let minAccBreath:  Int   = Int(accFS * 6)    // 6 s of data
    private static let minAccPhases:  Int   = Int(accFS * 20)   // 20 s

    // MARK: Public

    /// Estimate breathing rate from ACC Z-axis via Welch PSD.
    static func computeRate(accZ: [Float]) -> BreathingMetrics? {
        guard accZ.count >= minAccBreath else { return nil }

        // Normalise
        let mean  = vDSP.mean(accZ)
        var z     = vDSP.subtract(accZ, [Float](repeating: mean, count: accZ.count))
        let std   = HRVCompute.standardDeviation(z)
        if std > 0 { z = vDSP.divide(z, std) }

        let (freqs, psd) = HRVCompute.welchPSD(
            signal: z, fs: accFS, nperseg: min(4096, z.count))

        let band = zip(freqs, psd).filter { breathBand.contains($0.0) }
        guard !band.isEmpty else { return nil }

        let bandFreqs = band.map { $0.0 }
        let bandPSD   = band.map { $0.1 }
        guard let peakIdx = bandPSD.indices.max(by: { bandPSD[$0] < bandPSD[$1] }) else {
            return nil
        }
        let peakHz  = bandFreqs[peakIdx]
        let peakPSD = bandPSD[peakIdx]
        let meanPSD = vDSP.mean(bandPSD)

        let ratio      = meanPSD > 0 ? peakPSD / meanPSD : 1.0
        let regularity = min(ratio / 6.0, 1.0)

        return BreathingMetrics(
            peakHz:    peakHz,
            bpm:       peakHz * 60,
            regularity: regularity,
            psdFreqs:  bandFreqs,
            psdValues: bandPSD
        )
    }

    /// Segment breathing into inhale/exhale phases via bandpass + peak detection.
    /// Mirrors `compute_breath_phases` in metrics.py.
    static func computePhases(accZ: [Float]) -> BreathPhases? {
        guard accZ.count >= minAccPhases else { return nil }

        // Bandpass 0.05–0.8 Hz (3–48 br/min)
        guard let filtered = bandpassFilter(accZ, lowHz: 0.05, highHz: 0.8, fs: accFS) else {
            return nil
        }

        let std = HRVCompute.standardDeviation(filtered)
        let minProm = max(std * 0.30, 1e-6)
        let minDist = Int(accFS * 1.5)   // ≥ 1.5 s → max 40 br/min

        let peaks   = findPeaks( filtered, minDistance: minDist, minProminence: minProm)
        let troughs = findPeaks(filtered.map { -$0 }, minDistance: minDist, minProminence: minProm)

        guard peaks.count >= 2, troughs.count >= 2 else { return nil }

        let tArr   = (0..<filtered.count).map { Float($0) / accFS }
        let tNow   = tArr.last ?? 0

        var breaths: [BreathPhases.Breath] = []
        for i in 0..<troughs.count - 1 {
            let t1 = troughs[i]
            let t2 = troughs[i + 1]
            let mid = peaks.filter { $0 > t1 && $0 < t2 }
            guard let p = mid.first else { continue }

            let inh = Float(p  - t1) / accFS
            let exh = Float(t2 - p)  / accFS
            let dep = filtered[p] - filtered[t1]

            // Physiological sanity: 1.5–60 s cycle, half-phases ≥ 0.4 s
            guard (1.5...(60.0)).contains(inh + exh), inh >= 0.4, exh >= 0.4 else { continue }

            breaths.append(BreathPhases.Breath(
                inhaleDur:    inh,
                exhaleDur:    exh,
                depth:        dep,
                ieRatio:      exh / inh,
                tInhaleStart: tArr[t1] - tNow,
                tInhaleEnd:   tArr[p]  - tNow,
                tExhaleEnd:   tArr[t2] - tNow
            ))
        }
        guard !breaths.isEmpty else { return nil }

        let recent = Array(breaths.suffix(12))
        let win    = Int(accFS * 30)
        let sigSlice = Array(filtered.suffix(win))
        let tRel     = sigSlice.indices.map { Float($0 - sigSlice.count) / accFS }

        return BreathPhases(
            breaths:    recent,
            meanIE:     recent.map { $0.ieRatio }.reduce(0, +) / Float(recent.count),
            meanInhale: recent.map { $0.inhaleDur }.reduce(0, +) / Float(recent.count),
            meanExhale: recent.map { $0.exhaleDur }.reduce(0, +) / Float(recent.count),
            meanDepth:  recent.map { abs($0.depth) }.reduce(0, +) / Float(recent.count),
            nBreaths:   breaths.count,
            filtered:   sigSlice,
            filteredT:  tRel
        )
    }

    // MARK: DSP helpers

    /// 4th-order Butterworth bandpass filter via biquad cascade (matches scipy.butter order=4).
    static func bandpassFilter(_ signal: [Float], lowHz: Float, highHz: Float, fs: Float) -> [Float]? {
        // Design 2nd-order biquad sections analytically for Butterworth bandpass
        // A 4th-order Butterworth bandpass = 2 biquad sections in series
        guard let sections = butterworthBPCoeffs(order: 4, lowHz: lowHz, highHz: highHz, fs: fs) else {
            return nil
        }
        var out = signal
        for section in sections {
            out = applyBiquad(out, b: section.b, a: section.a)
        }
        // Forward-backward filter (sosfiltfilt equivalent)
        let outFwd = out
        var outRev = outFwd.reversed().map { $0 }
        for section in sections {
            outRev = applyBiquad(outRev, b: section.b, a: section.a)
        }
        return outRev.reversed().map { $0 }
    }

    /// Biquad section coefficients (b0,b1,b2 / a0,a1,a2 normalised so a0=1).
    struct BiquadSection {
        let b: [Float]   // [b0, b1, b2]
        let a: [Float]   // [1, a1, a2]
    }

    /// Design a 4th-order Butterworth bandpass filter as biquad sections.
    /// Uses bilinear transform from pre-warped analogue prototype.
    static func butterworthBPCoeffs(order: Int, lowHz: Float, highHz: Float,
                                    fs: Float) -> [BiquadSection]? {
        guard lowHz > 0, highHz > lowHz, highHz < fs / 2 else { return nil }
        // Pre-warp digital cutoffs to analogue
        let wl = 2 * fs * tan(.pi * lowHz  / fs)
        let wh = 2 * fs * tan(.pi * highHz / fs)
        let bw = wh - wl
        let w0 = sqrt(wl * wh)

        // For a 4th-order bandpass, we need 2 second-order sections.
        // Each section is produced from a first-order Butterworth lowpass prototype
        // transformed to a bandpass section.
        //
        // 1st-order LP prototype poles: s = -1 (normalised)
        // Bandpass transform: s → (s² + w0²) / (bw·s)  →  gives 2nd-order BP
        // Two such sections → 4th-order overall
        var sections: [BiquadSection] = []
        for _ in 0..<(order / 2) {
            // Analogue BP section: H(s) = (bw·s) / (s² + bw·s + w0²)
            // Bilinear transform: s → 2*fs*(z-1)/(z+1)
            let k  = 2 * fs
            let k2 = k * k
            let denom = k2 + bw * k + w0 * w0
            let b0 =  bw * k / denom
            let b1 =  0.0 as Float
            let b2 = -bw * k / denom
            let a1 = (2 * (w0 * w0 - k2)) / denom
            let a2 = (k2 - bw * k + w0 * w0) / denom
            sections.append(BiquadSection(b: [b0, b1, b2], a: [1, a1, a2]))
        }
        return sections
    }

    /// Apply a single biquad IIR section (direct form II transposed).
    private static func applyBiquad(_ x: [Float], b: [Float], a: [Float]) -> [Float] {
        var y = [Float](repeating: 0, count: x.count)
        var w1: Float = 0, w2: Float = 0
        for i in 0..<x.count {
            let xi = x[i]
            let yi = b[0] * xi + w1
            w1 = b[1] * xi - a[1] * yi + w2
            w2 = b[2] * xi - a[2] * yi
            y[i] = yi
        }
        return y
    }

    /// Simple peak detection: returns indices of local maxima with minimum distance
    /// and minimum prominence constraints (approximation — not scipy quality but sufficient).
    static func findPeaks(_ signal: [Float], minDistance: Int, minProminence: Float) -> [Int] {
        var peaks: [Int] = []
        let n = signal.count
        guard n > 2 else { return [] }

        // Find all local maxima
        var candidates: [Int] = []
        for i in 1..<n - 1 {
            if signal[i] > signal[i - 1] && signal[i] >= signal[i + 1] {
                candidates.append(i)
            }
        }

        // Apply min distance and prominence
        for c in candidates {
            // Prominence: height above the higher of the two surrounding minima
            let leftMin  = signal[0..<c].min() ?? 0
            let rightMin = signal[(c + 1)...].min() ?? 0
            let prom = signal[c] - max(leftMin, rightMin)
            guard prom >= minProminence else { continue }

            // Distance from last accepted peak
            if let last = peaks.last, c - last < minDistance { continue }
            peaks.append(c)
        }
        return peaks
    }
}
