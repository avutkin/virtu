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
}

private func f2(_ v: Double?) -> String { v.map { String(format: "%.2f", $0) } ?? "—" }
private func f1(_ v: Double?) -> String { v.map { String(format: "%.1f", $0) } ?? "—" }
private func fFloat(_ v: Double?, _ fmt: (Float?) -> String) -> String { fmt(v.map { Float($0) }) }

/// The 9 metrics, in display order, matching LiveView's MetricsTableView.
let activityMetricDefs: [ActivityMetricDef] = [
    .init(label: "Harmony",             techLabel: "DFA α1", unit: "",    direction: .target(1.0), extract: { $0.dfa1.map(Double.init) },    format: f2),
    .init(label: "Conscious Breathing", techLabel: "RSA",    unit: "ms",  direction: .higher,      extract: { $0.rsaMs.map(Double.init) },   format: { fFloat($0, MetricFormat.ms) }),
    .init(label: "Energy Reserve",      techLabel: "HRV",    unit: "ms",  direction: .higher,      extract: { $0.rmssd.map(Double.init) },   format: { fFloat($0, MetricFormat.ms) }),
    .init(label: "Adaptive Power",      techLabel: "RCMSE",  unit: "",    direction: .higher,      extract: { $0.rcmse.map(Double.init) },   format: f2),
    .init(label: "Inner Noise",         techLabel: "PIP",    unit: "%",   direction: .lower,       extract: { $0.pip.map(Double.init) },     format: f1),
    .init(label: "Calm Reserve",        techLabel: "DC",     unit: "ms",  direction: .higher,      extract: { $0.dc.map(Double.init) },      format: f1),
    .init(label: "Calm Power",          techLabel: "VTI",    unit: "",    direction: .higher,      extract: { $0.vti.map(Double.init) },     format: { fFloat($0, MetricFormat.ratio) }),
    .init(label: "Stress Balance",      techLabel: "LF/HF",  unit: "",    direction: .lower,       extract: { $0.lfHF.map(Double.init) },    format: { fFloat($0, MetricFormat.ratio) }),
    .init(label: "Pulse",               techLabel: "HR",     unit: "bpm", direction: .lower,       extract: { $0.meanBPM.map(Double.init) }, format: { fFloat($0, MetricFormat.bpm) }),
]

/// 3×3 grid of the 9 metrics. Each tile shows the peak-during value with a
/// large benefit-signed peak-uplift % and a small avg-during %. Used inside
/// ActivityDetailView, which renders its own header separately.
struct ActivityMetricsGrid: View {
    let metrics: [(def: ActivityMetricDef, stats: ActivityMetricStats)]

    private let cols = Array(repeating: GridItem(.flexible(), spacing: 10), count: 3)

    var body: some View {
        LazyVGrid(columns: cols, spacing: 10) {
            ForEach(metrics, id: \.def.id) { m in
                MetricTile(
                    label:         m.def.label,
                    techLabel:     m.def.techLabel,
                    value:         m.def.format(m.stats.peakValue),
                    unit:          m.def.unit,
                    peakUpliftPct: m.stats.peakUpliftPct.map { Float($0) },
                    avgUpliftPct:  m.stats.avgUpliftPct.map { Float($0) }
                )
            }
        }
        .cardStyle()
    }
}
