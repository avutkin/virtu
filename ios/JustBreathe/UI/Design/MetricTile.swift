import SwiftUI

struct MetricTile: View {
    let label:         String   // consumer name
    let techLabel:     String   // technical name shown in gray
    let value:         String
    let unit:          String
    let delta:         Float?
    let percent:       Float?   // legacy: when set (and no peakUpliftPct), shown large/bold
    let peakUpliftPct: Float?   // when set, tile renders peak-forward (benefit-signed %)
    let avgUpliftPct:  Float?   // small secondary line in peak mode
    let higherBetter:  Bool

    init(label: String, techLabel: String = "", value: String, unit: String,
         delta: Float? = nil, percent: Float? = nil,
         peakUpliftPct: Float? = nil, avgUpliftPct: Float? = nil,
         higherBetter: Bool = true) {
        self.label         = label
        self.techLabel     = techLabel
        self.value         = value
        self.unit          = unit
        self.delta         = delta
        self.percent       = percent
        self.peakUpliftPct = peakUpliftPct
        self.avgUpliftPct  = avgUpliftPct
        self.higherBetter  = higherBetter
    }

    private var hasData: Bool { value != "—" }
    private var isPeakMode: Bool { peakUpliftPct != nil }

    // Legacy delta coloring (Live tab)
    private var deltaColor: Color {
        guard let d = delta else { return Theme.dim }
        return (d >= 0) == higherBetter ? Theme.accent : Theme.warn
    }
    private var deltaText: String { delta.map { String(format: "%+.1f", $0) } ?? "" }
    private var percentText: String { percent.map { String(format: "%+.0f%%", $0) } ?? "" }

    // Peak mode: benefit-signed, so positive is always good.
    private var peakColor: Color {
        guard let p = peakUpliftPct else { return Theme.dim }
        return p >= 0 ? Theme.accent : Theme.warn
    }
    private var peakText: String {
        guard let p = peakUpliftPct else { return "" }
        return String(format: "%@ %+.0f%%", p >= 0 ? "▲" : "▼", p)
    }
    private var avgText: String {
        avgUpliftPct.map { String(format: "avg %+.0f%%", $0) } ?? ""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(Theme.text)
                .lineLimit(1)
                .truncationMode(.tail)
            if !techLabel.isEmpty {
                Text(techLabel)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(Theme.dim)
                    .lineLimit(1)
                    .padding(.top, -2)
            }

            Text(value)
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .foregroundStyle(hasData ? Theme.text : Theme.dim.opacity(0.4))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(minHeight: 28)

            // Primary line
            HStack(spacing: 4) {
                Text(unit.isEmpty ? " " : unit)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Theme.dim)
                if hasData, isPeakMode {
                    Text(peakText)
                        .font(.system(size: 15, weight: .bold, design: .monospaced))
                        .foregroundStyle(peakColor)
                } else if hasData, percent != nil {
                    Text(percentText)
                        .font(.system(size: 14, weight: .bold, design: .monospaced))
                        .foregroundStyle(deltaColor)
                } else if hasData, delta != nil {
                    Text(deltaText)
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(deltaColor)
                }
            }

            // Secondary line
            if hasData, isPeakMode, avgUpliftPct != nil {
                Text(avgText)
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundStyle(Theme.dim)
            } else if hasData, !isPeakMode, percent != nil, delta != nil {
                Text(deltaText + (unit.isEmpty ? "" : " \(unit)"))
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundStyle(deltaColor.opacity(0.7))
            }
        }
        .frame(maxWidth: .infinity, minHeight: (isPeakMode || percent != nil) ? 104 : 90, alignment: .leading)
        .padding(12)
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}
