# Extended Activity Card with 9 Live Metrics — Design Spec
Date: 2026-07-17

## Overview

Sub-project 2 of 4 in the Activities redesign (see `2026-07-17-activities-tab-restructure-design.md` for sub-project 1, already shipped). Replaces the compact `ActivityLogRow` in the day-grouped activity list with an extended card showing the same 9 key metrics displayed live in the Live tab's `MetricsTableView`, so a logged activity reads with the same vocabulary and visual language as the live dashboard.

**Sub-projects:**
1. ~~Tab restructure~~ (shipped)
2. **This spec** — extended 9-metric activity card
3. Per-activity before/during/after chart detail view (future spec)
4. OpenAI-backed insights/recommendations section + progress chart (future spec — spec/plan docs for this already exist: `2026-07-17-openai-activity-insights-design.md`)

---

## 1. Data model — `Models/ActivityLog.swift`

Add 5 new metrics, each as before/during/after `Float?` triplets, following the exact existing pattern (`beforeX`/`duringX`/`afterX`):

```swift
var beforeRMSSD: Float?; var duringRMSSD: Float?; var afterRMSSD: Float?
var beforeRCMSE: Float?; var duringRCMSE: Float?; var afterRCMSE: Float?
var beforePIP:   Float?; var duringPIP:   Float?; var afterPIP:   Float?
var beforeDC:    Float?; var duringDC:    Float?; var afterDC:    Float?
var beforeDFA1:  Float?; var duringDFA1:  Float?; var afterDFA1:  Float?
```

All 5 source fields (`rmssd`, `rcmse`, `pip`, `dc`, `dfa1`) already exist on `HRVSample` — confirmed present, no new sensor computation needed. `computeHRVWindows(context:)` gets 5 more `avg(...)` calls, following the exact pattern already used for the other 5 metrics:

```swift
beforeRMSSD = avg(before, \.rmssd);  duringRMSSD = avg(during, \.rmssd);  afterRMSSD = avg(after, \.rmssd)
beforeRCMSE = avg(before, \.rcmse);  duringRCMSE = avg(during, \.rcmse);  afterRCMSE = avg(after, \.rcmse)
beforePIP   = avg(before, \.pip);    duringPIP   = avg(during, \.pip);    afterPIP   = avg(after, \.pip)
beforeDC    = avg(before, \.dc);     duringDC    = avg(during, \.dc);     afterDC    = avg(after, \.dc)
beforeDFA1  = avg(before, \.dfa1);   duringDFA1  = avg(during, \.dfa1);   afterDFA1  = avg(after, \.dfa1)
```

This is a purely additive SwiftData schema change (new optional properties) — existing rows get `nil` for the new fields, no migration/deletion needed.

The existing `SDNN` before/during/after triplet is untouched — it's still used by the unmodified `ActivityDetailView` table (sub-project 3's concern, not this one).

---

## 2. The extended card

### New file: `UI/Activities/ActivityMetricsCard.swift`

Replaces `ActivityLogRow` as the row view used inside each day's `Section` in `ActivitiesView.swift`. Keeps `ActivitiesView.swift` from growing after already being trimmed in sub-project 1.

**Structure:**

```
VStack
  HStack                                    — header (unchanged content from today's ActivityLogRow)
    Icon (activityTypeEnum.icon/color)
    VStack: displayName, time + duration/LIVE
    Spacer
    chevron.right
  LazyVGrid(columns: 3, spacing: 10)         — NEW: 9 metric tiles
    9 × MetricTile(...)
```

### The 9 tiles — exact mirror of `LiveView.swift`'s `MetricsTableView`

| # | Consumer name | Tech label | Source field | Format | Unit | Higher better? |
|---|---|---|---|---|---|---|
| 1 | Harmony | DFA α1 | `duringDFA1` | `%.2f` | — | No |
| 2 | Conscious Breathing | RSA | `duringRSA` | `MetricFormat.ms` | ms | Yes |
| 3 | Energy Reserve | HRV | `duringRMSSD` | `MetricFormat.ms` | ms | Yes |
| 4 | Adaptive Power | RCMSE | `duringRCMSE` | `%.2f` | — | Yes |
| 5 | Inner Noise | PIP | `duringPIP` | `%.1f` | % | No |
| 6 | Calm Reserve | DC | `duringDC` | `%.1f` | ms | Yes |
| 7 | Calm Power | VTI | `duringVTI` | `MetricFormat.ratio` | — | Yes |
| 8 | Stress Balance | LF/HF | `duringLFHF` | `MetricFormat.ratio` | — | No |
| 9 | Pulse | HR | `duringHR` | `MetricFormat.bpm` | bpm | No |

Formats and higher-better directions are copied verbatim from `MetricsTableView`'s existing `dfa1String`/`rcmseString`/`pipString`/`dcString` helpers and its `MetricTile(...)` call sites.

**Value shown:** the *during* average is the tile's primary value (mirrors Live's `tick`). The delta badge is *during − before* (mirrors Live's `tick` vs `comparison` day-average, and matches the existing compact row's during/before delta convention — no new convention introduced). A tile with no data (both `nil`) shows `"—"` and no delta, same as `MetricTile`'s existing `hasData` handling.

**Visual style:** reuse `MetricTile`'s existing rendering rules (two-line label, bold value, unit, colored delta) so the card reads as the same design language as the Live tab. Tile grid uses a 3-column `LazyVGrid`, `spacing: 10`, matching `MetricsTableView`'s own grid parameters.

### Card container

Wrapped in `.cardStyle()` (existing modifier), consistent with other cards in the app.

---

## 3. Behavior — unchanged from sub-project 1

- Tap on the card → still opens the existing `ActivityDetailView` sheet via `activeSheet = .detail(entry)`. `ActivityDetailView`'s own content (the before/during/after table) is untouched by this sub-project — it becomes a chart view in sub-project 3.
- Swipe actions (edit/delete) — unchanged.
- Day-grouping, section headers, sort order, active-activity banner, Suggested Now, START/LOG PAST — all unchanged from sub-project 1.

---

## 4. Files Changed / Created

| Action | File |
|---|---|
| Modify | `Models/ActivityLog.swift` — 15 new `Float?` properties, extend `computeHRVWindows()` |
| Move | `MetricTile` out of `LiveView.swift` (currently `private struct`) into `UI/Design/MetricTile.swift` as an internal (non-private) type, so both `MetricsTableView` (Live) and the new `ActivityMetricsCard` (Activities) share one implementation instead of duplicating ~70 lines of view code |
| Create | `UI/Activities/ActivityMetricsCard.swift` — new card view (header + 9-tile `LazyVGrid` using the shared `MetricTile`) |
| Modify | `UI/Activities/ActivitiesView.swift` — swap `ActivityLogRow(entry:)` for `ActivityMetricsCard(entry:)` in the day-grouped `ForEach`; remove the now-unused `ActivityLogRow` struct |
| Modify | `UI/Live/LiveView.swift` — remove `MetricTile`'s definition (moved out), update any internal references to use the shared type (same type name, so call sites in `MetricsTableView` need no changes beyond the import already being in-module) |

---

## 5. Out of Scope

- Chart-based before/during/after detail view (sub-project 3)
- OpenAI insights/recommendations section, progress chart (sub-project 4)
- Any change to `ActivityDetailView`'s existing before/during/after table (still shows HR/SDNN/RSA/VTI/LF/HF as today)
- Any change to the Impact section, Suggested Now, START/LOG PAST, day-grouping logic (all already handled in sub-project 1)
