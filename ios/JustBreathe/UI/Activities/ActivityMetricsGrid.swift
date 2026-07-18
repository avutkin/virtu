import SwiftUI

/// 3×3 grid of the same 9 metrics shown live in LiveView's MetricsTableView,
/// using "during" as the primary value. Each tile shows a large, bold %
/// difference plus a small secondary absolute delta. For 8 metrics the
/// comparison is "during vs before"; DFA α1 (Harmony) is compared against
/// 1.0 instead — the "in harmony" reference point — since its meaningful
/// question isn't "did it change" but "how close is it to balanced."
/// Used inside ActivityDetailView, which renders its own header separately.
struct ActivityMetricsGrid: View {
    let entry: ActivityLog

    private let cols = Array(repeating: GridItem(.flexible(), spacing: 10), count: 3)

    var body: some View {
        LazyVGrid(columns: cols, spacing: 10) {
            MetricTile(label: "Harmony",             techLabel: "DFA α1", value: dfa1String,                          unit: "",    delta: dfa1TargetDelta,                            percent: dfa1TargetPercent,                            higherBetter: false)
            MetricTile(label: "Conscious Breathing", techLabel: "RSA",    value: MetricFormat.ms(entry.duringRSA),    unit: "ms",  delta: delta(entry.duringRSA,   entry.beforeRSA),   percent: percent(entry.duringRSA,   entry.beforeRSA),   higherBetter: true)
            MetricTile(label: "Energy Reserve",      techLabel: "HRV",    value: MetricFormat.ms(entry.duringRMSSD),  unit: "ms",  delta: delta(entry.duringRMSSD, entry.beforeRMSSD), percent: percent(entry.duringRMSSD, entry.beforeRMSSD), higherBetter: true)
            MetricTile(label: "Adaptive Power",      techLabel: "RCMSE",  value: rcmseString,                          unit: "",    delta: delta(entry.duringRCMSE, entry.beforeRCMSE), percent: percent(entry.duringRCMSE, entry.beforeRCMSE), higherBetter: true)
            MetricTile(label: "Inner Noise",         techLabel: "PIP",    value: pipString,                            unit: "%",   delta: delta(entry.duringPIP,   entry.beforePIP),   percent: percent(entry.duringPIP,   entry.beforePIP),   higherBetter: false)
            MetricTile(label: "Calm Reserve",        techLabel: "DC",     value: dcString,                             unit: "ms",  delta: delta(entry.duringDC,    entry.beforeDC),    percent: percent(entry.duringDC,    entry.beforeDC),    higherBetter: true)
            MetricTile(label: "Calm Power",          techLabel: "VTI",    value: MetricFormat.ratio(entry.duringVTI),  unit: "",    delta: delta(entry.duringVTI,   entry.beforeVTI),   percent: percent(entry.duringVTI,   entry.beforeVTI),   higherBetter: true)
            MetricTile(label: "Stress Balance",      techLabel: "LF/HF",  value: MetricFormat.ratio(entry.duringLFHF), unit: "",    delta: delta(entry.duringLFHF,  entry.beforeLFHF),  percent: percent(entry.duringLFHF,  entry.beforeLFHF),  higherBetter: false)
            MetricTile(label: "Pulse",               techLabel: "HR",     value: MetricFormat.bpm(entry.duringHR),    unit: "bpm", delta: delta(entry.duringHR,    entry.beforeHR),    percent: percent(entry.duringHR,    entry.beforeHR),    higherBetter: false)
        }
        .cardStyle()
    }

    private var dfa1String:  String { entry.duringDFA1.map  { String(format: "%.2f", $0) } ?? "—" }
    private var rcmseString: String { entry.duringRCMSE.map { String(format: "%.2f", $0) } ?? "—" }
    private var pipString:   String { entry.duringPIP.map   { String(format: "%.1f", $0) } ?? "—" }
    private var dcString:    String { entry.duringDC.map    { String(format: "%.1f", $0) } ?? "—" }

    /// DFA α1's distance from 1.0 (the "in harmony" reference point), not from "before".
    private var dfa1TargetDelta: Float? {
        entry.duringDFA1.map { $0 - 1.0 }
    }

    private var dfa1TargetPercent: Float? {
        entry.duringDFA1.map { ($0 - 1.0) * 100 }
    }

    private func delta(_ current: Float?, _ base: Float?) -> Float? {
        guard let c = current, let b = base else { return nil }
        return c - b
    }

    private func percent(_ current: Float?, _ base: Float?) -> Float? {
        guard let c = current, let b = base, b != 0 else { return nil }
        return (c - b) / b * 100
    }
}
