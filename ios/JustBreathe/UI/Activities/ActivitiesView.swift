import SwiftUI
import SwiftData

// MARK: - ActivitySheet

// Single sheet enum — prevents SwiftUI multiple-sheet chaining bug.
// Optional associated values cause type-inference issues in @ViewBuilder;
// use two explicit cases instead.
private enum ActivitySheet: Identifiable {
    case ble
    case start
    case logPast
    case detail(ActivityLog)
    case edit(ActivityLog)

    var id: String {
        switch self {
        case .ble:           return "ble"
        case .start:         return "start"
        case .logPast:       return "logPast"
        case .detail(let e): return "detail-\(e.id)"
        case .edit(let e):   return "edit-\(e.id)"
        }
    }
}

struct ActivitiesView: View {
    @Environment(AppEnvironment.self) var env
    @Environment(\.modelContext) var ctx
    @Query(sort: \ActivityLog.startedAt, order: .reverse)
    private var allEntries: [ActivityLog]

    @State private var activeSheet:  ActivitySheet?   = nil

    private struct DayGroup: Identifiable {
        let id:      Date
        let label:   String
        let entries: [ActivityLog]
    }

    private var dayGroups: [DayGroup] {
        let cal = Calendar.current
        let history = allEntries.filter { !$0.isActive }
        let grouped = Dictionary(grouping: history) { cal.startOfDay(for: $0.startedAt) }

        return grouped.keys.sorted(by: >).map { day in
            let label: String
            if cal.isDateInToday(day) {
                label = "TODAY"
            } else if cal.isDateInYesterday(day) {
                label = "YESTERDAY"
            } else {
                let fmt = DateFormatter()
                fmt.dateFormat = "MMM d"
                label = fmt.string(from: day).uppercased()
            }
            let entries = (grouped[day] ?? []).sorted { $0.startedAt > $1.startedAt }
            return DayGroup(id: day, label: label, entries: entries)
        }
    }

    private var activeEntry: ActivityLog? {
        allEntries.first(where: { $0.isActive })
    }

    private var suggested: [ActivityType] {
        suggestedActivities()
    }

