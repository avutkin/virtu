import SwiftUI

/// Beat-to-beat RR interval tachogram — Canvas, last 60 beats.
struct RRTachogramView: View {
    /// RR intervals in ms, FIFO order from DataBuffer.
    let rr: [Float]

    var body: some View {
        ZStack(alignment: .topLeading) {
            if rr.count < 3 {
                HStack {
                    Spacer()
                    Text("Waiting for RR intervals…")
                        .font(Theme.monoLabel)
                        .foregroundStyle(Theme.dim)
                    Spacer()
                }
            } else {
                Canvas { ctx, size in
                    Self.draw(&ctx, size: size, rr: rr)
                }
            }

            Text("RR TACHOGRAM")
                .font(Theme.monoLabel)
                .foregroundStyle(Theme.dim.opacity(0.7))
                .padding(.horizontal, 8)
                .padding(.top, 4)
        }
        .frame(height: 80)
        .background(Theme.card)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8)
            .strokeBorder(Theme.border, lineWidth: 0.5))
    }

    // MARK: - Canvas Drawing

    private static let rrLo: Float = 350
    private static let rrHi: Float = 1500

    private static func draw(_ ctx: inout GraphicsContext, size: CGSize, rr: [Float]) {
        let recent = Array(rr.suffix(60))
        let n = recent.count
        guard n > 1 else { return }

        func pt(_ i: Int) -> CGPoint {
            let x = CGFloat(i) / CGFloat(n - 1) * size.width
            let v = min(max(recent[i], rrLo), rrHi)
            let norm = CGFloat((v - rrLo) / (rrHi - rrLo))
            // inverted: low RR (high HR) → top
            let y = (1 - norm) * size.height * 0.82 + size.height * 0.09
            return CGPoint(x: x, y: y)
        }

        // Build path
        var path = Path()
        path.move(to: pt(0))
        for i in 1..<n { path.addLine(to: pt(i)) }

        // Glow + line
        ctx.stroke(path, with: .color(Theme.hrv.opacity(0.25)), lineWidth: 5)
        ctx.stroke(path, with: .color(Theme.hrv.opacity(0.7)), lineWidth: 1.0)

        // Beat dots
        for i in 0..<n {
            let p = pt(i)
            let r: CGFloat = i == n - 1 ? 3.5 : 2.0   // latest beat is slightly larger
            let c: GraphicsContext.Shading = i == n - 1
                ? .color(Theme.hrv)
                : .color(Theme.hrv.opacity(0.55))
            ctx.fill(
                Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)),
                with: c
            )
        }

        // Horizontal guide lines at 600 ms (100 bpm) and 1000 ms (60 bpm)
        let guides: [(ms: Float, label: String)] = [(600, "100 bpm"), (1000, "60 bpm")]
        for (msRef, label) in guides {
            let norm = CGFloat((msRef - rrLo) / (rrHi - rrLo))
            let y = (1 - norm) * size.height * 0.82 + size.height * 0.09
            var guide = Path()
            guide.move(to: CGPoint(x: 0, y: y))
            guide.addLine(to: CGPoint(x: size.width, y: y))
            ctx.stroke(guide, with: .color(Theme.dim.opacity(0.25)),
                       style: StrokeStyle(lineWidth: 0.5, dash: [4, 4]))

            // BPM label at right edge
            let labelText = Text(label)
                .font(.system(size: 8, design: .monospaced))
                .foregroundColor(Theme.dim.opacity(0.45))
            ctx.draw(labelText,
                     in: CGRect(x: size.width - 46, y: y - 10, width: 44, height: 10))
        }
    }
}
