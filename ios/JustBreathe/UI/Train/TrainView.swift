import SwiftUI
import Charts

// MARK: - Train State

enum TrainState: Equatable {
    case calibrating
    case ready
    case active
    case recover
}

// MARK: - Train Baseline

struct TrainBaseline {
    let hr:        Float
    let rmssd:     Float?
    let timestamp: Date
}

// MARK: - Polyvagal State

enum PolyvagalState: Equatable {
    case ventralVagal   // parasympathetic brake ON — HFnu ≥ 0.55
    case sympathetic    // SNS dominant — LFnu ≥ 0.65
    case dorsalVagal    // very low HRV + HR not elevated — shutdown warning
    case mixed          // transitioning
}

struct AutonomicIndices: Equatable {
    let sns:   Float           // LFnu 0–1
    let pns:   Float           // HFnu 0–1
    let state: PolyvagalState
}

// MARK: - Autonomic Compute

enum AutonomicCompute {
    /// Derives LFnu/HFnu balance from MetricsTick.
    /// Falls back to RMSSD-relative-to-baseline when freq-domain is absent.
    static func compute(tick: MetricsTick, baseline: TrainBaseline?) -> AutonomicIndices? {
        // Preferred: frequency-domain normalized units
        if let lf = tick.lfPower, let hf = tick.hfPower, (lf + hf) > 0 {
            let total = lf + hf
            let pns   = hf / total
            let sns   = lf / total
            return AutonomicIndices(sns: sns, pns: pns, state: classify(pns: pns, sns: sns, tick: tick, baseline: baseline))
        }
        // Fallback: RMSSD vs baseline
        if let rmssd = tick.rmssd, let b = baseline, let bRmssd = b.rmssd, bRmssd > 0 {
            let pns = min(1, rmssd / bRmssd)
            let sns = 1 - pns
            return AutonomicIndices(sns: sns, pns: pns, state: classify(pns: pns, sns: sns, tick: tick, baseline: baseline))
        }
        return nil
    }

    /// Precondition: `pns + sns == 1.0` (both call sites guarantee this).
    private static func classify(pns: Float, sns: Float, tick: MetricsTick, baseline: TrainBaseline?) -> PolyvagalState {
        if pns >= 0.55 { return .ventralVagal }
        if sns >= 0.65 { return .sympathetic }
        if let rmssd = tick.rmssd, rmssd < 10,
           let hr = tick.meanBPM, let b = baseline, hr <= b.hr + 20 {
            return .dorsalVagal
        }
        return .mixed
    }
}

// MARK: - Train View

struct TrainView: View {
    @Environment(AppEnvironment.self) var env

    @State private var trainHistory:    [MetricsTick]    = []
    @State private var baseline:        TrainBaseline?   = nil
    @State private var trainState:      TrainState       = .calibrating
    @State private var showBLESheet                      = false
    @State private var autonomicIndices: AutonomicIndices? = nil

