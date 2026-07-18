# Activity Detail — 9-Metric Summary + Before/During/After Charts — Design Spec
Date: 2026-07-17

## Overview

**Supersedes the list-card portion of `2026-07-17-activity-metrics-card-design.md`.** Mid-implementation of that spec, direction changed: the Activities tab's day-grouped list stays compact (`ActivityLogRow`, unchanged — the 9-tile grid card built for the list is reverted and never wired in there). Instead, the "extended" content moves entirely into the tap-through detail sheet: a 9-metric summary grid (reusing the component already built) plus a before/during/after time-series chart for each of the 9 metrics.

**Already shipped and reused as-is from the prior spec (no changes needed):**
- `Models/ActivityLog.swift` — 15 new `Float?` properties (RMSSD/RCMSE/PIP/DC/DFA1 × before/during/after) and `computeHRVWindows()` extension. Still needed — these power the 9-tile summary grid.
- `UI/Design/MetricTile.swift` — shared tile view, extracted from `LiveView.swift`. Still used, now exclusively inside the detail view's grid.

**Reverted (not part of the shipped branch):** wiring the 9-tile card into the day-grouped list; the list keeps `ActivityLogRow` exactly as it was before this session's work started.

**Repurposed:** the `ActivityMetricsCard` view built for the list (header + 9-tile grid) is trimmed down to just the grid and renamed, then dropped into the detail view instead.

---

## 1. Chart data source

No new SwiftData fields. `Models/MetricsHistoryPoint.swift` already has `init(from: HRVSample)` covering all 9 needed fields (confirmed present: `dfa1`, `rsaMs`, `rmssd`, `rcmse`, `pip`, `dc`, `vti`, `lfHF`, `meanBPM`).

On `ActivityDetailView` appearing, fetch `HRVSample` for the same window `computeHRVWindows` already uses:

```swift
let beforeStart = entry.startedAt.addingTimeInterval(-300)   // 5 min before
let afterEnd    = (entry.endedAt ?? entry.startedAt).addingTimeInterval(600)  // 10 min after
```

Map results through `MetricsHistoryPoint(from:)`, then `MetricsQualityFilter.filter(_:)` (existing wear-detection heuristic, used everywhere else in the app) before charting.

---

## 2. New chart component — `UI/Activities/ActivityWindowChart.swift`

**Why not reuse `MetricChartCard`:** that view (in `MetricsChartsView.swift`) is built around `TimeWindow` (fixed 30m/2h/24h enum) and a `windowDates` calculation that only understands "last N minutes ending at now" (today) or "one full calendar day starting at midnight" (past days). An activity's before/during/after window is an arbitrary past `[start, end]` range of variable length (5 min for a quick breathing exercise, 100+ min for a workout) — retrofitting `MetricChartCard` for this would mean threading a third windowing mode through anomaly-band logic, bucket-date logic, and selection-overlay logic that don't apply here. A new, smaller component is more legible and doesn't risk the live-view charts.

**What's reused from the existing chart, in spirit:** the shaded-region technique (`MetricChartCard`'s anomaly bands prove the pattern works well) is reapplied here for the three activity phases instead of anomaly detection.

**Signature:**

```swift
struct ActivityWindowChart: View {
    let title:         String   // consumer name, e.g. "Harmony"
    let techLabel:     String   // e.g. "DFA α1"
    let unit:          String
    let color:         Color    // activityTypeEnum.color, used for the "during" shaded band
    let points:        [MetricsHistoryPoint]
    let startedAt:     Date
    let endedAt:       Date
    let extract:       (MetricsHistoryPoint) -> Double?
}
```

**Rendering:**
- Background: three `RectangleMark`s spanning the full y-range — `[windowStart, startedAt)` and `[endedAt, windowEnd]` tinted `Theme.dim.opacity(0.06)`, `[startedAt, endedAt)` tinted `color.opacity(0.08)` — plus a `RuleMark` at `startedAt` and at `endedAt`, each with a small label ("START"/"END").
- Foreground: one `LineMark` per bucketed point, color as given, y-axis auto-scaled (no fixed `yDomain` — a short fixed window doesn't need the live view's pan/zoom-friendly fixed domains).
- Bucketing: target ~120 points regardless of window length, same density target as `TimeWindow`'s own `bucketSeconds` (`seconds / 120`), computed here as `(windowEnd.timeIntervalSince(windowStart)) / 120` — so a 15-minute activity buckets at ~7.5s/point and a 100-minute one at ~50s/point, both rendering a similarly-sized chart.
- No data (`points` empty after filtering): show the existing app convention for empty states — a centered "No data" `Text` in `Theme.dim`, same height as a populated chart so the stacked layout doesn't jump.
- Card chrome: wrapped in `.cardStyle()`, consistent with every other card in the app.

---

## 3. Repurpose `ActivityMetricsCard` → `ActivityMetricsGrid`

Rename `UI/Activities/ActivityMetricsCard.swift` → `UI/Activities/ActivityMetricsGrid.swift`, rename the type `ActivityMetricsCard` → `ActivityMetricsGrid`. Remove the header `HStack` (icon/name/time/duration/chevron) — `ActivityDetailView` already renders its own richer header (44pt icon, medium-weight name, full date + duration string). Keep the `LazyVGrid` of 9 `MetricTile`s and the `.cardStyle()` wrapper exactly as built. The 9 tiles, their order, labels, formats, and higher-better directions are unchanged from the prior spec (Harmony/DFA α1 → Pulse/HR, using during-value with during−before delta).

---

## 4. `ActivityDetailView` restructure

Current structure (header → BEFORE/DURING/AFTER metric table → Notes) becomes:

```
NavigationStack
  ScrollView
    Header                        — unchanged (icon, name, date+duration)
    ActivityMetricsGrid(entry:)   — NEW (9-tile snapshot, replaces the metric table)
    9 × ActivityWindowChart       — NEW (one per metric, same order as the grid)
    Notes                         — unchanged
```

`MetricTableHeader` and `MetricRow` (the old BEFORE/DURING/AFTER table views) are deleted — nothing else references them.

The view gains a small amount of state to hold the fetched chart data:

```swift
@State private var chartPoints: [MetricsHistoryPoint] = []
```

populated in `.onAppear` via the fetch described in §1, using `@Environment(\.modelContext) var ctx` (already present on this view).

---

## 5. Files Changed / Created

| Action | File |
|---|---|
| Rename+modify | `UI/Activities/ActivityMetricsCard.swift` → `UI/Activities/ActivityMetricsGrid.swift` (drop header, rename type) |
| Create | `UI/Activities/ActivityWindowChart.swift` |
| Modify | `UI/Activities/ActivitiesView.swift` — `ActivityDetailView` body restructure, HRVSample fetch in `.onAppear`, delete `MetricTableHeader`/`MetricRow` |
| Modify | `JustBreathe.xcodeproj/project.pbxproj` — file reference rename (`ActivityMetricsCard.swift` → `ActivityMetricsGrid.swift`), add entry for `ActivityWindowChart.swift` |

No changes needed to: `Models/ActivityLog.swift`, `Models/MetricsHistoryPoint.swift`, `UI/Design/MetricTile.swift`, `UI/Live/LiveView.swift`, `UI/Live/MetricsChartsView.swift`, the day-grouped list, `ActivityLogRow`, Suggested Now, START/LOG PAST.

---

## 6. Out of Scope

- OpenAI insights/recommendations section, progress chart (sub-project 4)
- Any change to `ActivityLogRow`'s compact list appearance
- A window-length picker or pan/zoom interaction on the detail charts (fixed window only, matching "5 min before, during, and 10 min after" as specified)
