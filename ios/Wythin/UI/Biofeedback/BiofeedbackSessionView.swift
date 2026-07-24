import SwiftUI

// MARK: - Biofeedback Session
//
// Live workout feedback (gym / run), started from a biofeedback practice. Reuses
// the autonomic / HR-recovery / RSA cards and the calibration + set-tracking
// logic lifted from the former TrainView. On appear it begins an ActivityLog; on
// Stop it ends that log (→ appears in Activities) AND dual-writes a TrainSession
// (→ History "TRAIN SESSIONS"), so both histories keep working unchanged.

struct BiofeedbackSessionView: View {
    let activityType: ActivityType
    let subtype:      String?

    @Environment(AppEnvironment.self) var env
    @Environment(\.modelContext) var ctx
    @Environment(\.dismiss) var dismiss

    @State private var trainHistory:     [MetricsTick]      = []
    @State private var baseline:         TrainBaseline?     = nil
    @State private var trainState:       TrainState         = .calibrating
    @State private var autonomicIndices: AutonomicIndices?  = nil
    @State private var showBLESheet                         = false

    @State private var logEntry: ActivityLog? = nil

    // Session recording (for the dual-written TrainSession)
    @State private var sessionSNSAccum: [Float]    = []
    @State private var sessionPNSAccum: [Float]    = []
    @State private var setCount:        Int        = 0
    @State private var recoveryStart:   Date?      = nil
    @State private var setRecoveryMins: [Float]    = []
    @State private var prevTrainState:  TrainState = .calibrating

    @AppStorage("train.maxHR") private var maxHR: Double = 160

    private var titleText: String {
        (subtype ?? activityType.rawValue).uppercased()
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {

                    StateBanner(state: trainState)

                    HRPanel(tick: env.latestTick, baseline: baseline, history: trainHistory)

                    AutonomicCard(indices: autonomicIndices)

                    HRRecoveryChart(history: Array(trainHistory.suffix(150)),
                                    baseline: baseline,
                                    maxHR: Float(maxHR))

                    maxHRStepper

                    if trainState == .recover || trainState == .ready {
                        RSACard(tick: env.latestTick)
                        RMSSDChart(history: Array(trainHistory.suffix(150)), baseline: baseline)
                    }

                    CalibrationBar(
                        baseline:        baseline,
                        isCollecting:    trainHistory.count < 15 && baseline == nil,
                        isSessionActive: true,
                        onRecalibrate:   recalibrate,
                        onStartSession:  {},
                        onEndSession:    stop
                    )
                }
                .padding(.horizontal)
                .padding(.top, 12)
                .padding(.bottom, 24)
            }
            .background(Theme.bg)
            .navigationTitle(titleText)
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
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Stop") { stop() }
                        .font(Theme.monoLabel)
                        .foregroundStyle(Theme.warn)
                }
            }
            .sheet(isPresented: $showBLESheet) {
                BLEConnectionSheet(ble: env.ble)
            }
        }
        .onAppear {
            if logEntry == nil {
                logEntry = ActivityLogging.begin(type: activityType, subtype: subtype,
                                                 customName: nil, context: ctx)
                prevTrainState = trainState
            }
        }
        .onChange(of: env.latestTick?.timestamp) { _, _ in
            guard let tick = env.latestTick else { return }
            appendTick(tick)
        }
    }

    // MARK: Max HR stepper

    private var maxHRStepper: some View {
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
    }

    // MARK: Tick pump + calibration (lifted from TrainView)

    private func appendTick(_ tick: MetricsTick) {
        // Rolling 60-min cap (1800 ticks at ~2 s each)
        if trainHistory.count >= 1800 { trainHistory.removeFirst() }
        trainHistory.append(tick)

        // Auto-calibrate after first 15 ticks
        if baseline == nil && trainHistory.count == 15 {
            calibrateFrom(Array(trainHistory))
        }

        trainState = deriveState(tick: tick)
        autonomicIndices = AutonomicCompute.compute(tick: tick, baseline: baseline)

        // Session is active for the whole view lifetime — track set/recovery.
        let now = Date.now
        if prevTrainState == .active && trainState == .recover {
            recoveryStart = now
            setCount += 1
        }
        if prevTrainState == .recover && trainState == .ready, let rs = recoveryStart {
            setRecoveryMins.append(Float(now.timeIntervalSince(rs) / 60))
            recoveryStart = nil
        }
        if let idx = autonomicIndices {
            sessionSNSAccum.append(idx.sns)
            sessionPNSAccum.append(idx.pns)
        }
        prevTrainState = trainState
    }

    private func calibrateFrom(_ ticks: [MetricsTick]) {
        let hrs    = ticks.compactMap(\.meanBPM)
        let rmssds = ticks.compactMap(\.rmssd)
        guard !hrs.isEmpty else { return }
        let meanHR    = hrs.reduce(0, +) / Float(hrs.count)
        let meanRMSSD = rmssds.isEmpty ? nil : rmssds.reduce(0, +) / Float(rmssds.count)
        baseline = TrainBaseline(hr: meanHR, rmssd: meanRMSSD, timestamp: .now)
    }

    private func recalibrate() {
        calibrateFrom(Array(trainHistory.suffix(15)))
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

    // MARK: Stop → finish log + dual-write TrainSession

    private func stop() {
        // 1. Finish the ActivityLog → appears in Activities (with coach insight).
        if let entry = logEntry {
            ActivityLogging.end(entry, context: ctx, client: env.sync.client)
            logEntry = nil
        }

        // 2. Dual-write a TrainSession → History "TRAIN SESSIONS" (unchanged).
        if let b = baseline {
            let avgSNS = sessionSNSAccum.isEmpty ? 0 : sessionSNSAccum.reduce(0, +) / Float(sessionSNSAccum.count)
            let avgPNS = sessionPNSAccum.isEmpty ? 0 : sessionPNSAccum.reduce(0, +) / Float(sessionPNSAccum.count)
            let avgRec = setRecoveryMins.isEmpty ? 0 : setRecoveryMins.reduce(0, +) / Float(setRecoveryMins.count)
            let recData = (try? JSONEncoder().encode(setRecoveryMins)) ?? Data()
            let rec     = String(data: recData, encoding: .utf8) ?? "[]"

            let session            = TrainSession(baselineHR: b.hr, baselineRMSSD: b.rmssd)
            session.endedAt        = .now
            session.setCount       = setCount
            session.avgSNSIndex    = avgSNS
            session.avgPNSIndex    = avgPNS
            session.avgRecoveryMin = avgRec
            session.recoveryMins   = rec
            ctx.insert(session)
            try? ctx.save()
        }

        dismiss()
    }
}
