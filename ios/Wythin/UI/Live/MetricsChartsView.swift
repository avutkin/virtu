import Charts
import SwiftUI

// MARK: - Time Window

enum TimeWindow: String, CaseIterable, Identifiable {
    case m30 = "30m"
    case h2  = "2h"
    case h24 = "24h"

    var id: String { rawValue }

    /// Duration in seconds shown from 00:00 of the selected day.
    var seconds: TimeInterval {
        switch self {
        case .m30: return 1_800
        case .h2:  return 7_200
        case .h24: return 86_400
        }
    }

    /// Target ~120 bucketed points per window for good granularity.
    var bucketSeconds: TimeInterval { seconds / 120 }

    var bucketLabel: String {
        let secs = Int(bucketSeconds)
        if secs < 60 { return "\(secs)s avg" }
        return "\(secs / 60) min avg"
    }
}

// MARK: - Reference Line

private struct RefLine {
    let value: Double
    let label: String
    let color: Color
}

// MARK: - Bucketed Data Point

private struct ChartPoint: Identifiable {
    let id:      Int    // bucket key — stable across re-renders
    let date:    Date
    let val:     Double
    let quality: Float? // average signal quality in this bucket (nil = no quality data)
}

// MARK: - Anomaly Band

/// A contiguous time span where raw ticks existed but every tick failed the quality filter —
/// indicating sensor removal or severe contact noise.
private struct AnomalyBand: Identifiable {
    let id:    Int    // index
    let start: Date
    let end:   Date
}

// MARK: - Metric Info

private struct MetricInfo {
    let description: String
    let physical:    String
    let physiology:  String
    let training:    String
    let sensitivity: String
    let levels:      String
    let notes:       String?

    init(_ description: String, physical: String, physiology: String,
         training: String, sensitivity: String, levels: String, notes: String? = nil) {
        self.description = description
        self.physical    = physical
        self.physiology  = physiology
        self.training    = training
        self.sensitivity = sensitivity
        self.levels      = levels
        self.notes       = notes
    }
}

// MARK: - Metric Info Sheet

private struct MetricInfoSheet: View {
    let title: String
    let color: Color
    let info:  MetricInfo
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.bg.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        row("DESCRIPTION",             info.description)
                        row("PHYSICAL MEANING",        info.physical)
                        row("PHYSIOLOGICAL MEANING",   info.physiology)
                        row("TRAINING ASPECTS",        info.training)
                        row("SENSITIVITY",             info.sensitivity)
                        row("REFERENCE LEVELS",        info.levels)
                        if let n = info.notes { row("NOTES", n) }
                    }
                    .padding()
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.bg, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                        .font(Theme.monoBody)
                        .foregroundStyle(color)
                }
            }
        }
    }

    private func row(_ heading: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(heading)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(color)
                .tracking(2)
            Text(body)
                .font(Theme.monoLabel)
                .foregroundStyle(Theme.text.opacity(0.82))
                .lineSpacing(5)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card)
        .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius))
        .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius)
            .strokeBorder(Theme.border, lineWidth: 0.5))
    }
}

// MARK: - Generic Chart Card

private struct MetricChartCard: View {
    let title:         String   // consumer name — shown in white
    let technicalName: String   // technical name — shown in gray after title
    let subtitle:      String   // description — shown on second line
    let yLabel:        String
    let color:      Color
    let windows:    [TimeWindow]
    let refs:       [RefLine]
    let yDomain:    ClosedRange<Double>
    let history:    [MetricsHistoryPoint]   // quality-filtered
    let rawHistory: [MetricsHistoryPoint]   // unfiltered — used for anomaly detection
    let date:       Date
    let smooth:     Bool
    let dynamicY:   Bool
    /// Dim the line where the underlying window is low-confidence (high artifact
    /// rate). Purely visual — no value is changed. Off for the signal-quality
    /// charts themselves (they must stay fully visible when artifacts are high).
    let flagUnreliable: Bool
    let info:       MetricInfo?
    let extract:          (MetricsHistoryPoint) -> Double?
    /// Optional transform applied to each bucket mean after averaging.
    /// Used for metrics like VTI where ln() must be applied AFTER averaging
    /// the underlying linear values (RMSSD), not before.
    let bucketTransform:  ((Double) -> Double)?

    let win: TimeWindow                    // shared window, chosen at the Today header
    @Binding var selectedX: Date?
    @Binding var panOffset: TimeInterval   // seconds the window is panned from its newest edge (≤ 0)
    @State private var showInfo = false

    init(title: String, technicalName: String = "", subtitle: String, yLabel: String,
         color: Color, windows: [TimeWindow], refs: [RefLine],
         yDomain: ClosedRange<Double>,
         win: TimeWindow,
         selectedX: Binding<Date?>,
         panOffset: Binding<TimeInterval>,
         smooth: Bool = false,
         dynamicY: Bool = false,
         flagUnreliable: Bool = true,
         info: MetricInfo? = nil,
         history: [MetricsHistoryPoint],
         rawHistory: [MetricsHistoryPoint] = [],
         date: Date,
         bucketTransform: ((Double) -> Double)? = nil,
         extract: @escaping (MetricsHistoryPoint) -> Double?) {
        self.title           = title
        self.technicalName   = technicalName
        self.subtitle        = subtitle
        self.yLabel          = yLabel
        self.color           = color
        self.windows         = windows
        self.refs            = refs
        self.yDomain         = yDomain
        self.smooth          = smooth
        self.dynamicY        = dynamicY
        self.flagUnreliable  = flagUnreliable
        self.info            = info
        self.history         = history
        self.rawHistory      = rawHistory
        self.date            = date
        self.bucketTransform = bucketTransform
        self.extract         = extract
        self.win   = win
        _selectedX = selectedX
        _panOffset = panOffset
    }

    // MARK: Anomaly bands

    /// Buckets where signal quality is poor (artifact rate > 20%) but data exists.
    /// Rendered as a subtle amber tint, distinct from full anomaly (gray = no signal).
    private var poorQualityBands: [AnomalyBand] {
        guard !history.isEmpty else { return [] }
        let (wStart, wEnd) = windowDates
        let bucket = win.bucketSeconds

        // Accumulate per-bucket quality sums
        var sums:   [Int: Float] = [:]
        var counts: [Int: Int]   = [:]
        for pt in history where pt.timestamp >= wStart && pt.timestamp < wEnd {
            guard let q = pt.signalQuality else { continue }
            let key = Int(pt.timestamp.timeIntervalSince1970 / bucket)
            sums[key]   = (sums[key]   ?? 0) + q
            counts[key] = (counts[key] ?? 0) + 1
        }

        let poorKeys = sums.keys
            .filter { key in
                guard let n = counts[key], n > 0, let s = sums[key] else { return false }
                return (s / Float(n)) < 0.80    // < 80% quality = > 20% artifact rate
            }
            .sorted()

        // Merge consecutive buckets into bands
        var bands: [AnomalyBand] = []
        var prevKey: Int? = nil
        for key in poorKeys {
            let bStart = Date(timeIntervalSince1970: Double(key)     * bucket)
            let bEnd   = Date(timeIntervalSince1970: Double(key + 1) * bucket)
            if let pk = prevKey, pk == key - 1, !bands.isEmpty {
                bands[bands.count - 1] = AnomalyBand(id: bands.last!.id, start: bands.last!.start, end: bEnd)
            } else {
                bands.append(AnomalyBand(id: bands.count, start: bStart, end: bEnd))
            }
            prevKey = key
        }
        return bands
    }