    @AppStorage("train.maxHR") private var maxHR: Double = 160

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {

                    StateBanner(state: trainState)

                    HRPanel(
                        tick:     env.latestTick,
                        baseline: baseline,
                        history:  trainHistory
                    )

                    AutonomicCard(indices: autonomicIndices)

                    HRRecoveryChart(
                        history:  Array(trainHistory.suffix(150)),
                        baseline: baseline,
                        maxHR:    Float(maxHR)
                    )

                    // Max HR stepper
                    HStack(spacing: 12) {
                        Button {
                            if maxHR > 100 { maxHR -= 5 }
                        } label: {
                            Image(systemName: "minus.circle")
                                .font(.system(size: 18, weight: .light))
                                .foregroundStyle(Theme.dim)
                        }

                        Text("MAX  \(Int(maxHR)) bpm")
                            .font(Theme.monoLabel)
                            .foregroundStyle(Theme.dim)

                        Button {
                            if maxHR < 220 { maxHR += 5 }
                        } label: {
                            Image(systemName: "plus.circle")
                                .font(.system(size: 18, weight: .light))
                                .foregroundStyle(Theme.dim)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.horizontal, 4)
                    .padding(.top, -8)

                    if trainState == .recover || trainState == .ready {
                        RSACard(tick: env.latestTick)

                        RMSSDChart(
                            history:  Array(trainHistory.suffix(150)),
                            baseline: baseline
                        )
                    }

                    CalibrationBar(
                        baseline:     baseline,
                        isCollecting: trainHistory.count < 15 && baseline == nil,
                        onRecalibrate: recalibrate
                    )
                }
                .padding(.horizontal)
                .padding(.top, 12)
                .padding(.bottom, 20)
            }
            .background(Theme.bg)
            .navigationTitle("TRAIN")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.bg, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    BLENavButton(state: env.ble.state,
                                 bpm: env.latestTick?.meanBPM) {
                        showBLESheet = true
                    }
                }
            }
            .sheet(isPresented: $showBLESheet) {
                BLEConnectionSheet(ble: env.ble)
            }
        }
        .onChange(of: env.latestTick?.timestamp) { _, _ in
            guard let tick = env.latestTick else { return }
            appendTick(tick)
        }
    }

    // MARK: - Data Management

    private func appendTick(_ tick: MetricsTick) {
        // Rolling 60-min cap (1800 ticks at ~2 s each)
        if trainHistory.count >= 1800 { trainHistory.removeFirst() }
        trainHistory.append(tick)

        // Auto-calibrate after first 15 ticks
        if baseline == nil && trainHistory.count == 15 {
            calibrateFrom(Array(trainHistory))
        }

        // Update state machine
        trainState = deriveState(tick: tick)
        autonomicIndices = AutonomicCompute.compute(tick: tick, baseline: baseline)
    }

    private func calibrateFrom(_ ticks: [MetricsTick]) {
        let hrs   = ticks.compactMap(\.meanBPM)
        let rmssds = ticks.compactMap(\.rmssd)
        guard !hrs.isEmpty else { return }
        let meanHR    = hrs.reduce(0, +) / Float(hrs.count)
        let meanRMSSD = rmssds.isEmpty ? nil : rmssds.reduce(0, +) / Float(rmssds.count)
        baseline = TrainBaseline(hr: meanHR, rmssd: meanRMSSD, timestamp: .now)
    }

    private func recalibrate() {
        let recent = Array(trainHistory.suffix(15))
        calibrateFrom(recent)
    }

    private func deriveState(tick: MetricsTick) -> TrainState {
        guard let b = baseline, let hr = tick.meanBPM else { return .calibrating }
        let delta = hr - b.hr
        switch trainState {
        case .calibrating, .ready:
            return delta > 20 ? .active : .ready
        case .active:
            let prevHR = trainHistory.suffix(3).compactMap(\.meanBPM).first ?? hr
            return (delta < 35 && hr <= prevHR) ? .recover : .active
        case .recover:
            return delta <= 15 ? .ready : .recover
        }
    }
}

// MARK: - Autonomic Card

private struct AutonomicCard: View {
    let indices: AutonomicIndices?

    private var state: PolyvagalState { indices?.state ?? .mixed }

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

private struct IndexBar: View {
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

private struct StateBanner: View {
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

private struct HRPanel: View {
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

private struct HRRecoveryChart: View {
    let history:  [MetricsTick]
    let baseline: TrainBaseline?
    let maxHR:    Float

    private struct ChartPoint: Identifiable {
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

private struct RSACard: View {
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

private struct RMSSDChart: View {
    let history:  [MetricsTick]
    let baseline: TrainBaseline?

    private struct ChartPoint: Identifiable {
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

private struct CalibrationBar: View {
    let baseline:     TrainBaseline?
    let isCollecting: Bool
    let onRecalibrate: () -> Void

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