    var body: some View {
        NavigationStack {
            logSection
                .navigationTitle("ACTIVITIES")
                .navigationBarTitleDisplayMode(.inline)
                .toolbarBackground(Theme.bg, for: .navigationBar)
                .toolbarColorScheme(.dark, for: .navigationBar)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        BLENavButton(state: env.ble.state,
                                     bpm: env.latestTick?.meanBPM) {
                            activeSheet = .ble
                        }
                    }
                }
                .sheet(item: $activeSheet) { sheet in
                    sheetContent(sheet)
                }
        }
    }

    // MARK: - Log Section

    private var logSection: some View {
        List {
            // ── Active banner ─────────────────────────────────────
            if let active = activeEntry {
                ActiveActivityBanner(entry: active, tick: env.latestTick) {
                    endActivity(active)
                }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(.init(top: 8, leading: 16, bottom: 0, trailing: 16))
            }

            // ── Suggestions + action buttons (hidden while recording) ──
            if activeEntry == nil {
                Section {
                    VStack(spacing: 10) {
                        HStack {
                            Text("SUGGESTED NOW")
                                .font(Theme.monoLabel)
                                .foregroundStyle(Theme.dim)
                            Spacer()
                            Text(hourLabel())
                                .font(Theme.monoLabel)
                                .foregroundStyle(Theme.dim.opacity(0.6))
                        }

                        HStack(spacing: 10) {
                            ForEach(suggested, id: \.self) { type in
                                SuggestionChip(type: type) {
                                    env.pendingTabRequest = .train
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

                        HStack(spacing: 12) {
                            Button {
                                activeSheet = .start
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "play.fill")
                                    Text("START")
                                }
                                .font(Theme.monoBody)
                                .foregroundStyle(Theme.bg)
                                .padding(.vertical, 10)
                                .frame(maxWidth: .infinity)
                                .background(Theme.accent)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                            }

                            Button {
                                activeSheet = .logPast
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "clock.arrow.circlepath")
                                    Text("LOG PAST")
                                }
                                .font(Theme.monoBody)
                                .foregroundStyle(Theme.accent)
                                .padding(.vertical, 10)
                                .frame(maxWidth: .infinity)
                                .background(Theme.accent.opacity(0.08))
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                .overlay(RoundedRectangle(cornerRadius: 8)
                                    .strokeBorder(Theme.accent.opacity(0.3), lineWidth: 0.5))
                            }
                        }
                    }
                    .cardStyle()
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(.init(top: 8, leading: 16, bottom: 4, trailing: 16))
                }
            }

            // ── Activity history, grouped by day ──────────────────
            ForEach(dayGroups) { group in
                Section {
                    ForEach(group.entries) { entry in
                        ActivityLogRow(entry: entry)
                            .contentShape(Rectangle())
                            .onTapGesture { activeSheet = .detail(entry) }
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    deleteEntry(entry)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                                Button {
                                    activeSheet = .edit(entry)
                                } label: {
                                    Label("Edit", systemImage: "pencil")
                                }
                                .tint(Theme.breathe)
                            }
                            .listRowBackground(Theme.card)
                            .listRowSeparator(.hidden)
                            .listRowInsets(.init(top: 4, leading: 16, bottom: 4, trailing: 16))
                    }
                } header: {
                    Text(group.label)
                        .font(Theme.monoLabel)
                        .foregroundStyle(Theme.dim)
                        .textCase(nil)
                }
                .listSectionSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Theme.bg)
    }

    // MARK: - Sheet content

    @ViewBuilder
    private func sheetContent(_ sheet: ActivitySheet) -> some View {
        switch sheet {
        case .ble:
            BLEConnectionSheet(ble: env.ble)
        case .start:
            StartActivitySheet(preselected: nil) { type, subtype, name in
                beginActivity(type: type, subtype: subtype, customName: name)
            }
        case .logPast:
            LogPastSheet { type, subtype, name, start, end, notes in
                logPast(type: type, subtype: subtype, customName: name,
                        start: start, end: end, notes: notes)
            }
        case .detail(let entry):
            ActivityDetailView(entry: entry)
        case .edit(let entry):
            EditActivitySheet(entry: entry) { ctx in
                entry.computeHRVWindows(context: ctx)
                try? ctx.save()
                Task { await InsightGenerator(client: env.sync.client).generate(for: entry, context: ctx) }
            }
        }
    }

    // MARK: - Helpers

    private func hourLabel() -> String {
        let h = Calendar.current.component(.hour, from: Date())
        switch h {
        case 5..<12:  return "MORNING"
        case 12..<17: return "AFTERNOON"
        case 17..<21: return "EVENING"
        default:      return "NIGHT"
        }
    }

    private func suggestedActivities() -> [ActivityType] {
        let hour = Calendar.current.component(.hour, from: Date())
        let bucket = hour / 3

        // Build frequency map from history
        var freq: [ActivityType: Int] = [:]
        for entry in allEntries {
            guard let type = ActivityType(rawValue: entry.activityType) else { continue }
            let entryBucket = Calendar.current.component(.hour, from: entry.startedAt) / 3
            if entryBucket == bucket { freq[type, default: 0] += 1 }
        }

        if !freq.isEmpty {
            let sorted = freq.sorted { $0.value > $1.value }.prefix(2).map(\.key)
            if !sorted.isEmpty { return sorted }
        }

        // Fallback: hard-coded defaults by hour
        return ActivityType.allCases
            .filter { $0 != .custom && $0.defaultHours.contains(hour) }
            .prefix(2)
            .asArray()
            .ifEmpty(fallback: [.meditation, .breathwork])
    }

    // MARK: - Activity CRUD

    private func beginActivity(type: ActivityType, subtype: String?, customName: String?) {
        let entry = ActivityLog(
            activityType:    type.rawValue,
            activitySubtype: subtype,
            customName:      customName,
            startedAt:       .now,
            isManual:        false
        )
        ctx.insert(entry)
        try? ctx.save()
    }

    private func endActivity(_ entry: ActivityLog) {
        entry.endedAt = .now
        entry.computeHRVWindows(context: ctx)
        try? ctx.save()
        Task { await InsightGenerator(client: env.sync.client).generate(for: entry, context: ctx) }
    }

    private func logPast(type: ActivityType, subtype: String?, customName: String?,
                         start: Date, end: Date, notes: String?) {
        let entry = ActivityLog(
            activityType:    type.rawValue,
            activitySubtype: subtype,
            customName:      customName,
            startedAt:       start,
            endedAt:         end,
            isManual:        true
        )
        entry.notes = notes
        entry.computeHRVWindows(context: ctx)
        ctx.insert(entry)
        try? ctx.save()
        Task { await InsightGenerator(client: env.sync.client).generate(for: entry, context: ctx) }
    }

    private func deleteEntry(_ entry: ActivityLog) {
        ctx.delete(entry)
        try? ctx.save()
    }

}

// MARK: - SuggestionChip

