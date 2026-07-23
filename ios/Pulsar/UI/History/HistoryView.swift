import SwiftUI
import SwiftData
import Charts

// MARK: - HistoryView (Track)

struct HistoryView: View {
    @Query(sort: \HRVSession.startedAt,   order: .reverse) var sessions:      [HRVSession]
    @Query(sort: \TrainSession.startedAt, order: .reverse) var trainSessions: [TrainSession]
    @Environment(AppEnvironment.self)     var env
    @Environment(\.modelContext)          var ctx

    @State private var window:          TrackWindow    = .d7
    @State private var tab:             TrackTab       = .hrv
    @State private var summaries:       [DailySummary] = []
    @State private var isLoading:       Bool           = false
    @State private var sharedSelectedDay: Date?        = nil

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.bg.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 12) {

                        // ── Tab picker ─────────────────────────────────────
                        tabPicker

                        if tab == .hrv {
                            // ── Live snapshot rings ────────────────────────
                            VStack(alignment: .leading, spacing: 6) {
                                Text("NOW")
                                    .font(Theme.monoLabel)
                                    .foregroundStyle(Theme.dim)
                                    .padding(.horizontal)
                                HRVRingGrid(tick: env.latestTick)
                                    .cardStyle()
                                    .padding(.horizontal)
                            }

                            // ── Window picker ──────────────────────────────
                            windowPicker

                            // ── Daily trend charts ─────────────────────────
                            if isLoading {
                                ProgressView()
                                    .tint(Theme.accent)
                                    .padding(.vertical, 40)
                            } else if summaries.isEmpty {
                                Text("No data for this period")
                                    .font(Theme.monoLabel)
                                    .foregroundStyle(Theme.dim)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 40)
                            } else {
                                ForEach(TrackMetric.allCases) { metric in
                                    TrackDailyChartCard(
                                        metric:       metric,
                                        summaries:    summaries,
                                        window:       window,
                                        selectedDay:  $sharedSelectedDay
                                    )
                                    .padding(.horizontal)
                                }
                            }

                            // ── HRV session list ───────────────────────────
                            sessionSection
                        }

                        if tab == .train {
                            trainSection
                        }

                        Spacer(minLength: 20)
                    }
                    .padding(.top, 8)
                }
            }
            .navigationTitle("TRACK")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.bg, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
        }
        .task(id: window) { await loadDailySummaries() }
    }

    // MARK: - Sub-views

    private var tabPicker: some View {
        HStack(spacing: 4) {
            ForEach(TrackTab.allCases) { t in
                Button(t.rawValue) {
                    withAnimation(.easeInOut(duration: 0.15)) { tab = t }
                }
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(t == tab ? Color.black : Theme.dim)
                .padding(.horizontal, 14)
                .padding(.vertical, 5)
                .background(t == tab ? Theme.accent : Color.clear)
                .clipShape(Capsule())
            }
            Spacer()
        }
        .padding(.horizontal)
    }

    private var windowPicker: some View {
        HStack(spacing: 4) {
            ForEach(TrackWindow.allCases) { w in
                Button(w.rawValue) {
                    withAnimation(.easeInOut(duration: 0.15)) { window = w }
                }
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(w == window ? Color.black : Theme.dim)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(w == window ? Theme.accent : Color.clear)
                .clipShape(Capsule())
            }
            Spacer()
        }
        .padding(.horizontal)
    }

    @ViewBuilder
    private var sessionSection: some View {
        let filtered = filteredSessions
        if !filtered.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("HRV SESSIONS")
                    .font(Theme.monoLabel)
                    .foregroundStyle(Theme.dim)
                    .padding(.horizontal)
                VStack(spacing: 0) {
                    ForEach(filtered) { session in
                        SessionRow(session: session)
                        if session.id != filtered.last?.id {
                            Divider().background(Theme.border).padding(.horizontal, 12)
                        }
                    }
                }
                .cardStyle()
                .padding(.horizontal)
            }
        }
    }

    @ViewBuilder
    private var trainSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("TRAIN SESSIONS")
                .font(Theme.monoLabel)
                .foregroundStyle(Theme.dim)
                .padding(.horizontal)
            if trainSessions.isEmpty {
                Text("No training sessions yet")
                    .font(Theme.monoLabel)
                    .foregroundStyle(Theme.dim)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 20)
                    .cardStyle()
                    .padding(.horizontal)
            } else {
                VStack(spacing: 0) {
                    ForEach(trainSessions) { session in
                        TrainSessionRow(session: session)
                        if session.id != trainSessions.last?.id {
                            Divider().background(Theme.border).padding(.horizontal, 12)
                        }
                    }
                }
                .cardStyle()
                .padding(.horizontal)
            }
        }
    }

    // MARK: - Data

    private var filteredSessions: [HRVSession] {
        let cutoff = Calendar.current.date(byAdding: .day, value: -window.days, to: .now)!
        return sessions.filter { $0.startedAt >= cutoff }
    }

    private func loadDailySummaries() async {
        isLoading = true
        let cal   = Calendar.current
        let today = cal.startOfDay(for: .now)
        let start = cal.date(byAdding: .day, value: -(window.days - 1), to: today)!
        let end   = cal.date(byAdding: .day, value: 1, to: today)!

        var desc = FetchDescriptor<HRVSample>(
            predicate: #Predicate { $0.timestamp >= start && $0.timestamp < end },
            sortBy:    [SortDescriptor(\.timestamp)]
        )
        desc.fetchLimit = 200_000

        // SwiftData fetch must stay on MainActor; convert to value types immediately.
        let pts = MetricsQualityFilter.filter(
            ((try? ctx.fetch(desc)) ?? []).map { MetricsHistoryPoint(from: $0) }
        )

        // Filter → group → average is CPU-heavy (up to 200k points on 90D).
        // Detach so the MainActor isn't blocked for 500ms–2s on large data sets.
        let result: [DailySummary] = await Task.detached(priority: .userInitiated) {
            var grouped: [Date: [MetricsHistoryPoint]] = [:]
            for pt in pts {
                let day = cal.startOfDay(for: pt.timestamp)
                grouped[day, default: []].append(pt)
            }
            // Require at least 5 minutes of quality ticks (150 × 2 s) for a day to appear.
            return grouped
                .compactMap { day, dayPts -> DailySummary? in
                    guard dayPts.count >= 150 else { return nil }
                    return DailySummary(id: day, from: dayPts)
                }
                .sorted { $0.id < $1.id }
        }.value

        summaries = result
        isLoading = false
    }
}

