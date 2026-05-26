import SwiftUI

struct ResonateView: View {
    @Environment(AppEnvironment.self) var env

    @State private var targetBPM:  Float = 6.0
    @State private var iePreset:   Int   = 0   // index into presets
    @State private var phase: PacerCircleView.BreathPhase = .idle

    private let bpmRange:  ClosedRange<Float> = 4.5...7.5
    private let presets = [
        ("4:6", Float(0.40)),
        ("5:5", Float(0.50)),
        ("4:7", Float(0.364)),
        ("3:7", Float(0.30)),
    ]

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()

            VStack(spacing: 24) {

                // ── Pacer circle ──────────────────────────────────
                PacerCircleView(
                    bpm:     targetBPM,
                    ieRatio: presets[iePreset].1,
                    phase:   phase
                )
                .padding(.top, 20)

                // ── BPM Slider ────────────────────────────────────
                VStack(spacing: 6) {
                    HStack {
                        Text("PACE")
                            .font(Theme.monoLabel)
                            .foregroundStyle(Theme.dim)
                        Spacer()
                        Text(String(format: "%.1f br/min", targetBPM))
                            .font(Theme.monoBody)
                            .foregroundStyle(Theme.accent)
                    }
                    Slider(value: $targetBPM, in: bpmRange, step: 0.5)
                        .tint(Theme.accent)
                }
                .cardStyle()
                .padding(.horizontal)

                // ── I:E Ratio Picker ──────────────────────────────
                VStack(spacing: 6) {
                    Text("INHALE : EXHALE")
                        .font(Theme.monoLabel)
                        .foregroundStyle(Theme.dim)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    HStack(spacing: 8) {
                        ForEach(presets.indices, id: \.self) { i in
                            Button(presets[i].0) {
                                iePreset = i
                            }
                            .font(Theme.monoBody)
                            .foregroundStyle(i == iePreset ? Theme.bg : Theme.accent)
                            .padding(.vertical, 6)
                            .padding(.horizontal, 10)
                            .background(i == iePreset ? Theme.accent : Theme.card)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                    }
                }
                .cardStyle()
                .padding(.horizontal)

                // ── Live coherence feedback ───────────────────────
                if let tick = env.latestTick {
                    ResonanceFeedbackCard(tick: tick, targetBPM: targetBPM)
                        .padding(.horizontal)
                }

                Spacer()
            }
        }
    }
}

// MARK: - Coherence feedback card

private struct ResonanceFeedbackCard: View {
    let tick:      MetricsTick
    let targetBPM: Float

    private var isNearTarget: Bool {
        guard let hz = tick.breathHz else { return false }
        let targetHz = targetBPM / 60
        return abs(hz - targetHz) < 0.05
    }

    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("COHERENCE")
                    .font(Theme.monoLabel)
                    .foregroundStyle(Theme.dim)
                Text(MetricFormat.score(tick.coherenceScore))
                    .font(Theme.mono(24))
                    .foregroundStyle(coherenceColor)
            }
            Divider().background(Theme.border)
            VStack(alignment: .leading, spacing: 4) {
                Text("BREATH")
                    .font(Theme.monoLabel)
                    .foregroundStyle(Theme.dim)
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(MetricFormat.bpm(tick.breathBPM))
                        .font(Theme.mono(24))
                        .foregroundStyle(isNearTarget ? Theme.accent : Theme.text)
                    Text("br/min")
                        .font(Theme.monoLabel)
                        .foregroundStyle(Theme.dim)
                }
            }
            Divider().background(Theme.border)
            VStack(alignment: .leading, spacing: 4) {
                Text("RSA")
                    .font(Theme.monoLabel)
                    .foregroundStyle(Theme.dim)
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(MetricFormat.ms(tick.rsaMs))
                        .font(Theme.mono(24))
                        .foregroundStyle(Theme.rsa)
                    Text("ms")
                        .font(Theme.monoLabel)
                        .foregroundStyle(Theme.dim)
                }
            }
        }
        .cardStyle()
    }

    private var coherenceColor: Color {
        guard let c = tick.coherenceScore else { return Theme.text }
        if c >= 0.7 { return Theme.accent }
        if c >= 0.4 { return Theme.warn }
        return Theme.warn.opacity(0.6)
    }
}
