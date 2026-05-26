import SwiftUI

// MARK: - HRVAnalysisView

struct HRVAnalysisView: View {
    let tick: MetricsTick?

    var body: some View {
        VStack(spacing: 10) {
            powerSpectrumCard
            if let t = tick, t.coherenceFreqs != nil {
                coherenceCard(t)
            }
        }
    }

    private var powerSpectrumCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("HRV POWER SPECTRUM")
                    .font(Theme.monoBody).foregroundStyle(Theme.text)
                Spacer()
                legendDot("VLF", Theme.dim)
                legendDot("LF",  Theme.hrv)
                legendDot("HF",  Theme.accent)
            }
            if let freqs = tick?.psdFreqs,
               let powers = tick?.psdValues,
               freqs.count > 3 {
                PSDCanvas(pts: zip(freqs, powers)
                    .filter { $0.0 <= 0.5 }
                    .map { PSDCanvas.Pt(f: Double($0.0), p: Double($0.1)) })
            } else {
                noData("Need 30+ RR intervals")
            }
        }
        .cardChartStyle()
    }

    private func coherenceCard(_ t: MetricsTick) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("RR–BREATHING COHERENCE")
                    .font(Theme.monoBody).foregroundStyle(Theme.text)
                Spacer()
                if let score = t.coherenceScore {
                    let col: Color = score > 0.6 ? Theme.coh : score > 0.3 ? Theme.rsa : Theme.warn
                    Text(String(format: "score %.2f", score))
                        .font(Theme.monoLabel).foregroundStyle(col)
                }
            }
            if let freqs = t.coherenceFreqs,
               let coh = t.coherenceValues,
               freqs.count > 3 {
                CohCanvas(pts: zip(freqs, coh)
                    .filter { $0.0 >= 0.04 && $0.0 <= 0.5 }
                    .map { CohCanvas.Pt(f: Double($0.0), c: Double($0.1)) })
            } else {
                noData("Collecting coherence data…")
            }
        }
        .cardChartStyle()
    }

    private func legendDot(_ label: String, _ color: Color) -> some View {
        HStack(spacing: 3) {
            RoundedRectangle(cornerRadius: 2).fill(color.opacity(0.7)).frame(width: 10, height: 10)
            Text(label).font(Theme.monoLabel).foregroundStyle(Theme.dim)
        }
    }

    private func noData(_ msg: String) -> some View {
        HStack {
            Spacer()
            Text(msg).font(Theme.monoLabel).foregroundStyle(Theme.dim)
            Spacer()
        }
        .frame(height: 90)
    }
}

// MARK: - PSD Canvas

private struct PSDCanvas: View {
    struct Pt { let f: Double; let p: Double }
    let pts: [Pt]

    var body: some View {
        Canvas { ctx, size in
            let axisH: CGFloat = 14          // bottom strip for Hz labels
            let plotH  = size.height - axisH
            let plotW  = size.width

            guard pts.count > 1, plotH > 4, plotW > 4 else { return }

            let yTop = (pts.map(\.p).max() ?? 1.0) * 1.2
            guard yTop > 0 else { return }

            func tx(_ f: Double) -> CGFloat { CGFloat(f / 0.5) * plotW }
            func ty(_ p: Double) -> CGFloat { plotH - CGFloat(p / yTop) * plotH }

            // Plot background
            ctx.fill(Path(CGRect(x: 0, y: 0, width: plotW, height: plotH)),
                     with: .color(.black.opacity(0.25)))

            // Band backgrounds
            let bands: [(Double, Double, Color)] = [
                (0.0,  0.04, Theme.dim),
                (0.04, 0.15, Theme.hrv),
                (0.15, 0.5,  Theme.accent),
            ]
            for (lo, hi, col) in bands {
                ctx.fill(
                    Path(CGRect(x: tx(lo), y: 0, width: tx(hi) - tx(lo), height: plotH)),
                    with: .color(col.opacity(0.08))
                )
            }

            // Vertical guides at band edges
            for xf in [0.04, 0.15, 0.40] {
                var p = Path()
                p.move(to: CGPoint(x: tx(xf), y: 0))
                p.addLine(to: CGPoint(x: tx(xf), y: plotH))
                ctx.stroke(p, with: .color(.white.opacity(0.12)), lineWidth: 0.5)
            }

            // Area fill
            var area = Path()
            area.move(to: CGPoint(x: tx(pts[0].f), y: plotH))
            for pt in pts { area.addLine(to: CGPoint(x: tx(pt.f), y: ty(pt.p))) }
            area.addLine(to: CGPoint(x: tx(pts.last!.f), y: plotH))
            area.closeSubpath()
            ctx.fill(area, with: .color(.white.opacity(0.12)))

            // Curve
            var line = Path()
            line.move(to: CGPoint(x: tx(pts[0].f), y: ty(pts[0].p)))
            for pt in pts.dropFirst() { line.addLine(to: CGPoint(x: tx(pt.f), y: ty(pt.p))) }
            ctx.stroke(line, with: .color(.white.opacity(0.9)), lineWidth: 1.5)

            // X-axis labels
            let xLabels: [(Double, String)] = [
                (0.0, "0"), (0.04, ".04"), (0.15, ".15"), (0.40, ".40"), (0.5, ".5")
            ]
            for (f, label) in xLabels {
                ctx.draw(
                    Text(label).font(.system(size: 8, design: .monospaced)).foregroundStyle(Theme.dim),
                    at: CGPoint(x: tx(f), y: plotH + axisH / 2),
                    anchor: .center
                )
            }

            // Band labels (top)
            let bandLabels: [(Double, Double, String, Color)] = [
                (0.0,  0.04, "VLF", Theme.dim),
                (0.04, 0.15, "LF",  Theme.hrv),
                (0.15, 0.5,  "HF",  Theme.accent),
            ]
            for (lo, hi, label, col) in bandLabels {
                ctx.draw(
                    Text(label).font(.system(size: 8, design: .monospaced)).foregroundStyle(col.opacity(0.8)),
                    at: CGPoint(x: (tx(lo) + tx(hi)) / 2, y: 8),
                    anchor: .center
                )
            }
        }
        .frame(maxWidth: .infinity, minHeight: 130, maxHeight: 130)
    }
}

