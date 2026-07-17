import SwiftUI
import SwiftData
import UIKit

// MARK: - Live View

struct LiveView: View {
    @Environment(AppEnvironment.self) var env
    @Environment(\.modelContext) var ctx
    @State private var showBLESheet  = false
    @State private var keepAwake     = false
    @State private var pageIndex:    Int = LiveView.todayIndex

    // 90-day window: index 0 = oldest, todayIndex = today.
    // Static so it's computed once; acceptable to require app restart at midnight.
    private static let days: [Date] = {
        let cal   = Calendar.current
        let today = cal.startOfDay(for: .now)
        return (0..<90).map { cal.date(byAdding: .day, value: -$0, to: today)! }.reversed()
    }()
    private static var todayIndex: Int { days.count - 1 }

    private var isToday:      Bool { pageIndex == LiveView.todayIndex }
    private var selectedDate: Date { LiveView.days[pageIndex] }

    private func goBack()    { if pageIndex > 0 { pageIndex -= 1 } }
    private func goForward() { if !isToday      { pageIndex += 1 } }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.bg.ignoresSafeArea()

                VStack(spacing: 0) {
                    // ── Date navigator lives OUTSIDE TabView so it never
                    //    conflicts with the inner ScrollViews.
                    DateNavigator(
                        date:      selectedDate,
                        isToday:   isToday,
                        onBack:    goBack,
                        onForward: goForward
                    )

                    // ── One page per day. TabView handles horizontal swiping
                    //    natively; SwiftUI disambiguates H vs V gestures for us.
                    TabView(selection: $pageIndex) {
                        ForEach(0..<LiveView.days.count, id: \.self) { i in
                            DayScrollView(date: LiveView.days[i])
                                .tag(i)
                        }
                    }
                    .tabViewStyle(.page(indexDisplayMode: .never))
                }
            }
            .navigationTitle("LIVE")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.bg, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        keepAwake.toggle()
                        UIApplication.shared.isIdleTimerDisabled = keepAwake
                    } label: {
                        Image(systemName: keepAwake ? "sun.max.fill" : "sun.max")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(keepAwake ? Theme.accent : Theme.dim)
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
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
    }
}

// MARK: - Day Scroll View

/// One page in the TabView — a plain vertical ScrollView for a single day.
/// Manages its own history fetch so the parent stays lightweight.
private struct DayScrollView: View {
    let date: Date

    @Environment(AppEnvironment.self) var env
    @Environment(\.modelContext) var ctx
    @State private var dayHistory:    [MetricsHistoryPoint] = []
    @State private var rawDayHistory: [MetricsHistoryPoint] = []
    @State private var showResonate   = false

    private var isToday: Bool { Calendar.current.isDateInToday(date) }

    private var currentHistory: [MetricsHistoryPoint] {
        let raw = isToday
            ? env.tickHistory.filter { Calendar.current.isDateInToday($0.timestamp) }
            : dayHistory
        return MetricsQualityFilter.filter(raw)
    }

    /// Unfiltered history — used by MetricsChartsView for anomaly band detection.
    private var rawCurrentHistory: [MetricsHistoryPoint] {
        isToday
            ? env.tickHistory.filter { Calendar.current.isDateInToday($0.timestamp) }
            : rawDayHistory
    }

    private var currentTick: MetricsTick? {
        dayAverageTick(from: currentHistory)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {

                // ── Autonomic state (today only) ────────────────────
                if isToday {
                    let state = PolyvagalState.infer(from: env.latestTick)
                    CurrentStateCard(tick: env.latestTick, state: state)
                        .padding(.horizontal)
                }

                // ── Metrics table ───────────────────────────────────
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(isToday ? "LIVE" : "DAY AVERAGE")
                            .font(Theme.monoLabel)
                            .foregroundStyle(Theme.dim)
                        Spacer()
                        if isToday && currentTick != nil {
                            Text("Δ vs today avg")
                                .font(Theme.monoLabel)
                                .foregroundStyle(Theme.dim.opacity(0.6))
                        }
                    }
                    .padding(.horizontal)
                    MetricsTableView(
                        tick:       isToday ? env.latestTick : currentTick,
                        comparison: isToday ? currentTick    : nil
                    )
                    .padding(.horizontal)
                }

