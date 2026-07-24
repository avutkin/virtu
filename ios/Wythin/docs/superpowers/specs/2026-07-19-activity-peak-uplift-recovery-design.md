# Activity Peak-Uplift & Recovery Visualization — Design Spec
Date: 2026-07-19

## Overview

Improve the activity detail sheet's metric visualization to focus on **how well a
practice actually worked** across metrics: emphasize peak uplift during practice
(as a benefit-direction-aware percentage), mark the peak visually on each chart,
and surface recovery in the 10-min-after window (how much of the gain is held and
how fast the metric returns toward baseline).

This refines the views shipped in `2026-07-17-activity-detail-charts-design.md`
(the 9-metric grid + before/during/after charts) and the tile-percent work that
followed it. No SwiftData schema change.

**Core accuracy principle:** every "peak" and "improvement %" is *benefit-direction
aware*. For metrics where lower is better (HR, LF/HF, PIP) the peak is the lowest
point and a decrease reads as a positive improvement; for higher-is-better metrics
(RSA, HRV/RMSSD, RCMSE, DC, VTI) the peak is the highest point; DFA α1 (Harmony)
measures getting *closer to 1.0*. Without this, a peak HR would misleadingly look
like a great outcome.

---

## 1. New compute unit — `Metrics/ActivityMetricStats.swift`

A pure, unit-tested value type (matching the codebase convention that compute logic
lives in `Metrics/` and is covered by `WythinTests`, while views are not). It
takes time-stamped scalar values plus a benefit direction and the activity's
start/end, and derives the stats both the tiles and charts consume.

```swift
enum BenefitDirection {
    case higher          // more is better (RSA, HRV, RCMSE, DC, VTI)
    case lower           // less is better (HR, LF/HF, PIP)
    case target(Double)  // closeness to a value is better (DFA α1 → 1.0)
}

struct ActivityMetricStats {
    let baseline:   Double?   // mean of before-phase values (date < startedAt)
    let peakValue:  Double?   // during value with the best benefit
    let peakDate:   Date?
    let duringMean: Double?
    let afterMean:  Double?

    let peakUpliftPct: Double?  // benefit-signed, peak vs baseline
    let avgUpliftPct:  Double?  // benefit-signed, during-mean vs baseline
    let retainedPct:   Double?  // how much of the during-peak gain persists after
    let timeToBaselineSeconds: Double?  // from endedAt to first near-baseline return

    /// Core initializer — operates on raw timed values so it is trivial to
    /// unit-test without constructing MetricsHistoryPoint.
    init(values: [(date: Date, value: Double)],
         direction: BenefitDirection,
         startedAt: Date, endedAt: Date)
}

extension ActivityMetricStats {
    /// Convenience: map MetricsHistoryPoint + extractor into timed values.
    init(points: [MetricsHistoryPoint],
         extract: (MetricsHistoryPoint) -> Double?,
         direction: BenefitDirection,
         startedAt: Date, endedAt: Date)
}
```

### Computation

Let `b(x)` be the **benefit-signed** transform, so higher `b` is always better:
- `.higher`: `b(x) = x`
- `.lower`:  `b(x) = -x`
- `.target(t)`: `b(x) = -abs(x - t)`

Partition the input values by timestamp into before (`date < startedAt`), during
(`startedAt <= date < endedAt`), after (`date >= endedAt`). The caller has already
bounded the fetched values to `[startedAt-5min, endedAt+10min]`, so no extra window
bounds are needed.

- `baseline` = mean of before-phase raw values (nil if none).
- `peakValue` / `peakDate` = the during value maximizing `b(value)` (nil if no
  during values).
- `duringMean` / `afterMean` = mean of during / after raw values (nil if none).
- `peakUpliftPct` = `(b(peak) - b(baseline)) / |b(baseline)| * 100`, requires
  baseline and peak present and `b(baseline) != 0` (else nil).
- `avgUpliftPct` = same with `duringMean` in place of `peak`.
- `gain` = `b(peak) - b(baseline)` (the during-peak improvement in benefit space).
- `retainedPct` = `(b(afterMean) - b(baseline)) / gain * 100`, only when `gain > 0`
  and both present (else nil — nothing to "retain" if the practice didn't improve
  the metric). May exceed 100 (held more than peak) or go negative (overshot back);
  the view clamps for display, the compute value is raw.
- `timeToBaselineSeconds` = for after-phase values in time order, the first whose
  `b(value) - b(baseline) <= 0.1 * gain` (returned within 10% of the gain of
  baseline); result is `date - endedAt`. Requires `gain > 0`; nil if never returns
  or gain ≤ 0.

All ratios guard their denominators; any missing-data path yields nil so the UI can
show "—".

### Tests — `WythinTests/ActivityMetricStatsTests.swift`