private struct SuggestionChip: View {
    let type:   ActivityType
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: type.icon)
                    .font(.system(size: 11))
                Text(type.rawValue)
                    .font(Theme.monoLabel)
            }
            .foregroundStyle(type.color)
            .padding(.vertical, 5)
            .padding(.horizontal, 10)
            .background(type.color.opacity(0.12))
            .clipShape(Capsule())
            .overlay(Capsule().strokeBorder(type.color.opacity(0.3), lineWidth: 0.5))
        }
    }
}

// MARK: - ActiveActivityBanner

private struct ActiveActivityBanner: View {
    let entry:  ActivityLog
    let tick:   MetricsTick?
    let onStop: () -> Void

    @State private var elapsed: TimeInterval = 0
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var elapsedString: String {
        let t = Int(elapsed)
        return String(format: "%02d:%02d", t / 60, t % 60)
    }

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                HStack(spacing: 6) {
                    Circle()
                        .fill(Theme.warn)
                        .frame(width: 6, height: 6)
                        .opacity(0.8)
                    Image(systemName: entry.activityTypeEnum.icon)
                        .font(.system(size: 13))
                        .foregroundStyle(entry.activityTypeEnum.color)
                    Text(entry.displayName.uppercased())
                        .font(Theme.monoLabel)
                        .foregroundStyle(Theme.text)
                }
                Spacer()
                Text(elapsedString)
                    .font(Theme.mono(18))
                    .foregroundStyle(Theme.warn)
                    .monospacedDigit()
            }

            HStack(spacing: 0) {
                MetricPill(label: "HR",  value: MetricFormat.bpm(tick?.meanBPM),  unit: "bpm")
                MetricPill(label: "RSA", value: MetricFormat.ms(tick?.rsaMs),     unit: "ms")
                MetricPill(label: "VTI", value: MetricFormat.ratio(tick?.vti),    unit: "")
            }

            Button(action: onStop) {
                HStack(spacing: 6) {
                    Image(systemName: "stop.fill")
                    Text("STOP")
                }
                .font(Theme.monoBody)
                .foregroundStyle(Theme.warn)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity)
                .background(Theme.warn.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Theme.warn.opacity(0.35), lineWidth: 0.5))
            }
        }
        .cardStyle()
        .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius)
            .strokeBorder(Theme.warn.opacity(0.3), lineWidth: 0.5))
        .onReceive(timer) { _ in
            elapsed = Date().timeIntervalSince(entry.startedAt)
        }
        .onAppear {
            elapsed = Date().timeIntervalSince(entry.startedAt)
        }
    }
}

private struct MetricPill: View {
    let label: String
    let value: String
    let unit:  String

    var body: some View {
        VStack(spacing: 2) {
            Text(label)
                .font(Theme.monoLabel)
                .foregroundStyle(Theme.dim)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value)
                    .font(Theme.monoBody)
                    .foregroundStyle(Theme.text)
                if !unit.isEmpty {
                    Text(unit)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(Theme.dim)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - ActivityLogRow

private struct ActivityLogRow: View {
    let entry: ActivityLog

    private var timeStr: String {
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm"
        return fmt.string(from: entry.startedAt)
    }

    var body: some View {
        HStack(spacing: 10) {
            // Icon
            ZStack {
                Circle()
                    .fill(entry.activityTypeEnum.color.opacity(0.15))
                    .frame(width: 36, height: 36)
                Image(systemName: entry.activityTypeEnum.icon)
                    .font(.system(size: 16))
                    .foregroundStyle(entry.activityTypeEnum.color)
            }

            // Name + time
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.displayName)
                    .font(.system(size: 14, weight: .medium, design: .monospaced))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Text(timeStr)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Theme.dim)
                    if entry.isActive {
                        Text("LIVE").font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.warn)
                    } else {
                        Text(entry.durationString).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.dim)
                    }
                }
            }
            .frame(width: 96, alignment: .leading)

            // Metric columns
            LogMetricCell(label: "HR",   value: entry.duringHR,   base: entry.beforeHR,   fmt: "%.0f", isRate: true)
            LogMetricCell(label: "RSA",  value: entry.duringRSA,  base: entry.beforeRSA,  fmt: "%.0f", isRate: false)
            LogMetricCell(label: "VTI",  value: entry.duringVTI,  base: entry.beforeVTI,  fmt: "%.2f", isRate: false)
            LogMetricCell(label: "SDNN", value: entry.duringSDNN, base: entry.beforeSDNN, fmt: "%.0f", isRate: false)

            Image(systemName: "chevron.right")
                .font(.system(size: 11))
                .foregroundStyle(Theme.dim.opacity(0.4))
        }
        .padding(.vertical, 7)
    }
}

private struct LogMetricCell: View {
    let label:  String
    let value:  Float?
    let base:   Float?
    let fmt:    String
    let isRate: Bool