// MARK: - Enums

enum TrackTab: String, CaseIterable, Identifiable {
    case hrv = "HRV", train = "TRAIN"
    var id: String { rawValue }
}

enum TrackWindow: String, CaseIterable, Identifiable {
    case d7 = "7D", d30 = "30D", d90 = "90D"
    var id: String { rawValue }
    var days: Int {
        switch self { case .d7: 7; case .d30: 30; case .d90: 90 }
    }
}

// MARK: - DailySummary

private struct DailySummary: Identifiable {
    let id:        Date   // start-of-day
    let hr:        Double?
    let sdnn:      Double?
    let vti:       Double?
    let rsa:       Double?
    let coherence: Double?
    let lfhf:      Double?
    let pnn50:     Double?
    let ulf:       Double?

    init(id: Date, from pts: [MetricsHistoryPoint]) {
        self.id        = id
        func avg(_ vals: [Double]) -> Double? { vals.isEmpty ? nil : vals.reduce(0,+) / Double(vals.count) }
        hr        = avg(pts.compactMap { $0.meanBPM.map(Double.init) })
        sdnn      = avg(pts.compactMap { $0.sdnn.map(Double.init) })
        vti       = avg(pts.compactMap { $0.vti.map(Double.init) })
        rsa       = avg(pts.compactMap { $0.rsaMs.map(Double.init) })
        coherence = avg(pts.compactMap { $0.coherence.map(Double.init) })
        lfhf      = avg(pts.compactMap { $0.lfHF.map(Double.init) })
        pnn50     = avg(pts.compactMap { $0.pnn50.map(Double.init) })
        ulf       = avg(pts.compactMap { $0.ulfPower.map(Double.init) })
    }
}