                // ── Historical metric charts ────────────────────────
                if !currentHistory.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("METRICS HISTORY")
                            .font(Theme.monoLabel)
                            .foregroundStyle(Theme.dim)
                            .padding(.horizontal)
                        MetricsChartsView(history: currentHistory, rawHistory: rawCurrentHistory, date: date)
                    }
                } else if !isToday {
                    Text("No data for this day")
                        .font(Theme.monoLabel)
                        .foregroundStyle(Theme.dim)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 48)
                }


            }
            .padding(.top, 8)
        }
        .onAppear {
            if !isToday { loadDayHistory() }
        }
        .sheet(isPresented: $showResonate) {
            ResonateView()
                .environment(env)
        }
    }

    // MARK: - Data helpers

    private func loadDayHistory() {
        let cal   = Calendar.current
        let start = cal.startOfDay(for: date)
        let end   = cal.date(byAdding: .day, value: 1, to: start)!
        var desc  = FetchDescriptor<HRVSample>(
            predicate: #Predicate { $0.timestamp >= start && $0.timestamp < end },
            sortBy:    [SortDescriptor(\.timestamp)]
        )
        desc.fetchLimit = 43_200
        let allPts = ((try? ctx.fetch(desc)) ?? []).map { MetricsHistoryPoint(from: $0) }
        rawDayHistory = allPts
        dayHistory    = MetricsQualityFilter.filter(allPts)
    }

    private func dayAverageTick(from history: [MetricsHistoryPoint]) -> MetricsTick? {
        guard !history.isEmpty else { return nil }
        func avg(_ vals: [Float]) -> Float? {
            vals.isEmpty ? nil : vals.reduce(0, +) / Float(vals.count)
        }
        return MetricsTick(
            timestamp:       history.last?.timestamp ?? .now,
            meanBPM:         avg(history.compactMap(\.meanBPM)),
            sdnn:            avg(history.compactMap(\.sdnn)),
            rmssd:           avg(history.compactMap(\.rmssd)),
            pnn50:           avg(history.compactMap(\.pnn50)),
            vti:             avg(history.compactMap(\.rmssd)).map { $0 > 0 ? log($0) : 0 },
            ulfPower:        avg(history.compactMap(\.ulfPower)),
            vlfPower:        avg(history.compactMap(\.vlfPower)),
            lfPower:         avg(history.compactMap(\.lfPower)),
            hfPower:         avg(history.compactMap(\.hfPower)),
            lfHF:            avg(history.compactMap(\.lfHF)),
            rsaMs:           avg(history.compactMap(\.rsaMs)),
            rsaIdx:          nil,
            breathBPM:       avg(history.compactMap(\.breathBPM)),
            breathHz:        nil,
            regularity:      nil,
            coherenceScore:  avg(history.compactMap(\.coherence)),
            cbi:             avg(history.compactMap(\.cbi)),
            dfa1:            avg(history.compactMap(\.dfa1)),
            signalQuality:   avg(history.compactMap(\.signalQuality)),
            ecgQuality:      nil,
            rcmse:           avg(history.compactMap(\.rcmse)),
            pip:             avg(history.compactMap(\.pip)),
            ials:            avg(history.compactMap(\.ials)),
            dc:              avg(history.compactMap(\.dc)),
            breathPhases:    nil,
            psdFreqs:        nil,
            psdValues:       nil,
            coherenceFreqs:  nil,
            coherenceValues: nil
        )
    }
}

// MARK: - Today Live Section
//
// Reads env.waveform (30 fps) and env.latestTick (2 s).
// Extracted from DayScrollView so waveform-rate redraws don't invalidate
// the chart area — DayScrollView.body now only runs at the 2-s tick rate.

private struct TodayLiveSection: View {
    @Environment(AppEnvironment.self) var env

    var body: some View { EmptyView() }
}

// MARK: - Date Navigator

private struct DateNavigator: View {
    let date:      Date
    let isToday:   Bool
    let onBack:    () -> Void
    let onForward: () -> Void

    var body: some View {
        HStack {
            Button(action: onBack) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Theme.text)
            }
            Spacer()
            Text(dateLabel)
                .font(Theme.monoBody)
                .foregroundStyle(Theme.text)
            Spacer()
            Button(action: onForward) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(isToday ? Theme.dim.opacity(0.3) : Theme.text)
            }
            .disabled(isToday)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    private var dateLabel: String {
        let cal = Calendar.current
        if cal.isDateInToday(date)     { return "TODAY" }
        if cal.isDateInYesterday(date) { return "YESTERDAY" }
        let fmt = DateFormatter()
        fmt.dateFormat = "EEE  MMM d"
        return fmt.string(from: date).uppercased()
    }
}

// MARK: - BLE Connection Sheet