    private var delta: Float? {
        guard let v = value, let b = base else { return nil }
        return v - b
    }

    private var deltaColor: Color {
        guard let d = delta else { return Theme.dim }
        return isRate ? Theme.dim : (d >= 0 ? Theme.accent : Theme.warn)
    }

    var body: some View {
        VStack(spacing: 2) {
            Text(label)
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(Theme.dim)
            Text(value.map { String(format: fmt, $0) } ?? "—")
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(Theme.text)
            Group {
                if let d = delta {
                    Text("\(d >= 0 ? "+" : "")\(String(format: fmt, d))")
                        .foregroundStyle(deltaColor)
                } else {
                    Text("—").foregroundStyle(Theme.dim.opacity(0.4))
                }
            }
            .font(.system(size: 10, design: .monospaced))
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - DeltaChip

private struct DeltaChip: View {
    let value: Float
    let unit:  String

    private var color: Color { value >= 0 ? Theme.accent : Theme.warn }
    private var sign:  String { value >= 0 ? "+" : "" }

    var body: some View {
        Text("\(sign)\(Int(value.rounded())) \(unit)")
            .font(Theme.monoLabel)
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(color.opacity(0.12))
            .clipShape(Capsule())
    }
}

// MARK: - ActivityDetailView

struct ActivityDetailView: View {
    @Environment(\.modelContext) var ctx
    @Environment(\.dismiss) var dismiss
    @Bindable var entry: ActivityLog

    @State private var chartPoints: [MetricsHistoryPoint] = []
    @State private var twoMonthAvg: [String: Double] = [:]      // avg absolute during-value

    private var timeStr: String {
        let fmt = DateFormatter()
        fmt.dateStyle = .medium
        fmt.timeStyle = .short
        return fmt.string(from: entry.startedAt)
    }

    /// Average absolute "during" value per metric across the OTHER completed
    /// sessions of the same activity type in the past ~2 months (the current
    /// session is excluded so it can be compared against this baseline).
    /// Keyed by metric id.
    private func loadTwoMonthAverages() {
        let cutoff = Calendar.current.date(byAdding: .day, value: -60, to: .now) ?? .distantPast
        let type   = entry.activityType
        let predicate = #Predicate<ActivityLog> {
            $0.activityType == type && $0.startedAt >= cutoff && $0.endedAt != nil
        }
        let sessions = ((try? ctx.fetch(FetchDescriptor<ActivityLog>(predicate: predicate))) ?? [])
            .filter { $0.id != entry.id }

        var absResult: [String: Double] = [:]
        for def in activityMetricDefs {
            // Average absolute during-value.
            let vals = sessions.compactMap { $0[keyPath: def.duringKey].map(Double.init) }
            if !vals.isEmpty {
                absResult[def.id] = vals.reduce(0, +) / Double(vals.count)
            }
        }
        twoMonthAvg = absResult
    }

    private func loadChartPoints() {
        let beforeStart = entry.startedAt.addingTimeInterval(-300)
        let afterEnd    = (entry.endedAt ?? entry.startedAt).addingTimeInterval(600)
        let predicate = #Predicate<HRVSample> {
            $0.timestamp >= beforeStart && $0.timestamp <= afterEnd
        }
        var desc = FetchDescriptor<HRVSample>(
            predicate: predicate,
            sortBy: [SortDescriptor(\.timestamp)]
        )
        desc.fetchLimit = 10_000
        let samples = (try? ctx.fetch(desc)) ?? []
        chartPoints = MetricsQualityFilter.filter(samples.map { MetricsHistoryPoint(from: $0) })
    }

    private func impactCaption(_ score: Int) -> String {
        switch score {
        case 80...:   return "excellent session"
        case 65..<80: return "solid session"
        case 50..<65: return "steady session"
        case 35..<50: return "gentle session"
        default:      return "light session"
        }
    }

    private func recIcon(_ kind: ActivityRecommendation.Kind) -> String {
        switch kind {
        case .keep:  return "checkmark.circle"
        case .watch: return "eye"
        case .trend: return "chart.line.uptrend.xyaxis"
        }
    }

    private func recColor(_ kind: ActivityRecommendation.Kind) -> Color {
        switch kind {
        case .keep:  return Theme.accent
        case .watch: return Theme.warn
        case .trend: return Theme.dim
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {

                    // Header
                    HStack(spacing: 10) {
                            ZStack {
                                Circle()
                                    .fill(entry.activityTypeEnum.color.opacity(0.15))
                                    .frame(width: 44, height: 44)
                                Image(systemName: entry.activityTypeEnum.icon)
                                    .font(.system(size: 20))
                                    .foregroundStyle(entry.activityTypeEnum.color)
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.displayName)
                                    .font(Theme.mono(16))
                                    .foregroundStyle(Theme.text)
                                Text(timeStr + " · " + entry.durationString)
                                    .font(Theme.monoLabel)
                                    .foregroundStyle(Theme.dim)
                            }
                            Spacer()
                        }

                        // Compute peak/uplift/recovery once per metric, shared
                        // by the gauge, the rows and the recommendations so
                        // they can't drift.
                        let windowEnd = entry.endedAt ?? entry.startedAt
                        let metrics = activityMetricDefs.map { def in
                            (def: def,
                             stats: ActivityMetricStats(points: chartPoints,
                                                        extract: def.extract,
                                                        direction: def.direction,
                                                        startedAt: entry.startedAt,
                                                        endedAt: windowEnd))
                        }
                        let uplifts = metrics.compactMap { $0.stats.avgUpliftPct }

                        // Overall practice impact.
                        if let score = ActivityImpact.score(uplifts: uplifts) {
                            let bd = ActivityImpact.breakdown(uplifts: uplifts)
                            VStack(spacing: 6) {
                                Text("OVERALL PRACTICE IMPACT")
                                    .font(Theme.monoLabel)
                                    .foregroundStyle(Theme.dim)
                                PracticeImpactGauge(score: score, caption: impactCaption(score))
                                Text("\(bd.improved) improved · \(bd.held) held · \(bd.dipped) dipped")
                                    .font(Theme.monoLabel)
                                    .foregroundStyle(Theme.dim)
                            }
                            .cardStyle()
                        }

                        // Per-metric progressive disclosure — tap a row to open
                        // its before/during/after chart and why-it-matters note.

                        ForEach(metrics, id: \.def.id) { m in
                            MetricProgressRow(def: m.def,
                                              stats: m.stats,
                                              twoMonthValue: twoMonthAvg[m.def.id],
                                              color: entry.activityTypeEnum.color,
                                              points: chartPoints,
                                              startedAt: entry.startedAt,
                                              endedAt: windowEnd)
                        }

                        // Recommendations (rule-based, from this session's moves).
                        let recs = ActivityImpact.recommendations(metrics.map { m in
                            MetricMovement(name: m.def.label,
                                           uplift: m.stats.avgUpliftPct,
                                           vs2mo: m.def.benefitDelta(current: m.stats.duringMean,
                                                                     base: twoMonthAvg[m.def.id]))
                        })
                        if !recs.isEmpty {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("RECOMMENDATIONS")
                                    .font(Theme.monoLabel)
                                    .foregroundStyle(Theme.dim)
                                ForEach(recs) { rec in
                                    HStack(alignment: .top, spacing: 8) {
                                        Image(systemName: recIcon(rec.kind))
                                            .font(.system(size: 12))
                                            .foregroundStyle(recColor(rec.kind))
                                            .frame(width: 16)
                                        Text(rec.text)
                                            .font(Theme.monoBody)
                                            .foregroundStyle(Theme.text)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                            }
                            .cardStyle()
                        }

                        // Insight
                        if let insight = entry.insightText {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("INSIGHT")
                                    .font(Theme.monoLabel)
                                    .foregroundStyle(Theme.dim)
                                Text(insight)
                                    .font(Theme.monoBody)
                                    .foregroundStyle(Theme.text)
                            }
                            .cardStyle()
                        }

                        // Notes
                        VStack(alignment: .leading, spacing: 6) {
                            Text("NOTES")
                                .font(Theme.monoLabel)
                                .foregroundStyle(Theme.dim)
                            TextField("Add notes…", text: Binding(
                                get: { entry.notes ?? "" },
                                set: { entry.notes = $0.isEmpty ? nil : $0 }
                            ), axis: .vertical)
                            .font(Theme.monoBody)
                            .foregroundStyle(Theme.text)
                            .lineLimit(3...6)
                        }
                        .cardStyle()
                    }
                    .padding(.horizontal)
                    .padding(.top, 16)
                    .padding(.bottom, 30)
                }
            }
            .navigationTitle(entry.displayName.uppercased())
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.bg, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        try? ctx.save()
                        dismiss()
                    }
                    .font(Theme.monoLabel)
                    .foregroundStyle(Theme.accent)
                }
            }
            .onAppear {
                loadChartPoints()
                loadTwoMonthAverages()
            }
        }
    }

