import SwiftUI

/// Animated breathing pacer circle — mirrors `rf-pacer-anim.js` behaviour.
/// Expands on inhale, contracts on exhale, with glow pulse at peak.
struct PacerCircleView: View {
    let bpm:      Float   // target breathing rate (4.5–7.5)
    let ieRatio:  Float   // inhale fraction, e.g. 0.40 for 4:6
    let phase:    BreathPhase

    enum BreathPhase { case inhale, exhale, idle }

    @State private var scale:   CGFloat = 0.55
    @State private var glowR:   CGFloat = 0
    @State private var glowO:   Double  = 0
    @State private var phaseLabel: String = "BREATHE"

    private let minScale: CGFloat = 0.50
    private let maxScale: CGFloat = 1.0

    private var cycleDuration: Double {
        guard bpm > 0 else { return 10 }
        return 60.0 / Double(bpm)
    }
    private var inhaleDuration:  Double { cycleDuration * Double(ieRatio) }
    private var exhaleDuration:  Double { cycleDuration * Double(1 - ieRatio) }

    var body: some View {
        ZStack {
            // Outer glow ring
            Circle()
                .fill(Theme.accent.opacity(glowO * 0.12))
                .frame(width: 220, height: 220)
                .scaleEffect(1 + glowR * 0.3)

            // Mid halo
            Circle()
                .fill(Theme.accent.opacity(glowO * 0.06))
                .frame(width: 200, height: 200)

            // Main breathing circle
            Circle()
                .fill(
                    RadialGradient(
                        colors: [Theme.accent.opacity(0.25), Theme.accent.opacity(0.05)],
                        center: .center,
                        startRadius: 0,
                        endRadius: 100
                    )
                )
                .frame(width: 190, height: 190)
                .scaleEffect(scale)
                .animation(.easeInOut(duration: inhaleDuration), value: scale)

            // Stroke ring
            Circle()
                .stroke(Theme.accent.opacity(0.5), lineWidth: 1.5)
                .frame(width: 190, height: 190)
                .scaleEffect(scale)
                .animation(.easeInOut(duration: inhaleDuration), value: scale)

            // Phase label
            Text(phaseLabel)
                .font(Theme.display(18))
                .foregroundStyle(Theme.accent)
                .tracking(4)
        }
        .onAppear { startCycle() }
        .onChange(of: bpm) { startCycle() }
    }

    private func startCycle() {
        runInhale()
    }

    private func runInhale() {
        phaseLabel = "INHALE"
        withAnimation(.easeIn(duration: inhaleDuration)) {
            scale  = maxScale
            glowR  = 1
            glowO  = 1
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + inhaleDuration) {
            runExhale()
        }
    }

    private func runExhale() {
        phaseLabel = "EXHALE"
        withAnimation(.easeOut(duration: exhaleDuration)) {
            scale  = minScale
            glowR  = 0
            glowO  = 0
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + exhaleDuration) {
            runInhale()
        }
    }
}