// MARK: - TrackMetric

private enum TrackMetric: String, CaseIterable, Identifiable {
    case hr, sdnn, vti, rsa, coherence, lfhf, pnn50, ulf
    var id: String { rawValue }

    func extract(_ s: DailySummary) -> Double? {
        switch self {
        case .hr:        return s.hr
        case .sdnn:      return s.sdnn
        case .vti:       return s.vti
        case .rsa:       return s.rsa
        case .coherence: return s.coherence
        case .lfhf:      return s.lfhf
        case .pnn50:     return s.pnn50
        case .ulf:       return s.ulf
        }
    }

    var title: String {
        switch self {
        case .hr:        return "Heart Rate"
        case .sdnn:      return "SDNN"
        case .vti:       return "Vagal Tone (VTI)"
        case .rsa:       return "RSA"
        case .coherence: return "Coherence"
        case .lfhf:      return "LF/HF Ratio"
        case .pnn50:     return "pNN50"
        case .ulf:       return "ULF Power"
        }
    }

    var unit: String {
        switch self {
        case .hr:        return "bpm"
        case .sdnn:      return "ms"
        case .vti:       return ""
        case .rsa:       return "ms"
        case .coherence: return ""
        case .lfhf:      return ""
        case .pnn50:     return "%"
        case .ulf:       return "ms²"
        }
    }

    var color: Color {
        switch self {
        case .hr:        return Theme.warn
        case .sdnn:      return Theme.hrv
        case .vti:       return Theme.breathe
        case .rsa:       return Theme.rsa
        case .coherence: return Theme.coh
        case .lfhf:      return Theme.breathe
        case .pnn50:     return Theme.hrv
        case .ulf:       return Theme.ulf
        }
    }

    var yDomain: ClosedRange<Double> {
        switch self {
        case .hr:        return 40...130
        case .sdnn:      return 0...160
        case .vti:       return 2.0...5.5
        case .rsa:       return 0...120
        case .coherence: return 0...1
        case .lfhf:      return 0...4
        case .pnn50:     return 0...60
        case .ulf:       return 0...600
        }
    }

    /// Reference lines: (value, short label)
    var refs: [(value: Double, label: String)] {
        switch self {
        case .hr:        return [(60, "60"), (80, "80")]
        case .sdnn:      return [(50, "50ms"), (100, "100ms")]
        case .vti:       return [(3.0, "low"), (3.9, "mod"), (4.6, "good")]
        case .rsa:       return [(30, "mod"), (60, "good")]
        case .coherence: return [(0.4, "0.4"), (0.7, "0.7")]
        case .lfhf:      return [(1.0, "bal"), (2.0, "sym")]
        case .pnn50:     return [(10, "10%"), (25, "25%")]
        case .ulf:       return [(100, "100"), (300, "300")]
        }
    }
}

// MARK: - TrackDailyChartCard

private struct TrackDailyChartCard: View {
    let metric:    TrackMetric
    let summaries: [DailySummary]
    let window:    TrackWindow

    @Binding var selectedDay: Date?

    init(metric: TrackMetric, summaries: [DailySummary],
         window: TrackWindow, selectedDay: Binding<Date?>) {
        self.metric    = metric
        self.summaries = summaries
        self.window    = window
        _selectedDay   = selectedDay
    }

    private struct Pt: Identifiable {
        let id:  Date   // start-of-day
        let val: Double
    }

    private var points: [Pt] {
        summaries.compactMap { s in
            metric.extract(s).map { Pt(id: s.id, val: $0) }
        }
    }

    /// Full x-axis domain for the current window, even if some days have no data.
    private var xDomain: ClosedRange<Date> {
        let cal   = Calendar.current
        let today = cal.startOfDay(for: .now)
        let start = cal.date(byAdding: .day, value: -(window.days - 1), to: today)!
        let end   = cal.date(byAdding: .day, value: 1, to: today)!
        return start...end
    }