    /// Buckets where raw ticks existed but ALL failed the quality filter.
    /// Adjacent bad buckets are merged into a single continuous span.
    private var anomalyBands: [AnomalyBand] {
        guard !rawHistory.isEmpty else { return [] }
        let (wStart, wEnd) = windowDates
        let bucket = win.bucketSeconds

        var rawCounts: [Int: Int]  = [:]
        var qualCounts: [Int: Int] = [:]

        for pt in rawHistory where pt.timestamp >= wStart && pt.timestamp < wEnd {
            let key = Int(pt.timestamp.timeIntervalSince1970 / bucket)
            rawCounts[key] = (rawCounts[key] ?? 0) + 1
        }
        for pt in history where pt.timestamp >= wStart && pt.timestamp < wEnd {
            let key = Int(pt.timestamp.timeIntervalSince1970 / bucket)
            qualCounts[key] = (qualCounts[key] ?? 0) + 1
        }

        // Flag buckets with ≥2 raw ticks but 0 passing quality (sensor noise/removal).
        let badKeys = rawCounts.keys
            .filter { (rawCounts[$0] ?? 0) >= 2 && (qualCounts[$0] ?? 0) == 0 }
            .sorted()

        // Merge consecutive bucket keys into continuous bands.
        var bands: [AnomalyBand] = []
        var prevKey: Int? = nil
        for key in badKeys {
            let bStart = Date(timeIntervalSince1970: Double(key)     * bucket)
            let bEnd   = Date(timeIntervalSince1970: Double(key + 1) * bucket)
            if let pk = prevKey, pk == key - 1, !bands.isEmpty {
                bands[bands.count - 1] = AnomalyBand(
                    id: bands.last!.id, start: bands.last!.start, end: bEnd)
            } else {
                bands.append(AnomalyBand(id: bands.count, start: bStart, end: bEnd))
            }
            prevKey = key
        }
        return bands
    }

    /// Data bucketing range — always loads the full day so selection-based
    /// panning can reach any point without a data gap.
    private var bucketDates: (start: Date, end: Date) {
        let cal = Calendar.current
        if cal.isDateInToday(date) {
            return (cal.startOfDay(for: date), Date())
        }
        let s = cal.startOfDay(for: date)
        return (s, s.addingTimeInterval(86_400))
    }

    /// Newest edge the window can reach (right edge at pan 0): now for today,
    /// end-of-day for a past day.
    private var anchorEnd: Date {
        let cal = Calendar.current
        return cal.isDateInToday(date)
            ? Date()
            : cal.startOfDay(for: date).addingTimeInterval(86_400)
    }

    /// Allowed pan range in seconds (≤ 0). Panning back is bounded by the
    /// earliest data; you can't pan past the newest edge (0).
    private var panBounds: ClosedRange<TimeInterval> {
        let span = anchorEnd.timeIntervalSince(bucketDates.start) - win.seconds
        return min(0, -span)...0
    }

    /// Visible chart domain. The window is a fixed `win.seconds` wide and is
    /// dragged through time via `panOffset` (0 = newest edge). Selecting a
    /// point only shows an inspection cursor; it no longer moves the window.
    private var windowDates: (start: Date, end: Date) {
        let clamped = min(max(panOffset, panBounds.lowerBound), panBounds.upperBound)
        let end     = anchorEnd.addingTimeInterval(clamped)
        return (end.addingTimeInterval(-win.seconds), end)
    }

    private var windowLabel: String {
        // Panned back from the newest edge → show the window's start time.
        if panOffset < -1 {
            let fmt = DateFormatter()
            fmt.dateFormat = "HH:mm"
            return "\(fmt.string(from: windowDates.start))  ·  \(win.bucketLabel)"
        }
        if Calendar.current.isDateInToday(date) {
            return "last \(win.rawValue)  ·  \(win.bucketLabel)"
        }
        return "00:00 + \(win.rawValue)  ·  \(win.bucketLabel)"
    }

