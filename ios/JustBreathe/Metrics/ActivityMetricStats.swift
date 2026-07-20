import Foundation

/// Which direction of change counts as "better" for a metric — so peaks and
/// uplift percentages read correctly (a drop in HR is an improvement; a drop
/// in RSA is not).
enum BenefitDirection {
    case higher          // more is better (RSA, HRV, RCMSE, DC, VTI)
    case lower           // less is better (HR, LF/HF, PIP)
    case target(Double)  // closeness to a value is better (DFA α1 → 1.0)

    /// Benefit-signed transform: a higher output is always "better".
    func benefit(_ x: Double) -> Double {
        switch self {
        case .higher:        return x
        case .lower:         return -x
        case .target(let t): return -abs(x - t)
        }
    }
}

/// Peak / uplift / recovery statistics for one metric across an activity's
/// before / during / after windows. Pure and unit-tested; views consume it.
struct ActivityMetricStats {
    let baseline:   Double?   // mean of before-phase values
    let peakValue:  Double?   // during value with the best benefit
    let peakDate:   Date?
    let duringMean: Double?
    let afterMean:  Double?

    let peakUpliftPct: Double?  // benefit-signed, peak vs baseline
    let avgUpliftPct:  Double?  // benefit-signed, during-mean vs baseline
    let retainedPct:   Double?  // how much of the during-peak gain persists after
    let timeToBaselineSeconds: Double?  // endedAt → first near-baseline return

    /// Core initializer over raw timed values (trivially unit-testable).
    /// Values are partitioned by timestamp: before (< startedAt),
    /// during ([startedAt, endedAt)), after (>= endedAt).
    init(values: [(date: Date, value: Double)],
         direction: BenefitDirection,
         startedAt: Date, endedAt: Date) {

        let before = values.filter { $0.date < startedAt }
        let during = values.filter { $0.date >= startedAt && $0.date < endedAt }
        let after  = values.filter { $0.date >= endedAt }

        func mean(_ arr: [(date: Date, value: Double)]) -> Double? {
            guard !arr.isEmpty else { return nil }
            return arr.reduce(0) { $0 + $1.value } / Double(arr.count)
        }

        let baseline   = mean(before)
        let duringMean = mean(during)
        let afterMean  = mean(after)
        let peak       = during.max { direction.benefit($0.value) < direction.benefit($1.value) }

        self.baseline   = baseline
        self.duringMean = duringMean
        self.afterMean  = afterMean
        self.peakValue  = peak?.value
        self.peakDate   = peak?.date

        func upliftPct(_ v: Double?) -> Double? {
            guard let v, let b = baseline else { return nil }
            let bb = direction.benefit(b)
            guard bb != 0 else { return nil }
            return (direction.benefit(v) - bb) / abs(bb) * 100
        }
        self.peakUpliftPct = upliftPct(peak?.value)
        self.avgUpliftPct  = upliftPct(duringMean)

        // Retention + time-to-baseline are only meaningful when the practice
        // actually improved the metric (positive gain in benefit space).
        if let b = baseline, let pk = peak?.value {
            let bb   = direction.benefit(b)
            let gain = direction.benefit(pk) - bb
            if gain > 0 {
                if let am = afterMean {
                    self.retainedPct = (direction.benefit(am) - bb) / gain * 100
                } else {
                    self.retainedPct = nil
                }
                let threshold = 0.1 * gain
                let firstReturn = after
                    .sorted { $0.date < $1.date }
                    .first { direction.benefit($0.value) - bb <= threshold }
                self.timeToBaselineSeconds = firstReturn.map { $0.date.timeIntervalSince(endedAt) }
            } else {
                self.retainedPct = nil
                self.timeToBaselineSeconds = nil
            }
        } else {
            self.retainedPct = nil
            self.timeToBaselineSeconds = nil
        }
    }
}

extension ActivityMetricStats {
    /// Convenience: map MetricsHistoryPoint + extractor into timed values.
    init(points: [MetricsHistoryPoint],
         extract: (MetricsHistoryPoint) -> Double?,
         direction: BenefitDirection,
         startedAt: Date, endedAt: Date) {
        let values = points.compactMap { pt -> (date: Date, value: Double)? in
            guard let v = extract(pt) else { return nil }
            return (pt.timestamp, v)
        }
        self.init(values: values, direction: direction, startedAt: startedAt, endedAt: endedAt)
    }
}