// MARK: - StartActivitySheet

private struct StartActivitySheet: View {
    var preselected: ActivityType? = nil
    let onStart: (ActivityType, String?, String?) -> Void
    @Environment(\.dismiss) var dismiss
    @State private var selected:         ActivityType
    @State private var selectedSubtype:  String?      = nil
    @State private var customName:       String       = ""
    @State private var showCustom:       Bool         = false

    init(preselected: ActivityType? = nil, onStart: @escaping (ActivityType, String?, String?) -> Void) {
        self.preselected = preselected
        self.onStart     = onStart
        _selected  = State(initialValue: preselected ?? .meditation)
        _showCustom = State(initialValue: preselected == .custom)
    }

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 3)

    private var startLabel: String {
        if let sub = selectedSubtype { return sub.uppercased() }
        if selected == .custom { return customName.isEmpty ? "CUSTOM" : customName.uppercased() }
        return selected.rawValue.uppercased()
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    Text("SELECT ACTIVITY")
                        .font(Theme.monoLabel)
                        .foregroundStyle(Theme.dim)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal)

                    LazyVGrid(columns: columns, spacing: 10) {
                        ForEach(ActivityType.allCases, id: \.self) { type in
                            ActivityTypeCell(type: type, isSelected: selected == type) {
                                selected = type
                                selectedSubtype = nil
                                showCustom = (type == .custom)
                            }
                        }
                    }
                    .padding(.horizontal)

                    if !selected.subtypes.isEmpty {
                        SubtypePicker(type: selected, selected: $selectedSubtype)
                            .padding(.horizontal)
                    }

                    if showCustom {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("CUSTOM NAME")
                                .font(Theme.monoLabel)
                                .foregroundStyle(Theme.dim)
                            TextField("e.g. Ice bath", text: $customName)
                                .font(Theme.monoBody)
                                .foregroundStyle(Theme.text)
                                .padding(10)
                                .background(Theme.card)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                .overlay(RoundedRectangle(cornerRadius: 8)
                                    .strokeBorder(Theme.border, lineWidth: 0.5))
                        }
                        .padding(.horizontal)
                    }

                    Button {
                        let name = selected == .custom && !customName.isEmpty ? customName : nil
                        onStart(selected, selectedSubtype, name)
                        dismiss()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "play.fill")
                            Text("START \(startLabel)")
                        }
                        .font(Theme.monoBody)
                        .foregroundStyle(Theme.bg)
                        .padding(.vertical, 14)
                        .frame(maxWidth: .infinity)
                        .background(Theme.accent)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                    .padding(.horizontal)
                    .disabled(selected == .custom && customName.isEmpty)
                }
                .padding(.top, 16)
                .padding(.bottom, 30)
            }
            .background(Theme.bg)
            .navigationTitle("START ACTIVITY")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.bg, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                        .font(Theme.monoLabel)
                        .foregroundStyle(Theme.dim)
                }
            }
        }
    }
}