struct BLEConnectionSheet: View {
    let ble: BLEService
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.bg.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 16) {
                        statusCard
                        actionSection
                        if let err = ble.lastError { errorCard(err) }
                    }
                    .padding()
                }
            }
            .navigationTitle("BLUETOOTH")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.bg, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                        .font(Theme.monoBody)
                        .foregroundStyle(Theme.accent)
                }
            }
        }
    }

    private var statusCard: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(stateColor.opacity(0.14))
                    .frame(width: 50, height: 50)
                Image(systemName: stateIcon)
                    .font(.system(size: 22, weight: .light))
                    .foregroundStyle(stateColor)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(stateTitle)
                    .font(Theme.monoBody)
                    .foregroundStyle(Theme.text)
                Text(stateSubtitle)
                    .font(Theme.monoLabel)
                    .foregroundStyle(Theme.dim)
                // Diagnostic: always show raw CB state so the user can tell us
                // whether Bluetooth is actually on and available.
                Text(ble.cbStateDescription)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Theme.dim.opacity(0.6))
            }
            Spacer()
        }
        .cardStyle()
    }

    @ViewBuilder
    private var actionSection: some View {
        if case .connected(let name) = ble.state {
            connectedCard(name: name)
        } else {
            deviceScanSection
        }
    }

    private func connectedCard(name: String) -> some View {
        VStack(spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text(name.uppercased())
                        .font(Theme.monoBody)
                        .foregroundStyle(Theme.accent)
                    if let bat = ble.batteryLevel {
                        HStack(spacing: 5) {
                            Image(systemName: batteryIcon(bat))
                                .foregroundStyle(bat > 20 ? Theme.accent : Theme.warn)
                                .font(.caption)
                            Text("\(bat)%")
                                .font(Theme.monoLabel)
                                .foregroundStyle(Theme.dim)
                        }
                    }
                }
                Spacer()
                Button("Disconnect") { ble.disconnect() }
                    .font(Theme.monoBody)
                    .foregroundStyle(Theme.warn)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Theme.warn.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(Theme.warn.opacity(0.3), lineWidth: 0.5)
                    )
            }
        }
        .cardStyle()
    }

    private var deviceScanSection: some View {
        VStack(spacing: 12) {
            Button {
                if case .scanning = ble.state { ble.stopScanning() }
                else { ble.startScanning() }
            } label: {
                HStack(spacing: 10) {
                    if case .scanning = ble.state {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .tint(Theme.accent)
                            .scaleEffect(0.75)
                        Text("SCANNING…  TAP TO STOP")
                    } else {
                        Image(systemName: "arrow.clockwise")
                        Text("SCAN FOR DEVICES")
                    }
                }
                .font(Theme.monoBody)
                .foregroundStyle(Theme.accent)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
                .background(Theme.accent.opacity(0.09))
                .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.cardRadius)
                        .strokeBorder(Theme.accent.opacity(0.35), lineWidth: 1)
                )
            }

            if !ble.discoveredDevices.isEmpty {
                VStack(spacing: 0) {
                    ForEach(ble.discoveredDevices) { device in
                        DeviceRow(device: device, isConnecting: {
                            if case .connecting(let n) = ble.state { return n == device.name }
                            return false
                        }()) {
                            ble.connectToDevice(device)
                        }
                        if device.id != ble.discoveredDevices.last?.id {
                            Divider().background(Theme.border).padding(.horizontal, 12)
                        }
                    }
                }
                .background(Theme.card)
                .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.cardRadius)
                        .strokeBorder(Theme.border, lineWidth: 0.5)
                )
            } else if case .scanning = ble.state {
                Text("Looking for Polar H10…")
                    .font(Theme.monoLabel)
                    .foregroundStyle(Theme.dim)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
            }

            if UserDefaults.standard.string(forKey: "justbreathe.polar.uuid") != nil {
                Button {
                    UserDefaults.standard.removeObject(forKey: "justbreathe.polar.uuid")
                    ble.disconnect()
                } label: {
                    Text("Forget saved device")
                        .font(Theme.monoLabel)
                        .foregroundStyle(Theme.dim)
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }

    private func errorCard(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Theme.warn)
                .font(.caption)
            Text(message)
                .font(Theme.monoLabel)
                .foregroundStyle(Theme.warn)
                .lineLimit(3)
            Spacer()
        }
        .padding(12)
        .background(Theme.warn.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Theme.warn.opacity(0.25), lineWidth: 0.5)
        )
    }

    private var stateColor: Color {
        switch ble.state {
        case .connected:             return Theme.accent
        case .scanning, .connecting: return Theme.warn
        case .disconnected:          return Theme.warn.opacity(0.7)
        default:                     return Theme.dim
        }
    }

    private var stateIcon: String {
        switch ble.state {
        case .connected:   return "checkmark.circle.fill"
        case .scanning:    return "dot.radiowaves.left.and.right"
        case .connecting:  return "arrow.triangle.2.circlepath"
        case .unauthorized: return "lock.slash"
        default:           return "antenna.radiowaves.left.and.right.slash"
        }
    }

    private var stateTitle: String {
        switch ble.state {
        case .idle:              return "Not Connected"
        case .scanning:          return "Scanning…"
        case .connecting(let n): return "Connecting to \(n)"
        case .connected(let n):  return n
        case .disconnected:      return "Disconnected"
        case .unauthorized:      return "No Bluetooth Permission"
        case .unsupported:       return "Bluetooth Unavailable"
        }
    }

    private var stateSubtitle: String {
        switch ble.state {
        case .idle:              return "Tap Scan to find your Polar H10"
        case .scanning:          return "Searching (Heart Rate service filter)…"
        case .connecting:        return "Establishing connection…"
        case .connected:         return "ECG + ACC streaming"
        case .disconnected(let r): return r
        case .unauthorized:      return "Allow Bluetooth in iPhone Settings"
        case .unsupported:       return "This device doesn't support BLE"
        }
    }

    private func batteryIcon(_ level: Int) -> String {
        switch level {
        case 75...: return "battery.100"
        case 50...: return "battery.75"
        case 25...: return "battery.50"
        default:    return "battery.25"
        }
    }
}

