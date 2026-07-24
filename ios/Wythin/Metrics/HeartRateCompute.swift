import Foundation

/// Robust current heart rate (bpm), resilient to motion artifacts.
///
/// Prefers the Polar H10's own BPM: Polar's firmware detects beats from the
/// full ECG with its own artifact handling and stays accurate during running,
/// exactly where app-side RR timing degrades. Falls back to the median of
/// recent RR intervals when no sensor BPM is available.
///
/// Both paths take a MEDIAN over a RECENT window, so a handful of missed/extra
/// beats (long/short RR outliers) can't drag the reading — unlike the previous
/// `60000 / mean(entire RR buffer)`, which read far too low during a run
/// because the buffer still held minutes of older, slower resting beats.
enum HeartRateCompute {

    private static let sensorWindow = 8     // most recent sensor BPM samples (~8 s)
    private static let rrWindow     = 20    // most recent RR intervals

    /// Current heart rate in bpm, or nil when there is no usable data.
    static func current(rrMs: [Int], sensorBPM: [Float]) -> Float? {
        // 1. Sensor BPM — most robust during motion.
        let bpm = sensorBPM.suffix(sensorWindow).filter { $0 >= 30 && $0 <= 240 }
        if let m = median(bpm) { return m }

        // 2. Fallback: median of recent plausible RR intervals.
        let rr = rrMs.suffix(rrWindow).compactMap { v -> Float? in
            (300...2000).contains(v) ? Float(v) : nil
        }
        if let medRR = median(rr), medRR > 0 { return 60_000 / medRR }

        return nil
    }

    /// Median of a Float array, or nil if empty.
    static func median(_ values: [Float]) -> Float? {
        guard !values.isEmpty else { return nil }
        let s = values.sorted()
        let n = s.count
        return n % 2 == 1 ? s[n / 2] : (s[n / 2 - 1] + s[n / 2]) / 2
    }
}
