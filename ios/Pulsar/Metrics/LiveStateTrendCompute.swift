import Foundation

// MARK: - MetricTrend

struct MetricTrend {
    let start: Float?
    let end:   Float?
    let min:   Float?
    let max:   Float?
    let mean:  Float?
    let direction: String   // "rising" | "falling" | "stable"
}

// MARK: - LiveStateTrendCompute

enum LiveStateTrendCompute {

    /// Metric keys, matching the backend's expected `metrics` dict keys.
    private static let keyPaths: [(key: String, path: (MetricsHistoryPoint) -> Float?)] = [
        ("hr",         { $0.meanBPM }),
        ("rmssd",      { $0.rmssd }),
        ("rsa",        { $0.rsaMs }),
        ("sdnn",       { $0.sdnn }),
        ("lf_hf",      { $0.lfHF }),
        ("coherence",  { $0.coherence }),
        ("breath_bpm", { $0.breathBPM }),
        ("cbi",        { $0.cbi }),
        ("pip",        { $0.pip }),     // inner noise — focus proxy
        ("dfa1",       { $0.dfa1 }),    // fractal organization — focus proxy
    ]

    /// Minimum quality-passing points required in the window before summarizing
    /// (≈2 minutes at 2 s/tick).
    static let minimumPoints = 30

    /// Summarizes the last `windowMinutes` of quality-filtered history into one
    /// MetricTrend per core metric. Returns nil if there isn't enough valid
    /// data yet.
    static func summarize(_ history: [MetricsHistoryPoint], windowMinutes: Int = 10, now: Date = .now) -> [String: MetricTrend]? {
        let cutoff = now.addingTimeInterval(-Double(windowMinutes) * 60)
        let window = history.filter { $0.timestamp >= cutoff }
        guard window.count >= minimumPoints else { return nil }

        var result: [String: MetricTrend] = [:]
        for (key, path) in keyPaths {
            let values = window.compactMap(path)
            guard !values.isEmpty else { continue }
            result[key] = trend(for: values)
        }
        guard !result.isEmpty else { return nil }
        return result
    }

    private static func trend(for values: [Float]) -> MetricTrend {
        let startVal = values.first
        let endVal   = values.last
        let minVal   = values.min()
        let maxVal   = values.max()
        let meanVal  = values.reduce(0, +) / Float(values.count)

        let direction: String
        if values.count >= 2 {
            let mid = values.count / 2
            let firstHalf  = Array(values[..<mid])
            let secondHalf = Array(values[mid...])
            let firstMean  = firstHalf.reduce(0, +) / Float(firstHalf.count)
            let secondMean = secondHalf.reduce(0, +) / Float(secondHalf.count)
            let relChange  = abs(secondMean - firstMean) / max(abs(firstMean), 1e-6)
            if relChange > 0.05 {
                direction = secondMean > firstMean ? "rising" : "falling"
            } else {
                direction = "stable"
            }
        } else {
            direction = "stable"
        }

        return MetricTrend(start: startVal, end: endVal, min: minVal, max: maxVal, mean: meanVal, direction: direction)
    }
}