    private var points: [ChartPoint] {
        let (start, end) = bucketDates
        let bucket = win.bucketSeconds
        var sums:    [Int: Double] = [:]
        var counts:  [Int: Int]    = [:]
        var qualSum: [Int: Float]  = [:]
        var qualCnt: [Int: Int]    = [:]
        for pt in history where pt.timestamp >= start && pt.timestamp < end {
            guard let v = extract(pt) else { continue }
            let key = Int(pt.timestamp.timeIntervalSince1970 / bucket)
            sums[key]   = (sums[key]   ?? 0) + v
            counts[key] = (counts[key] ?? 0) + 1
            if let q = pt.signalQuality {
                qualSum[key] = (qualSum[key] ?? 0) + q
                qualCnt[key] = (qualCnt[key] ?? 0) + 1
            }
        }
        return sums.keys
            .sorted()
            .compactMap { key -> ChartPoint? in
                guard let n = counts[key], n > 0 else { return nil }
                let mid = Double(key) * bucket + bucket / 2
                var val = sums[key]! / Double(n)
                if let transform = bucketTransform { val = transform(val) }
                let q: Float? = qualCnt[key].map { (qualSum[key] ?? 0) / Float($0) }
                return ChartPoint(id: key, date: Date(timeIntervalSince1970: mid), val: val, quality: q)
            }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            chartBody
        }
        .padding(12)
        .background(Theme.card)
        .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius))
        .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius)
            .strokeBorder(Theme.border, lineWidth: 0.5))
        .sheet(isPresented: $showInfo) {
            if let i = info {
                MetricInfoSheet(title: title, color: color, info: i)
            }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.text)
                    if !technicalName.isEmpty {
                        Text(technicalName)
                            .font(Theme.monoLabel)
                            .foregroundStyle(Theme.dim)
                    }
                    if info != nil {
                        Button { showInfo = true } label: {
                            Text("?")
                                .font(.system(size: 9, weight: .bold, design: .monospaced))
                                .foregroundStyle(Theme.dim)
                                .frame(width: 15, height: 15)
                                .background(Theme.border)
                                .clipShape(Circle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(Theme.monoLabel)
                        .foregroundStyle(Theme.dim.opacity(0.7))
                }
            }
            Spacer()
        }
    }

    // MARK: Chart

    /// 3-point centred rolling average — keeps date/id of the centre point.
    private func smoothed(_ pts: [ChartPoint]) -> [ChartPoint] {
        guard pts.count >= 3 else { return pts }
        return pts.indices.map { idx in
            let lo  = max(0, idx - 1)
            let hi  = min(pts.count - 1, idx + 1)
            let avg = pts[lo...hi].reduce(0.0) { $0 + $1.val } / Double(hi - lo + 1)
            return ChartPoint(id: pts[idx].id, date: pts[idx].date, val: avg, quality: pts[idx].quality)
        }
    }

    @ViewBuilder
    private var chartBody: some View {
        let raw = points
        let pts = smooth ? smoothed(raw) : raw
        // Auto-fit the y-axis to whatever is actually visible in the current
        // x-window (plus any reference lines) with a little padding, so the
        // whole curve is always in frame rather than clipped by a fixed domain.
        let domain: ClosedRange<Double> = {
            let (wStart, wEnd) = windowDates
            let vals = pts.filter { $0.date >= wStart && $0.date <= wEnd }.map(\.val)
                     + refs.map(\.value)
            guard let lo = vals.min(), let hi = vals.max() else { return yDomain }
            let span = hi - lo
            let pad  = span > 0 ? span * 0.12 : max(abs(lo) * 0.1, 1)
            return (lo - pad)...(hi + pad)
        }()
        if pts.isEmpty {
            noDataPlaceholder
        } else {
            chart(pts, domain: domain)
        }
    }

    private var noDataPlaceholder: some View {
        HStack {
            Spacer()
            VStack(spacing: 6) {
                Image(systemName: "chart.line.uptrend.xyaxis")
                    .font(.title3)
                    .foregroundStyle(Theme.dim.opacity(0.4))
                Text("No data for this window")
                    .font(Theme.monoLabel)
                    .foregroundStyle(Theme.dim)
            }
            Spacer()
        }
        .frame(height: 110)
    }

    /// Line/point colour for a bucket: faded when the window is low-confidence
    /// (artifact rate > 30%), so unreliable stretches read as uncertain without
    /// altering the plotted value. Full colour when flagging is off or quality
    /// is unknown.
    private func markColor(_ pt: ChartPoint) -> Color {
        guard flagUnreliable, let q = pt.quality, q < 0.70 else { return color }
        return color.opacity(0.22)
    }

    private func chart(_ pts: [ChartPoint], domain: ClosedRange<Double>) -> some View {
        let (start, end) = windowDates
        let bands        = anomalyBands
        let poorBands    = poorQualityBands

        return HStack(alignment: .center, spacing: 4) {
            Text(yLabel)
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(Theme.dim)
                .rotationEffect(.degrees(-90))
                .fixedSize()
                .frame(width: 14)

            Chart {
                // Poor quality: amber tint (artifact rate > 20%, signal present but noisy)
                ForEach(poorBands) { band in
                    RectangleMark(
                        xStart: .value("poor start", band.start),
                        xEnd:   .value("poor end",   band.end)
                    )
                    .foregroundStyle(Color.orange.opacity(0.12))
                }
                // No signal: gray (sensor removed or severe contact failure)
                ForEach(bands) { band in
                    RectangleMark(
                        xStart: .value("anomaly start", band.start),
                        xEnd:   .value("anomaly end",   band.end)
                    )
                    .foregroundStyle(Color.gray.opacity(0.22))
                }

                ForEach(pts) { pt in
                    AreaMark(
                        x: .value("time", pt.date),
                        yStart: .value("base", domain.lowerBound),
                        yEnd: .value(yLabel, pt.val)
                    )
                    .foregroundStyle(
                        LinearGradient(
                            colors: [color.opacity(0.22), color.opacity(0.02)],
                            startPoint: .top, endPoint: .bottom
                        )
                    )
                    .interpolationMethod(.catmullRom)
                }

                ForEach(refs.indices, id: \.self) { i in
                    let r = refs[i]
                    RuleMark(y: .value(r.label, r.value))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [6, 4]))
                        .foregroundStyle(r.color.opacity(0.6))
                        .annotation(position: .top, alignment: .trailing, spacing: 2) {
                            Text(r.label)
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(r.color.opacity(0.85))
                                .fixedSize()
                        }
                }

                ForEach(pts) { pt in
                    LineMark(
                        x: .value("time", pt.date),
                        y: .value(yLabel, pt.val)
                    )
                    .foregroundStyle(markColor(pt))
                    .interpolationMethod(.catmullRom)
                    .lineStyle(StrokeStyle(lineWidth: 1.5))
                }

                ForEach(pts) { pt in
                    PointMark(
                        x: .value("time", pt.date),
                        y: .value(yLabel, pt.val)
                    )
                    .foregroundStyle(markColor(pt))
                    .symbolSize(18)
                }
            }
            .chartXScale(domain: start...end)
            .chartYScale(domain: domain)
            // Native selection: scroll-safe (a plain swipe scrolls the list; a
            // press-drag scrubs), and it drives the crosshair via `selectedX`.
            .chartXSelection(value: $selectedX)
            .onChange(of: selectedX) { _, sel in edgePanIfNeeded(sel) }
            .chartOverlay { proxy in chartOverlay(pts: pts, proxy: proxy) }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 4)) {
                    AxisGridLine().foregroundStyle(Theme.border)
                    AxisValueLabel(format: .dateTime.hour().minute())
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(Theme.dim)
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) {
                    AxisGridLine().foregroundStyle(Theme.border)
                    AxisValueLabel()
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(Theme.dim)
                }
            }
            .chartPlotStyle { plot in
                plot.background(Color.black.opacity(0.2))
            }
            .frame(height: 130)
        }
    }

    // MARK: Selection overlay

    /// Purely visual crosshair for the current selection. It never participates
    /// in hit-testing (`allowsHitTesting(false)`), so it can't block the vertical
    /// ScrollView or the chart's own native selection gesture. The selection
    /// itself is driven by `.chartXSelection` (see `chart(_:domain:)`), which is
    /// scroll-safe: a plain swipe scrolls the list, a press-drag scrubs the line.
    private func chartOverlay(pts: [ChartPoint], proxy: ChartProxy) -> some View {
        GeometryReader { geo in
            let pf = proxy.plotFrame.map { geo[$0] } ?? CGRect(origin: .zero, size: geo.size)
            ZStack(alignment: .topLeading) {
                if let selX = selectedX,
                   let nearest = pts.min(by: {
                       abs($0.date.timeIntervalSince(selX)) < abs($1.date.timeIntervalSince(selX))
                   }) {
                    let xPt = (proxy.position(forX: nearest.date) ?? 0) + pf.origin.x
                    let yPt = (proxy.position(forY: nearest.val)  ?? 0) + pf.origin.y
                    Rectangle()
                        .fill(color.opacity(0.35))
                        .frame(width: 1, height: pf.height)
                        .offset(x: xPt - 0.5, y: pf.origin.y)
                    Circle()
                        .fill(color)
                        .frame(width: 8, height: 8)
                        .position(x: xPt, y: yPt)
                    selectionBubble(nearest)
                        .fixedSize()
                        .position(
                            x: min(max(xPt, 44), geo.size.width - 44),
                            y: pf.origin.y + 18
                        )
                }
            }
            .allowsHitTesting(false)
        }
    }

    /// When the selection is dragged to the far edge of the visible window,
    /// nudge the shared window through time so the chart scrolls left/right —
    /// this is the "move the chart with the line" behaviour, and it only happens
    /// while actively scrubbing (selection non-nil), never during a plain scroll.
    private func edgePanIfNeeded(_ selection: Date?) {
        guard let sel = selection else { return }
        let (wStart, wEnd) = windowDates
        let span   = wEnd.timeIntervalSince(wStart)
        guard span > 0 else { return }
        let margin = span * 0.06
        let step   = span * 0.04
        if sel > wEnd.addingTimeInterval(-margin) {
            let next = min(panOffset + step, panBounds.upperBound)
            if next != panOffset { panOffset = next }
        } else if sel < wStart.addingTimeInterval(margin) {
            let next = max(panOffset - step, panBounds.lowerBound)
            if next != panOffset { panOffset = next }
        }
    }

    private func selectionBubble(_ pt: ChartPoint) -> some View {
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm"
        return HStack(spacing: 5) {
            Text(fmt.string(from: pt.date)).foregroundStyle(Theme.dim)
            Text(String(format: "%.1f", pt.val)).foregroundStyle(Theme.text)
        }
        .font(.system(size: 9, design: .monospaced))
        .padding(.horizontal, 6).padding(.vertical, 4)
        .background(Theme.card.opacity(0.96))
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(color.opacity(0.6), lineWidth: 0.5))
    }
}

