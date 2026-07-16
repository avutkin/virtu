import Accelerate
import Foundation

// MARK: - Output structs

struct RCMSEResult {
    /// Per-scale entropy values (index 0 = scale 1).
    let values:    [Float]
    /// Mean entropy across scales 1–5 (or fewer if data is short).
    let meanEntropy: Float
    let windowSize:  Int
}

struct HRFragResult {
    /// % of inflection points (higher = more fragmented). Healthy: ~55%.
    let pip:  Float
    /// Inverse average segment length (higher = more fragmented). Healthy: ~0.52.
    let ials: Float
    /// % of beats in short segments (len ≤ 2). Higher = more fragmented. Healthy: ~62%.
    let pss:  Float
}

struct DCResult {
    /// Deceleration Capacity in ms. Healthy 5-min range: ~6–9 ms. <4.5 ms = high risk (24h norm).
    let dc: Float
    /// Acceleration Capacity in ms (mirror metric).
    let ac: Float
    let anchorCount: Int
}

// MARK: - Advanced HRV Compute

enum AdvancedHRVCompute {

    // ── RCMSE ────────────────────────────────────────────────────────────────

    static let rcmseMinIntervals = 100
    private static let rcmseScales     = Array(1...10)
    private static let rcmseM: Int     = 2
    private static let rcmseR: Float   = 0.15   // tolerance = 0.15 × SD(original)

    /// Refined Composite Multiscale Sample Entropy (Wu et al. 2014).
    /// Requires ≥ 100 RR intervals. Returns nil otherwise.
    static func computeRCMSE(rrMs: [Int]) -> RCMSEResult? {
        let rr = HRVCompute.cleanRR(rrMs)
        guard rr.count >= rcmseMinIntervals else { return nil }

        let sd  = standardDeviation(rr)
        guard sd > 0 else { return nil }
        let tol = rcmseR * sd

        var values = [Float]()
        for tau in rcmseScales {
            guard rr.count / tau >= 10 else { break }
            var totalA = 0, totalB = 0
            for k in 1...tau {
                let cg = coarseGrain(rr, tau: tau, offset: k)
                let (a, b) = templateCounts(cg, m: rcmseM, r: Double(tol))
                totalA += a
                totalB += b
            }
            guard totalB > 0, totalA > 0 else { break }
            values.append(-log(Float(totalA) / Float(totalB)))
        }
        guard !values.isEmpty else { return nil }

        let report = min(values.count, 5)
        let mean   = values.prefix(report).reduce(0, +) / Float(report)
        return RCMSEResult(values: values, meanEntropy: mean, windowSize: rr.count)
    }

    // ── HR Fragmentation ──────────────────────────────────────────────────────

    static let hrfMinIntervals = 30

    /// HR Fragmentation indices (Costa et al. 2017).
    /// Returns nil when fewer than 30 NN intervals are available.
    static func computeHRF(rrMs: [Int]) -> HRFragResult? {
        let nn = HRVCompute.cleanRR(rrMs)
        let N  = nn.count
        guard N >= hrfMinIntervals else { return nil }

        // Increment series: delta[i] = nn[i+1] - nn[i]
        let delta = (0..<N-1).map { nn[$0+1] - nn[$0] }

        // Inflection points: delta[i] * delta[i+1] <= 0
        var inflectionAt = [Bool](repeating: false, count: delta.count)
        var inflectionCount = 0
        for i in 0..<(delta.count - 1) {
            if delta[i] * delta[i+1] <= 0 {
                inflectionAt[i] = true
                inflectionCount += 1
            }
        }
        let pip = Float(inflectionCount) / Float(N - 2) * 100.0

        // Segment extraction
        var segments = [Int]()
        var segLen   = 1
        for idx in 0..<(delta.count - 1) {
            if inflectionAt[idx] {
                segments.append(segLen)
                segLen = 1
            } else {
                segLen += 1
            }
        }
        segments.append(segLen)

        let totalSegs   = Float(segments.count)
        let totalInSegs = Float(segments.reduce(0, +))
        guard totalInSegs > 0 else { return nil }

        let ials = totalSegs / totalInSegs

        let nnInLong = Float(segments.filter { $0 >= 3 }.reduce(0, +))
        let pss      = (1.0 - nnInLong / totalInSegs) * 100.0

        return HRFragResult(pip: pip, ials: ials, pss: pss)
    }

    // ── Deceleration Capacity (PRSA) ──────────────────────────────────────────