// MARK: - Coherence Canvas

private struct CohCanvas: View {
    struct Pt { let f: Double; let c: Double }
    let pts: [Pt]

    var body: some View {
        Canvas { ctx, size in
            let axisH: CGFloat = 14
            let plotH  = size.height - axisH
            let plotW  = size.width

            guard pts.count > 1, plotH > 4, plotW > 4 else { return }

            let fMin = 0.04, fMax = 0.5

            func tx(_ f: Double) -> CGFloat { CGFloat((f - fMin) / (fMax - fMin)) * plotW }
            func ty(_ c: Double) -> CGFloat { plotH - CGFloat(c) * plotH }

            // Plot background
            ctx.fill(Path(CGRect(x: 0, y: 0, width: plotW, height: plotH)),
                     with: .color(.black.opacity(0.25)))

            // Horizontal grid lines at 0.25, 0.5, 0.75
            for cv in [0.25, 0.5, 0.75] {
                var gp = Path()
                gp.move(to: CGPoint(x: 0, y: ty(cv)))
                gp.addLine(to: CGPoint(x: plotW, y: ty(cv)))
                ctx.stroke(gp, with: .color(.white.opacity(0.10)), lineWidth: 0.5)
            }

            // Area fill
            var area = Path()
            area.move(to: CGPoint(x: tx(pts[0].f), y: plotH))
            for pt in pts { area.addLine(to: CGPoint(x: tx(pt.f), y: ty(pt.c))) }
            area.addLine(to: CGPoint(x: tx(pts.last!.f), y: plotH))
            area.closeSubpath()
            ctx.fill(area, with: .color(Theme.coh.opacity(0.25)))

            // Coherence line
            var line = Path()
            line.move(to: CGPoint(x: tx(pts[0].f), y: ty(pts[0].c)))
            for pt in pts.dropFirst() { line.addLine(to: CGPoint(x: tx(pt.f), y: ty(pt.c))) }
            ctx.stroke(line, with: .color(Theme.coh), lineWidth: 1.5)

            // Threshold at 0.5 (dashed)
            var thresh = Path()
            thresh.move(to: CGPoint(x: 0, y: ty(0.5)))
            thresh.addLine(to: CGPoint(x: plotW, y: ty(0.5)))
            ctx.stroke(thresh,
                       with: .color(Theme.warn.opacity(0.5)),
                       style: StrokeStyle(lineWidth: 1, dash: [5, 3]))

            // Y-axis labels (right side)
            for (cv, label) in [(1.0, "1.0"), (0.5, "0.5"), (0.0, "0.0")] {
                ctx.draw(
                    Text(label).font(.system(size: 7, design: .monospaced)).foregroundStyle(Theme.dim),
                    at: CGPoint(x: plotW - 2, y: ty(cv)),
                    anchor: .trailing
                )
            }

            // X-axis labels
            for f in [0.04, 0.1, 0.2, 0.3, 0.4, 0.5] {
                ctx.draw(
                    Text(String(format: "%.2f", f))
                        .font(.system(size: 8, design: .monospaced))
                        .foregroundStyle(Theme.dim),
                    at: CGPoint(x: tx(f), y: plotH + axisH / 2),
                    anchor: .center
                )
            }
        }
        .frame(maxWidth: .infinity, minHeight: 110, maxHeight: 110)
    }
}

// MARK: - Card style

private extension View {
    func cardChartStyle() -> some View {
        self
            .padding(12)
            .background(Theme.card)
            .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cardRadius)
                    .strokeBorder(Theme.border, lineWidth: 0.5)
            )
    }
}
