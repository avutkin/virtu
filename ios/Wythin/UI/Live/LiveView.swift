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
    // Shared chart window for every chart on every day-page; persisted.
    @AppStorage("liveChartWindow") private var chartWindow: TimeWindow = .h24

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

    private var currentQuality: CombinedSignalQuality? {
        ECGQualityCompute.combinedTier(
            rrSignalQuality: env.latestTick?.signalQuality,
            ecgResult:       env.latestTick?.ecgQuality
        )
    }

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
                        window:    $chartWindow,
                        onBack:    goBack,
                        onForward: goForward
                    )

                    // ── One page per day. TabView handles horizontal swiping
                    //    natively; SwiftUI disambiguates H vs V gestures for us.
                    TabView(selection: $pageIndex) {
                        ForEach(0..<LiveView.days.count, id: \.self) { i in
                            DayScrollView(date: LiveView.days[i], window: chartWindow)
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
                                 bpm: env.latestTick?.meanBPM,
                                 quality: currentQuality) {
                        showBLESheet = true
                    }
                }
            }
            .sheet(isPresented: $showBLESheet) {
                BLEConnectionSheet(ble: env.ble, quality: currentQuality)
            }
        }
    }
}

// MARK: - Day Scroll View

/// One page in the TabView — a plain vertical ScrollView for a single day.
/// Manages its own history fetch so the parent stays lightweight.
private struct DayScrollView: View {
    let date: Date
    let window: TimeWindow

    @Environment(AppEnvironment.self) var env
    @Environment(\.modelContext) var ctx
    // Snapshot arrays feeding the (expensive) charts. Deliberately NOT read from
    // env.tickHistory in `body`: the today page's body re-evaluates every 2 s
    // (it reads env.latestTick for the live card/table), and if the charts were
    // fed live data they would re-render all 9 Swift Charts on every tick — the
    // periodic scroll hitch. Instead these refresh on a ~15 s cadence (today) or
    // once on load (past days); MetricsChartsView is `.equatable()` so the 2 s
    // body re-evals don't touch it while this snapshot is unchanged.
    @State private var chartRaw:      [MetricsHistoryPoint] = []
    @State private var chartFiltered: [MetricsHistoryPoint] = []
    @State private var chartDayAvg:   MetricsTick?          = nil
    @State private var liveStore      = LiveStateStore()

    private var isToday: Bool { Calendar.current.isDateInToday(date) }

    /// Half-open [startOfDay, nextDay) for `date` — computed once instead of
    /// calling Calendar.isDateInToday per history element.
    private var dayRange: Range<Date>? {
        let cal   = Calendar.current
        let start = cal.startOfDay(for: date)
        guard let end = cal.date(byAdding: .day, value: 1, to: start) else { return nil }
        return start..<end
    }

