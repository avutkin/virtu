import SwiftUI

/// One metric's presentation + data-access definition. Shared by the tile
/// grid and the stacked charts so the two views cannot drift.
struct ActivityMetricDef: Identifiable {
    var id: String { label }
    let label:     String
    let techLabel: String
    let unit:      String
    let direction: BenefitDirection
    let extract:   (MetricsHistoryPoint) -> Double?
    let format:    (Double?) -> String
    // Stored ActivityLog fields for this metric, used to compute the
    // 2-month per-activity-type average uplift from past sessions.
    let beforeKey: KeyPath<ActivityLog, Float?>
    let duringKey: KeyPath<ActivityLog, Float?>
    /// One-to-two sentences: why improving this metric matters and the state
    /// to expect. Shown under the metric's chart in the detail view.
    let why:       String
}

extension ActivityMetricDef {
    /// Benefit-signed % change of `current` vs `base` (positive = better),
    /// e.g. this session's during-average vs the 2-month baseline.
    func benefitDelta(current: Double?, base: Double?) -> Double? {
        guard let c = current, let b = base else { return nil }
        let bb = direction.benefit(b)
        guard bb != 0 else { return nil }
        return (direction.benefit(c) - bb) / abs(bb) * 100
    }

    /// Position of `value` on a 0…1 benefit axis spanning `others` (higher =
    /// better = right). Returns nil when the span collapses or data is missing.
    func benefitPosition(of value: Double?, across others: [Double?]) -> Double? {
        guard let v = value else { return nil }
        let benefits = ([value] + others).compactMap { $0.map(direction.benefit) }
        guard let lo = benefits.min(), let hi = benefits.max(), hi > lo else { return nil }
        let frac = (direction.benefit(v) - lo) / (hi - lo)
        return 0.08 + frac * 0.84   // inset so end dots stay off the edges
    }
}

private func f2(_ v: Double?) -> String { v.map { String(format: "%.2f", $0) } ?? "—" }
private func f1(_ v: Double?) -> String { v.map { String(format: "%.1f", $0) } ?? "—" }
private func fFloat(_ v: Double?, _ fmt: (Float?) -> String) -> String { fmt(v.map { Float($0) }) }

