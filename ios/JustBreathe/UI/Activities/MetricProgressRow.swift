import SwiftUI

/// One metric as a progressive-disclosure row: a compact before → during
/// progress bar (with a 2-month tick) that expands to reveal the metric's
/// before/during/after chart and a short "why it matters" note.
struct MetricProgressRow: View {
    let def:            ActivityMetricDef
    let stats:          ActivityMetricStats
    let twoMonthValue:  Double?      // avg absolute during-value, past 2 months
    let color:          Color
    let points:         [MetricsHistoryPoint]
    let startedAt:      Date
    let endedAt:        Date

    @State private var expanded = false

    /// Benefit-signed uplift this session (during vs before).
    private var uplift: Double? { stats.avgUpliftPct }
    /// Benefit-signed change vs the 2-month average during-value.
    private var vs2mo: Double? { def.benefitDelta(current: stats.duringMean, base: twoMonthValue) }

    private func deltaColor(_ v: Double?) -> Color {
        guard let v else { return Theme.dim }
        if v > 2 { return Theme.accent }
        if v < -2 { return Theme.warn }
        return Theme.dim
    }

    private func signed(_ v: Double) -> String { String(format: "%+.0f%%", v) }

    var body: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() }
            } label: {
                summary
            }
            .buttonStyle(.plain)

            if expanded {
                VStack(alignment: .leading, spacing: 10) {
                    ActivityWindowChart(def: def, color: color, points: points,
                                        startedAt: startedAt, endedAt: endedAt, stats: stats)
                    Text(def.why)
                        .font(Theme.monoLabel)
                        .foregroundStyle(Theme.dim)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.leading, 8)
                        .overlay(alignment: .leading) {
                            Rectangle().fill(color.opacity(0.5)).frame(width: 2)
                        }
                }
                .padding(.top, 12)
            }
        }
        .cardStyle()
    }

    // MARK: Summary (always visible)

    private var summary: some View {
        VStack(spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(def.label).font(Theme.mono(14)).foregroundStyle(Theme.text)
                Text(def.techLabel).font(Theme.monoLabel).foregroundStyle(Theme.dim)
                Spacer()
                if let u = uplift {
                    Text(signed(u)).font(Theme.mono(13)).foregroundStyle(deltaColor(u))
                }
                Image(systemName: expanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.dim)
            }

            progressBar
        }
    }

    // MARK: before → during bar

    /// Position of the 2-month average along the before(0)→during(1) axis,
    /// by benefit so "toward during" reads correctly. nil when there's no
    /// 2-month value; 0.5 when before and during coincide.
    private func twoMonthFraction() -> Double? {
        guard let base = stats.baseline, let during = stats.duringMean,
              let m = twoMonthValue.map(def.direction.benefit) else { return nil }
        let a = def.direction.benefit(base)
        let b = def.direction.benefit(during)
        guard a != b else { return 0.5 }
        return min(max((m - a) / (b - a), 0.12), 0.88)
    }

    private var progressBar: some View {
        let tmFrac = twoMonthFraction()

        return GeometryReader { geo in
            let w = geo.size.width
            let leftX:  CGFloat = 9
            let rightX  = w - 9
            let barY:   CGFloat = 22

            ZStack {
                // before → during line, gray at the start deepening to the
                // improved/dipped colour at the end.
                Capsule()
                    .fill(LinearGradient(colors: [Theme.dim.opacity(0.55), deltaColor(uplift)],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(width: rightX - leftX, height: 6)
                    .position(x: (leftX + rightX) / 2, y: barY)

                // 2-month average: labelled gray tick between the two.
                if let f = tmFrac {
                    let x = leftX + CGFloat(f) * (rightX - leftX)
                    Rectangle().fill(Theme.dim)
                        .frame(width: 2, height: 15)
                        .position(x: x, y: barY)
                    VStack(spacing: 1) {
                        Text(def.format(twoMonthValue))
                            .foregroundStyle(Theme.text.opacity(0.9))
                        if let d = vs2mo {
                            Text(signed(d)).foregroundStyle(deltaColor(d))
                        }
                    }
                    .font(.system(size: 9, design: .monospaced))
                    .position(x: min(max(x, 22), w - 22), y: 6)
                }

                // Start point (before) at the beginning of the line.
                Circle().fill(Theme.dim)
                    .frame(width: 12, height: 12)
                    .position(x: leftX, y: barY)
                // End point (during) at the end of the line.
                Circle().fill(deltaColor(uplift))
                    .frame(width: 15, height: 15)
                    .position(x: rightX, y: barY)
            }
            .overlay(alignment: .bottomLeading) {
                Text(def.format(stats.baseline))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Theme.text.opacity(0.9))
            }
            .overlay(alignment: .bottomTrailing) {
                Text(def.format(stats.duringMean))
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Theme.text)
            }
        }
        .frame(height: 44)
    }
}
