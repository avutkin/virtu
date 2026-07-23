import Accelerate
import Foundation

// MARK: - DFA α1 Output

struct DFAResult {
    /// Short-term fractal scaling exponent (scales n = 4–16 beats).
    /// Healthy range: 0.75–1.5. Ideal: ~1.0.
    let alpha1: Float

    /// Number of RR intervals used for this computation.
    let windowSize: Int
}

// MARK: - DFACompute

/// Detrended Fluctuation Analysis — short-term scaling exponent α1.
///
/// Algorithm (Peng et al. 1995):
///   1. Integrate the mean-subtracted RR series → y(k).
///   2. For each box size n in [4, 16], divide y into non-overlapping
///      boxes, linearly detrend each box, compute root-mean-square F(n).
///   3. α1 = slope of log F(n) vs log n (linear regression).
///
/// Best practice interval: compute every 30–60 s on a rolling window of
/// 256 beats. Requires ≥ 128 RR intervals; returns nil if unavailable.
enum DFACompute {

    /// Short-term scales per the standard short-term α1 definition.
    private static let scales = [4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16]

    /// Minimum beats required for a reliable α1 estimate.
    static let minIntervals = 128

    /// Rolling window — use at most this many recent beats.
    private static let windowSize = 256

    /// Compute DFA α1 from raw RR intervals in milliseconds.
    /// - Returns: `nil` when fewer than `minIntervals` are available.
    static func compute(rrMs: [Int]) -> DFAResult? {
        let cleaned = HRVCompute.cleanRR(rrMs)
        guard cleaned.count >= minIntervals else { return nil }

        let n   = min(cleaned.count, windowSize)
        let rr  = Array(cleaned.suffix(n))

        // 1. Integrate: y[k] = Σ (rr[i] - mean_rr)
        let mean: Float = vDSP.mean(rr)
        var y = [Float](repeating: 0, count: rr.count)
        var cum: Float = 0
        for i in 0..<rr.count {
            cum   += rr[i] - mean
            y[i]   = cum
        }

        // 2. Fluctuation function F(n) for each scale
        var logN = [Float]()
        var logF = [Float]()

        for scale in scales {
            guard scale * 4 <= y.count else { continue }   // need ≥ 4 boxes
            let nBoxes = y.count / scale
            guard nBoxes > 0 else { continue }

            var sumSq: Float = 0

            for box in 0..<nBoxes {
                let lo  = box * scale
                let seg = Array(y[lo..<lo + scale])

                // Linear detrending inside the box
                let (a, b) = linearFit(n: scale, y: seg)
                var rmsq: Float = 0
                for j in 0..<scale {
                    let res = seg[j] - (a + b * Float(j))
                    rmsq += res * res
                }
                sumSq += rmsq / Float(scale)
            }

            let F = sqrt(sumSq / Float(nBoxes))
            guard F > 1e-8 else { continue }

            logN.append(log(Float(scale)))
            logF.append(log(F))
        }

        guard logN.count >= 4 else { return nil }

        // 3. α1 = slope of log F vs log n
        let alpha = linearSlope(x: logN, y: logF)
        guard alpha.isFinite else { return nil }

        return DFAResult(alpha1: alpha, windowSize: n)
    }

    // MARK: - Private helpers

    /// Returns (intercept a, slope b) of the least-squares line y = a + b·x
    /// for x = 0, 1, …, n-1.
    private static func linearFit(n: Int, y: [Float]) -> (Float, Float) {
        let fN   = Float(n)
        let sumX = fN * (fN - 1) / 2                        // 0+1+…+(n-1)
        let sumX2 = fN * (fN - 1) * (2 * fN - 1) / 6       // 0²+1²+…+(n-1)²
        var sumY: Float = 0
        var sumXY: Float = 0
        for i in 0..<n {
            sumY  += y[i]
            sumXY += Float(i) * y[i]
        }
        let denom = fN * sumX2 - sumX * sumX
        guard abs(denom) > 1e-8 else { return (sumY / fN, 0) }
        let b = (fN * sumXY - sumX * sumY) / denom
        let a = (sumY - b * sumX) / fN
        return (a, b)
    }

    /// Ordinary least-squares slope for arbitrary x, y vectors.
    private static func linearSlope(x: [Float], y: [Float]) -> Float {
        let n     = Float(x.count)
        let sumX  = vDSP.sum(x)
        let sumY  = vDSP.sum(y)
        let sumX2 = vDSP.sumOfSquares(x)
        let sumXY = vDSP.dot(x, y)
        let denom = n * sumX2 - sumX * sumX
        guard abs(denom) > 1e-8 else { return 1.0 }
        return (n * sumXY - sumX * sumY) / denom
    }
}