// MARK: - LogPastSheet

private struct LogPastSheet: View {
    let onSave: (ActivityType, String?, String?, Date, Date, String?) -> Void
    @Environment(\.dismiss) var dismiss
    @State private var selected:        ActivityType = .meditation
    @State private var selectedSubtype: String?      = nil
    @State private var customName:      String       = ""
    @State private var showCustom:      Bool         = false
    @State private var startDate:       Date         = .now
    @State private var durationMins:    Double       = 30
    @State private var notes:           String       = ""

    private var endDate: Date { startDate.addingTimeInterval(durationMins * 60) }

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 3)

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {

                    Text("SELECT ACTIVITY")
                        .font(Theme.monoLabel)
                        .foregroundStyle(Theme.dim)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal)

                    LazyVGrid(columns: columns, spacing: 10) {
                        ForEach(ActivityType.allCases, id: \.self) { type in
                            ActivityTypeCell(type: type, isSelected: selected == type) {
                                selected = type
                                selectedSubtype = nil
                                showCustom = (type == .custom)
                            }
                        }
                    }
                    .padding(.horizontal)

                    if !selected.subtypes.isEmpty {
                        SubtypePicker(type: selected, selected: $selectedSubtype)
                            .padding(.horizontal)
                    }

                    if showCustom {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("CUSTOM NAME")
                                .font(Theme.monoLabel)
                                .foregroundStyle(Theme.dim)
                            TextField("e.g. Ice bath", text: $customName)
                                .font(Theme.monoBody)
                                .foregroundStyle(Theme.text)
                                .padding(10)
                                .background(Theme.card)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                .overlay(RoundedRectangle(cornerRadius: 8)
                                    .strokeBorder(Theme.border, lineWidth: 0.5))
                        }
                        .padding(.horizontal)
                    }

                    VStack(spacing: 12) {
                        DatePicker("START TIME", selection: $startDate, displayedComponents: [.date, .hourAndMinute])
                            .font(Theme.monoLabel)
                            .foregroundStyle(Theme.dim)
                            .tint(Theme.accent)

                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("DURATION")
                                    .font(Theme.monoLabel)
                                    .foregroundStyle(Theme.dim)
                                Spacer()
                                Text("\(Int(durationMins)) min")
                                    .font(Theme.monoBody)
                                    .foregroundStyle(Theme.accent)
                            }
                            Slider(value: $durationMins, in: 1...180, step: 1)
                                .tint(Theme.accent)
                        }
                    }
                    .cardStyle()
                    .padding(.horizontal)

                    VStack(alignment: .leading, spacing: 6) {
                        Text("NOTES (OPTIONAL)")
                            .font(Theme.monoLabel)
                            .foregroundStyle(Theme.dim)
                        TextField("Notes…", text: $notes, axis: .vertical)
                            .font(Theme.monoBody)
                            .foregroundStyle(Theme.text)
                            .lineLimit(2...4)
                            .padding(10)
                            .background(Theme.card)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(Theme.border, lineWidth: 0.5))
                    }
                    .padding(.horizontal)

                    Button {
                        let name = selected == .custom && !customName.isEmpty ? customName : nil
                        let noteVal = notes.isEmpty ? nil : notes
                        onSave(selected, selectedSubtype, name, startDate, endDate, noteVal)
                        dismiss()
                    } label: {
                        Text("SAVE")
                            .font(Theme.monoBody)
                            .foregroundStyle(Theme.bg)
                            .padding(.vertical, 14)
                            .frame(maxWidth: .infinity)
                            .background(Theme.accent)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                    .padding(.horizontal)
                    .disabled(selected == .custom && customName.isEmpty)
                }
                .padding(.top, 16)
                .padding(.bottom, 30)
            }
            .background(Theme.bg)
            .navigationTitle("LOG PAST ACTIVITY")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.bg, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                        .font(Theme.monoLabel)
                        .foregroundStyle(Theme.dim)
                }
            }
        }
    }
}