/// The 9 metrics, in display order, matching the Live section's charts
/// (MetricsChartsView): DC, RCMSE, PIP, DFA α1, LF/HF, RSA, VTI, HRV, HR.
let activityMetricDefs: [ActivityMetricDef] = [
    .init(label: "Calm Reserve",        techLabel: "DC",     unit: "ms",  direction: .higher,      extract: { $0.dc.map(Double.init) },      format: f1,                                 beforeKey: \.beforeDC,    duringKey: \.duringDC,
          why: "Calm Reserve (Deceleration Capacity) is your vagal “brake” — how readily the heart slows. Higher means deeper parasympathetic recovery; expect it to climb as you settle."),
    .init(label: "Adaptive Power",      techLabel: "RCMSE",  unit: "",    direction: .higher,      extract: { $0.rcmse.map(Double.init) },   format: f2,                                 beforeKey: \.beforeRCMSE, duringKey: \.duringRCMSE,
          why: "Adaptive Power (Refined Composite Multiscale Entropy) reflects how flexible your system is across timescales. Higher signals a resilient, responsive heart; expect a modest rise with calm focus."),
    .init(label: "Inner Noise",         techLabel: "PIP",    unit: "%",   direction: .lower,       extract: { $0.pip.map(Double.init) },     format: f1,                                 beforeKey: \.beforePIP,   duringKey: \.duringPIP,
          why: "Inner Noise (Percentage of Inflection Points) captures beat-to-beat jitter — erratic, non-restorative variability. Lower means a cleaner, calmer signal; expect it to fall as you relax."),
    .init(label: "Harmony",             techLabel: "DFA α1", unit: "",    direction: .target(1.0), extract: { $0.dfa1.map(Double.init) },    format: f2,                                 beforeKey: \.beforeDFA1,  duringKey: \.duringDFA1,
          why: "Harmony (DFA α1) is the fractal balance of your heartbeat, with ~1.0 the healthy sweet spot. Moving toward 1.0 signals well-organised regulation; expect it to approach 1.0 as you relax."),
    .init(label: "Stress Balance",      techLabel: "LF/HF",  unit: "",    direction: .lower,       extract: { $0.lfHF.map(Double.init) },    format: { fFloat($0, MetricFormat.ratio) }, beforeKey: \.beforeLFHF,  duringKey: \.duringLFHF,
          why: "Stress Balance (LF/HF ratio) weighs sympathetic drive against parasympathetic calm. Lower means you’re shifting into rest-and-digest; expect it to drop through the session."),
    .init(label: "Conscious Breathing", techLabel: "RSA",    unit: "ms",  direction: .higher,      extract: { $0.rsaMs.map(Double.init) },   format: { fFloat($0, MetricFormat.ms) },    beforeKey: \.beforeRSA,   duringKey: \.duringRSA,
          why: "Conscious Breathing (Respiratory Sinus Arrhythmia) is the swing of heart rate with each breath — the clearest sign of vagal tone. Higher means slow, deep breathing is landing; expect it to rise with paced diaphragmatic breaths."),
    .init(label: "Calm Power",          techLabel: "VTI",    unit: "",    direction: .higher,      extract: { $0.vti.map(Double.init) },     format: { fFloat($0, MetricFormat.ratio) }, beforeKey: \.beforeVTI,   duringKey: \.duringVTI,
          why: "Calm Power (Vagal Tone Index) sums your restorative parasympathetic activity. Higher means a stronger recovery drive; expect it to build as you ease down."),
    .init(label: "Energy Reserve",      techLabel: "HRV",    unit: "ms",  direction: .higher,      extract: { $0.rmssd.map(Double.init) },   format: { fFloat($0, MetricFormat.ms) },    beforeKey: \.beforeRMSSD, duringKey: \.duringRMSSD,
          why: "Energy Reserve (HRV · RMSSD) is your core beat-to-beat variability — the headline marker of recovery and vagal tone. Higher signals a rested, adaptable system; expect it to rise during restful practice."),
    .init(label: "Pulse",               techLabel: "HR",     unit: "bpm", direction: .lower,       extract: { $0.meanBPM.map(Double.init) }, format: { fFloat($0, MetricFormat.bpm) },   beforeKey: \.beforeHR,    duringKey: \.duringHR,
          why: "Pulse (Heart Rate) reflects the overall load on your heart. A lower rate during practice means you’re offloading stress and settling; expect it to fall as you relax."),
]

/// 3×3 grid of the 9 metrics. Each tile shows the peak-during value with a
/// large benefit-signed peak-uplift % and a small avg-during %. Used inside
/// ActivityDetailView, which renders its own header separately.
struct ActivityMetricsGrid: View {
    let metrics: [(def: ActivityMetricDef, stats: ActivityMetricStats)]
    /// Metric id → average absolute "during" value across other sessions of
    /// the same activity type over the past 2 months (the baseline).
    let history: [String: Double]
    /// Metric id → average uplift % (during vs before) over the past 2 months.
    let historyUplift: [String: Double]

    private let cols = Array(repeating: GridItem(.flexible(), spacing: 10), count: 3)

    var body: some View {
        LazyVGrid(columns: cols, spacing: 10) {
            ForEach(metrics, id: \.def.id) { m in
                let base = history[m.def.id]
                MetricTile(
                    label:            m.def.label,
                    techLabel:        m.def.techLabel,
                    value:            m.def.format(m.stats.duringMean),
                    unit:             m.def.unit,
                    avgUpliftPct:     m.stats.avgUpliftPct.map { Float($0) },
                    historyValue:     base.map { m.def.format($0) },
                    historyDeltaPct:  historyDelta(m.def, current: m.stats.duringMean, base: base),
                    historyUpliftPct: historyUplift[m.def.id].map { Float($0) }
                )
            }
        }
        .cardStyle()
    }

    /// Benefit-signed % of this session's during-average vs the 2-month
    /// baseline (green = better, matching the tiles).
    private func historyDelta(_ def: ActivityMetricDef, current: Double?, base: Double?) -> Float? {
        guard let c = current, let b = base else { return nil }
        let bb = def.direction.benefit(b)
        guard bb != 0 else { return nil }
        return Float((def.direction.benefit(c) - bb) / abs(bb) * 100)
    }
}
