import SwiftUI

/// Scrolling ACC Z-axis (breathing) strip at 60 fps.
/// Uses the same WaveformRenderer as ECG but with breathing-blue colour and no QRS bloom.
struct ACCWaveformView: View {
    let buffer: [Float]

    private static let cfg = WaveformRenderer.Config(
        color:       Theme.breathe,
        lineWidth:   1.2,
        glowPasses:  [(6, 0.05), (3, 0.14), (1.2, 1.0)],
        bloomRadius: 0,
        bloomOpacity: 0
    )

    var body: some View {
        ZStack(alignment: .topLeading) {
            if buffer.isEmpty {
                HStack {
                    Spacer()
                    Text("Waiting for ACC…")
                        .font(Theme.monoLabel)
                        .foregroundStyle(Theme.dim)
                    Spacer()
                }
            } else {
                TimelineView(.periodic(from: .now, by: 1.0 / 60.0)) { _ in
                    Canvas { ctx, size in
                        WaveformRenderer.draw(in: &ctx, size: size,
                                              samples: buffer,
                                              config: ACCWaveformView.cfg)
                    }
                }
                .drawingGroup()
            }

            Text("ACC Z — BREATHING")
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
}