    /// Value to show in the header — nearest point to the selected day, or most recent.
    private var displayPoint: Pt? {
        if let sel = selectedDay {
            return points.min(by: {
                abs($0.id.timeIntervalSince(sel)) < abs($1.id.timeIntervalSince(sel))
            })
        }
        return points.last
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {

            // ── Header ──────────────────────────────────────────────
            HStack(spacing: 6) {
                Text(metric.title.uppercased())
                    .font(Theme.monoLabel)
                    .foregroundStyle(Theme.text)
                if !metric.unit.isEmpty {
                    Text(metric.unit)
                        .font(Theme.monoLabel)
                        .foregroundStyle(Theme.dim)
                }
                Spacer()
                if let dp = displayPoint {
                    if selectedDay != nil {
                        // Show selected date label
                        Text(dp.id, format: .dateTime.weekday(.abbreviated).month(.abbreviated).day())
                            .font(Theme.monoLabel)
                            .foregroundStyle(Theme.dim)
                    }
                    Text(String(format: valFormat, dp.val))
                        .font(Theme.monoBody)
                        .foregroundStyle(metric.color)
                }
            }

            // ── Chart ────────────────────────────────────────────────
            Chart {
                // Reference lines
                ForEach(metric.refs, id: \.value) { ref in
                    RuleMark(y: .value("ref", ref.value))
                        .lineStyle(StrokeStyle(lineWidth: 0.5, dash: [3, 3]))
                        .foregroundStyle(Theme.dim.opacity(0.5))
                        .annotation(position: .trailing, alignment: .leading) {
                            Text(ref.label)
                                .font(.system(size: 8, design: .monospaced))
                                .foregroundStyle(Theme.dim.opacity(0.7))
                        }
                }

                // Data
                ForEach(points) { pt in
                    LineMark(
                        x: .value("Date", pt.id, unit: .day),
                        y: .value(metric.title, pt.val)
                    )
                    .foregroundStyle(metric.color.opacity(0.8))
                    .interpolationMethod(.catmullRom)

                    PointMark(
                        x: .value("Date", pt.id, unit: .day),
                        y: .value(metric.title, pt.val)
                    )
                    .foregroundStyle(
                        isSelected(pt) ? metric.color : metric.color.opacity(0.7)
                    )
                    .symbolSize(isSelected(pt) ? 60 : 28)
                }
            }
            .frame(height: 120)
            .chartXScale(domain: xDomain)
            .chartYScale(domain: metric.yDomain)
            .chartXSelection(value: $selectedDay)
            .chartOverlay { proxy in selectionOverlay(proxy: proxy) }
            .chartXAxis {
                AxisMarks(values: xAxisValues) { _ in
                    AxisGridLine()
                        .foregroundStyle(Theme.border)
                    AxisValueLabel(format: xFormat)
                        .foregroundStyle(Theme.dim)
                        .font(.system(size: 9, design: .monospaced))
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading) { v in
                    AxisGridLine()
                        .foregroundStyle(Theme.border)
                    AxisValueLabel {
                        Text(yLabel(v))
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(Theme.dim)
                    }
                }
            }
            .chartPlotStyle { plot in plot.background(Color.black.opacity(0.2)) }
        }
        .cardStyle()
    }

    // MARK: Selection overlay

    @ViewBuilder
    private func selectionOverlay(proxy: ChartProxy) -> some View {
        if let sel = selectedDay,
           let nearest = points.min(by: {
               abs($0.id.timeIntervalSince(sel)) < abs($1.id.timeIntervalSince(sel))
           }) {
            GeometryReader { geo in
                let pf  = proxy.plotFrame.map { geo[$0] } ?? CGRect(origin: .zero, size: geo.size)
                let xPt = (proxy.position(forX: nearest.id) ?? 0) + pf.origin.x
                let yPt = (proxy.position(forY: nearest.val) ?? 0) + pf.origin.y
                ZStack(alignment: .topLeading) {
                    // Vertical crosshair line
                    Rectangle()
                        .fill(metric.color.opacity(0.4))
                        .frame(width: 1, height: pf.height)
                        .offset(x: xPt - 0.5, y: pf.origin.y)
                    // Value dot
                    Circle()
                        .fill(metric.color)
                        .frame(width: 8, height: 8)
                        .position(x: xPt, y: yPt)
                }
            }
        }
    }