Cover, using the `values:` initializer with hand-built timed points:
- `.higher` metric: a during peak above baseline → positive `peakUpliftPct`; a
  synthetic after-phase that decays halfway → `retainedPct ≈ 50%`; and a return
  within threshold → a finite `timeToBaselineSeconds`.
- `.lower` metric: a during trough *below* baseline reads as a *positive*
  `peakUpliftPct` (improvement), confirming direction-awareness.
- `.target(1.0)`: a during value closer to 1.0 than baseline yields positive uplift;
  a baseline exactly at 1.0 yields nil (zero denominator), not a crash.
- Empty / no-before / no-during inputs → nil fields, no crash.
- `gain <= 0` (practice worsened the metric) → `retainedPct` and
  `timeToBaselineSeconds` nil.

---

## 2. Metric tiles — `MetricTile.swift` + `ActivityMetricsGrid.swift`

### `MetricTile`
Extend to present peak-forward information. Add optional inputs (keeping the Live
tab's existing call sites valid, since they won't pass the new fields):
- The **displayed value** becomes the peak-during value (the best moment) when a
  peak is provided; otherwise unchanged.
- **Primary (large, bold, colored)**: `peakUpliftPct`, formatted `▲ +38%` /
  `▼ -12%` with an arrow indicating the benefit direction of the change, colored
  `Theme.accent` for improvement and `Theme.warn` for regression.
- **Secondary (small, dim)**: `avgUpliftPct`, e.g. `avg +12%`.
- Missing peak/uplift → "—", same fixed tile height as today.

### `ActivityMetricsGrid`
Now needs the raw points and a per-metric `BenefitDirection`, not just the stored
before/during/after scalars. Change its input to accept `points:
[MetricsHistoryPoint]` and, for each of the 9 metrics, build an
`ActivityMetricStats` via the extractor + direction, then feed the tile. The 9
metric definitions (label, techLabel, unit, extractor, direction) become a single
ordered list shared with the charts (see §4) so grid and charts cannot drift.

Directions:
Harmony/DFA α1 → `.target(1.0)`; Conscious Breathing/RSA, Energy Reserve/HRV,
Adaptive Power/RCMSE, Calm Reserve/DC, Calm Power/VTI → `.higher`; Inner Noise/PIP,
Stress Balance/LF/HF, Pulse/HR → `.lower`.

---

## 3. Charts — `ActivityWindowChart.swift`

Keep the existing full before/during/**10-min-after** window, phase bands, and
start/end rule marks. Add:
- A **peak dot** — a `PointMark` (with a subtle halo `PointMark` behind it) at
  `(peakDate, peakValue)`, in the metric color, annotated with the peak uplift %
  (`▲ +38%`) so the top number is visually located on the curve.
- The three **phase-average reference lines** (before/during/after) — retained;
  during and after annotated with their % vs baseline. The after line's annotation
  also shows retention (`+26% · 70% held`).
- A **return-to-baseline marker** — a small `PointMark`/rule at the
  `timeToBaselineSeconds` position on the after-phase curve, labeled `↩ ~4m`, when a
  return is detected; omitted otherwise.
- Empty-data path unchanged ("No data", fixed height).

The chart takes an `ActivityMetricStats` (computed once by the caller and shared
with the tile) rather than recomputing, so the dot, the tile's headline %, and the
recovery readout are guaranteed consistent.

---

## 4. Shared metric definition & call sites — `ActivitiesView.swift`

Introduce one ordered list of the 9 metrics (label, techLabel, unit, extractor,
direction) used by both `ActivityMetricsGrid` and the stacked charts, so the two
views stay in lockstep. `ActivityDetailView` computes `ActivityMetricStats` per
metric once from `chartPoints` and passes each to both the corresponding tile and
chart. `loadChartPoints()`'s fetch window and limit are unchanged (already covers
multi-hour activities after the earlier fix).

---

## 5. Files Changed / Created

| Action | File |
|---|---|
| Create | `Metrics/ActivityMetricStats.swift` |
| Create | `WythinTests/ActivityMetricStatsTests.swift` |
| Modify | `UI/Design/MetricTile.swift` — peak value + big uplift % + small avg % |
| Modify | `UI/Activities/ActivityMetricsGrid.swift` — take points + direction, compute stats per tile |
| Modify | `UI/Activities/ActivityWindowChart.swift` — peak dot, retention, return marker; take stats |
| Modify | `UI/Activities/ActivitiesView.swift` — shared 9-metric list, compute stats once, pass to grid + charts |
| Modify | `Wythin.xcodeproj/project.pbxproj` — register the 2 new files |

---

## 6. Out of Scope

- Any change to the Live tab's `MetricsTableView` (its `MetricTile` calls stay valid
  via the new optional params).
- OpenAI insight generation, the Notes card, day-grouped list, Suggested Now.
- Cross-activity trends / history-of-this-metric (a possible later feature).