// MARK: - Device Row

private struct DeviceRow: View {
    let device:       BLEDevice
    let isConnecting: Bool
    let onConnect:    () -> Void

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(device.name)
                    .font(Theme.monoBody)
                    .foregroundStyle(Theme.text)
                HStack(spacing: 5) {
                    Text(device.rssiDots)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(rssiColor)
                    Text("\(device.rssi) dBm  ·  \(device.rssiLabel)")
                        .font(Theme.monoLabel)
                        .foregroundStyle(Theme.dim)
                }
            }
            Spacer()
            if isConnecting {
                ProgressView()
                    .progressViewStyle(.circular)
                    .tint(Theme.accent)
                    .scaleEffect(0.8)
            } else {
                Button("CONNECT", action: onConnect)
                    .font(Theme.monoLabel)
                    .foregroundStyle(Theme.accent)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Theme.accent.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private var rssiColor: Color {
        switch device.rssi {
        case (-50)...: return Theme.accent
        case (-70)...: return Theme.warn
        default:       return Theme.dim
        }
    }
}

// MARK: - Sub-components

// MARK: - Metrics Table

private struct MetricsTableView: View {
    let tick:       MetricsTick?
    let comparison: MetricsTick?   // day avg (today) or nil

    private let cols = Array(repeating: GridItem(.flexible(), spacing: 10), count: 3)

    var body: some View {
        LazyVGrid(columns: cols, spacing: 10) {
            MetricTile(label: "Mental Clarity",       techLabel: "DFA α1",  value: dfa1String,                       unit: "",    delta: delta(tick?.dfa1,    comparison?.dfa1),    higherBetter: false)
            MetricTile(label: "Conscious Breathing",  techLabel: "RSA",     value: MetricFormat.ms(tick?.rsaMs),    unit: "ms",  delta: delta(tick?.rsaMs,   comparison?.rsaMs),   higherBetter: true)
            MetricTile(label: "Energy Reserve",       techLabel: "HRV",     value: MetricFormat.ms(tick?.rmssd),    unit: "ms",  delta: delta(tick?.rmssd,   comparison?.rmssd),   higherBetter: true)
            MetricTile(label: "Adaptive Power",       techLabel: "RCMSE",   value: rcmseString,                      unit: "",    delta: delta(tick?.rcmse,   comparison?.rcmse),   higherBetter: true)
            MetricTile(label: "Inner Noise",          techLabel: "PIP",     value: pipString,                        unit: "%",   delta: delta(tick?.pip,     comparison?.pip),     higherBetter: false)
            MetricTile(label: "Calm Reserve",         techLabel: "DC",      value: dcString,                         unit: "ms",  delta: delta(tick?.dc,      comparison?.dc),      higherBetter: true)
            MetricTile(label: "Calm Power",           techLabel: "VTI",     value: MetricFormat.ratio(tick?.vti),   unit: "",    delta: delta(tick?.vti,     comparison?.vti),     higherBetter: true)
            MetricTile(label: "Stress Balance",       techLabel: "LF/HF",   value: MetricFormat.ratio(tick?.lfHF), unit: "",    delta: delta(tick?.lfHF,    comparison?.lfHF),    higherBetter: false)
            MetricTile(label: "Pulse",                techLabel: "HR",      value: MetricFormat.bpm(tick?.meanBPM), unit: "bpm", delta: delta(tick?.meanBPM, comparison?.meanBPM), higherBetter: false)
        }
    }