// MARK: - MetricsChartsView

/// `Equatable` so callers can wrap it in `.equatable()` and skip re-rendering
/// all 9 charts when the underlying history hasn't changed. The comparison is
/// cheap by design — count + newest timestamp + date — never a deep compare of
/// the (up to 43k-element) arrays. Append-only day history means count and the
/// last timestamp fully capture "did the data change".
struct MetricsChartsView: View, Equatable {
    let history:    [MetricsHistoryPoint]   // quality-filtered
    let rawHistory: [MetricsHistoryPoint]   // unfiltered — for anomaly highlighting
    let date:       Date
    let window:     TimeWindow              // shared across all charts, set at the Today header

    static func == (lhs: MetricsChartsView, rhs: MetricsChartsView) -> Bool {
        lhs.date == rhs.date
            && lhs.window == rhs.window
            && lhs.history.count == rhs.history.count
            && lhs.rawHistory.count == rhs.rawHistory.count
            && lhs.history.last?.timestamp == rhs.history.last?.timestamp
    }

    init(history: [MetricsHistoryPoint],
         rawHistory: [MetricsHistoryPoint] = [],
         date: Date,
         window: TimeWindow) {
        self.history    = history
        self.rawHistory = rawHistory
        self.date       = date
        self.window     = window
    }

    @State private var sharedSelectedX: Date? = nil
    @State private var sharedPanOffset: TimeInterval = 0
    @State private var showSignalQuality = false

    var body: some View {
        VStack(spacing: 10) {
            dcCard
            rcmseCard
            pipCard
            dfa1Card
            lfhfCard
            rsaCard
            vtiCard
            sdnnCard
            hrCard

            signalQualitySection
        }
        .onChange(of: date)   { _, _ in resetPan() }
        .onChange(of: window) { _, _ in resetPan() }
    }

    private func resetPan() {
        sharedPanOffset = 0
        sharedSelectedX = nil
    }

    // MARK: Signal-quality section (collapsible)

