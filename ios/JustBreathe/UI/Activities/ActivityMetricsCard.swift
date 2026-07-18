import SwiftUI

/// Extended per-activity card for the day-grouped history list: header
/// (icon/name/time/duration) plus a 3×3 grid of the same 9 metrics shown
/// live in LiveView's MetricsTableView, using "during" as the primary
/// value and "during − before" as the delta — mirroring both the Live
/// tab's tick/day-average convention and the prior compact row's
/// during/before convention.
struct ActivityMetricsCard: View {
    let entry: ActivityLog

    private var timeStr: String {
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm"
        return fmt.string(from: entry.startedAt)
    }

    private let cols = Array(repeating: GridItem(.flexible(), spacing: 10), count: 3)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(entry.activityTypeEnum.color.opacity(0.15))
                        .frame(width: 36, height: 36)
                    Image(systemName: entry.activityTypeEnum.icon)
                        .font(.system(size: 16))
                        .foregroundStyle(entry.activityTypeEnum.color)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.displayName)
                        .font(.system(size: 14, weight: .medium, design: .monospaced))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                    HStack(spacing: 4) {
                        Text(timeStr)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Theme.dim)
                        if entry.isActive {
                            Text("LIVE").font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.warn)
                        } else {
                            Text(entry.durationString).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.dim)
                        }
                    }
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.dim.opacity(0.4))
            }

            LazyVGrid(columns: cols, spacing: 10) {
                MetricTile(label: "Harmony",             techLabel: "DFA α1", value: dfa1String,                          unit: "",    delta: delta(entry.duringDFA1,  entry.beforeDFA1),  higherBetter: false)
                MetricTile(label: "Conscious Breathing", techLabel: "RSA",    value: MetricFormat.ms(entry.duringRSA),    unit: "ms",  delta: delta(entry.duringRSA,   entry.beforeRSA),   higherBetter: true)
                MetricTile(label: "Energy Reserve",      techLabel: "HRV",    value: MetricFormat.ms(entry.duringRMSSD),  unit: "ms",  delta: delta(entry.duringRMSSD, entry.beforeRMSSD), higherBetter: true)
                MetricTile(label: "Adaptive Power",      techLabel: "RCMSE",  value: rcmseString,                          unit: "",    delta: delta(entry.duringRCMSE, entry.beforeRCMSE), higherBetter: true)
                MetricTile(label: "Inner Noise",         techLabel: "PIP",    value: pipString,                            unit: "%",   delta: delta(entry.duringPIP,   entry.beforePIP),   higherBetter: false)
                MetricTile(label: "Calm Reserve",        techLabel: "DC",     value: dcString,                             unit: "ms",  delta: delta(entry.duringDC,    entry.beforeDC),    higherBetter: true)
                MetricTile(label: "Calm Power",          techLabel: "VTI",    value: MetricFormat.ratio(entry.duringVTI),  unit: "",    delta: delta(entry.duringVTI,   entry.beforeVTI),   higherBetter: true)
                MetricTile(label: "Stress Balance",      techLabel: "LF/HF",  value: MetricFormat.ratio(entry.duringLFHF), unit: "",    delta: delta(entry.duringLFHF,  entry.beforeLFHF),  higherBetter: false)
                MetricTile(label: "Pulse",               techLabel: "HR",     value: MetricFormat.bpm(entry.duringHR),    unit: "bpm", delta: delta(entry.duringHR,    entry.beforeHR),    higherBetter: false)
            }
        }
        .cardStyle()
    }

    private var dfa1String:  String { entry.duringDFA1.map  { String(format: "%.2f", $0) } ?? "—" }
    private var rcmseString: String { entry.duringRCMSE.map { String(format: "%.2f", $0) } ?? "—" }
    private var pipString:   String { entry.duringPIP.map   { String(format: "%.1f", $0) } ?? "—" }
    private var dcString:    String { entry.duringDC.map    { String(format: "%.1f", $0) } ?? "—" }

    private func delta(_ current: Float?, _ base: Float?) -> Float? {
        guard let c = current, let b = base else { return nil }
        return c - b
    }
}