    private func isSelected(_ pt: Pt) -> Bool {
        guard let sel = selectedDay else { return false }
        return Calendar.current.isDate(pt.id, inSameDayAs: sel)
    }

    // MARK: Helpers

    private var valFormat: String {
        switch metric {
        case .coherence, .lfhf, .vti: return "%.2f"
        case .pnn50:                   return "%.1f%%"
        default:                       return "%.0f"
        }
    }

    private var xAxisValues: AxisMarkValues {
        switch window {
        case .d7:  return .stride(by: .day, count: 1)
        case .d30: return .stride(by: .day, count: 5)
        case .d90: return .stride(by: .day, count: 14)
        }
    }

    private var xFormat: Date.FormatStyle {
        switch window {
        case .d7:  return .dateTime.weekday(.abbreviated).day()   // "Mon 7"
        case .d30: return .dateTime.month(.abbreviated).day()     // "Jan 7"
        case .d90: return .dateTime.month(.abbreviated).day()     // "Jan 7"
        }
    }

    private func yLabel(_ v: AxisValue) -> String {
        guard let d = v.as(Double.self) else { return "" }
        switch metric {
        case .coherence, .lfhf, .vti: return String(format: "%.1f", d)
        default:                       return String(format: "%.0f", d)
        }
    }
}

// MARK: - Session Rows

private struct SessionRow: View {
    let session: HRVSession

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(session.startedAt, format: .dateTime.month().day().hour().minute())
                    .font(Theme.monoBody)
                    .foregroundStyle(Theme.text)
                Text(durationString)
                    .font(Theme.monoLabel)
                    .foregroundStyle(Theme.dim)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                if let rsa = session.avgRSAms {
                    Text(String(format: "RSA %.1f ms", rsa))
                        .font(Theme.monoLabel)
                        .foregroundStyle(Theme.rsa)
                }
                if let coh = session.avgCoherence {
                    Text(String(format: "COH %.2f", coh))
                        .font(Theme.monoLabel)
                        .foregroundStyle(Theme.coh)
                }
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 4)
    }

    private var durationString: String {
        let d = Int(session.duration)
        return String(format: "%d:%02d", d / 60, d % 60)
    }
}

private struct TrainSessionRow: View {
    let session: TrainSession

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(session.startedAt, format: .dateTime.month().day().hour().minute())
                    .font(Theme.monoBody)
                    .foregroundStyle(Theme.text)
                Spacer()
                Text(session.durationString)
                    .font(Theme.monoLabel)
                    .foregroundStyle(Theme.dim)
            }

            HStack(spacing: 16) {
                Label("\(session.setCount) sets", systemImage: "bolt")
                    .font(Theme.monoLabel)
                    .foregroundStyle(Theme.warn)
                if session.avgRecoveryMin > 0 {
                    Label(String(format: "%.1f min avg recovery", session.avgRecoveryMin),
                          systemImage: "arrow.down.heart")
                        .font(Theme.monoLabel)
                        .foregroundStyle(Theme.rsa)
                }
            }

            HStack(spacing: 16) {
                Text(String(format: "SNS %.2f", session.avgSNSIndex))
                    .font(Theme.monoLabel)
                    .foregroundStyle(Theme.warn.opacity(0.8))
                Text(String(format: "PNS %.2f", session.avgPNSIndex))
                    .font(Theme.monoLabel)
                    .foregroundStyle(Theme.accent.opacity(0.8))
            }

            let recs = session.recoveryMinArray
            if !recs.isEmpty {
                Text("Sets: " + recs.map { String(format: "%.1f", $0) }.joined(separator: " → ") + " min")
                    .font(Theme.monoLabel)
                    .foregroundStyle(Theme.dim)
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 4)
    }
}
