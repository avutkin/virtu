import SwiftUI

/// The big "overall practice impact" arc gauge (0–100), styled after a health
/// score dial: a 240° track with a segmented green fill and a check-knob at the
/// fill end, the score in the centre. Built from trimmed, rotated circles so
/// the geometry is exact (gap centred at the bottom, fill grows from the
/// lower-left up over the top).
struct PracticeImpactGauge: View {
    let score: Int          // 0–100
    let caption: String

    private let lineWidth: CGFloat = 14
    private let arcFraction: CGFloat = 240.0 / 360.0   // 240° of the circle
    private let rotation = Angle.degrees(150)          // gap centred at bottom

    private var scoreFrac: CGFloat { CGFloat(min(max(score, 0), 100)) / 100 }
    private var fillTrim:  CGFloat { arcFraction * scoreFrac }

    var body: some View {
        ZStack {
            Circle()
                .trim(from: 0, to: arcFraction)
                .stroke(Theme.surface, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(rotation)

            Circle()
                .trim(from: 0, to: fillTrim)
                .stroke(
                    LinearGradient(colors: [Color(hex: "#8BE86B"), Theme.accent, Color(hex: "#2FCF9A")],
                                   startPoint: .bottomLeading, endPoint: .topTrailing),
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .butt, dash: [3.4, 3.4])
                )
                .rotationEffect(rotation)

            // Check-knob at the fill end, placed on the same arc.
            if score > 0 {
                GeometryReader { geo in
                    let r = min(geo.size.width, geo.size.height) / 2 - lineWidth / 2
                    let c = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
                    let theta = (150.0 + 240.0 * Double(scoreFrac)) * .pi / 180
                    let p = CGPoint(x: c.x + r * CGFloat(cos(theta)),
                                    y: c.y + r * CGFloat(sin(theta)))
                    Circle()
                        .fill(Theme.bg)
                        .overlay(Circle().strokeBorder(Theme.accent, lineWidth: 2))
                        .overlay(Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(Theme.accent))
                        .frame(width: 24, height: 24)
                        .position(p)
                }
            }

            VStack(spacing: 2) {
                Text("\(score)%")
                    .font(.system(size: 42, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.text)
                    .monospacedDigit()
                Text(caption)
                    .font(Theme.monoLabel)
                    .foregroundStyle(Theme.dim)
            }
        }
        .frame(height: 168)
    }
}