    private var dfa1String:  String { tick?.dfa1.map  { String(format: "%.2f", $0) } ?? "—" }
    private var rcmseString: String { tick?.rcmse.map { String(format: "%.2f", $0) } ?? "—" }
    private var pipString:   String { tick?.pip.map   { String(format: "%.1f", $0) } ?? "—" }
    private var dcString:    String { tick?.dc.map    { String(format: "%.1f", $0) } ?? "—" }

    private func delta(_ live: Float?, _ avg: Float?) -> Float? {
        guard let l = live, let a = avg else { return nil }
        return l - a
    }
}

private struct MetricTile: View {
    let label:        String   // consumer name
    let techLabel:    String   // technical name shown in gray
    let value:        String
    let unit:         String
    let delta:        Float?
    let higherBetter: Bool

    init(label: String, techLabel: String = "", value: String, unit: String,
         delta: Float?, higherBetter: Bool) {
        self.label        = label
        self.techLabel    = techLabel
        self.value        = value
        self.unit         = unit
        self.delta        = delta
        self.higherBetter = higherBetter
    }

    private var deltaColor: Color {
        guard let d = delta else { return Theme.dim }
        let positive = d >= 0
        return (positive == higherBetter) ? Theme.accent : Theme.warn
    }

    private var deltaText: String {
        guard let d = delta else { return "" }
        return String(format: "%+.1f", d)
    }

    private var hasData: Bool { value != "—" }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Line 1 — white consumer name
            Text(label)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(Theme.text)
                .lineLimit(1)
                .truncationMode(.tail)
            // Line 2 — gray technical term (tight spacing so they read as one label)
            if !techLabel.isEmpty {
                Text(techLabel)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(Theme.dim)
                    .lineLimit(1)
                    .padding(.top, -2)
            }

            // Value — fixed height so all tiles are the same size
            Text(value)
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .foregroundStyle(hasData ? Theme.text : Theme.dim.opacity(0.4))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(minHeight: 28)

            // Unit + delta — always rendered to lock row height
            HStack(spacing: 4) {
                Text(unit.isEmpty ? " " : unit)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Theme.dim)
                if hasData, delta != nil {
                    Text(deltaText)
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(deltaColor)
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 90, alignment: .leading)
        .padding(12)
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - Preview

#Preview("Live View - Connected") {
    LiveView()
        .environment(createMockEnvironment())
}

@MainActor
private func createMockEnvironment() -> AppEnvironment {
    let config    = ModelConfiguration(isStoredInMemoryOnly: true)
    let container = try! ModelContainer(for: HRVSession.self, configurations: config)
    let env = AppEnvironment(modelContainer: container)
    env.ble.state       = .connected(name: "Polar H10")
    env.waveform.ecg    = generateMockECG()
    env.latestTick      = MetricsTick(
        timestamp: Date(), meanBPM: 72.5, sdnn: 45.3, rmssd: 38.7,
        pnn50: 22.1, vti: 12.5, ulfPower: 25, vlfPower: 550, lfPower: 850, hfPower: 1200, lfHF: 0.71,
        rsaMs: 42.0, rsaIdx: 1.41, breathBPM: 6.2, breathHz: 0.103,
        regularity: 0.85, coherenceScore: 0.76, cbi: 0.82, dfa1: 1.02, signalQuality: 0.97,
        ecgQuality: ECGQualityResult(tier: .good, reason: "clean"),
        rcmse: 1.45, pip: 54.2, ials: 0.51, dc: 7.2,
        breathPhases: nil, psdFreqs: nil, psdValues: nil,
        coherenceFreqs: nil, coherenceValues: nil
    )
    return env
}

private func generateMockECG() -> [Float] {
    (0..<650).map { i in
        let t = Float(i) / 650.0
        let p = (t * 5.8).truncatingRemainder(dividingBy: 1.0)
        var v: Float = 0
        if p < 0.15 { v = 50 * sin(p * .pi / 0.15) }
        else if p < 0.35 {
            let q = (p - 0.25) / 0.1
            if      q < 0.3  { v = -100 * sin(q * .pi / 0.3) }
            else if q < 0.7  { v =  800 * sin((q - 0.3) * .pi / 0.4) }
            else              { v = -200 * sin((q - 0.7) * .pi / 0.3) }
        } else if p < 0.7 { v = 150 * sin((p - 0.5) * .pi / 0.2) }
        return v + Float.random(in: -15...15)
    }
}
