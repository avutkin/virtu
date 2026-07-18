import SwiftUI

struct MetricTile: View {
    let label:        String   // consumer name
    let techLabel:    String   // technical name shown in gray
    let value:        String
    let unit:         String
    let delta:        Float?
    let percent:      Float?   // when provided, shown large/bold; delta becomes the small secondary line
    let higherBetter: Bool

    init(label: String, techLabel: String = "", value: String, unit: String,
         delta: Float?, percent: Float? = nil, higherBetter: Bool) {
        self.label        = label
        self.techLabel    = techLabel
        self.value        = value
        self.unit         = unit
        self.delta        = delta
        self.percent      = percent
        self.higherBetter = higherBetter
    }

    private var deltaColor: Color {
        guard let d = delta else { return Theme.dim }
        let positive = d >= 0
        return (positive == higherBetter) ? Theme.accent : Theme.warn
    }

    private var deltaText: String {
        guard let d = delta else { return "" }
        return String(format: "%+.1f", d)
    }

    private var percentText: String {
        guard let p = percent else { return "" }
        return String(format: "%+.0f%%", p)
    }

    private var hasData: Bool { value != "—" }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Line 1 — white consumer name
            Text(label)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(Theme.text)
                .lineLimit(1)
                .truncationMode(.tail)
            // Line 2 — gray technical term (tight spacing so they read as one label)
            if !techLabel.isEmpty {
                Text(techLabel)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(Theme.dim)
                    .lineLimit(1)
                    .padding(.top, -2)
            }

            // Value — fixed height so all tiles are the same size
            Text(value)
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .foregroundStyle(hasData ? Theme.text : Theme.dim.opacity(0.4))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(minHeight: 28)

            // Unit + primary delta (percent when provided, else the plain absolute delta)
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

            // Secondary line — absolute delta, only shown alongside percent
            if hasData, percent != nil, delta != nil {
                Text(deltaText + (unit.isEmpty ? "" : " \(unit)"))
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundStyle(deltaColor.opacity(0.7))
            }
        }
        .frame(maxWidth: .infinity, minHeight: percent != nil ? 104 : 90, alignment: .leading)
        .padding(12)
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}
