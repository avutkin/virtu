import SwiftUI
import Charts

// MARK: - Biofeedback Views
//
// The autonomic / HR-recovery / RSA feedback cards and calibration bar, shown
// live inside a workout BiofeedbackSessionView. Extracted from the former
// TrainView (now replaced by the Practices hub).

// MARK: - Autonomic Card

struct AutonomicCard: View {
    let indices: AutonomicIndices?

    private var state: ANSState { indices?.state ?? .mixed }

    private var stateLabel: String {
        switch state {
        case .ventralVagal: return "VENTRAL VAGAL"
        case .sympathetic:  return "SYMPATHETIC"
        case .dorsalVagal:  return "DORSAL VAGAL"
        case .mixed:        return "TRANSITIONING"
        }
    }

    private var stateColor: Color {
        switch state {
        case .ventralVagal: return Theme.accent
        case .sympathetic:  return Theme.warn
        case .dorsalVagal:  return Theme.hrv
        case .mixed:        return Theme.rsa
        }
    }

    private var tipText: String {
        switch state {
        case .ventralVagal: return "Parasympathetic brake ON — good time to push"
        case .sympathetic:  return "Sympathetic dominant — complete your set"
        case .dorsalVagal:  return "HRV very low — consider stopping"
        case .mixed:        return "Autonomic transition — extend rest"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("AUTONOMIC BALANCE")
                .font(Theme.monoLabel)
                .foregroundStyle(Theme.dim)

            if indices == nil {
                Text("Waiting for HRV data…")
                    .font(Theme.monoLabel)
                    .foregroundStyle(Theme.dim.opacity(0.6))
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                HStack(spacing: 6) {
                    Circle()
                        .fill(stateColor)
                        .frame(width: 8, height: 8)
                    Text(stateLabel)
                        .font(Theme.mono(14))
                        .fontWeight(.medium)
                        .foregroundStyle(stateColor)
                }

                IndexBar(label: "SNS", value: indices?.sns, color: Theme.warn)
                IndexBar(label: "PNS", value: indices?.pns, color: Theme.accent)

                Text(tipText)
                    .font(Theme.monoLabel)
                    .foregroundStyle(Theme.breathe.opacity(0.8))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(Theme.cardPad)
        .background(Theme.card)
        .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius))
        .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius)
            .strokeBorder((indices == nil ? Theme.dim : stateColor).opacity(0.25), lineWidth: 0.5))
        .animation(.easeInOut(duration: 0.4), value: indices?.state)
    }
}

struct IndexBar: View {
    let label: String
    let value: Float?
    let color: Color

    var body: some View {
        HStack(spacing: 10) {
            Text(label)
                .font(Theme.monoLabel)
                .foregroundStyle(Theme.dim)
                .frame(width: 30, alignment: .leading)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Theme.border)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(color.opacity(0.7))
                        .frame(width: geo.size.width * CGFloat(min(1, max(0, value ?? 0))))
                }
            }
            .frame(height: 8)

            Text(value.map { String(format: "%.2f", $0) } ?? "—")
                .font(Theme.monoLabel)
                .foregroundStyle(Theme.text)
                .frame(width: 36, alignment: .trailing)
        }
    }
}

// MARK: - State Banner

struct StateBanner: View {
    let state: TrainState

    var label: String {
        switch state {
        case .calibrating: return "CALIBRATING"
        case .ready:       return "READY TO PUSH"
        case .active:      return "ACTIVE"
        case .recover:     return "RECOVERING"
        }
    }

    var color: Color {
        switch state {
        case .calibrating: return Theme.dim
        case .ready:       return Theme.accent
        case .active:      return Theme.warn
        case .recover:     return Theme.rsa
        }
    }

    var icon: String {
        switch state {
        case .calibrating: return "hourglass"
        case .ready:       return "checkmark.circle"
        case .active:      return "bolt"
        case .recover:     return "arrow.down.heart"
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
            Text(label)
                .font(Theme.mono(18))
                .fontWeight(.medium)
        }
        .foregroundStyle(color)
        .padding(.vertical, 14)
        .padding(.horizontal, 24)
        .background(color.opacity(0.12))
        .clipShape(Capsule())
        .overlay(Capsule().strokeBorder(color.opacity(0.4), lineWidth: 1))
        .animation(.easeInOut(duration: 0.3), value: state)
    }
}