    /// Signal-integrity diagnostics — share the same timeline as the metric
    /// charts so artifacts correlate with any anomaly. Grouped in a dropdown so
    /// they stay out of the way until you want to inspect signal quality.
    private var signalQualitySection: some View {
        VStack(spacing: 10) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { showSignalQuality.toggle() }
            } label: {
                HStack {
                    Text("SIGNAL QUALITY")
                        .font(Theme.monoLabel)
                        .foregroundStyle(Theme.dim)
                    Text("· artifacts · corrected · ECG")
                        .font(Theme.monoLabel)
                        .foregroundStyle(Theme.dim.opacity(0.6))
                    Spacer()
                    Image(systemName: showSignalQuality ? "chevron.up" : "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.dim)
                }
                .padding(.vertical, 4)
            }
            .buttonStyle(.plain)

            if showSignalQuality {
                signalArtifactsCard
                rrCorrectedCard
                ecgSignalCard
            }
        }
    }

    // MARK: Signal quality / artifacts

    /// Total RR artifact rate = % of beats invalid (dropped) or corrected
    /// (interpolated), from the persisted signalQuality (= 1 − artifactRate).
    private var signalArtifactsCard: some View {
        MetricChartCard(
            title:    "Signal Artifacts",
            technicalName: "RR",
            subtitle: "% of beats invalid or corrected",
            yLabel:   "%",
            color:    Theme.warn,
            windows:  TimeWindow.allCases,
            refs: [
                RefLine(value:  5, label:  "5%  acceptable", color: Theme.coh),
                RefLine(value: 20, label: "20%  poor",       color: Theme.warn),
            ],
            yDomain: 0...25,
            win: window, selectedX: $sharedSelectedX, panOffset: $sharedPanOffset,
            dynamicY: true,
            flagUnreliable: false,
            info: MetricInfo(
                "How much of the heartbeat signal was messy and had to be cleaned up. Think of it as a static meter for your recording — lower means a cleaner, more trustworthy reading.",
                physical:    "Your chest strap catches each heartbeat. If it slips, dries out, or you move a lot, it can miss a beat or catch a false one — and those bad beats show up here.",
                physiology:  "This one isn't about your body — it's about signal quality. When it's high, the other numbers on this screen can't be trusted, because they're built on a shaky signal.",
                training:    "If it creeps up, it's almost always the strap. Dampen the electrode pads, snug the strap just under your chest muscles, and stay still. That drives it back toward 0%.",
                sensitivity: "Reacts instantly to movement or a loose strap — so keep an eye on it live while you're getting set up.",
                levels:      "Great: under 2%\nFine: 2–5%\nShaky: 5–20%\nUnreliable: over 20% (fix the strap)"
            ),
            history: history, rawHistory: rawHistory, date: date
        ) { pt in
            guard let inv = pt.rrInvalidRate else { return nil }
            return Double(inv + (pt.rrCorrectedRate ?? 0)) * 100
        }
    }

    /// Fraction of beats that were interpolated (missed/extra), as opposed to
    /// dropped. Invalid % = Signal Artifacts − RR Corrected.
    private var rrCorrectedCard: some View {
        MetricChartCard(
            title:    "RR Corrected",
            technicalName: "interpolated",
            subtitle: "% of beats replaced (missed / extra beat)",
            yLabel:   "%",
            color:    Theme.rsa,
            windows:  TimeWindow.allCases,
            refs: [],
            yDomain: 0...10,
            win: window, selectedX: $sharedSelectedX, panOffset: $sharedPanOffset,
            dynamicY: true,
            flagUnreliable: false,
            history: history, rawHistory: rawHistory, date: date
        ) { $0.rrCorrectedRate.map { Double($0) * 100 } }
    }

    /// ECG waveform fault from the raw 130 Hz trace: 0% clean, 50% clipping/noise
    /// (movement), 100% lead-off (flatline → bad electrode contact/positioning).
    private var ecgSignalCard: some View {
        MetricChartCard(
            title:    "ECG Signal",
            technicalName: "waveform",
            subtitle: "contact & motion  ·  higher = worse",
            yLabel:   "%",
            color:    Theme.breathe,
            windows:  TimeWindow.allCases,
            refs: [
                RefLine(value:  50, label: "clipping / noise", color: Theme.rsa),
                RefLine(value: 100, label: "lead-off",         color: Theme.warn),
            ],
            yDomain: 0...100,
            win: window, selectedX: $sharedSelectedX, panOffset: $sharedPanOffset,
            flagUnreliable: false,
            info: MetricInfo(
                "A second signal-quality check that looks at the raw heartbeat waveform itself. 0% is clean; 100% means the strap has lost contact with your skin.",
                physical:    "A flat line means an electrode isn't touching your skin. A spiky, maxed-out line means you were moving. Either way, the strap needs attention.",
                physiology:  "This is about the sensor, not you. A strap that's lost contact can look 'quiet' while actually being unusable — that's what this catches.",
                training:    "If it's high, fix the hardware: dampen the electrode pads, tighten and reposition the strap just under your chest muscles, and move less. It falls to 0% once contact is solid.",
                sensitivity: "Reacts fast to contact and movement. Nothing to do with your stress or fitness — purely signal quality.",
                levels:      "Clean: 0%\nMoving / noisy: around 50%\nStrap not connected: 100% (reseat it)"
            ),
            history: history, rawHistory: rawHistory, date: date
        ) { $0.ecgQualityTier.map { Double(2 - $0) / 2 * 100 } }
    }

    // MARK: Heart Rate

    private var hrCard: some View {
        MetricChartCard(
            title:    "Pulse",
            technicalName: "HR",
            subtitle: "Your heart rate",
            yLabel:   "bpm",
            color:    Theme.warn,
            windows:  TimeWindow.allCases,
            refs: [
                RefLine(value: 60,  label: "60 bpm  resting",  color: Theme.coh),
                RefLine(value: 80,  label: "80 bpm  moderate", color: Theme.dim),
                RefLine(value: 100, label: "100 bpm  elevated", color: Theme.warn),
            ],
            yDomain: 40...160,
            win: window, selectedX: $sharedSelectedX, panOffset: $sharedPanOffset,
            dynamicY: true,
            info: MetricInfo(
                "Your heart rate — how many times your heart beats per minute, averaged over the time window you're viewing.",
                physical:    "Each beat pushes blood around your body. At rest, a lower number usually means your heart is working efficiently.",
                physiology:  "Your heart speeds up under stress, caffeine, or effort, and slows when you're calm and rested. Over time, a lower resting pulse is a good sign of fitness and recovery.",
                training:    "Check it first thing after waking as a recovery gauge. If it's 5+ beats above your usual, your body may still be recovering, run-down, or fighting something off. Regular cardio lowers it over weeks.",
                sensitivity: "Changes within seconds — posture, stress, caffeine, a warm room, or a big breath all move it. For a clean baseline, measure at rest.",
                levels:      "Very fit: under 50 bpm\nExcellent: 50–60 bpm\nGood: 60–70 bpm\nAverage: 70–80 bpm\nHigh for rest: over 80 bpm (measured fully at rest)"
            ),
            history: history, rawHistory: rawHistory, date: date
        ) { $0.meanBPM.map(Double.init) }
    }

    // MARK: RR Interval History

    private var rrHistoryCard: some View {
        MetricChartCard(
            title:    "RR Interval",
            subtitle: "mean beat-to-beat  ·  60000 / BPM",
            yLabel:   "ms",
            color:    Theme.hrv,
            windows:  TimeWindow.allCases,
            refs: [
                RefLine(value:  600, label: "100 bpm", color: Theme.warn),
                RefLine(value:  750, label:  "80 bpm", color: Theme.dim),
                RefLine(value: 1000, label:  "60 bpm", color: Theme.coh),
            ],
            yDomain: 350...1500,
            win: window, selectedX: $sharedSelectedX, panOffset: $sharedPanOffset,
            info: MetricInfo(
                "The exact gap between two heartbeats, in milliseconds. It's just your pulse viewed up close — one beat at a time instead of an average.",
                physical:    "Your heart never beats like a metronome; the tiny gaps between beats constantly shift. Those shifts are the raw material behind every other number here.",
                physiology:  "Longer, freely-changing gaps at rest are a sign of a calm, adaptable nervous system. Short, rigid, unchanging gaps point to stress or strain.",
                training:    "A great live signal while breathing: watch the gap stretch on each exhale and shrink on each inhale. Big, smooth waves mean you've found your rhythm.",
                sensitivity: "Changes with every breath and every shift in posture or stress. Very live.",
                levels:      "60 bpm: about 1000 ms\n70 bpm: about 860 ms\n80 bpm: about 750 ms\nVery fit (50 bpm): about 1200 ms"
            ),
            history: history, rawHistory: rawHistory, date: date
        ) {
            guard let bpm = $0.meanBPM, bpm > 0 else { return nil }
            return Double(60_000.0 / bpm)
        }
    }

    // MARK: I:E Ratio

    private var ieRatioCard: some View {
        MetricChartCard(
            title:   "Breathing I:E Ratio",
            subtitle: "exhale / inhale",
            yLabel:  "I:E ratio",
            color:   Theme.accent,
            windows: TimeWindow.allCases,
            refs: [
                RefLine(value: 1.0, label: "balanced  1.0",       color: Theme.warn),
                RefLine(value: 1.5, label: "mild vagal  ≥ 1.5",   color: Theme.coh),
                RefLine(value: 2.0, label: "strong vagal  ≥ 2.0", color: Theme.coh),
            ],
            yDomain: 0...2.8,
            win: window, selectedX: $sharedSelectedX, panOffset: $sharedPanOffset,
            info: MetricInfo(
                "How long your exhale is compared with your inhale. A longer out-breath is the simplest lever you have for calming your body down.",
                physical:    "Breathing in gently speeds the heart; breathing out slows it. So the longer your exhale, the more you engage your body's natural brake.",
                physiology:  "When your exhale is longer than your inhale, your nervous system shifts toward 'rest and recover' — heart rate drops and stress eases.",
                training:    "Aim for an exhale about 1.5–2× your inhale. Try 4 seconds in and 6 out (that's 1.5), or 4 in and 8 out (that's 2.0). Ease into it — don't strain for a long exhale.",
                sensitivity: "Fully in your control — even a half-second longer exhale shows up here right away.",
                levels:      "Even:            1.0 (in = out)\nCalming:         1.5 or more\nDeeply calming:  2.0 or more\nSweet spot:      2.0–2.5"
            ),
            history: history, rawHistory: rawHistory, date: date
        ) { $0.ieRatio.map(Double.init) }
    }

    // MARK: VTI

    private var vtiCard: some View {
        MetricChartCard(
            title:   "Calm Power",
            technicalName: "VTI",
            subtitle: "Total strength of your recovery drive",
            yLabel:  "VTI",
            color:   Theme.breathe,
            windows: TimeWindow.allCases,
            refs: [
                RefLine(value: 3.0, label: "low (≈20ms)",   color: Theme.warn),
                RefLine(value: 3.9, label: "mod (≈50ms)",   color: Theme.rsa),
                RefLine(value: 4.6, label: "good (≈100ms)", color: Theme.coh),
            ],
            yDomain: 2.0...5.5,
            win: window, selectedX: $sharedSelectedX, panOffset: $sharedPanOffset,
            info: MetricInfo(
                "The overall strength of your body's calm-and-recover system, on a steady, easy-to-track scale. Higher means a stronger ability to relax and bounce back.",
                physical:    "It's built from how much your heartbeat naturally varies from beat to beat — a hallmark of a relaxed, well-regulated body — put on a smooth scale that's easy to compare day to day.",
                physiology:  "A higher number means your 'brakes' are strong: you handle stress better, recover faster, and tend to sleep and feel better. A low number is a nudge to rest and downshift.",
                training:    "Check it each morning after a few minutes of rest as a recovery score. A sharp drop means you're not fully recovered. It climbs over months with regular cardio and slow-breathing practice.",
                sensitivity: "Fairly steady — it smooths out moment-to-moment noise, so it's reliable for day-to-day comparison.",
                levels:      "Low:      under 3.0\nModerate: 3.0–3.9\nGood:     3.9–4.6\nHigh:     4.6+\nElite:    5.0+\nHigher is better."
            ),
            history: history, rawHistory: rawHistory, date: date,
            bucketTransform: { v in v > 0 ? log(v) : 0 }
        ) { $0.rmssd.map(Double.init) }
    }

    // MARK: RSA

    private var rsaCard: some View {
        MetricChartCard(
            title:   "Conscious Breathing",
            technicalName: "RSA",
            subtitle: "How your breath moves your heart rate",
            yLabel:  "ms",
            color:   Theme.rsa,
            windows: TimeWindow.allCases,
            refs: [
                RefLine(value: 10, label: "low",    color: Theme.warn),
                RefLine(value: 30, label: "mod",    color: Theme.rsa),
                RefLine(value: 60, label: "good",   color: Theme.coh),
                RefLine(value: 90, label: "strong", color: Theme.coh),
            ],
            yDomain: 0...120,
            win: window, selectedX: $sharedSelectedX, panOffset: $sharedPanOffset,
            smooth:  true,
            info: MetricInfo(
                "How much your heart rate rises and falls with each breath. It's the live signature of your breathing actually reaching your nervous system.",
                physical:    "Breathe in and your heart speeds up a little; breathe out and it slows. This measures the size of that wave — bigger waves mean your breath is having a bigger calming effect.",
                physiology:  "It's the most direct real-time sign that your calming system is engaged. Big, steady waves are linked to better emotional control and faster recovery.",
                training:    "This is your main feedback signal during slow breathing. Around 6 breaths per minute most people see it peak. Watch it grow as you settle into a rhythm — and it strengthens over weeks of practice.",
                sensitivity: "Very live — it drops quickly if your breathing gets fast, shallow, or irregular.",
                levels:      "Low:       under 10 ms\nModerate:  10–30 ms\nGood:      30–60 ms\nStrong:    60–90 ms\nExcellent: 90+ ms",
                notes:       "Brief dips to near zero are normal — for example right after a breath-hold or a sudden change in posture."
            ),
            history: history, rawHistory: rawHistory, date: date
        ) { $0.rsaMs.map(Double.init) }
    }

    // MARK: SDNN

    private var sdnnCard: some View {
        MetricChartCard(
            title:   "Energy Reserve",
            technicalName: "SDNN",
            subtitle: "Your overall heart-rate variability",
            yLabel:  "ms",
            color:   Theme.hrv,
            windows: TimeWindow.allCases,
            refs: [
                RefLine(value: 20,  label: "unhealthy", color: Theme.warn),
                RefLine(value: 50,  label: "moderate",  color: Theme.rsa),
                RefLine(value: 100, label: "healthy",   color: Theme.coh),
            ],
            yDomain: 0...160,
            win: window, selectedX: $sharedSelectedX, panOffset: $sharedPanOffset,
            info: MetricInfo(
                "Your overall reserve of adaptability — the big-picture measure of how much your heart rate flexes. More flex means more capacity to handle whatever the day brings.",
                physical:    "It rolls up every kind of variation in your heartbeat, from fast breathing-driven changes to slow background ones, into a single overall number.",
                physiology:  "A bigger reserve means a flexible, resilient system that adapts well to stress. A small one points to a body that's running rigid and taxed.",
                training:    "Builds with fitness, good sleep, and lower stress. It doesn't move much within a single session — compare it day to day or week to week.",
                sensitivity: "Steady within a session; most useful as a multi-day trend.",
                levels:      "Low:           under 20 ms\nBelow average: 20–50 ms\nModerate:      50–100 ms\nStrong:        100+ ms\nAthletic:      130+ ms"
            ),
            history: history, rawHistory: rawHistory, date: date
        ) { $0.sdnn.map(Double.init) }
    }

    // MARK: pNN50

    private var pnn50Card: some View {
        MetricChartCard(
            title:   "pNN50",
            subtitle: "% successive RR diff > 50 ms",
            yLabel:  "%",
            color:   Theme.accent,
            windows: TimeWindow.allCases,
            refs: [
                RefLine(value: 3,  label: "low",    color: Theme.warn),
                RefLine(value: 8,  label: "normal", color: Theme.rsa),
                RefLine(value: 20, label: "good",   color: Theme.coh),
            ],
            yDomain: 0...80,
            win: window, selectedX: $sharedSelectedX, panOffset: $sharedPanOffset,
            info: MetricInfo(
                "How often your heartbeat makes a noticeable jump from one beat to the next — a simple, robust sign of an active calming system.",
                physical:    "It counts the share of back-to-back beats where the timing changed by more than a blink (50 ms). More of these little jumps means a livelier, more relaxed rhythm.",
                physiology:  "Mostly reflects your calming (vagal) system. It rises during slow breathing, relaxation, and sleep, and falls under stress or exertion.",
                training:    "A nice, noise-resistant companion to your other calm metrics. It should rise during slow-breathing sessions and improve over weeks of practice.",
                sensitivity: "Responsive — moves quickly with your breathing and with sudden stress.",
                levels:      "Very low:  under 3%\nLow:       3–8%\nNormal:    8–20%\nGood:      20–35%\nExcellent: 35%+"
            ),
            history: history, rawHistory: rawHistory, date: date
        ) { $0.pnn50.map(Double.init) }
    }

    // MARK: Deceleration Capacity

    private var dcCard: some View {
        MetricChartCard(
            title:    "Vagal Tone",
            technicalName: "DC",
            subtitle: "Your relaxation and recovery capacity",
            yLabel:   "ms",
            color:    Color(red: 0.4, green: 0.7, blue: 1.0),
            windows:  TimeWindow.allCases,
            refs: [
                RefLine(value: 4.5,  label: "Reduced",    color: Theme.warn),
                RefLine(value: 6.1,  label: "Developing", color: Color(hex: "#FCD34D")),
                RefLine(value: 10.0, label: "Strong",     color: Theme.coh),
            ],
            yDomain: 0...20,
            win: window, selectedX: $sharedSelectedX, panOffset: $sharedPanOffset,
            smooth: true,
            dynamicY: true,
            info: MetricInfo(
                "How strongly your body can hit the brakes and relax — your heart's ability to slow itself down, which is the engine behind calming, recovering, and winding down.",
                physical:    "Every time your heart eases off slightly between beats, that's your rest-and-recover system tapping the brake. This tracks how big and consistent those braking moments are.",
                physiology:  "A strong brake means you bounce back faster after stress, fall asleep more easily, and stay calmer under pressure. A weak one is a sign you're stuck in 'go mode' too often.",
                training:    "Slow breathing, good sleep, and regular cardio build it over weeks. Try a few minutes of paced breathing daily and watch it climb.",
                sensitivity: "Changes slowly — read it as a trend over days and weeks. It needs a couple of minutes of clean signal to show a value.",
                levels:      "Building: under 4.5\nTypical:  around 6\nStrong:   10+\nHigher = more calm-and-recover capacity.\n(Short readings aren't directly comparable to overnight ones.)"
            ),
            history: history, rawHistory: rawHistory, date: date
        ) { $0.dc.map(Double.init) }
    }

    // MARK: RCMSE

    private var rcmseCard: some View {
        MetricChartCard(
            title:    "Adaptive Capacity",
            technicalName: "RCMSE",
            subtitle: "How flexibly your system adapts across timescales",
            yLabel:   "entropy",
            color:    Color(red: 0.8, green: 0.5, blue: 1.0),
            windows:  TimeWindow.allCases,
            refs: [
                RefLine(value: 1.0, label: "Depleted",   color: Theme.warn),
                RefLine(value: 1.5, label: "Recharging", color: Theme.dim),
                RefLine(value: 2.0, label: "Thriving",   color: Theme.coh),
            ],
            yDomain: 0.5...3.0,
            win: window, selectedX: $sharedSelectedX, panOffset: $sharedPanOffset,
            smooth: true,
            dynamicY: false,
            info: MetricInfo(
                "How rich and flexible your heart rhythm is across many timescales at once. A more intricate, less repetitive pattern is a sign of a healthy, adaptable system.",
                physical:    "A healthy heartbeat isn't perfectly regular — it has layered, ever-shifting patterns. This measures how much of that healthy complexity is present.",
                physiology:  "Higher complexity goes with resilience and good health. When the body is stressed, exhausted, or aging poorly, the rhythm gets simpler and more repetitive — and this drops.",
                training:    "Builds slowly with steady aerobic training and breathing practice — think weeks to months. Best read as a trend, not a single reading.",
                sensitivity: "Fairly steady — needs a few minutes of continuous wear and is far more useful as a trend than a one-off number.",
                levels:      "Stressed / depleted: under 1.2\nTypical healthy:     about 1.4–2.2\nHighly trained:      2.0+\nHigher is better."
            ),
            history: history, rawHistory: rawHistory, date: date
        ) { $0.rcmse.map(Double.init) }
    }

    // MARK: PIP (HR Fragmentation)

    private var pipCard: some View {
        MetricChartCard(
            title:    "Inner Noise",
            technicalName: "PIP",
            subtitle: "Beat-to-beat fragmentation — rises with stress and fatigue",
            yLabel:   "%",
            color:    Color(red: 1.0, green: 0.7, blue: 0.3),
            windows:  TimeWindow.allCases,
            refs: [
                RefLine(value: 40.0, label: "low fragmentation", color: Theme.coh),
                RefLine(value: 55.0, label: "healthy median",    color: Theme.dim),
                RefLine(value: 70.0, label: "high fragmentation",color: Theme.warn),
            ],
            yDomain: 20...90,
            win: window, selectedX: $sharedSelectedX, panOffset: $sharedPanOffset,
            smooth: true,
            dynamicY: false,
            info: MetricInfo(
                "How choppy and jittery your heartbeat pattern is. Some choppiness is normal; a lot of it tends to show up with stress, fatigue, or poor recovery. Lower is calmer.",
                physical:    "It measures how often your heart keeps flip-flopping between speeding up and slowing down beat to beat. More constant flip-flopping means a more fragmented, less settled rhythm.",
                physiology:  "A moderate amount is completely normal. High choppiness points to a nervous system that isn't coordinating smoothly — often from stress, poor sleep, or being run-down.",
                training:    "You don't train this directly, but it eases as your overall health improves. Chronic stress and short sleep push it up; fitness and recovery bring it down over weeks.",
                sensitivity: "Moderately responsive to your state, and steadier than the complexity metrics on short recordings.",
                levels:      "Calm:     under 45%\nTypical:  around 55%\nElevated: over 70%\nLower is calmer."
            ),
            history: history, rawHistory: rawHistory, date: date
        ) { $0.pip.map(Double.init) }
    }

    // MARK: DFA α1

    private var dfa1Card: some View {
        MetricChartCard(
            title:   "Harmony",
            technicalName: "DFA α1",
            subtitle: "How ordered vs random your heart rhythm is",
            yLabel:  "α1",
            color:   Theme.ulf,
            windows: TimeWindow.allCases,
            refs: [
                RefLine(value: 0.75, label: "Drifting",    color: Theme.warn),
                RefLine(value: 1.0,  label: "In Harmony",  color: Theme.coh),
                RefLine(value: 1.5,  label: "Strained",    color: Theme.warn),
            ],
            yDomain: 0.5...1.8,
            win: window, selectedX: $sharedSelectedX, panOffset: $sharedPanOffset,
            smooth: true,
            dynamicY: false,
            info: MetricInfo(
                "How balanced your heart rhythm is between too-random and too-rigid. Right in the middle — around 1.0 — is the sweet spot of a healthy, adaptable heart.",
                physical:    "Your heartbeat has a natural 'texture.' Too random (low) or too locked-in (high) both signal strain; a balanced middle is ideal.",
                physiology:  "The middle zone reflects a flexible, well-regulated system. Drifting low is linked to fatigue and poor recovery; running high can show over-strain.",
                training:    "Improves with regular cardio and breathing practice — track it over weeks. Heavy exertion or high stress can pull it out of the ideal band for a while.",
                sensitivity: "Slow and steady — it needs about 2 minutes of wear to appear and settles over 3–5 minutes.",
                levels:      "Drifting (too random): under 0.75\nIn balance:            0.75–1.5  (aim here)\nIdeal:                 around 1.0\nStrained (too rigid):  over 1.5",
                notes:       "Shows '—' until about 2 minutes of data have been collected. That's just how long the math needs — not a sensor problem."
            ),
            history: history, rawHistory: rawHistory, date: date
        ) { $0.dfa1.map(Double.init) }
    }

    // MARK: Stress Balance (breathing-robust arousal)

    private var lfhfCard: some View {
        MetricChartCard(
            title:   "Stress Balance",
            technicalName: "LF/HF",
            subtitle: "Balance of activation vs rest",
            yLabel:  "%",
            color:   Theme.rsa,
            windows: TimeWindow.allCases,
            refs: [
                RefLine(value: 45, label: "parasympathetic",  color: Theme.coh),
                RefLine(value: 50, label: "flow · balanced",  color: Theme.accent),
                RefLine(value: 65, label: "sympathetic",      color: Theme.warn),
            ],
            yDomain: 0...100,
            win: window, selectedX: $sharedSelectedX, panOffset: $sharedPanOffset,
            info: MetricInfo(
                "A simple 0–100 stress dial: higher means more revved-up and alert, lower means calmer. It's built so that slow, calming breathing actually reads as calmer.",
                physical:    "It's based on how relaxed your heartbeat is moment to moment — a calm, variable heartbeat reads low, a tense, flat one reads high.",
                physiology:  "Most stress scores get fooled by slow breathing and spike as if you were stressed. This one is designed to avoid that trap, so paced breathing correctly shows up as calm.",
                training:    "Watch it fall during slow breathing and recovery, and rise with stress or exercise. A good breathing session should trend it downward.",
                sensitivity: "Moderately responsive — and, unlike older stress ratios, it isn't thrown off by how slowly you breathe.",
                levels:      "Calm:      under 45%\nBalanced:  45–65%\nRevved-up: over 65%\nLower is calmer.",
                notes:       "An old-school 'stress ratio' isn't shown here because it misleads during breathwork — this dial is the app's stress signal."
            ),
            history: history, rawHistory: rawHistory, date: date
        ) { pt in
            AutonomicCompute.balance(rmssd: pt.rmssd, lf: pt.lfPower, hf: pt.hfPower,
                                     breathBPM: pt.breathBPM, meanBPM: pt.meanBPM,
                                     baselineRmssd: nil).map { Double($0.sns) * 100 }
        }
    }

    // MARK: VLF

    private var vlfCard: some View {
        MetricChartCard(
            title:   "VLF Power",
            subtitle: "very low frequency  ·  0.003–0.04 Hz",
            yLabel:  "ms²",
            color:   Theme.breathe,
            windows: TimeWindow.allCases,
            refs: [],
            yDomain: 0...50,
            win: window, selectedX: $sharedSelectedX, panOffset: $sharedPanOffset,
            dynamicY: true,
            info: MetricInfo(
                "A slow, background rhythm in your heartbeat that plays out over minutes. It reflects deep, long-running regulation rather than anything you feel moment to moment.",
                physical:    "These are very slow waves — cycles lasting from about half a minute to five minutes — tied to things like your body's internal chemistry and temperature control, not your breathing.",
                physiology:  "Healthy long-term regulation shows up as solid activity here. Persistently low levels can reflect a run-down, poorly-regulated system. Think of it as a background health marker, not a moment-to-moment one.",
                training:    "Not something you change in the moment. It improves over months with consistent exercise, good sleep, and lower chronic stress. Needs 5+ minute recordings to mean anything.",
                sensitivity: "Slow-moving — needs steady, clean recordings of at least 5 minutes.",
                levels:      "These values depend on recording length, so compare only your own trends under similar conditions — not against fixed targets.",
                notes:       "Needs about 5 minutes of data to compute. It reads near zero in short sessions — that's normal, not an error."
            ),
            history: history, rawHistory: rawHistory, date: date
        ) { $0.vlfPower.map(Double.init) }
    }

    // MARK: ULF

    private var ulfCard: some View {
        MetricChartCard(
            title:   "ULF Power",
            subtitle: "ultra low frequency  ·  < 0.003 Hz  ·  10 min+ sessions",
            yLabel:  "ms²",
            color:   Theme.dim,
            windows: TimeWindow.allCases,
            refs: [],
            yDomain: 0...50,
            win: window, selectedX: $sharedSelectedX, panOffset: $sharedPanOffset,
            dynamicY: true,
            info: MetricInfo(
                "The very slowest rhythm in your heartbeat, unfolding over many minutes to hours. It only appears in long recordings and reflects deep daily cycles like your body clock and hormones.",
                physical:    "These are ultra-slow waves — one cycle can take from five minutes to a whole day — linked to your sleep-wake cycle, body temperature, and hormone rhythms.",
                physiology:  "Over full-day recordings this is a powerful long-term health signal, capturing daily rhythms no short measurement can. It isn't meaningful for a quick session.",
                training:    "Only shows up in long or overnight recordings. If you wear the sensor for hours, its trend over weeks reflects improving sleep and daily-rhythm health.",
                sensitivity: "Very slow — needs at least ~10 minutes of continuous wear to appear, and hours for a stable read.",
                levels:      "Meaningful values come from long (24-hour) recordings; short-session numbers here aren't comparable to those.",
                notes:       "This chart fills in only after about 10 minutes of continuous recording — a limitation of the math, not the sensor."
            ),
            history: history, rawHistory: rawHistory, date: date
        ) { $0.ulfPower.map(Double.init) }
    }

    // MARK: Coherence Score

    private var coherenceCard: some View {
        MetricChartCard(
            title:   "Coherence Score",
            subtitle: "RR–breathing coupling",
            yLabel:  "score",
            color:   Theme.coh,
            windows: TimeWindow.allCases,
            refs: [
                RefLine(value: 0.30, label: "low",       color: Theme.warn),
                RefLine(value: 0.60, label: "good",      color: Theme.coh),
                RefLine(value: 0.80, label: "excellent", color: Theme.coh),
            ],
            yDomain: 0...1,
            win: window, selectedX: $sharedSelectedX, panOffset: $sharedPanOffset,
            info: MetricInfo(
                "How well your heartbeat and your breathing are moving in sync, from 0 to 1. High sync is the 'in the zone' state of a good breathing session.",
                physical:    "When your heart rate rises and falls in lockstep with each breath, they're in sync. A score near 1 means they're perfectly in step; near 0 means they're unrelated.",
                physiology:  "High sync is the sweet spot where slow breathing pays off most — the largest, smoothest heart-rate waves and the strongest relaxation response.",
                training:    "This is your main target during slow breathing. It jumps up when you find your natural pace (around 6 breaths/min for most people). Try to hold it above 0.6 for most of a session, and notice how fast you can get there — that improves with practice.",
                sensitivity: "Very live — it responds within a couple of breaths to changes in your pace, depth, or steadiness.",
                levels:      "Low:       under 0.30\nModerate:  0.30–0.60\nGood:      0.60–0.80\nExcellent: 0.80+\nPeak:      0.90+  (rare — perfect sync)"
            ),
            history: history, rawHistory: rawHistory, date: date
        ) { $0.coherence.map(Double.init) }
    }
}

