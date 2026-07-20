import SwiftUI

struct MetricTile: View {
    let label:         String   // consumer name
    let techLabel:     String   // technical name shown in gray
    let value:         String
    let unit:          String
    let delta:         Float?
    let percent:       Float?   // legacy: when set (and no peak mode), shown large/bold
    let peakUpliftPct: Float?   // max (peak) uplift — smallest line in peak mode
    let avgUpliftPct:  Float?   // average uplift — the big headline in peak mode
    let historyPct:    Float?   // 2-month avg uplift for this activity type
    let higherBetter:  Bool

    init(label: String, techLabel: String = "", value: String, unit: String,
         delta: Float? = nil, percent: Float? = nil,
         peakUpliftPct: Float? = nil, avgUpliftPct: Float? = nil,
         historyPct: Float? = nil,
         higherBetter: Bool = true) {
        self.label         = label
        self.techLabel     = techLabel
        self.value         = value
        self.unit          = unit
        self.delta         = delta
        self.percent       = percent
        self.peakUpliftPct = peakUpliftPct
        self.avgUpliftPct  = avgUpliftPct
        self.historyPct    = historyPct
        self.higherBetter  = higherBetter
    }

    private var hasData: Bool { value != "—" }
    // Peak-forward layout is used whenever an uplift % is supplied.
    private var isPeakMode: Bool { peakUpliftPct != nil || avgUpliftPct != nil }

    // Legacy delta coloring (Live tab)
    private var deltaColor: Color {
        guard let d = delta else { return Theme.dim }
        return (d >= 0) == higherBetter ? Theme.accent : Theme.warn
    }
    private var deltaText: String { delta.map { String(format: "%+.1f", $0) } ?? "" }
    private var percentText: String { percent.map { String(format: "%+.0f%%", $0) } ?? "" }

    // Peak mode: benefit-signed, so positive is always good.
    private var avgColor: Color {
        guard let a = avgUpliftPct else { return Theme.dim }
        return a >= 0 ? Theme.accent : Theme.warn
    }
    private var avgHeadline: String { avgUpliftPct.map { String(format: "%+.0f%%", $0) } ?? "—" }
    private var peakText: String {
        guard let p = peakUpliftPct else { return "" }
        return String(format: "pk %@ %+.0f%%", p >= 0 ? "▲" : "▼", p)
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

            if isPeakMode {
                // Big average uplift % with the smaller absolute value + unit
                // on the same line.
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(avgHeadline)
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                        .foregroundStyle(hasData ? avgColor : Theme.dim.opacity(0.4))
                    if hasData {
                        Text(value)
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(Theme.text.opacity(0.85))
                        if !unit.isEmpty {
                            Text(unit)
                                .font(.system(size: 8, design: .monospaced))
                                .foregroundStyle(Theme.dim)
                        }
                    }
                }
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .frame(minHeight: 28)

                // Smallest: max (peak) delta %
                if hasData, peakUpliftPct != nil {
                    Text(peakText)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(Theme.dim)
                }

                // 2-month average uplift for this activity type
                if let h = historyPct {
                    Text(String(format: "2mo %+.0f%%", h))
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundStyle((h >= 0 ? Theme.accent : Theme.warn).opacity(0.85))
                }
            } else {
                // Legacy (Live tab): value big, then delta / percent
                Text(value)
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .foregroundStyle(hasData ? Theme.text : Theme.dim.opacity(0.4))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .frame(minHeight: 28)

                HStack(spacing: 4) {
                    Text(unit.isEmpty ? " " : unit)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Theme.dim)
                    if hasData, percent != nil {
                        Text(percentText)
                            .font(.system(size: 14, weight: .bold, design: .monospaced))
                            .foregroundStyle(deltaColor)
                    } else if hasData, delta != nil {
                        Text(deltaText)
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundStyle(deltaColor)
                    }
                }

                if hasData, percent != nil, delta != nil {
                    Text(deltaText + (unit.isEmpty ? "" : " \(unit)"))
                        .font(.system(size: 8, design: .monospaced))
                        .foregroundStyle(deltaColor.opacity(0.7))
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: isPeakMode ? 108 : (percent != nil ? 104 : 90), alignment: .leading)
        .padding(12)
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}