// MARK: - SubtypePicker

private struct SubtypePicker: View {
    let type:     ActivityType
    @Binding var selected: String?

    private let cols = Array(repeating: GridItem(.flexible(), spacing: 8), count: 3)

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("SUBTYPE")
                    .font(Theme.monoLabel)
                    .foregroundStyle(Theme.dim)
                Spacer()
                if selected != nil {
                    Button("clear") { selected = nil }
                        .font(Theme.monoLabel)
                        .foregroundStyle(Theme.dim.opacity(0.5))
                }
            }

            LazyVGrid(columns: cols, spacing: 8) {
                ForEach(type.subtypes, id: \.self) { sub in
                    Button {
                        selected = selected == sub ? nil : sub
                    } label: {
                        Text(sub)
                            .font(Theme.monoLabel)
                            .foregroundStyle(selected == sub ? Theme.bg : type.color)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                            .padding(.vertical, 8)
                            .frame(maxWidth: .infinity)
                            .background(selected == sub ? type.color : type.color.opacity(0.1))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(selected == sub ? .clear : type.color.opacity(0.25), lineWidth: 0.5))
                    }
                }
            }
        }
        .cardStyle()
    }
}

// MARK: - ActivityTypeCell

private struct ActivityTypeCell: View {
    let type:       ActivityType
    let isSelected: Bool
    let action:     () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                ZStack {
                    Circle()
                        .fill(isSelected ? type.color : type.color.opacity(0.12))
                        .frame(width: 44, height: 44)
                    Image(systemName: type.icon)
                        .font(.system(size: 18))
                        .foregroundStyle(isSelected ? Theme.bg : type.color)
                }
                Text(type == .custom ? "Custom" : type.rawValue)
                    .font(Theme.monoLabel)
                    .foregroundStyle(isSelected ? Theme.text : Theme.dim)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .background(isSelected ? type.color.opacity(0.15) : Theme.card)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10)
                .strokeBorder(isSelected ? type.color.opacity(0.5) : Theme.border, lineWidth: 0.5))
        }
    }
}

// MARK: - EditActivitySheet

private struct EditActivitySheet: View {
    @Bindable var entry: ActivityLog
    let onSave: (ModelContext) -> Void

    @Environment(\.modelContext) var ctx
    @Environment(\.dismiss) var dismiss

    @State private var selected:        ActivityType
    @State private var selectedSubtype: String?
    @State private var customName:      String
    @State private var showCustom:      Bool
    @State private var startDate:       Date
    @State private var durationMins:    Double
    @State private var notes:           String