// MARK: - Preview

#Preview("Metrics Charts") {
    ScrollView {
        MetricsChartsView(history: mockHistory(), date: Date(), window: .h24)
            .padding(.horizontal)
    }
    .background(Theme.bg)
}

private func mockHistory() -> [MetricsHistoryPoint] {
    let start = Calendar.current.startOfDay(for: Date())
    return (0..<1800).map { i in
        let t = start.addingTimeInterval(Double(i) * 2)
        let phase = Float(i) / 60
        return MetricsHistoryPoint(from: MetricsTick(
            timestamp:      t,
            meanBPM:        Float(65 + 8 * sin(phase)),
            sdnn:           Float(45 + 10 * sin(phase * 0.7)),
            rmssd:          Float(38 + 20 * sin(phase * 0.5)),
            pnn50:          Float(22 + 8 * sin(phase * 0.3)),
            vti:            Float(3.6 + 0.8 * sin(phase * 0.5)),
            ulfPower:       Float(30 + 15 * sin(phase * 0.1)),
            vlfPower:       Float(600 + 300 * sin(phase * 0.4)),
            lfPower:        Float(800 + 400 * sin(phase * 0.8)),
            hfPower:        Float(1200 + 600 * sin(phase * 0.5)),
            lfHF:           Float(0.7 + 0.3 * sin(phase)),
            rsaMs:          Float(45 + 25 * sin(phase * 0.6)),
            rsaIdx:         Float(1.4 + 0.4 * sin(phase * 0.6)),
            breathBPM:      Float(6.0 + 0.5 * sin(phase * 0.2)),
            breathHz:       Float(0.10 + 0.008 * sin(phase * 0.2)),
            regularity:     Float(0.8 + 0.1 * sin(phase * 0.4)),
            coherenceScore: Float(0.7 + 0.2 * sin(phase * 0.3)),
            cbi:            Float(0.75 + 0.1 * sin(phase * 0.3)),
            dfa1:           Float(1.0 + 0.15 * sin(phase * 0.15)),
            signalQuality:  Float(0.95 + 0.05 * sin(phase * 0.2)),
            ecgQuality:     nil,
            rcmse:          Float(1.4 + 0.2 * sin(phase * 0.12)),
            pip:            Float(54.0 + 6.0 * sin(phase * 0.09)),
            ials:           Float(0.51 + 0.04 * sin(phase * 0.11)),
            dc:             Float(7.0 + 1.5 * sin(phase * 0.08)),
            breathPhases: BreathPhases(
                breaths:    [],
                meanIE:     Float(1.4 + 0.4 * sin(phase * 0.4)),
                meanInhale: 4.0, meanExhale: 5.5, meanDepth: 0.5,
                nBreaths:   10, filtered: [], filteredT: []
            ),
            psdFreqs: nil, psdValues: nil,
            coherenceFreqs: nil, coherenceValues: nil
        ))
    }
}