    /// L parameter — validated for 5-min recordings (Bauer 2006, PMC11659320).
    private static let prsa_L = 64

    static let dcMinIntervals = 150   // 2*L + safety margin

    /// Deceleration and Acceleration Capacity via Phase-Rectified Signal Averaging
    /// (Bauer et al. 2006, Lancet).
    /// DC > 0 is normal. Healthy 5-min median ≈ 6.1 ms.
    static func computeDC(rrMs: [Int]) -> DCResult? {
        let L  = prsa_L
        let rr = cleanRRForPRSA(rrMs)
        guard rr.count >= dcMinIntervals else { return nil }

        // Deceleration anchors: rr[i] > rr[i-1], with boundary guard
        let decAnchors = (L..<rr.count - L).filter { rr[$0] > rr[$0 - 1] }
        let accAnchors = (L..<rr.count - L).filter { rr[$0] < rr[$0 - 1] }
        guard decAnchors.count >= 20, accAnchors.count >= 20 else { return nil }

        let dc = prsa(rr: rr, anchors: decAnchors, L: L)
        let ac = prsa(rr: rr, anchors: accAnchors, L: L)

        return DCResult(dc: Float(dc), ac: Float(ac), anchorCount: decAnchors.count)
    }

    // MARK: - Private helpers

    /// PRSA averaging and Haar wavelet extraction.
    private static func prsa(rr: [Double], anchors: [Int], L: Int) -> Double {
        var X = [Double](repeating: 0, count: 2 * L)
        for anchor in anchors {
            for k in -L..<L {
                X[k + L] += rr[anchor + k]
            }
        }
        let M = Double(anchors.count)
        X = X.map { $0 / M }
        // DC = (X[0] + X[1] - X[-1] - X[-2]) / 4
        // Array indices: k=-2→L-2, k=-1→L-1, k=0→L, k=1→L+1
        return (X[L] + X[L + 1] - X[L - 1] - X[L - 2]) / 4.0
    }

    /// Artifact rejection for PRSA only: keep intervals in [300, 2500] ms and
    /// exclude beats differing > 20% from predecessor. PRSA/DC is uniquely
    /// sensitive to ectopic beats (phase-rectified averaging around each
    /// accel/decel anchor), unlike the time/frequency-domain metrics, which
    /// need to see genuine large RSA swings during paced breathing — so this
    /// stricter filter is intentionally NOT part of the shared `HRVCompute.cleanRR`.
    private static func cleanRRForPRSA(_ rrMs: [Int]) -> [Double] {
        var clean = [Double]()
        for v in rrMs {
            let d = Double(v)
            guard d >= 300, d <= 2500 else { continue }
            if let prev = clean.last, abs(d - prev) / prev > 0.20 { continue }
            clean.append(d)
        }
        return clean
    }

    /// Create k-th coarse-grained series at scale τ (1-indexed offset k, 1…τ).
    private static func coarseGrain(_ rr: [Float], tau: Int, offset k: Int) -> [Float] {
        let length = rr.count / tau
        return (1...length).compactMap { j -> Float? in
            let start = (j - 1) * tau + (k - 1)
            let end   = j * tau + (k - 2)
            guard end < rr.count else { return nil }
            let slice = Array(rr[start...end])
            return vDSP.mean(slice)
        }
    }

    /// Count template matches of length m (B) and m+1 (A) using Chebyshev distance.
    private static func templateCounts(_ y: [Float], m: Int, r: Double) -> (A: Int, B: Int) {
        let L = y.count
        guard L > m + 1 else { return (0, 0) }
        var B = 0, A = 0
        for i in 0..<(L - m) {
            for j in (i + 1)..<(L - m) {
                // Length-m match
                var matchM = true
                for p in 0..<m {
                    if abs(Double(y[i + p] - y[j + p])) > r { matchM = false; break }
                }
                if matchM {
                    B += 1
                    // Extend to m+1
                    if i + m < L, j + m < L {
                        if abs(Double(y[i + m] - y[j + m])) <= r { A += 1 }
                    }
                }
            }
        }
        return (A, B)
    }

    private static func standardDeviation(_ v: [Float]) -> Float {
        guard v.count > 1 else { return 0 }
        let mean = vDSP.mean(v)
        let sq   = vDSP.sumOfSquares(vDSP.subtract(v, [Float](repeating: mean, count: v.count)))
        return sqrt(sq / Float(v.count - 1))
    }
}