    private var endDate: Date { startDate.addingTimeInterval(durationMins * 60) }

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 3)

    init(entry: ActivityLog, onSave: @escaping (ModelContext) -> Void) {
        self.entry  = entry
        self.onSave = onSave
        let typeEnum = ActivityType(rawValue: entry.activityType) ?? .custom
        _selected        = State(initialValue: typeEnum)
        _selectedSubtype = State(initialValue: entry.activitySubtype)
        _customName      = State(initialValue: entry.customName ?? "")
        _showCustom      = State(initialValue: typeEnum == .custom)
        _startDate       = State(initialValue: entry.startedAt)
        let dur = entry.endedAt.map { $0.timeIntervalSince(entry.startedAt) / 60 } ?? 30
        _durationMins    = State(initialValue: max(1, min(180, dur)))
        _notes           = State(initialValue: entry.notes ?? "")
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {

                    Text("SELECT ACTIVITY")
                        .font(Theme.monoLabel)
                        .foregroundStyle(Theme.dim)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal)

                    LazyVGrid(columns: columns, spacing: 10) {
                        ForEach(ActivityType.allCases, id: \.self) { type in
                            ActivityTypeCell(type: type, isSelected: selected == type) {
                                selected = type
                                selectedSubtype = nil
                                showCustom = (type == .custom)
                            }
                        }
                    }
                    .padding(.horizontal)

                    if !selected.subtypes.isEmpty {
                        SubtypePicker(type: selected, selected: $selectedSubtype)
                            .padding(.horizontal)
                    }

                    if showCustom {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("CUSTOM NAME")
                                .font(Theme.monoLabel)
                                .foregroundStyle(Theme.dim)
                            TextField("e.g. Ice bath", text: $customName)
                                .font(Theme.monoBody)
                                .foregroundStyle(Theme.text)
                                .padding(10)
                                .background(Theme.card)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                .overlay(RoundedRectangle(cornerRadius: 8)
                                    .strokeBorder(Theme.border, lineWidth: 0.5))
                        }
                        .padding(.horizontal)
                    }

                    VStack(spacing: 12) {
                        DatePicker("START TIME", selection: $startDate, displayedComponents: [.date, .hourAndMinute])
                            .font(Theme.monoLabel)
                            .foregroundStyle(Theme.dim)
                            .tint(Theme.accent)

                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("DURATION")
                                    .font(Theme.monoLabel)
                                    .foregroundStyle(Theme.dim)
                                Spacer()
                                Text("\(Int(durationMins)) min")
                                    .font(Theme.monoBody)
                                    .foregroundStyle(Theme.accent)
                            }
                            Slider(value: $durationMins, in: 1...180, step: 1)
                                .tint(Theme.accent)
                        }
                    }
                    .cardStyle()
                    .padding(.horizontal)

                    VStack(alignment: .leading, spacing: 6) {
                        Text("NOTES (OPTIONAL)")
                            .font(Theme.monoLabel)
                            .foregroundStyle(Theme.dim)
                        TextField("Notes…", text: $notes, axis: .vertical)
                            .font(Theme.monoBody)
                            .foregroundStyle(Theme.text)
                            .lineLimit(2...4)
                            .padding(10)
                            .background(Theme.card)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(Theme.border, lineWidth: 0.5))
                    }
                    .padding(.horizontal)

                    Button {
                        entry.activityType    = selected.rawValue
                        entry.activitySubtype = selectedSubtype
                        entry.customName      = (selected == .custom && !customName.isEmpty) ? customName : nil
                        entry.startedAt       = startDate
                        entry.endedAt         = endDate
                        entry.isManual        = true
                        entry.notes           = notes.isEmpty ? nil : notes
                        onSave(ctx)
                        dismiss()
                    } label: {
                        Text("SAVE CHANGES")
                            .font(Theme.monoBody)
                            .foregroundStyle(Theme.bg)
                            .padding(.vertical, 14)
                            .frame(maxWidth: .infinity)
                            .background(Theme.accent)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                    .padding(.horizontal)
                    .disabled(selected == .custom && customName.isEmpty)
                }
                .padding(.top, 16)
                .padding(.bottom, 30)
            }
            .background(Theme.bg)
            .navigationTitle("EDIT ACTIVITY")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.bg, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                        .font(Theme.monoLabel)
                        .foregroundStyle(Theme.dim)
                }
            }
        }
    }
}

// MARK: - Collection helpers

private extension Array {
    func asArray() -> [Element] { Array(self) }
    func ifEmpty(fallback: [Element]) -> [Element] { isEmpty ? fallback : self }
}

private extension ArraySlice {
    func asArray() -> [Element] { Array(self) }
}
