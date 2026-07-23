# Activity Detail Charts Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace `ActivityDetailView`'s static BEFORE/DURING/AFTER metric table with a 9-tile metric summary grid plus 9 stacked before/during/after time-series charts, one per metric.

**Architecture:** Repurpose the already-built 9-tile grid (`ActivityMetricsCard`, currently unused) by dropping its duplicate header and renaming it. Add one new lightweight chart view built directly with Swift Charts marks (not a reuse of the heavier live-view `MetricChartCard`, which is hardwired for "last N minutes ending now" or "one full calendar day" windows — incompatible with an activity's arbitrary past `[start, end]` span). Fetch the underlying `HRVSample` data the same way `ActivityLog.computeHRVWindows` already does, convert via the existing `MetricsHistoryPoint(from:)` initializer, and quality-filter with the existing `MetricsQualityFilter`.

**Tech Stack:** Swift 5 / SwiftUI, Swift Charts (`Chart`, `LineMark`, `RectangleMark`, `RuleMark`), SwiftData (`FetchDescriptor`, `#Predicate`), Xcode project with explicit `PBXFileReference`/`PBXGroup` entries (no synchronized folder groups — new/renamed files must be registered in `project.pbxproj` by hand).

## Global Constraints

- No unit-test target covers SwiftUI view files in this codebase — verification for every task is **build success** (`xcodebuild build`) plus, where noted, a manual Simulator check.
- Build verification command (use for every task):
  ```bash
  cd /Users/alexutkin/ios && xcodebuild build -project Virtu.xcodeproj -scheme Virtu -destination 'platform=iOS Simulator,name=iPhone 17 Pro' 2>&1 | tail -40
  ```
  Expected final line: `** BUILD SUCCEEDED **`
- Commit after every task with a message describing that task only.
- The spec is `docs/superpowers/specs/2026-07-17-activity-detail-charts-design.md` — re-read it if anything here seems ambiguous.
- The 9 metrics, their order, consumer names, technical labels, and units must match exactly across the grid and the charts: Harmony/DFA α1 (""), Conscious Breathing/RSA (ms), Energy Reserve/HRV (ms), Adaptive Power/RCMSE (""), Inner Noise/PIP (%), Calm Reserve/DC (ms), Calm Power/VTI (""), Stress Balance/LF/HF (""), Pulse/HR (bpm).
- Do not change `ActivityLogRow`, the day-grouped list, Suggested Now, START/LOG PAST, or the Notes card in `ActivityDetailView` — all out of scope.
- Do not touch `UI/Live/MetricsChartsView.swift` or its `MetricChartCard`/`TimeWindow` — this plan does not reuse or modify them.

---

### Task 1: Rename ActivityMetricsCard → ActivityMetricsGrid, drop its header

**Files:**
- Rename: `UI/Activities/ActivityMetricsCard.swift` → `UI/Activities/ActivityMetricsGrid.swift`
- Modify: `Virtu.xcodeproj/project.pbxproj`

**Interfaces:**
- Produces: `ActivityMetricsGrid(entry: ActivityLog): View` — a `LazyVGrid` of 9 `MetricTile`s wrapped in `.cardStyle()`, no header row. Same tile content/order/formatting as before, just the file/type renamed and the header removed.
- Consumes: `MetricTile` (existing, `UI/Design/MetricTile.swift`), `MetricFormat` (existing, `UI/Design/Theme.swift`), `ActivityLog.{during,before}{HR,RSA,RMSSD,RCMSE,PIP,DC,VTI,LFHF,DFA1}` (existing).

- [ ] **Step 1: Rename the file**

```bash
cd /Users/alexutkin/ios/Virtu/UI/Activities
git mv ActivityMetricsCard.swift ActivityMetricsGrid.swift
```

- [ ] **Step 2: Rename the type and drop the header**

The file currently reads:

```swift
import SwiftUI

/// Extended per-activity card for the day-grouped history list: header
/// (icon/name/time/duration) plus a 3×3 grid of the same 9 metrics shown
/// live in LiveView's MetricsTableView, using "during" as the primary
/// value and "during − before" as the delta — mirroring both the Live
/// tab's tick/day-average convention and the prior compact row's
/// during/before convention.
struct ActivityMetricsCard: View {
    let entry: ActivityLog

    private var timeStr: String {
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm"
        return fmt.string(from: entry.startedAt)
    }

    private let cols = Array(repeating: GridItem(.flexible(), spacing: 10), count: 3)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(entry.activityTypeEnum.color.opacity(0.15))
                        .frame(width: 36, height: 36)
                    Image(systemName: entry.activityTypeEnum.icon)
                        .font(.system(size: 16))
                        .foregroundStyle(entry.activityTypeEnum.color)
                }

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

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.dim.opacity(0.4))
            }

            LazyVGrid(columns: cols, spacing: 10) {
                MetricTile(label: "Harmony",             techLabel: "DFA α1", value: dfa1String,                          unit: "",    delta: delta(entry.duringDFA1,  entry.beforeDFA1),  higherBetter: false)
                MetricTile(label: "Conscious Breathing", techLabel: "RSA",    value: MetricFormat.ms(entry.duringRSA),    unit: "ms",  delta: delta(entry.duringRSA,   entry.beforeRSA),   higherBetter: true)
                MetricTile(label: "Energy Reserve",      techLabel: "HRV",    value: MetricFormat.ms(entry.duringRMSSD),  unit: "ms",  delta: delta(entry.duringRMSSD, entry.beforeRMSSD), higherBetter: true)
                MetricTile(label: "Adaptive Power",      techLabel: "RCMSE",  value: rcmseString,                          unit: "",    delta: delta(entry.duringRCMSE, entry.beforeRCMSE), higherBetter: true)
                MetricTile(label: "Inner Noise",         techLabel: "PIP",    value: pipString,                            unit: "%",   delta: delta(entry.duringPIP,   entry.beforePIP),   higherBetter: false)
                MetricTile(label: "Calm Reserve",        techLabel: "DC",     value: dcString,                             unit: "ms",  delta: delta(entry.duringDC,    entry.beforeDC),    higherBetter: true)
                MetricTile(label: "Calm Power",          techLabel: "VTI",    value: MetricFormat.ratio(entry.duringVTI),  unit: "",    delta: delta(entry.duringVTI,   entry.beforeVTI),   higherBetter: true)
                MetricTile(label: "Stress Balance",      techLabel: "LF/HF",  value: MetricFormat.ratio(entry.duringLFHF), unit: "",    delta: delta(entry.duringLFHF,  entry.beforeLFHF),  higherBetter: false)
                MetricTile(label: "Pulse",               techLabel: "HR",     value: MetricFormat.bpm(entry.duringHR),    unit: "bpm", delta: delta(entry.duringHR,    entry.beforeHR),    higherBetter: false)
            }
        }
        .cardStyle()
    }

    private var dfa1String:  String { entry.duringDFA1.map  { String(format: "%.2f", $0) } ?? "—" }
    private var rcmseString: String { entry.duringRCMSE.map { String(format: "%.2f", $0) } ?? "—" }
    private var pipString:   String { entry.duringPIP.map   { String(format: "%.1f", $0) } ?? "—" }
    private var dcString:    String { entry.duringDC.map    { String(format: "%.1f", $0) } ?? "—" }

    private func delta(_ current: Float?, _ base: Float?) -> Float? {
        guard let c = current, let b = base else { return nil }
        return c - b
    }
}
```

Replace the entire file content with:

```swift
import SwiftUI

/// 3×3 grid of the same 9 metrics shown live in LiveView's MetricsTableView,
/// using "during" as the primary value and "during − before" as the delta —
/// mirroring both the Live tab's tick/day-average convention and the
/// original compact list row's during/before convention. Used inside
/// ActivityDetailView, which renders its own header separately.
struct ActivityMetricsGrid: View {
    let entry: ActivityLog

    private let cols = Array(repeating: GridItem(.flexible(), spacing: 10), count: 3)

    var body: some View {
        LazyVGrid(columns: cols, spacing: 10) {
            MetricTile(label: "Harmony",             techLabel: "DFA α1", value: dfa1String,                          unit: "",    delta: delta(entry.duringDFA1,  entry.beforeDFA1),  higherBetter: false)
            MetricTile(label: "Conscious Breathing", techLabel: "RSA",    value: MetricFormat.ms(entry.duringRSA),    unit: "ms",  delta: delta(entry.duringRSA,   entry.beforeRSA),   higherBetter: true)
            MetricTile(label: "Energy Reserve",      techLabel: "HRV",    value: MetricFormat.ms(entry.duringRMSSD),  unit: "ms",  delta: delta(entry.duringRMSSD, entry.beforeRMSSD), higherBetter: true)
            MetricTile(label: "Adaptive Power",      techLabel: "RCMSE",  value: rcmseString,                          unit: "",    delta: delta(entry.duringRCMSE, entry.beforeRCMSE), higherBetter: true)
            MetricTile(label: "Inner Noise",         techLabel: "PIP",    value: pipString,                            unit: "%",   delta: delta(entry.duringPIP,   entry.beforePIP),   higherBetter: false)
            MetricTile(label: "Calm Reserve",        techLabel: "DC",     value: dcString,                             unit: "ms",  delta: delta(entry.duringDC,    entry.beforeDC),    higherBetter: true)
            MetricTile(label: "Calm Power",          techLabel: "VTI",    value: MetricFormat.ratio(entry.duringVTI),  unit: "",    delta: delta(entry.duringVTI,   entry.beforeVTI),   higherBetter: true)
            MetricTile(label: "Stress Balance",      techLabel: "LF/HF",  value: MetricFormat.ratio(entry.duringLFHF), unit: "",    delta: delta(entry.duringLFHF,  entry.beforeLFHF),  higherBetter: false)
            MetricTile(label: "Pulse",               techLabel: "HR",     value: MetricFormat.bpm(entry.duringHR),    unit: "bpm", delta: delta(entry.duringHR,    entry.beforeHR),    higherBetter: false)
        }
        .cardStyle()
    }

    private var dfa1String:  String { entry.duringDFA1.map  { String(format: "%.2f", $0) } ?? "—" }
    private var rcmseString: String { entry.duringRCMSE.map { String(format: "%.2f", $0) } ?? "—" }
    private var pipString:   String { entry.duringPIP.map   { String(format: "%.1f", $0) } ?? "—" }
    private var dcString:    String { entry.duringDC.map    { String(format: "%.1f", $0) } ?? "—" }

    private func delta(_ current: Float?, _ base: Float?) -> Float? {
        guard let c = current, let b = base else { return nil }
        return c - b
    }
}
```

- [ ] **Step 3: Update the Xcode project file**

In `Virtu.xcodeproj/project.pbxproj`, make these 4 exact replacements (same IDs `F146`/`A146`, just renamed path/comment — this is a rename, not a new file, so no new IDs):

Find:
```
		A146 /* ActivityMetricsCard.swift in Sources */ = {isa = PBXBuildFile; fileRef = F146 /* ActivityMetricsCard.swift */; };
```
Replace with:
```
		A146 /* ActivityMetricsGrid.swift in Sources */ = {isa = PBXBuildFile; fileRef = F146 /* ActivityMetricsGrid.swift */; };
```

Find:
```
		F146 /* ActivityMetricsCard.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = ActivityMetricsCard.swift; sourceTree = "<group>"; };
```
Replace with:
```
		F146 /* ActivityMetricsGrid.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = ActivityMetricsGrid.swift; sourceTree = "<group>"; };
```

Find:
```
				F146 /* ActivityMetricsCard.swift */,
```
Replace with:
```
				F146 /* ActivityMetricsGrid.swift */,
```

Find:
```
				A146 /* ActivityMetricsCard.swift in Sources */,
```
Replace with:
```
				A146 /* ActivityMetricsGrid.swift in Sources */,
```

- [ ] **Step 4: Build to verify**

```bash
cd /Users/alexutkin/ios && xcodebuild build -project Virtu.xcodeproj -scheme Virtu -destination 'platform=iOS Simulator,name=iPhone 17 Pro' 2>&1 | tail -40
```
Expected: `** BUILD SUCCEEDED **`. `ActivityMetricsGrid` is unused so far — that's expected, it's wired into `ActivityDetailView` in Task 3.

- [ ] **Step 5: Commit**

```bash
cd /Users/alexutkin/ios && git add Virtu/UI/Activities/ActivityMetricsGrid.swift Virtu/UI/Activities/ActivityMetricsCard.swift Virtu.xcodeproj/project.pbxproj
git commit -m "refactor(activities): rename ActivityMetricsCard to ActivityMetricsGrid, drop duplicate header"
```

---

### Task 2: Create ActivityWindowChart

**Files:**
- Create: `UI/Activities/ActivityWindowChart.swift`
- Modify: `Virtu.xcodeproj/project.pbxproj`

**Interfaces:**
- Produces: `ActivityWindowChart(title:techLabel:unit:color:points:startedAt:endedAt:extract:): View`. Not yet used anywhere (wired into `ActivityDetailView` in Task 3) — it compiling standing alone is this task's deliverable.
- Consumes: `MetricsHistoryPoint` (existing, `Models/MetricsHistoryPoint.swift`), `Theme.{dim,text,border,accent,warn}` (existing).

- [ ] **Step 1: Create the file**

Write `ios/Virtu/UI/Activities/ActivityWindowChart.swift`:

```swift
import Charts
import SwiftUI

/// A single metric's before/during/after time series for one activity.
/// Not a reuse of MetricsChartsView's MetricChartCard — that view is built
/// around a fixed TimeWindow (30m/2h/24h) anchored to "now" or a full
/// calendar day, which doesn't fit an activity's arbitrary past
/// [start, end] span of variable length. This is a smaller, purpose-built
/// chart for exactly that case.
struct ActivityWindowChart: View {
    let title:     String   // consumer name, e.g. "Harmony"
    let techLabel: String   // e.g. "DFA α1"
    let unit:      String
    let color:     Color    // activityTypeEnum.color — tints the "during" band
    let points:    [MetricsHistoryPoint]
    let startedAt: Date
    let endedAt:   Date
    let extract:   (MetricsHistoryPoint) -> Double?

    private struct Pt: Identifiable {
        let id:   Int
        let date: Date
        let val:  Double
    }

    private var windowStart: Date { startedAt.addingTimeInterval(-300) }
    private var windowEnd:   Date { endedAt.addingTimeInterval(600) }

    /// Buckets to ~120 points regardless of activity length, same density
    /// target as MetricsChartsView's TimeWindow.bucketSeconds convention.
    private var bucketed: [Pt] {
        let span = windowEnd.timeIntervalSince(windowStart)
        guard span > 0 else { return [] }
        let bucketSeconds = max(span / 120, 1)
        var sums:   [Int: Double] = [:]
        var counts: [Int: Int]    = [:]
        for pt in points {
            guard let v = extract(pt) else { continue }
            let key = Int(pt.timestamp.timeIntervalSince(windowStart) / bucketSeconds)
            sums[key]   = (sums[key]   ?? 0) + v
            counts[key] = (counts[key] ?? 0) + 1
        }
        return sums.keys.sorted().map { key in
            let date = windowStart.addingTimeInterval(Double(key) * bucketSeconds + bucketSeconds / 2)
            return Pt(id: key, date: date, val: sums[key]! / Double(counts[key]!))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Theme.text)
                if !techLabel.isEmpty {
                    Text(techLabel)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Theme.dim)
                }
                Spacer()
                if !unit.isEmpty {
                    Text(unit)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Theme.dim)
                }
            }

            let pts = bucketed
            if pts.isEmpty {
                HStack {
                    Spacer()
                    Text("No data")
                        .font(Theme.monoLabel)
                        .foregroundStyle(Theme.dim)
                    Spacer()
                }
                .frame(height: 110)
            } else {
                Chart {
                    RectangleMark(
                        xStart: .value("before start", windowStart),
                        xEnd:   .value("before end",   startedAt)
                    )
                    .foregroundStyle(Theme.dim.opacity(0.06))

                    RectangleMark(
                        xStart: .value("during start", startedAt),
                        xEnd:   .value("during end",   endedAt)
                    )
                    .foregroundStyle(color.opacity(0.08))

                    RectangleMark(
                        xStart: .value("after start", endedAt),
                        xEnd:   .value("after end",   windowEnd)
                    )
                    .foregroundStyle(Theme.dim.opacity(0.06))

                    RuleMark(x: .value("start", startedAt))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        .foregroundStyle(Theme.dim.opacity(0.5))
                        .annotation(position: .top, alignment: .leading, spacing: 2) {
                            Text("START")
                                .font(.system(size: 8, design: .monospaced))
                                .foregroundStyle(Theme.dim)
                        }

                    RuleMark(x: .value("end", endedAt))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        .foregroundStyle(Theme.dim.opacity(0.5))
                        .annotation(position: .top, alignment: .leading, spacing: 2) {
                            Text("END")
                                .font(.system(size: 8, design: .monospaced))
                                .foregroundStyle(Theme.dim)
                        }

                    ForEach(pts) { pt in
                        LineMark(
                            x: .value("time", pt.date),
                            y: .value(title, pt.val)
                        )
                        .foregroundStyle(color)
                        .interpolationMethod(.catmullRom)
                        .lineStyle(StrokeStyle(lineWidth: 1.5))
                    }
                }
                .chartXScale(domain: windowStart...windowEnd)
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 4)) {
                        AxisGridLine().foregroundStyle(Theme.border)
                        AxisValueLabel(format: .dateTime.hour().minute())
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(Theme.dim)
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) {
                        AxisGridLine().foregroundStyle(Theme.border)
                        AxisValueLabel()
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(Theme.dim)
                    }
                }
                .frame(height: 110)
            }
        }
        .cardStyle()
    }
}
```

- [ ] **Step 2: Register the new file in the Xcode project**

In `Virtu.xcodeproj/project.pbxproj`, make these 4 additions (new IDs `F147`/`A147` — confirmed unused by `grep -n "F147\|A147" Virtu.xcodeproj/project.pbxproj`, one past the `F146`/`A146` pair):

Addition 1 — PBXBuildFile, immediately after the `A146` line:
Find:
```
		A146 /* ActivityMetricsGrid.swift in Sources */ = {isa = PBXBuildFile; fileRef = F146 /* ActivityMetricsGrid.swift */; };
```
Replace with:
```
		A146 /* ActivityMetricsGrid.swift in Sources */ = {isa = PBXBuildFile; fileRef = F146 /* ActivityMetricsGrid.swift */; };
		A147 /* ActivityWindowChart.swift in Sources */ = {isa = PBXBuildFile; fileRef = F147 /* ActivityWindowChart.swift */; };
```

Addition 2 — PBXFileReference, immediately after the `F146` line:
Find:
```
		F146 /* ActivityMetricsGrid.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = ActivityMetricsGrid.swift; sourceTree = "<group>"; };
```
Replace with:
```
		F146 /* ActivityMetricsGrid.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = ActivityMetricsGrid.swift; sourceTree = "<group>"; };
		F147 /* ActivityWindowChart.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = ActivityWindowChart.swift; sourceTree = "<group>"; };
```

Addition 3 — add as a child of the `Activities` group:
Find:
```
		GAPP_ACT /* Activities */ = {
			isa = PBXGroup;
			children = (
				F137 /* ActivitiesView.swift */,
				F146 /* ActivityMetricsGrid.swift */,
			);
			path = Activities;
			sourceTree = "<group>";
		};
```
Replace with:
```
		GAPP_ACT /* Activities */ = {
			isa = PBXGroup;
			children = (
				F137 /* ActivitiesView.swift */,
				F146 /* ActivityMetricsGrid.swift */,
				F147 /* ActivityWindowChart.swift */,
			);
			path = Activities;
			sourceTree = "<group>";
		};
```

Addition 4 — add to the Sources build phase (immediately after the `A146` entry):
Find:
```
				A146 /* ActivityMetricsGrid.swift in Sources */,
```
Replace with:
```
				A146 /* ActivityMetricsGrid.swift in Sources */,
				A147 /* ActivityWindowChart.swift in Sources */,
```

- [ ] **Step 3: Build to verify**

```bash
cd /Users/alexutkin/ios && xcodebuild build -project Virtu.xcodeproj -scheme Virtu -destination 'platform=iOS Simulator,name=iPhone 17 Pro' 2>&1 | tail -40
```
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Commit**

```bash
cd /Users/alexutkin/ios && git add Virtu/UI/Activities/ActivityWindowChart.swift Virtu.xcodeproj/project.pbxproj
git commit -m "feat(activities): add ActivityWindowChart for before/during/after metric charts"
```

---

### Task 3: Restructure ActivityDetailView

**Files:**
- Modify: `UI/Activities/ActivitiesView.swift`

**Interfaces:**
- Consumes: `ActivityMetricsGrid(entry:)` (Task 1), `ActivityWindowChart(...)` (Task 2), `MetricsHistoryPoint(from: HRVSample)` and `MetricsQualityFilter.filter(_:)` (existing, `Models/MetricsHistoryPoint.swift`).
- Produces: nothing new — `MetricTableHeader` and `MetricRow` are deleted since nothing calls them after this task.

- [ ] **Step 1: Add chart-data state and a loader function**

Find:
```swift
struct ActivityDetailView: View {
    @Environment(\.modelContext) var ctx
    @Environment(\.dismiss) var dismiss
    @Bindable var entry: ActivityLog

    private var timeStr: String {
        let fmt = DateFormatter()
        fmt.dateStyle = .medium
        fmt.timeStyle = .short
        return fmt.string(from: entry.startedAt)
    }
```
Replace with:
```swift
struct ActivityDetailView: View {
    @Environment(\.modelContext) var ctx
    @Environment(\.dismiss) var dismiss
    @Bindable var entry: ActivityLog

    @State private var chartPoints: [MetricsHistoryPoint] = []

    private var timeStr: String {
        let fmt = DateFormatter()
        fmt.dateStyle = .medium
        fmt.timeStyle = .short
        return fmt.string(from: entry.startedAt)
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
        desc.fetchLimit = 2_000
        let samples = (try? ctx.fetch(desc)) ?? []
        chartPoints = MetricsQualityFilter.filter(samples.map { MetricsHistoryPoint(from: $0) })
    }
```

- [ ] **Step 2: Replace the metric table with the grid and charts, add `.onAppear`**

Find:
```swift
                        // Metric table: BEFORE / DURING / AFTER
                        VStack(spacing: 0) {
                            MetricTableHeader()
                            Divider().background(Theme.border)
                            MetricRow(label: "HR",   unit: "bpm",
                                      before: entry.beforeHR,    during: entry.duringHR,    after: entry.afterHR,    fmt: { MetricFormat.bpm($0) })
                            MetricRow(label: "SDNN", unit: "ms",
                                      before: entry.beforeSDNN,  during: entry.duringSDNN,  after: entry.afterSDNN,  fmt: { MetricFormat.ms($0) })
                            MetricRow(label: "RSA",  unit: "ms",
                                      before: entry.beforeRSA,   during: entry.duringRSA,   after: entry.afterRSA,   fmt: { MetricFormat.ms($0) })
                            MetricRow(label: "VTI",  unit: "",
                                      before: entry.beforeVTI,   during: entry.duringVTI,   after: entry.afterVTI,   fmt: { MetricFormat.ratio($0) })
                            MetricRow(label: "LF/HF", unit: "",
                                      before: entry.beforeLFHF,  during: entry.duringLFHF,  after: entry.afterLFHF,  fmt: { MetricFormat.ratio($0) })
                        }
                        .cardStyle()
```
Replace with:
```swift
                        // 9-metric summary
                        ActivityMetricsGrid(entry: entry)

                        // Before/during/after charts, one per metric — same
                        // order as the grid above.
                        let windowEnd = entry.endedAt ?? entry.startedAt
                        ActivityWindowChart(title: "Harmony",             techLabel: "DFA α1", unit: "",    color: entry.activityTypeEnum.color, points: chartPoints, startedAt: entry.startedAt, endedAt: windowEnd) { $0.dfa1.map(Double.init) }
                        ActivityWindowChart(title: "Conscious Breathing", techLabel: "RSA",    unit: "ms",  color: entry.activityTypeEnum.color, points: chartPoints, startedAt: entry.startedAt, endedAt: windowEnd) { $0.rsaMs.map(Double.init) }
                        ActivityWindowChart(title: "Energy Reserve",      techLabel: "HRV",    unit: "ms",  color: entry.activityTypeEnum.color, points: chartPoints, startedAt: entry.startedAt, endedAt: windowEnd) { $0.rmssd.map(Double.init) }
                        ActivityWindowChart(title: "Adaptive Power",      techLabel: "RCMSE",  unit: "",    color: entry.activityTypeEnum.color, points: chartPoints, startedAt: entry.startedAt, endedAt: windowEnd) { $0.rcmse.map(Double.init) }
                        ActivityWindowChart(title: "Inner Noise",         techLabel: "PIP",    unit: "%",   color: entry.activityTypeEnum.color, points: chartPoints, startedAt: entry.startedAt, endedAt: windowEnd) { $0.pip.map(Double.init) }
                        ActivityWindowChart(title: "Calm Reserve",        techLabel: "DC",     unit: "ms",  color: entry.activityTypeEnum.color, points: chartPoints, startedAt: entry.startedAt, endedAt: windowEnd) { $0.dc.map(Double.init) }
                        ActivityWindowChart(title: "Calm Power",          techLabel: "VTI",    unit: "",    color: entry.activityTypeEnum.color, points: chartPoints, startedAt: entry.startedAt, endedAt: windowEnd) { $0.vti.map(Double.init) }
                        ActivityWindowChart(title: "Stress Balance",      techLabel: "LF/HF",  unit: "",    color: entry.activityTypeEnum.color, points: chartPoints, startedAt: entry.startedAt, endedAt: windowEnd) { $0.lfHF.map(Double.init) }
                        ActivityWindowChart(title: "Pulse",               techLabel: "HR",     unit: "bpm", color: entry.activityTypeEnum.color, points: chartPoints, startedAt: entry.startedAt, endedAt: windowEnd) { $0.meanBPM.map(Double.init) }
```

Find (adds `.onAppear` after the `NavigationStack`'s closing brace so chart data loads when the sheet is presented):
```swift
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
        }
    }
```
Replace with:
```swift
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
        }
        .onAppear { loadChartPoints() }
    }
```

- [ ] **Step 3: Delete the now-unused `MetricTableHeader` and `MetricRow`**

Find:
```swift
private struct MetricTableHeader: View {
    var body: some View {
        HStack {
            Text("METRIC")
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("BEFORE")
                .frame(width: 60, alignment: .center)
            Text("DURING")
                .frame(width: 60, alignment: .center)
            Text("AFTER")
                .frame(width: 60, alignment: .center)
            Text("Δ")
                .frame(width: 50, alignment: .trailing)
        }
        .font(Theme.monoLabel)
        .foregroundStyle(Theme.dim)
        .padding(.vertical, 6)
    }
}

private struct MetricRow: View {
    let label:  String
    let unit:   String
    let before: Float?
    let during: Float?
    let after:  Float?
    let fmt:    (Float?) -> String

    private var delta: Float? {
        guard let a = after, let b = before else { return nil }
        return a - b
    }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .font(Theme.monoBody)
                    .foregroundStyle(Theme.text)
                if !unit.isEmpty {
                    Text(unit)
                        .font(Theme.monoLabel)
                        .foregroundStyle(Theme.dim)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(fmt(before))
                .frame(width: 60, alignment: .center)
            Text(fmt(during))
                .frame(width: 60, alignment: .center)
            Text(fmt(after))
                .frame(width: 60, alignment: .center)

            Group {
                if let d = delta {
                    let sign = d >= 0 ? "+" : ""
                    Text("\(sign)\(String(format: "%.1f", d))")
                        .foregroundStyle(d >= 0 ? Theme.accent : Theme.warn)
                } else {
                    Text("—").foregroundStyle(Theme.dim)
                }
            }
            .font(Theme.monoLabel)
            .frame(width: 50, alignment: .trailing)
        }
        .font(Theme.monoLabel)
        .foregroundStyle(Theme.text)
        .padding(.vertical, 8)
        .overlay(alignment: .bottom) {
            Theme.border.frame(height: 0.5).opacity(0.6)
        }
    }
}
```
Replace with nothing (delete the whole block).

- [ ] **Step 4: Build to verify**

```bash
cd /Users/alexutkin/ios && xcodebuild build -project Virtu.xcodeproj -scheme Virtu -destination 'platform=iOS Simulator,name=iPhone 17 Pro' 2>&1 | tail -40
```
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 5: Manual check in Simulator**

```bash
cd /Users/alexutkin/ios
xcrun simctl boot "iPhone 17 Pro" 2>/dev/null; open -a Simulator
xcodebuild -project Virtu.xcodeproj -scheme Virtu -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -derivedDataPath /tmp/jb-build-detail build 2>&1 | tail -5
xcrun simctl install "iPhone 17 Pro" /tmp/jb-build-detail/Build/Products/Debug-iphonesimulator/Virtu.app
xcrun simctl launch "iPhone 17 Pro" com.alexutkin.virtu
```
This environment has previously had no tap/touch-automation tooling available (no idb, no cliclick, no assistive-access `osascript`). Reaching `ActivityDetailView` requires a tap on an activity row (Activities tab → tap a logged entry), which cannot be automated here. Acceptable fallback, consistent with prior sub-projects: confirm build success (already done in Step 4), and verify by code reading that `ActivityMetricsGrid` and the 9 `ActivityWindowChart` calls reference only fields that exist on `ActivityLog`/`MetricsHistoryPoint` (the build's success already proves this via type-checking). If a temporary default-tab change is used to reach the screen for a screenshot, it must be reverted before committing (do not leave it in the diff) — same rule as prior sub-projects. Note in your report whichever verification path was taken.

- [ ] **Step 6: Commit**

```bash
cd /Users/alexutkin/ios && git add Virtu/UI/Activities/ActivitiesView.swift
git commit -m "feat(activities): show 9-metric summary and before/during/after charts in ActivityDetailView"
```