// MARK: - HR Panel

struct HRPanel: View {
    let tick:     MetricsTick?
    let baseline: TrainBaseline?
    let history:  [MetricsTick]

    private var delta: Float? {
        guard let hr = tick?.meanBPM, let b = baseline else { return nil }
        return hr - b.hr
    }

    private var trendUp: Bool? {
        let recent = history.suffix(3).compactMap(\.meanBPM)
        guard recent.count >= 2 else { return nil }
        return recent.last! > recent.first!
    }

    var body: some View {
        VStack(spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "heart.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(Theme.warn)

                Text(tick?.meanBPM.map { "\(Int($0.rounded()))" } ?? "—")
                    .font(Theme.mono(52))
                    .foregroundStyle(Theme.text)

                Text("bpm")
                    .font(Theme.monoLabel)
                    .foregroundStyle(Theme.dim)
                    .padding(.bottom, 6)

                if let d = delta {
                    Text(d >= 0 ? "+\(Int(d.rounded()))" : "\(Int(d.rounded()))")
                        .font(Theme.monoBody)
                        .foregroundStyle(d > 20 ? Theme.warn : Theme.dim)
                        .padding(.bottom, 6)
                }

                if let up = trendUp {
                    Image(systemName: up ? "arrow.up" : "arrow.down")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(up ? Theme.warn : Theme.accent)
                        .padding(.bottom, 6)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .cardStyle()
    }
}

// MARK: - HR Recovery Chart

struct HRRecoveryChart: View {
    let history:  [MetricsTick]
    let baseline: TrainBaseline?
    let maxHR:    Float

    struct ChartPoint: Identifiable {
        let id    = UUID()
        let index: Int
        let hr:    Float
    }

    private var points: [ChartPoint] {
        history.enumerated().compactMap { i, tick in
            tick.meanBPM.map { ChartPoint(index: i, hr: $0) }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("HR RECOVERY  (5 MIN)")
                .font(Theme.monoLabel)
                .foregroundStyle(Theme.dim)

            Chart {
                // HR line
                ForEach(points) { p in
                    LineMark(
                        x: .value("Tick", p.index),
                        y: .value("HR", p.hr)
                    )
                    .foregroundStyle(hrColor(p.hr))
                    .interpolationMethod(.catmullRom)
                }

                // Area fill below line
                ForEach(points) { p in
                    AreaMark(
                        x: .value("Tick", p.index),
                        yStart: .value("Base", baseline?.hr ?? 0),
                        yEnd:   .value("HR", p.hr)
                    )
                    .foregroundStyle(
                        LinearGradient(
                            colors: [hrColor(p.hr).opacity(0.18), .clear],
                            startPoint: .top,
                            endPoint:   .bottom
                        )
                    )
                    .interpolationMethod(.catmullRom)
                }

                // Baseline rule
                if let b = baseline {
                    RuleMark(y: .value("Rest", b.hr))
                        .foregroundStyle(Theme.accent.opacity(0.5))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        .annotation(position: .trailing, alignment: .leading) {
                            Text("rest")
                                .font(Theme.monoLabel)
                                .foregroundStyle(Theme.accent.opacity(0.7))
                        }

                    // Ready threshold (+15)
                    RuleMark(y: .value("Ready", b.hr + 15))
                        .foregroundStyle(Theme.rsa.opacity(0.5))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        .annotation(position: .trailing, alignment: .leading) {
                            Text("ready")
                                .font(Theme.monoLabel)
                                .foregroundStyle(Theme.rsa.opacity(0.7))
                        }
                }

                // Max HR rule
                RuleMark(y: .value("Max", maxHR))
                    .foregroundStyle(Theme.warn.opacity(0.5))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .annotation(position: .trailing, alignment: .leading) {
                        Text("max")
                            .font(Theme.monoLabel)
                            .foregroundStyle(Theme.warn.opacity(0.7))
                    }
            }
            .chartXAxis(.hidden)
            .chartYAxis {
                AxisMarks(values: .automatic(desiredCount: 4)) { val in
                    AxisGridLine().foregroundStyle(Theme.border)
                    AxisValueLabel {
                        if let v = val.as(Double.self) {
                            Text("\(Int(v))")
                                .font(Theme.monoLabel)
                                .foregroundStyle(Theme.dim)
                        }
                    }
                }
            }
            .frame(height: 140)
        }
        .cardStyle()
    }

    private func hrColor(_ hr: Float) -> Color {
        guard let b = baseline else { return Theme.accent }
        let delta = hr - b.hr
        if delta <= 15  { return Theme.accent }
        if delta <= 30  { return Theme.rsa }
        return Theme.warn
    }
}

// MARK: - RSA Card

struct RSACard: View {
    let tick: MetricsTick?

    private var rsaDots: String {
        guard let rsa = tick?.rsaMs else { return "○○○○" }
        let filled = min(4, Int((rsa / 90.0) * 4))
        let empty  = 4 - filled
        return String(repeating: "●", count: filled) + String(repeating: "○", count: empty)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("RSA BIOFEEDBACK")
                .font(Theme.monoLabel)
                .foregroundStyle(Theme.dim)

            HStack(spacing: 0) {
                // RSA
                VStack(spacing: 4) {
                    Text("RSA")
                        .font(Theme.monoLabel)
                        .foregroundStyle(Theme.dim)
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(rsaDots)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Theme.rsa)
                        Text(tick?.rsaMs.map { "\(Int($0.rounded()))" } ?? "—")
                            .font(Theme.monoBody)
                            .foregroundStyle(Theme.text)
                        Text("ms")
                            .font(Theme.monoLabel)
                            .foregroundStyle(Theme.dim)
                    }
                }
                .frame(maxWidth: .infinity)

                Divider().background(Theme.border)

                // Coherence
                VStack(spacing: 4) {
                    Text("COHER")
                        .font(Theme.monoLabel)
                        .foregroundStyle(Theme.dim)
                    Text(tick?.coherenceScore.map { String(format: "%.2f", $0) } ?? "—")
                        .font(Theme.monoBody)
                        .foregroundStyle(Theme.text)
                }
                .frame(maxWidth: .infinity)

                Divider().background(Theme.border)

                // Breathing
                VStack(spacing: 4) {
                    Text("BREATH")
                        .font(Theme.monoLabel)
                        .foregroundStyle(Theme.dim)
                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                        Text(tick?.breathBPM.map { String(format: "%.1f", $0) } ?? "—")
                            .font(Theme.monoBody)
                            .foregroundStyle(Theme.text)
                        Text("/min")
                            .font(Theme.monoLabel)
                            .foregroundStyle(Theme.dim)
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .frame(height: 52)

            Text("Breathe at 5–6 /min to maximize RSA recovery")
                .font(Theme.monoLabel)
                .foregroundStyle(Theme.breathe.opacity(0.8))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .cardStyle()
    }
}

// MARK: - RMSSD Chart

struct RMSSDChart: View {
    let history:  [MetricsTick]
    let baseline: TrainBaseline?

    struct ChartPoint: Identifiable {
        let id    = UUID()
        let index: Int
        let rmssd: Float
    }

    private var points: [ChartPoint] {
        history.enumerated().compactMap { i, tick in
            tick.rmssd.map { ChartPoint(index: i, rmssd: $0) }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("RMSSD  (5 MIN)")
                .font(Theme.monoLabel)
                .foregroundStyle(Theme.dim)

            Chart {
                ForEach(points) { p in
                    LineMark(
                        x: .value("Tick",  p.index),
                        y: .value("RMSSD", p.rmssd)
                    )
                    .foregroundStyle(Theme.hrv)
                    .interpolationMethod(.catmullRom)
                }

                ForEach(points) { p in
                    AreaMark(
                        x: .value("Tick",  p.index),
                        yStart: .value("Base", 0),
                        yEnd:   .value("RMSSD", p.rmssd)
                    )
                    .foregroundStyle(
                        LinearGradient(
                            colors: [Theme.hrv.opacity(0.15), .clear],
                            startPoint: .top,
                            endPoint:   .bottom
                        )
                    )
                    .interpolationMethod(.catmullRom)
                }

                if let rmssd = baseline?.rmssd {
                    RuleMark(y: .value("Rest RMSSD", rmssd))
                        .foregroundStyle(Theme.accent.opacity(0.5))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        .annotation(position: .trailing, alignment: .leading) {
                            Text("rest")
                                .font(Theme.monoLabel)
                                .foregroundStyle(Theme.accent.opacity(0.7))
                        }
                }
            }
            .chartXAxis(.hidden)
            .chartYAxis {
                AxisMarks(values: .automatic(desiredCount: 4)) { val in
                    AxisGridLine().foregroundStyle(Theme.border)
                    AxisValueLabel {
                        if let v = val.as(Double.self) {
                            Text("\(Int(v))")
                                .font(Theme.monoLabel)
                                .foregroundStyle(Theme.dim)
                        }
                    }
                }
            }
            .frame(height: 120)
        }
        .cardStyle()
    }
}

// MARK: - Calibration Bar

struct CalibrationBar: View {
    let baseline:        TrainBaseline?
    let isCollecting:    Bool
    let isSessionActive: Bool
    let onRecalibrate:   () -> Void
    let onStartSession:  () -> Void
    let onEndSession:    () -> Void

    @State private var dotCount = 1

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                if isCollecting {
                    HStack(spacing: 4) {
                        Text("CALIBRATING")
                            .font(Theme.monoLabel)
                            .foregroundStyle(Theme.dim)
                        Text(String(repeating: "●", count: dotCount) +
                             String(repeating: "○", count: 3 - dotCount))
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(Theme.dim)
                            .animation(.easeInOut(duration: 0.4), value: dotCount)
                    }
                    Text("Collecting 30 s resting baseline…")
                        .font(Theme.monoLabel)
                        .foregroundStyle(Theme.dim.opacity(0.6))
                } else if let b = baseline {
                    Text("BASELINE")
                        .font(Theme.monoLabel)
                        .foregroundStyle(Theme.dim)
                    HStack(spacing: 8) {
                        Text("\(Int(b.hr.rounded())) bpm")
                            .font(Theme.monoBody)
                            .foregroundStyle(Theme.text)
                        if let rmssd = b.rmssd {
                            Text("·")
                                .foregroundStyle(Theme.dim)
                            Text("\(Int(rmssd.rounded())) ms RMSSD")
                                .font(Theme.monoBody)
                                .foregroundStyle(Theme.text)
                        }
                    }
                }
            }

            Spacer()

            if !isCollecting {
                Button("RECALIBRATE", action: onRecalibrate)
                    .font(Theme.monoLabel)
                    .foregroundStyle(Theme.accent)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Theme.accent.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(Theme.accent.opacity(0.3), lineWidth: 0.5)
                    )

                if isSessionActive {
                    Button("END TRAINING", action: onEndSession)
                        .font(Theme.monoLabel)
                        .foregroundStyle(Theme.warn)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Theme.warn.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(Theme.warn.opacity(0.3), lineWidth: 0.5))
                } else {
                    Button("START TRAINING", action: onStartSession)
                        .font(Theme.monoLabel)
                        .foregroundStyle(Theme.accent)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Theme.accent.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(Theme.accent.opacity(0.3), lineWidth: 0.5))
                        .disabled(baseline == nil)
                }
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 14)
        .background(Theme.card)
        .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cardRadius)
                .strokeBorder(Theme.border, lineWidth: 0.5)
        )
        .onAppear { startDotAnimation() }
    }

    private func startDotAnimation() {
        guard isCollecting else { return }
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { t in
            if !isCollecting { t.invalidate(); return }
            dotCount = (dotCount % 3) + 1
        }
    }
}