    var body: some View {
        LogoRefreshableScrollView(enabled: isToday, onRefresh: {
            // Pull down on today's page to refresh — honors the 5-minute floor
            // (updates once the window has elapsed, or for the first reading).
            await liveStore.refresh(env: env)
        }) {
            VStack(spacing: 12) {

                // ── Autonomic state (today only) ────────────────────
                if isToday {
                    LiveStateWidget(store: liveStore)
                        .padding(.horizontal)
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
                        if isToday && chartDayAvg != nil {
                            Text("Δ vs today avg")
                                .font(Theme.monoLabel)
                                .foregroundStyle(Theme.dim.opacity(0.6))
                        }
                    }
                    .padding(.horizontal)
                    MetricsTableView(
                        tick:       isToday ? env.latestTick : chartDayAvg,
                        comparison: isToday ? chartDayAvg    : nil
                    )
                    .padding(.horizontal)
                }

                // ── Historical metric charts ────────────────────────
                if !chartFiltered.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("METRICS HISTORY")
                            .font(Theme.monoLabel)
                            .foregroundStyle(Theme.dim)
                            .padding(.horizontal)
                        MetricsChartsView(history: chartFiltered, rawHistory: chartRaw, date: date, window: window)
                            .equatable()
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
        .task(id: date) {
            if isToday {
                // Refresh the charts immediately, then on a slow cadence. The live
                // card/table still update every 2 s via env.latestTick; the charts
                // don't need 2 s granularity and re-rendering 9 Swift Charts that
                // often is what made scrolling hitch.
                refreshLiveCharts()
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(15))
                    guard !Task.isCancelled else { break }
                    refreshLiveCharts()
                }
            } else {
                // Debounce: if the user swipes past this day within 150 ms, the
                // task is cancelled during the sleep and the fetch never fires —
                // keeps fast swiping smooth and avoids piling up background fetches
                // for days you only pass through.
                try? await Task.sleep(for: .milliseconds(150))
                guard !Task.isCancelled else { return }
                await loadDayHistory()
            }
        }
    }

    // MARK: - Data helpers

    /// Snapshots today's live history into the chart @State on a slow cadence.
    /// Reads env.tickHistory OUTSIDE `body` (from the .task loop) so it does not
    /// register a body dependency — the 9 charts stay off the 2 s tick path.
    @MainActor
    private func refreshLiveCharts() {
        guard let range = dayRange else { return }
        let raw      = env.tickHistory.filter { range.contains($0.timestamp) }
        let filtered = MetricsQualityFilter.filter(raw)
        chartRaw      = raw
        chartFiltered = filtered
        chartDayAvg   = dayAverageTick(from: filtered)
    }

    /// Loads a past day's history off the main thread. The synchronous 43k-row
    /// SwiftData fetch used to run in `onAppear` on the main thread, blocking the
    /// horizontal swipe animation; here it runs on a background ModelContext and
    /// only the (Sendable) plain-struct result is handed back to the main actor.
    @MainActor
    private func loadDayHistory() async {
        guard chartRaw.isEmpty else { return }   // already loaded for this day
        let container = ctx.container
        let cal   = Calendar.current
        let start = cal.startOfDay(for: date)
        guard let end = cal.date(byAdding: .day, value: 1, to: start) else { return }

        let result: ([MetricsHistoryPoint], [MetricsHistoryPoint]) = await Task.detached {
            let bg = ModelContext(container)
            var desc = FetchDescriptor<HRVSample>(
                predicate: #Predicate { $0.timestamp >= start && $0.timestamp < end },
                sortBy:    [SortDescriptor(\.timestamp)]
            )
            desc.fetchLimit = 43_200
            let pts = ((try? bg.fetch(desc)) ?? []).map { MetricsHistoryPoint(from: $0) }
            return (pts, MetricsQualityFilter.filter(pts))
        }.value

        guard !Task.isCancelled else { return }
        chartRaw      = result.0
        chartFiltered = result.1
        chartDayAvg   = dayAverageTick(from: result.1)
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
    @Binding var window: TimeWindow
    let onBack:    () -> Void
    let onForward: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onBack) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Theme.text)
            }
            Text(dateLabel)
                .font(Theme.monoBody)
                .foregroundStyle(Theme.text)
            Button(action: onForward) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(isToday ? Theme.dim.opacity(0.3) : Theme.text)
            }
            .disabled(isToday)

            Spacer()

            // Shared window selector — applies to every chart on the page.
            HStack(spacing: 3) {
                ForEach(TimeWindow.allCases) { w in
                    Button(w.rawValue) {
                        withAnimation(.easeInOut(duration: 0.15)) { window = w }
                    }
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(w == window ? Color.black : Theme.dim)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(w == window ? Theme.accent : Color.clear)
                    .clipShape(Capsule())
                }
            }
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
    let ble:     BLEService
    let quality: CombinedSignalQuality?
    @Environment(\.dismiss) private var dismiss

    init(ble: BLEService, quality: CombinedSignalQuality? = nil) {
        self.ble     = ble
        self.quality = quality
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.bg.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 16) {
                        statusCard
                        if let quality { signalQualityCard(quality) }
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

    private func signalQualityCard(_ q: CombinedSignalQuality) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("SIGNAL QUALITY")
                    .font(Theme.monoLabel)
                    .foregroundStyle(Theme.dim)
                Spacer()
                HStack(spacing: 5) {
                    Circle().fill(q.tier.color).frame(width: 7, height: 7)
                    Text(q.tier.label)
                        .font(Theme.monoBody)
                        .foregroundStyle(q.tier.color)
                }
            }
            HStack {
                Text("RR artifacts")
                    .font(Theme.monoLabel)
                    .foregroundStyle(Theme.dim)
                Spacer()
                Text(q.rrArtifactPercent.map { "\($0)%" } ?? "—")
                    .font(Theme.monoBody)
                    .foregroundStyle(Theme.text)
            }
            HStack {
                Text("ECG waveform")
                    .font(Theme.monoLabel)
                    .foregroundStyle(Theme.dim)
                Spacer()
                Text(q.ecgReason ?? "—")
                    .font(Theme.monoBody)
                    .foregroundStyle(Theme.text)
            }
            if q.tier != .good {
                Divider().background(Theme.border)
                Text("Improving signal quality")
                    .font(Theme.monoLabel)
                    .foregroundStyle(Theme.dim)
                ForEach(Self.improvementTips, id: \.self) { tip in
                    Text("•  \(tip)")
                        .font(Theme.monoLabel)
                        .foregroundStyle(Theme.text.opacity(0.85))
                }
            }
        }
        .cardStyle()
    }

    private static let improvementTips = [
        "Limit movement during measurement",
        "Ensure the chest strap is moist",
        "Ensure the strap is tightened appropriately",
        "Check and replace worn-out chest straps",
        "Check and replace HR monitor batteries that are low",
    ]

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

            if UserDefaults.standard.string(forKey: "wythin.polar.uuid") != nil {
                Button {
                    UserDefaults.standard.removeObject(forKey: "wythin.polar.uuid")
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
            MetricTile(label: "Harmony",               techLabel: "DFA α1",  value: dfa1String,                       unit: "",    delta: delta(tick?.dfa1,    comparison?.dfa1),    higherBetter: false)
            MetricTile(label: "Conscious Breathing",  techLabel: "RSA",     value: MetricFormat.ms(tick?.rsaMs),    unit: "ms",  delta: delta(tick?.rsaMs,   comparison?.rsaMs),   higherBetter: true)
            MetricTile(label: "Energy Reserve",       techLabel: "HRV",     value: MetricFormat.ms(tick?.rmssd),    unit: "ms",  delta: delta(tick?.rmssd,   comparison?.rmssd),   higherBetter: true)
            MetricTile(label: "Adaptive Power",       techLabel: "RCMSE",   value: rcmseString,                      unit: "",    delta: delta(tick?.rcmse,   comparison?.rcmse),   higherBetter: true)
            MetricTile(label: "Inner Noise",          techLabel: "PIP",     value: pipString,                        unit: "%",   delta: delta(tick?.pip,     comparison?.pip),     higherBetter: false)
            MetricTile(label: "Vagal Tone",           techLabel: "DC",      value: dcString,                         unit: "ms",  delta: delta(tick?.dc,      comparison?.dc),      higherBetter: true)
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

// MARK: - Logo Pull-to-Refresh

/// Vertical ScrollView with a custom pull-to-refresh whose indicator is the
/// Wythin logo: it rotates with the pull and spins continuously while
/// refreshing. Uses scroll-offset detection (not a gesture) so it never fights
/// the horizontal day-paging TabView, and it only reacts to downward overscroll
/// so normal scrolling doesn't re-evaluate the (heavy) content.
struct LogoRefreshableScrollView<Content: View>: View {
    var enabled: Bool = true
    let onRefresh: () async -> Void
    let content: Content

    init(enabled: Bool = true,
         onRefresh: @escaping () async -> Void,
         @ViewBuilder content: () -> Content) {
        self.enabled   = enabled
        self.onRefresh = onRefresh
        self.content   = content()
    }

    @State private var pull: CGFloat = 0
    @State private var isRefreshing = false

    private let threshold       = 72.0
    private let indicatorHeight = 60.0
    private let logoSize        = 26.0
    private let space           = "wythinLogoRefresh"

    private var progress: Double { min(1, Double(pull) / threshold) }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                // Zero-height anchor at the very top: its minY in the scroll
                // space is 0 at rest and grows as the user overscrolls down.
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: RefreshOffsetKey.self,
                        value: proxy.frame(in: .named(space)).minY)
                }
                .frame(height: 0)

                // Revealed band that holds the spinning logo while refreshing.
                Color.clear.frame(height: isRefreshing ? indicatorHeight : 0)

                content
            }
        }
        .coordinateSpace(name: space)
        .overlay(alignment: .top) {
            if enabled {
                let y = isRefreshing
                    ? indicatorHeight / 2 - logoSize / 2
                    : min(max(0, Double(pull)), 140) / 2 - logoSize / 2
                RefreshLogo(spinning: isRefreshing,
                            pullAngle: progress * 270,
                            opacity:  isRefreshing ? 1 : progress,
                            size: logoSize)
                    .offset(y: y)
                    .allowsHitTesting(false)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: isRefreshing)
        .onPreferenceChange(RefreshOffsetKey.self) { value in
            guard enabled else { return }
            let p = max(0, value)              // ignore normal (upward) scrolling
            if p != pull { pull = p }
            if !isRefreshing && p > threshold { trigger() }
        }
    }

    private func trigger() {
        isRefreshing = true
        Task {
            await onRefresh()
            isRefreshing = false
        }
    }
}

/// The Wythin logo used as the refresh indicator. Owns its own spin animation
/// so keeping it turning doesn't re-evaluate the scroll view's content.
private struct RefreshLogo: View {
    let spinning:  Bool
    let pullAngle: Double
    let opacity:   Double
    let size:      Double

    @State private var spin = false

    var body: some View {
        Image("WythinLogo")
            .resizable()
            .renderingMode(.template)
            .scaledToFit()
            .frame(width: size, height: size)
            .foregroundStyle(Theme.accent)
            .rotationEffect(.degrees(spinning ? (spin ? 360 : 0) : pullAngle))
            .opacity(opacity)
            .onChange(of: spinning) { _, now in
                if now {
                    spin = false
                    withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) {
                        spin = true
                    }
                } else {
                    withAnimation(.easeOut(duration: 0.2)) { spin = false }
                }
            }
    }
}

private struct RefreshOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}
