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
            // Name + technical code, chevron.
            HStack(spacing: 6) {
                Text(def.label).font(Theme.mono(15)).foregroundStyle(Theme.text)
                Text(def.techLabel).font(Theme.monoLabel).foregroundStyle(Theme.dim)
                Spacer()
                Image(systemName: expanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.dim)
            }

            // Centred: uplift (during vs before) · vs-2-month delta.
            if uplift != nil || vs2mo != nil {
                HStack(spacing: 6) {
                    if let u = uplift {
                        Text(signed(u)).foregroundStyle(deltaColor(u))
                    }
                    if uplift != nil, vs2mo != nil {
                        Text("·").foregroundStyle(Theme.dim)
                    }
                    if let d = vs2mo {
                        Text("vs 2mo").foregroundStyle(Theme.dim)
                        Text(signed(d)).foregroundStyle(deltaColor(d))
                    }
                }
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .frame(maxWidth: .infinity)
            }

            barWithLabels
        }
    }

    // MARK: before → during bar, with each value under its marker

    private var barWithLabels: some View {
        let before = def.benefitPosition(of: stats.baseline,   across: [stats.duringMean, twoMonthValue])
        let during = def.benefitPosition(of: stats.duringMean, across: [stats.baseline,   twoMonthValue])
        let tick   = def.benefitPosition(of: twoMonthValue,    across: [stats.baseline,   stats.duringMean])

        return GeometryReader { geo in
            let w = geo.size.width
            let barY:   CGFloat = 9
            let labelY: CGFloat = 30
            let clampX: (Double) -> CGFloat = { min(max(CGFloat($0) * w, 18), w - 18) }

            ZStack {
                Capsule().fill(Theme.surface)
                    .frame(height: 4).position(x: w / 2, y: barY)

                // Change segment between before and during.
                if let b = before, let d = during {
                    let lo = min(b, d), hi = max(b, d)
                    Capsule().fill(deltaColor(uplift))
                        .frame(width: max(CGFloat(hi - lo) * w, 3), height: 4)
                        .position(x: CGFloat((lo + hi) / 2) * w, y: barY)
                }

                // 2-month tick.
                if let t = tick {
                    Rectangle().fill(Theme.text.opacity(0.85))
                        .frame(width: 2, height: 13)
                        .position(x: CGFloat(t) * w, y: barY)
                }

                // Before (hollow) dot.
                if let b = before {
                    Circle().fill(Theme.card)
                        .overlay(Circle().strokeBorder(Theme.dim, lineWidth: 2))
                        .frame(width: 12, height: 12)
                        .position(x: CGFloat(b) * w, y: barY)
                }
                // During (filled) dot with a soft glow.
                if let d = during {
                    let c = deltaColor(uplift)
                    Circle().fill(c.opacity(0.25)).frame(width: 22, height: 22)
                        .position(x: CGFloat(d) * w, y: barY)
                    Circle().fill(c).frame(width: 14, height: 14)
                        .position(x: CGFloat(d) * w, y: barY)
                }

                // Values under each marker.
                if let b = before {
                    Text(def.format(stats.baseline))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Theme.dim)
                        .position(x: clampX(b), y: labelY)
                }
                if let t = tick {
                    Text(def.format(twoMonthValue))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Theme.dim)
                        .position(x: clampX(t), y: labelY)
                }
                if let d = during {
                    Text(def.format(stats.duringMean))
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Theme.text)
                        .position(x: clampX(d), y: labelY)
                }
            }
        }
        .frame(height: 40)
    }
}
