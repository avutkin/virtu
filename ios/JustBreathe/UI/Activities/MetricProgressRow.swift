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
        VStack(spacing: 9) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(def.label).font(Theme.mono(14)).foregroundStyle(Theme.text)
                Text(def.techLabel).font(Theme.monoLabel).foregroundStyle(Theme.dim)
                Spacer()
                Text(def.format(stats.duringMean)).font(Theme.mono(14)).foregroundStyle(Theme.text)
                if let u = uplift {
                    Text(signed(u)).font(Theme.mono(12)).foregroundStyle(deltaColor(u))
                }
                Image(systemName: expanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.dim)
            }

            progressBar

            HStack(spacing: 6) {
                Text("before \(def.format(stats.baseline))")
                    .font(Theme.monoLabel).foregroundStyle(Theme.dim)
                Spacer()
                if let tm = twoMonthValue {
                    Text("2mo \(def.format(tm))")
                        .font(Theme.monoLabel).foregroundStyle(Theme.dim)
                }
                if let d = vs2mo {
                    Text("· \(signed(d)) vs 2mo")
                        .font(Theme.monoLabel).foregroundStyle(deltaColor(d))
                }
            }
        }
    }

    // MARK: before → during bar

    private var progressBar: some View {
        let before = def.benefitPosition(of: stats.baseline,   across: [stats.duringMean, twoMonthValue])
        let during = def.benefitPosition(of: stats.duringMean, across: [stats.baseline,   twoMonthValue])
        let tick   = def.benefitPosition(of: twoMonthValue,    across: [stats.baseline,   stats.duringMean])

        return GeometryReader { geo in
            let w = geo.size.width
            let h: CGFloat = 8
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.surface).frame(height: h)

                // Change segment between before and during.
                if let b = before, let d = during {
                    let lo = min(b, d), hi = max(b, d)
                    Capsule()
                        .fill(deltaColor(uplift).opacity(0.55))
                        .frame(width: max((hi - lo) * w, 2), height: h)
                        .offset(x: lo * w)
                }

                // 2-month tick.
                if let t = tick {
                    Rectangle()
                        .fill(Theme.dim)
                        .frame(width: 2, height: h + 8)
                        .offset(x: t * w - 1)
                }

                // Before (hollow) and during (filled) dots.
                if let b = before {
                    Circle().strokeBorder(Theme.dim, lineWidth: 2)
                        .background(Circle().fill(Theme.card))
                        .frame(width: 11, height: 11)
                        .offset(x: b * w - 5.5)
                }
                if let d = during {
                    Circle().fill(deltaColor(uplift))
                        .frame(width: 12, height: 12)
                        .offset(x: d * w - 6)
                }
            }
            .frame(height: h + 8)
        }
        .frame(height: 16)
    }
}
