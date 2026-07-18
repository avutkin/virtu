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
    let info:       MetricInfo?
    let extract:          (MetricsHistoryPoint) -> Double?
    /// Optional transform applied to each bucket mean after averaging.
    /// Used for metrics like VTI where ln() must be applied AFTER averaging
    /// the underlying linear values (RMSSD), not before.
    let bucketTransform:  ((Double) -> Double)?

    @Binding var win: TimeWindow
    @Binding var selectedX: Date?
    @State private var showInfo = false

    init(title: String, technicalName: String = "", subtitle: String, yLabel: String,
         color: Color, windows: [TimeWindow], refs: [RefLine],
         yDomain: ClosedRange<Double>,
         win: Binding<TimeWindow>,
         selectedX: Binding<Date?>,
         smooth: Bool = false,
         dynamicY: Bool = false,
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
        self.info            = info
        self.history         = history
        self.rawHistory      = rawHistory
        self.date            = date
        self.bucketTransform = bucketTransform
        self.extract         = extract
        _win       = win
        _selectedX = selectedX
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

    /// Visible chart domain. When a point is selected all charts align to
    /// show a window centred on that time. Otherwise right edge = now (today)
    /// or start-of-day anchor (past days).
    private var windowDates: (start: Date, end: Date) {
        let cal     = Calendar.current
        let isToday = cal.isDateInToday(date)

        if let sel = selectedX {
            // Centre the window on the selected time, clamped so end ≤ now.
            let half   = win.seconds / 2
            let maxEnd = isToday ? Date() : cal.startOfDay(for: date).addingTimeInterval(86_400)
            let end    = min(sel.addingTimeInterval(half), maxEnd)
            return (end.addingTimeInterval(-win.seconds), end)
        }

        if isToday {
            let e = Date()
            return (e.addingTimeInterval(-win.seconds), e)
        }
        let s = cal.startOfDay(for: date)
        return (s, s.addingTimeInterval(win.seconds))
    }

    private var windowLabel: String {
        if selectedX != nil {
            return "aligned to selection  ·  \(win.bucketLabel)"
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
                Text(windowLabel)
                    .font(Theme.monoLabel)
                    .foregroundStyle(Theme.dim)
            }
            Spacer()
            windowPicker
        }
    }

    private var windowPicker: some View {
        HStack(spacing: 3) {
            ForEach(windows) { w in
                Button(w.rawValue) {
                    withAnimation(.easeInOut(duration: 0.15)) { win = w }
                }
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(w == win ? Color.black : Theme.dim)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(w == win ? color : Color.clear)
                .clipShape(Capsule())
            }
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
        let domain: ClosedRange<Double> = {
            guard dynamicY, let maxVal = pts.map(\.val).max(), maxVal > 0 else { return yDomain }
            return yDomain.lowerBound...(maxVal * 1.3)
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
                    .foregroundStyle(color)
                    .interpolationMethod(.catmullRom)
                    .lineStyle(StrokeStyle(lineWidth: 1.5))
                }

                ForEach(pts) { pt in
                    PointMark(
                        x: .value("time", pt.date),
                        y: .value(yLabel, pt.val)
                    )
                    .foregroundStyle(color)
                    .symbolSize(18)
                }
            }
            .chartXScale(domain: start...end)
            .chartYScale(domain: domain)
            .chartXSelection(value: $selectedX)
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

    @ViewBuilder
    private func chartOverlay(pts: [ChartPoint], proxy: ChartProxy) -> some View {
        if let selX = selectedX,
           let nearest = pts.min(by: {
               abs($0.date.timeIntervalSince(selX)) < abs($1.date.timeIntervalSince(selX))
           }) {
            GeometryReader { geo in
                let pf  = proxy.plotFrame.map { geo[$0] } ?? CGRect(origin: .zero, size: geo.size)
                let xPt = (proxy.position(forX: nearest.date) ?? 0) + pf.origin.x
                let yPt = (proxy.position(forY: nearest.val)  ?? 0) + pf.origin.y
                ZStack(alignment: .topLeading) {
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

struct MetricsChartsView: View {
    let history:    [MetricsHistoryPoint]   // quality-filtered
    let rawHistory: [MetricsHistoryPoint]   // unfiltered — for anomaly highlighting
    let date:       Date

    init(history: [MetricsHistoryPoint],
         rawHistory: [MetricsHistoryPoint] = [],
         date: Date) {
        self.history    = history
        self.rawHistory = rawHistory
        self.date       = date
    }

    @State private var sharedWin: TimeWindow = .h24
    @State private var sharedSelectedX: Date? = nil

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
        }
    }

    // MARK: Heart Rate

    private var hrCard: some View {
        MetricChartCard(
            title:    "Pulse",
            technicalName: "Heart Rate",
            subtitle: "average BPM",
            yLabel:   "bpm",
            color:    Theme.warn,
            windows:  TimeWindow.allCases,
            refs: [
                RefLine(value: 60,  label: "60 bpm  resting",  color: Theme.coh),
                RefLine(value: 80,  label: "80 bpm  moderate", color: Theme.dim),
                RefLine(value: 100, label: "100 bpm  elevated", color: Theme.warn),
            ],
            yDomain: 40...160,
            win: $sharedWin, selectedX: $sharedSelectedX,
            dynamicY: true,
            info: MetricInfo(
                "Average heart rate over the selected time window, expressed in beats per minute.",
                physical:    "Number of complete cardiac cycles per minute. Each beat is driven by an electrical impulse from the sinoatrial node.",
                physiology:  "Resting HR reflects the balance between sympathetic drive (accelerates) and parasympathetic (vagal) tone (slows). Lower resting HR generally indicates better cardiovascular fitness and stronger vagal tone.",
                training:    "Track resting HR on wake-up as a recovery marker. A rise of 5+ bpm above baseline signals incomplete recovery, illness, or overtraining. HR drops predictably with aerobic fitness gains over weeks.",
                sensitivity: "Very high. Responds within seconds to posture, stress, caffeine, temperature, and breathing pattern.",
                levels:      "Athletic: <50 bpm\nExcellent: 50–60 bpm\nGood: 60–70 bpm\nAverage: 70–80 bpm\nElevated: >80 bpm (at complete rest)"
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
            win: $sharedWin, selectedX: $sharedSelectedX,
            info: MetricInfo(
                "Time between consecutive heartbeats in milliseconds. Calculated as 60,000 ÷ BPM.",
                physical:    "The R-R interval is the gap between successive QRS complexes on an ECG. It varies continuously due to autonomic nervous system modulation — this variability is the basis of HRV analysis.",
                physiology:  "Longer, more variable RR intervals at rest reflect stronger parasympathetic (vagal) control. Short, rigid RR intervals indicate sympathetic dominance. The fluctuation pattern encodes ANS state more richly than BPM alone.",
                training:    "Use as a real-time feedback signal during breathing practice. The RR interval should lengthen visibly on each exhale and shorten on inhale (RSA). Smooth, large oscillations confirm resonance.",
                sensitivity: "Very high. Responds beat-to-beat to breathing phase, posture, and stress.",
                levels:      "At 60 BPM: ~1000 ms\nAt 70 BPM: ~857 ms\nAt 80 BPM: ~750 ms\nAt 50 BPM (athlete): ~1200 ms"
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
            win: $sharedWin, selectedX: $sharedSelectedX,
            info: MetricInfo(
                "Ratio of exhale duration to inhale duration, averaged across breaths in the window.",
                physical:    "Inhalation expands the thorax, lowering intrathoracic pressure and briefly inhibiting vagal outflow. Exhalation reverses this, activating the vagal brake and slowing HR. A longer exhale therefore produces stronger parasympathetic activation.",
                physiology:  "An I:E ratio above 1.0 means each exhale is longer than each inhale. This asymmetry shifts autonomic balance toward parasympathetic dominance, lowering HR, increasing HRV, and reducing cortisol.",
                training:    "During resonance breathing sessions aim for a ratio of 1.5–2.0. A 4-second inhale with 6-second exhale gives 1.5; 4:8 gives 2.0. Practice extending the exhale gradually — forcing it too early reduces depth and coherence.",
                sensitivity: "Directly under voluntary control. Even a 0.5-second change in exhale length shifts the ratio measurably.",
                levels:      "Neutral:     1.0 (equal)\nMild vagal:  ≥ 1.5\nStrong vagal: ≥ 2.0\nTherapeutic: 2.0–2.5"
            ),
            history: history, rawHistory: rawHistory, date: date
        ) { $0.ieRatio.map(Double.init) }
    }

    // MARK: VTI

    private var vtiCard: some View {
        MetricChartCard(
            title:   "Calm Power",
            technicalName: "VTI · Vagal Tone Index",
            subtitle: "ln(RMSSD)  — higher = more parasympathetic",
            yLabel:  "VTI",
            color:   Theme.breathe,
            windows: TimeWindow.allCases,
            refs: [
                RefLine(value: 3.0, label: "low (≈20ms)",   color: Theme.warn),
                RefLine(value: 3.9, label: "mod (≈50ms)",   color: Theme.rsa),
                RefLine(value: 4.6, label: "good (≈100ms)", color: Theme.coh),
            ],
            yDomain: 2.0...5.5,
            win: $sharedWin, selectedX: $sharedSelectedX,
            info: MetricInfo(
                "Natural logarithm of RMSSD — a normalised, scale-independent index of parasympathetic tone.",
                physical:    "RMSSD is the root mean square of successive RR differences — the most validated time-domain HRV measure for vagal activity. Taking ln() compresses its skewed distribution into a roughly normal one, making it more suitable for tracking and comparison.",
                physiology:  "VTI directly reflects the activity of cardiac vagal efferents. High VTI means the vagus nerve is actively modulating heart rhythm — associated with better stress resilience, faster recovery, lower inflammatory markers, and reduced arrhythmia risk.",
                training:    "Track VTI on waking daily (after 5 min rest) as a recovery score. Acute drops of >0.5 suggest incomplete recovery. Sustained improvement over months reflects aerobic adaptation and ANS remodelling from resonance breathing practice.",
                sensitivity: "Moderate. Averages over the window; smooths out breath-by-breath noise. Stable enough for day-to-day comparison.",
                levels:      "Low:      < 3.0  (~20 ms RMSSD)\nModerate: 3.0–3.9 (~20–50 ms)\nGood:     3.9–4.6 (~50–100 ms)\nHigh:     > 4.6  (>100 ms)\nElite:    > 5.0  (>150 ms)"
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
            subtitle: "",
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
            win: $sharedWin, selectedX: $sharedSelectedX,
            smooth:  true,
            info: MetricInfo(
                "Amplitude of the heart rate oscillation driven specifically by breathing — the peak-to-trough RR swing at your current breathing frequency.",
                physical:    "As you inhale, sympathetic inhibition briefly accelerates the heart; as you exhale, the vagus slows it. RSA measures this oscillation in milliseconds. It is computed from the power in the HF band (0.15–0.40 Hz) or, when breathing rate is detected, via a narrow bandpass filter centred on your breathing frequency.",
                physiology:  "RSA is the most direct real-time measure of vagal efficiency. Large RSA means the vagus is powerfully coupling with every breath. It is linked to emotional regulation, baroreflex sensitivity, and anti-inflammatory signalling via the cholinergic pathway.",
                training:    "RSA is the key biofeedback signal during resonance breathing. At resonance frequency (~6 br/min) RSA reaches its individual maximum. Watch it grow during a session as synchrony deepens. Chronic RSA increases with regular slow-breathing practice over weeks.",
                sensitivity: "Extremely high. Drops sharply if breathing deviates from resonance, becomes irregular, or exits the HF band (below ~9 br/min).",
                levels:      "Low:       < 10 ms\nModerate:  10–30 ms\nGood:      30–60 ms\nStrong:    60–90 ms\nExcellent: > 90 ms",
                notes:       "RSA is smoothed with a 3-point rolling average to reduce tick-to-tick noise. Values near zero for brief periods are physiologically normal — e.g. after a breath-hold or sudden posture change."
            ),
            history: history, rawHistory: rawHistory, date: date
        ) { $0.rsaMs.map(Double.init) }
    }

    // MARK: SDNN

    private var sdnnCard: some View {
        MetricChartCard(
            title:   "Energy Reserve",
            technicalName: "SDNN",
            subtitle: "overall HRV",
            yLabel:  "ms",
            color:   Theme.hrv,
            windows: TimeWindow.allCases,
            refs: [
                RefLine(value: 20,  label: "unhealthy", color: Theme.warn),
                RefLine(value: 50,  label: "moderate",  color: Theme.rsa),
                RefLine(value: 100, label: "healthy",   color: Theme.coh),
            ],
            yDomain: 0...160,
            win: $sharedWin, selectedX: $sharedSelectedX,
            info: MetricInfo(
                "Standard deviation of all RR intervals in the window — the broadest measure of total heart rate variability.",
                physical:    "SDNN captures variability across all time scales simultaneously: ultra-slow hormonal rhythms, baroreceptor loops (LF), and respiratory modulation (HF). It reflects the total power of the ANS's influence on heart rhythm.",
                physiology:  "The single most validated predictor of all-cause cardiovascular mortality in clinical studies. Low SDNN indicates a rigid, poorly regulated heart — associated with stress, inflammation, and post-infarction risk. High SDNN reflects rich, multi-scale autonomic regulation.",
                training:    "Improves with aerobic fitness, sleep quality, and stress reduction. Use as a long-term adaptation marker. Does not change substantially within a single session — compare it day-to-day or week-to-week.",
                sensitivity: "Low within a session (averages across all frequencies). High for multi-day trends.",
                levels:      "Unhealthy: < 20 ms\nLow:       20–50 ms\nModerate:  50–100 ms\nHealthy:   > 100 ms\nAthletic:  > 130 ms"
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
            win: $sharedWin, selectedX: $sharedSelectedX,
            info: MetricInfo(
                "Percentage of consecutive RR interval pairs that differ by more than 50 ms.",
                physical:    "Each pair of adjacent beats is checked: if |RR[n+1] − RR[n]| > 50 ms, it counts. pNN50 is the proportion of such pairs. It is highly correlated with HF power and captures rapid, breath-linked parasympathetic fluctuations.",
                physiology:  "Predominantly reflects high-frequency vagal modulation. Low pNN50 indicates sympathetic dominance or ANS rigidity. Rises during parasympathetic activation (slow breathing, relaxation, sleep) and falls during stress and exercise.",
                training:    "A useful simplicity: no Fourier transform required, making it robust to noise and non-stationarities. Track alongside RMSSD/VTI. Should rise during resonance breathing sessions and improve over weeks of regular practice.",
                sensitivity: "High. Very reactive to breathing pattern changes and acute stress.",
                levels:      "Very low:  < 3 %\nLow:       3–8 %\nNormal:    8–20 %\nGood:      20–35 %\nExcellent: > 35 %"
            ),
            history: history, rawHistory: rawHistory, date: date
        ) { $0.pnn50.map(Double.init) }
    }

    // MARK: Deceleration Capacity

    private var dcCard: some View {
        MetricChartCard(
            title:    "Calm Reserve",
            technicalName: "DC · Deceleration Capacity",
            subtitle: "PRSA vagal modulation  ·  L=64",
            yLabel:   "ms",
            color:    Color(red: 0.4, green: 0.7, blue: 1.0),
            windows:  TimeWindow.allCases,
            refs: [
                RefLine(value: 4.5,  label: "high risk (24h)",  color: Theme.warn),
                RefLine(value: 6.1,  label: "5-min median",     color: Theme.dim),
                RefLine(value: 10.0, label: "healthy",          color: Theme.coh),
            ],
            yDomain: 0...20,
            win: $sharedWin, selectedX: $sharedSelectedX,
            smooth: true,
            dynamicY: true,
            info: MetricInfo(
                "Deceleration Capacity quantifies the heart's ability to slow down via vagal activation, computed by Phase-Rectified Signal Averaging (PRSA) over all deceleration anchor points.",
                physical:    "The PRSA algorithm aligns all beat-to-beat decelerations (beats longer than their predecessor) and averages the surrounding 128-beat window. DC is the Haar wavelet coefficient at the anchor — a measure of how consistently the heart decelerates.",
                physiology:  "DC reflects vagally-mediated deceleration reserve. High DC = strong parasympathetic brake. Low DC indicates diminished vagal control, seen in heart failure, post-MI patients, and autonomic neuropathy. The original Bauer 2006 Lancet study showed DC < 4.5 ms predicted mortality in post-MI patients better than LVEF.",
                training:    "Improves with aerobic fitness, HRV biofeedback, and recovery. Responds to training over weeks. Note: the 4.5 ms risk threshold is from 24-hour recordings; 5-minute thresholds are not yet standardized.",
                sensitivity: "Moderate. Requires ~150+ clean RR intervals. Most meaningful over 5-minute segments. Shows '—' until enough deceleration anchors accumulate.",
                levels:      "5-min healthy median: ~6.1 ms (IQR 3.9–8.5)\nPost-MI high-risk: < 4.5 ms (24-hour norm)\nHealthy trained: > 10 ms\nNote: 5-min and 24-hour values are not directly comparable"
            ),
            history: history, rawHistory: rawHistory, date: date
        ) { $0.dc.map(Double.init) }
    }

    // MARK: RCMSE

    private var rcmseCard: some View {
        MetricChartCard(
            title:    "Adaptive Power",
            technicalName: "RCMSE",
            subtitle: "",
            yLabel:   "entropy",
            color:    Color(red: 0.8, green: 0.5, blue: 1.0),
            windows:  TimeWindow.allCases,
            refs: [
                RefLine(value: 1.0, label: "Burnout",    color: Theme.warn),
                RefLine(value: 1.5, label: "Recovering", color: Theme.dim),
                RefLine(value: 2.0, label: "Thriving",   color: Theme.coh),
            ],
            yDomain: 0.5...3.0,
            win: $sharedWin, selectedX: $sharedSelectedX,
            smooth: true,
            dynamicY: false,
            info: MetricInfo(
                "Refined Composite Multiscale Sample Entropy measures the complexity and irregularity of RR interval dynamics across multiple time scales (Wu et al. 2014). Higher values indicate richer, more adaptive cardiac regulation.",
                physical:    "At each scale τ, the RR series is coarse-grained into τ sub-series. Template-match counts are pooled across all sub-series before computing a single log-ratio — this is the 'refined composite' innovation that avoids undefined entropy at coarse scales.",
                physiology:  "RCMSE captures fractal-like, multi-scale complexity of cardiac regulation. Healthy hearts show moderate to high entropy across scales (the 1/f complexity signature). Pathological conditions (heart failure, severe stress, aging) produce entropy curves that peak at small scales then collapse — loss of multi-scale complexity.",
                training:    "Improves slowly with sustained aerobic training and HRV biofeedback. Changes over weeks to months. Requires ≥100 RR intervals for any estimate; ≥200 for reliable values. Parameters: m=2, r=0.15×SD, scales 1–10.",
                sensitivity: "Low to moderate. Stable over 3-5 minutes of continuous wear. More informative as a trend than a single reading.",
                levels:      "Healthy young adults (scale 1–5 mean): ~1.4–2.2\nStressed/diseased: < 1.2\nHighly trained: > 2.0\nNote: no universal normative table exists for 5-min HRV"
            ),
            history: history, rawHistory: rawHistory, date: date
        ) { $0.rcmse.map(Double.init) }
    }

    // MARK: PIP (HR Fragmentation)

    private var pipCard: some View {
        MetricChartCard(
            title:    "Inner Noise",
            technicalName: "HR Fragmentation · PIP",
            subtitle: "% inflection points  ·  Costa 2017",
            yLabel:   "%",
            color:    Color(red: 1.0, green: 0.7, blue: 0.3),
            windows:  TimeWindow.allCases,
            refs: [
                RefLine(value: 40.0, label: "low fragmentation", color: Theme.coh),
                RefLine(value: 55.0, label: "healthy median",    color: Theme.dim),
                RefLine(value: 70.0, label: "high fragmentation",color: Theme.warn),
            ],
            yDomain: 20...90,
            win: $sharedWin, selectedX: $sharedSelectedX,
            smooth: true,
            dynamicY: false,
            info: MetricInfo(
                "HR Fragmentation (PIP) is the percentage of RR intervals that are inflection points — local direction reversals in the heartbeat sequence (Costa et al. 2017). High PIP indicates a fragmented, less coordinated rhythm.",
                physical:    "An inflection point occurs when consecutive beat-to-beat differences switch sign (the heart alternates between speeding up and slowing down). PIP = inflection count / (N-2). A perfectly regular alternating pattern gives PIP = 100%; a purely monotonic series gives PIP = 0%.",
                physiology:  "Low-level fragmentation (~55%) is normal — the heart's regulatory loops produce natural short-term direction reversals. High fragmentation (>70%) indicates pathological disruption of autonomic coordination, seen in atrial fibrillation, heart failure, and severe autonomic neuropathy. May reflect disrupted sympatho-vagal oscillation.",
                training:    "PIP is not directly trainable but reflects underlying autonomic health. Chronic stress and sleep deprivation increase fragmentation. Decreases with improved cardiovascular fitness and HRV biofeedback over weeks. Requires ≥30 RR intervals.",
                sensitivity: "Moderate-high. Responds relatively quickly to state changes. More stable than entropy metrics for short recordings.",
                levels:      "24-hour healthy median: 55.4% (IQR 52–59%)\nHigh fragmentation: > 70%\nLow fragmentation: < 45%\nNote: 5-min norms not yet established; 24-hour values used as reference",
                notes:       "IALS (Inverse Average Segment Length) is also computed internally and reflects the same fragmentation phenomenon from a segment-length perspective."
            ),
            history: history, rawHistory: rawHistory, date: date
        ) { $0.pip.map(Double.init) }
    }

    // MARK: DFA α1

    private var dfa1Card: some View {
        MetricChartCard(
            title:   "Harmony",
            technicalName: "DFA α1",
            subtitle: "short-term fractal scaling  ·  scales 4–16 beats",
            yLabel:  "α1",
            color:   Theme.ulf,
            windows: TimeWindow.allCases,
            refs: [
                RefLine(value: 0.75, label: "Drifting",    color: Theme.warn),
                RefLine(value: 1.0,  label: "In Harmony",  color: Theme.coh),
                RefLine(value: 1.5,  label: "Strained",    color: Theme.warn),
            ],
            yDomain: 0.5...1.8,
            win: $sharedWin, selectedX: $sharedSelectedX,
            smooth: true,
            dynamicY: false,
            info: MetricInfo(
                "Short-term fractal scaling exponent from Detrended Fluctuation Analysis (Peng et al. 1995). Captures the self-similar correlation structure of RR intervals over 4–16 beat windows.",
                physical:    "DFA α1 measures how RR interval fluctuations at short time scales are correlated. A value of 1.0 indicates 1/f (pink) noise — the hallmark of a healthy, adaptive heart. Values near 0.5 indicate uncorrelated (white) noise; values near 1.5 indicate Brownian (random-walk) dynamics.",
                physiology:  "α1 reflects the complexity and adaptability of cardiac regulation. It is closely tied to vagal tone and parasympathetic modulation. Lower values (< 0.75) are linked to reduced cardiac complexity seen in heart failure, aging, and autonomic neuropathy. Values > 1.5 indicate over-correlated dynamics also associated with pathology.",
                training:    "α1 improves with regular aerobic exercise and HRV biofeedback. Track it over weeks — meaningful changes require consistent training. Acute reductions may appear during heavy exercise or high stress. Best interpreted alongside RMSSD and LF/HF.",
                sensitivity: "Low to moderate. Requires ≥ 128 RR intervals (~2 min at rest). Computed on a 256-beat rolling window. Updates every 2 seconds but stabilises over 3–5 minutes of continuous wear.",
                levels:      "Pathological low: < 0.5\nLow:             0.5–0.75\nNormal:          0.75–1.5  (target range)\nIdeal:           ~1.0\nHigh:            > 1.5\nPathological high: > 2.0",
                notes:       "α1 will display '—' until 128 RR intervals have been collected (~2 minutes of wear). This is a fundamental requirement of the DFA algorithm, not a sensor issue."
            ),
            history: history, rawHistory: rawHistory, date: date
        ) { $0.dfa1.map(Double.init) }
    }

    // MARK: LF/HF Ratio

    private var lfhfCard: some View {
        MetricChartCard(
            title:   "Stress Balance",
            technicalName: "LF/HF Ratio",
            subtitle: "sympathovagal balance",
            yLabel:  "ratio",
            color:   Theme.rsa,
            windows: TimeWindow.allCases,
            refs: [
                RefLine(value: 0.5, label: "parasympathetic", color: Theme.breathe),
                RefLine(value: 1.0, label: "balanced",        color: Theme.coh),
                RefLine(value: 2.0, label: "sympathetic",     color: Theme.warn),
            ],
            yDomain: 0...5,
            win: $sharedWin, selectedX: $sharedSelectedX,
            dynamicY: true,
            info: MetricInfo(
                "Ratio of low-frequency (LF, 0.04–0.15 Hz) to high-frequency (HF, 0.15–0.40 Hz) spectral power.",
                physical:    "LF power reflects baroreceptor-mediated oscillations (~10-second Mayer waves) with contributions from both sympathetic and parasympathetic branches. HF power is almost exclusively vagal, locked to respiration. Their ratio was once considered a pure sympathovagal balance index.",
                physiology:  "High LF/HF → more sympathetic influence or slow breathing shifting power into LF. Low LF/HF → parasympathetic dominance. Caution: slow resonance breathing (6 br/min) moves respiratory frequency into the LF band, artificially inflating LF/HF even during deep relaxation.",
                training:    "More useful as a trend than an absolute value. Expect LF/HF to rise during stress or exercise and fall during recovery and resonance breathing (provided breathing rate stays above ~9 br/min). At exactly 6 br/min the ratio loses interpretive meaning.",
                sensitivity: "Moderate. Highly sensitive to breathing rate — use it alongside coherence score for fuller context.",
                levels:      "Parasympathetic: < 0.5\nBalanced:        0.5–1.5\nSympatho-vagal:  1.5–3.0\nStress/exercise: > 3.0\n(Can exceed 10 during intense activity)",
                notes:       "The sympathovagal balance interpretation of LF/HF is contested in recent literature. Treat it as one signal among many, not as a definitive autonomic index."
            ),
            history: history, rawHistory: rawHistory, date: date
        ) { $0.lfHF.map(Double.init) }
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
            win: $sharedWin, selectedX: $sharedSelectedX,
            dynamicY: true,
            info: MetricInfo(
                "Spectral power in the very low frequency band (0.003–0.04 Hz) — oscillations with cycles of 25 seconds to 5 minutes.",
                physical:    "VLF oscillations are too slow to be driven by breathing or baroreflex. They reflect intrinsic cardiac regulatory mechanisms, sympathetic innervation of peripheral vessels, thermoregulatory control, and possibly renin-angiotensin hormonal activity.",
                physiology:  "VLF power is a strong independent predictor of mortality in post-infarction and heart failure studies — stronger than LF or HF power in some datasets. It is thought to reflect tonic sympathetic activity and the integrity of slow regulatory loops. Low VLF is associated with autonomic neuropathy.",
                training:    "Not directly trainable in the short term. Improves with regular aerobic exercise, sufficient sleep, and reduced chronic stress over months. Meaningful changes require recordings of 5+ minutes. Use as a long-term health marker rather than a session-by-session target.",
                sensitivity: "Low. Requires stable, artefact-free recordings of at least 5 minutes. Not meaningful for recordings shorter than ~5 minutes.",
                levels:      "Values scale with recording duration — not directly comparable across different window lengths. Use relative trends within consistent conditions.",
                notes:       "VLF computation requires ~5 minutes of data for sufficient frequency resolution. Values appear near zero for short sessions — this is normal, not an error."
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
            win: $sharedWin, selectedX: $sharedSelectedX,
            dynamicY: true,
            info: MetricInfo(
                "Spectral power in the ultra low frequency band (< 0.003 Hz) — oscillations slower than one cycle per 5 minutes.",
                physical:    "ULF reflects the very slowest regulatory processes: circadian rhythm modulation of HR, core body temperature fluctuations, and hormonal systems (cortisol, growth hormone). These oscillations complete a single cycle over 5 minutes to 24 hours.",
                physiology:  "In 24-hour Holter recordings, ULF power is the dominant component of total HRV power and a powerful cardiovascular risk marker. It captures neuroendocrine rhythms that no shorter-duration metric can access. Its absence or reduction is seen in diabetic autonomic neuropathy and severe heart failure.",
                training:    "Not meaningful for individual sessions. Requires multi-hour recordings to observe. If wearing the sensor for full days or nights, ULF trends over weeks reflect long-term hormonal and circadian health improvements from consistent training and sleep discipline.",
                sensitivity: "Very low. Requires a minimum of ~10 minutes of continuous recording for any computation, and hours for stable estimates. Data emerges in this app after 10+ minutes of continuous wear.",
                levels:      "Clinically relevant values are from 24-hour recordings (typically thousands of ms²). Short-session values computed here are not directly comparable to clinical norms.",
                notes:       "ULF data will appear in this chart only after ~10 minutes of continuous recording in the current session. This is a fundamental frequency-resolution constraint, not a sensor or software issue."
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
            win: $sharedWin, selectedX: $sharedSelectedX,
            info: MetricInfo(
                "Degree of synchronisation between RR interval oscillations and the breathing cycle, scored 0–1.",
                physical:    "Computed as the normalised cross-spectral coherence between the RR tachogram and the ACC-derived breathing signal at the dominant breathing frequency. A score of 1.0 means the heart rate oscillation is perfectly phase-locked to breathing; 0 means no coupling.",
                physiology:  "High coherence indicates that the baroreflex and vagal pathways are efficiently amplifying each respiratory cycle into a large, rhythmic HR oscillation. This state is associated with maximum baroreceptor gain, enhanced vagal tone, and the largest RSA amplitude.",
                training:    "Coherence is the primary real-time training target during resonance breathing. It rises sharply when breathing rate matches the individual resonance frequency (~6 br/min for most people). Maintain coherence > 0.6 for the majority of a session. Track how quickly you reach high coherence — this improves with practice.",
                sensitivity: "Very high. Coherence responds within 2–3 breath cycles to changes in breathing rate, depth, or regularity. It is the most immediate feedback signal for session quality.",
                levels:      "Low:       < 0.30\nModerate:  0.30–0.60\nGood:      0.60–0.80\nExcellent: > 0.80\nPeak:      > 0.90  (rare; indicates perfect resonance)"
            ),
            history: history, rawHistory: rawHistory, date: date
        ) { $0.coherence.map(Double.init) }
    }
}

// MARK: - Preview

#Preview("Metrics Charts") {
    ScrollView {
        MetricsChartsView(history: mockHistory(), date: Date())
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
