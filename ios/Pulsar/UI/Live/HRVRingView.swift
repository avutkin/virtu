import SwiftUI

/// Animated arc ring showing a single metric as a fraction of its reference range.
struct HRVRingView: View {
    let label:    String
    let value:    String   // formatted display string
    let unit:     String
    let fraction: Double   // 0–1 fill level
    let color:    Color
    var size:     CGFloat = Theme.ringSize

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                // Track
                Circle()
                    .stroke(color.opacity(0.12), lineWidth: 5)

                // Fill arc
                Circle()
                    .trim(from: 0, to: fraction)
                    .stroke(color, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.spring(duration: 0.6), value: fraction)

                VStack(spacing: 0) {
                    Text(value)
                        .font(Theme.monoBody)
                        .foregroundStyle(Theme.text)
                    Text(unit)
                        .font(Theme.monoLabel)
                        .foregroundStyle(Theme.dim)
                }
            }
            .frame(width: size, height: size)

            Text(label)
                .font(Theme.monoLabel)
                .foregroundStyle(Theme.dim)
        }
    }
}

// MARK: - 4×2 Ring Grid (Oura-style, 8 metrics)

struct HRVRingGrid: View {
    let tick: MetricsTick?

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 4)

    var body: some View {
        LazyVGrid(columns: columns, spacing: 10) {
            // ── Row 1 ──────────────────────────────────────────────
            HRVRingView(
                label: "HR",
                value: MetricFormat.bpm(tick?.meanBPM),
                unit: "bpm",
                fraction: hrFraction,
                color: Theme.warn,
                size: 60
            )
            HRVRingView(
                label: "SDNN",
                value: MetricFormat.ms(tick?.sdnn),
                unit: "ms",
                fraction: clamp((tick?.sdnn ?? 0) / 130),
                color: Theme.hrv,
                size: 60
            )
            HRVRingView(
                label: "VTI",
                value: MetricFormat.ratio(tick?.vti),
                unit: "",
                fraction: clamp(((tick?.vti ?? 2) - 2) / 3),
                color: Theme.breathe,
                size: 60
            )
            HRVRingView(
                label: "RSA",
                value: MetricFormat.ms(tick?.rsaMs),
                unit: "ms",
                fraction: clamp((tick?.rsaMs ?? 0) / 90),
                color: Theme.rsa,
                size: 60
            )
            // ── Row 2 ──────────────────────────────────────────────
            HRVRingView(
                label: "COHER",
                value: MetricFormat.score(tick?.coherenceScore),
                unit: "",
                fraction: Double(tick?.coherenceScore ?? 0),
                color: Theme.coh,
                size: 60
            )
            HRVRingView(
                label: "LF/HF",
                value: MetricFormat.ratio(tick?.lfHF),
                unit: "",
                fraction: clamp((tick?.lfHF ?? 0) / 4),
                color: Theme.breathe,
                size: 60
            )
            HRVRingView(
                label: "PNN50",
                value: MetricFormat.percent(tick?.pnn50),
                unit: "",
                fraction: clamp((tick?.pnn50 ?? 0) / 40),
                color: Theme.hrv,
                size: 60
            )
            HRVRingView(
                label: "ULF",
                value: tick?.ulfPower.map { String(format: "%.0f", $0) } ?? "—",
                unit: "ms²",
                fraction: clamp((tick?.ulfPower ?? 0) / 500),
                color: Theme.ulf,
                size: 60
            )
        }
    }

    // HR is inverted: lower resting HR fills more of the ring.
    private var hrFraction: Double {
        guard let bpm = tick?.meanBPM else { return 0 }
        return clamp((160 - bpm) / (160 - 35))
    }

    private func clamp(_ v: Float) -> Double { Double(min(max(v, 0), 1)) }
}
