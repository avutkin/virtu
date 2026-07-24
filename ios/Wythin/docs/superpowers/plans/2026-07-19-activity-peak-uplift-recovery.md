# Activity Peak-Uplift & Recovery Visualization Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Refocus the activity detail sheet on how well a practice worked: benefit-direction-aware peak-uplift % on each metric tile, a peak dot on each chart, and recovery readouts (retention % + return-to-baseline time) in the 10-min-after window.

**Architecture:** A new pure, unit-tested value type `ActivityMetricStats` derives peak / uplift / retention / recovery from timed scalar values + a `BenefitDirection`. A shared ordered list of 9 metric definitions drives both the tile grid and the stacked charts, computed once per metric in `ActivityDetailView` so grid, chart dot, and recovery readout can never disagree.

**Tech Stack:** Swift 5 / SwiftUI, Swift Charts, XCTest (`WythinTests`), Xcode project with explicit `PBXFileReference`/`PBXGroup` entries (new files registered in `project.pbxproj` by hand).

## Global Constraints

- Compute logic is unit-tested (`WythinTests`); SwiftUI views are not — matches codebase convention. Verification: build success + the new compute tests passing, plus a manual/visual check where noted.
- Build command:
  ```bash
  cd /Users/alexutkin/ios && xcodebuild build -project Wythin.xcodeproj -scheme Wythin -destination 'platform=iOS Simulator,name=iPhone 17 Pro' 2>&1 | tail -40
  ```
  Expected final line: `** BUILD SUCCEEDED **`
- Test command (whole suite):
  ```bash
  cd /Users/alexutkin/ios && xcodebuild test -project Wythin.xcodeproj -scheme Wythin -destination 'platform=iOS Simulator,name=iPhone 17 Pro' 2>&1 | grep -E "error:|failed \(|Executed"
  ```
  **Two failures are pre-existing and unrelated** (`testBreathingRateInBand` in MetricsTests, `testECGFrameParsing` in BLETests) — both fail on `main` independent of this work. A task is green when it builds and its own new tests pass; do not chase those two.
- Commit after every task, message describing that task only.
- Spec: `docs/superpowers/specs/2026-07-19-activity-peak-uplift-recovery-design.md`.
- All "peak" / "uplift %" must be benefit-direction aware per the spec: `.higher` for RSA/HRV(RMSSD)/RCMSE/DC/VTI, `.lower` for PIP/LF-HF/HR, `.target(1.0)` for DFA α1. A positive `peakUpliftPct` always means "better," so tiles/charts color positive = `Theme.accent`, negative = `Theme.warn`, regardless of raw up/down.
- Do not change the Live tab's `MetricsTableView` / its `MetricTile` calls — `MetricTile`'s existing `delta`/`percent`/`higherBetter` path stays valid; new behavior is opt-in via new optional params.
- Free Xcode IDs to use: `F151`/`A151` (ActivityMetricStats.swift), `FT07`/`AT07` (ActivityMetricStatsTests.swift). Confirmed unused.

---

### Task 1: Create ActivityMetricStats compute type + tests

**Files:**
- Create: `Metrics/ActivityMetricStats.swift`
- Create: `WythinTests/ActivityMetricStatsTests.swift`
- Modify: `Wythin.xcodeproj/project.pbxproj`

**Interfaces:**
- Produces: `enum BenefitDirection { case higher, lower, target(Double) }` with `func benefit(_:) -> Double`; `struct ActivityMetricStats` with fields `baseline, peakValue, peakDate, duringMean, afterMean, peakUpliftPct, avgUpliftPct, retainedPct, timeToBaselineSeconds` (all optional), a core `init(values:direction:startedAt:endedAt:)` and a `init(points:extract:direction:startedAt:endedAt:)` convenience.
- Consumes: `MetricsHistoryPoint` (existing, has `.timestamp` + `Float?` metric fields) for the convenience init only. The core type is pure Foundation.

- [ ] **Step 1: Write `Metrics/ActivityMetricStats.swift`**

```swift
import Foundation

/// Which direction of change counts as "better" for a metric — so peaks and
/// uplift percentages read correctly (a drop in HR is an improvement; a drop
/// in RSA is not).
enum BenefitDirection {
    case higher          // more is better (RSA, HRV, RCMSE, DC, VTI)
    case lower           // less is better (HR, LF/HF, PIP)
    case target(Double)  // closeness to a value is better (DFA α1 → 1.0)

    /// Benefit-signed transform: a higher output is always "better".
    func benefit(_ x: Double) -> Double {
        switch self {
        case .higher:        return x
        case .lower:         return -x
        case .target(let t): return -abs(x - t)
        }
    }
}

/// Peak / uplift / recovery statistics for one metric across an activity's
/// before / during / after windows. Pure and unit-tested; views consume it.
struct ActivityMetricStats {
    let baseline:   Double?   // mean of before-phase values
    let peakValue:  Double?   // during value with the best benefit
    let peakDate:   Date?
    let duringMean: Double?
    let afterMean:  Double?

    let peakUpliftPct: Double?  // benefit-signed, peak vs baseline
    let avgUpliftPct:  Double?  // benefit-signed, during-mean vs baseline
    let retainedPct:   Double?  // how much of the during-peak gain persists after
    let timeToBaselineSeconds: Double?  // endedAt → first near-baseline return

    /// Core initializer over raw timed values (trivially unit-testable).
    /// Values are partitioned by timestamp: before (< startedAt),
    /// during ([startedAt, endedAt)), after (>= endedAt).
    init(values: [(date: Date, value: Double)],
         direction: BenefitDirection,
         startedAt: Date, endedAt: Date) {

        let before = values.filter { $0.date < startedAt }
        let during = values.filter { $0.date >= startedAt && $0.date < endedAt }
        let after  = values.filter { $0.date >= endedAt }

        func mean(_ arr: [(date: Date, value: Double)]) -> Double? {
            guard !arr.isEmpty else { return nil }
            return arr.reduce(0) { $0 + $1.value } / Double(arr.count)
        }

        let baseline   = mean(before)
        let duringMean = mean(during)
        let afterMean  = mean(after)
        let peak       = during.max { direction.benefit($0.value) < direction.benefit($1.value) }

        self.baseline   = baseline
        self.duringMean = duringMean
        self.afterMean  = afterMean
        self.peakValue  = peak?.value
        self.peakDate   = peak?.date

        func upliftPct(_ v: Double?) -> Double? {
            guard let v, let b = baseline else { return nil }
            let bb = direction.benefit(b)
            guard bb != 0 else { return nil }
            return (direction.benefit(v) - bb) / abs(bb) * 100
        }
        self.peakUpliftPct = upliftPct(peak?.value)
        self.avgUpliftPct  = upliftPct(duringMean)

        // Retention + time-to-baseline are only meaningful when the practice
        // actually improved the metric (positive gain in benefit space).
        if let b = baseline, let pk = peak?.value {
            let bb   = direction.benefit(b)
            let gain = direction.benefit(pk) - bb
            if gain > 0 {
                if let am = afterMean {
                    self.retainedPct = (direction.benefit(am) - bb) / gain * 100
                } else {
                    self.retainedPct = nil
                }
                let threshold = 0.1 * gain
                let firstReturn = after
                    .sorted { $0.date < $1.date }
                    .first { direction.benefit($0.value) - bb <= threshold }
                self.timeToBaselineSeconds = firstReturn.map { $0.date.timeIntervalSince(endedAt) }
            } else {
                self.retainedPct = nil
                self.timeToBaselineSeconds = nil
            }
        } else {
            self.retainedPct = nil
            self.timeToBaselineSeconds = nil
        }
    }
}

extension ActivityMetricStats {
    /// Convenience: map MetricsHistoryPoint + extractor into timed values.
    init(points: [MetricsHistoryPoint],
         extract: (MetricsHistoryPoint) -> Double?,
         direction: BenefitDirection,
         startedAt: Date, endedAt: Date) {
        let values = points.compactMap { pt -> (date: Date, value: Double)? in
            guard let v = extract(pt) else { return nil }
            return (pt.timestamp, v)
        }
        self.init(values: values, direction: direction, startedAt: startedAt, endedAt: endedAt)
    }
}
```

- [ ] **Step 2: Write `WythinTests/ActivityMetricStatsTests.swift`**

```swift
import XCTest
@testable import Wythin

final class ActivityMetricStatsTests: XCTestCase {
    // during window is [start, end) = offset [0, 1000); after is offset >= 1000.
    private let start = Date(timeIntervalSince1970: 1000)
    private let end   = Date(timeIntervalSince1970: 2000)

    private func v(_ offset: TimeInterval, _ value: Double) -> (date: Date, value: Double) {
        (start.addingTimeInterval(offset), value)
    }

    func testHigherBetterPeakAndAvgUplift() {
        // before 40; during mean 50 (+25%), peak 60 (+50%)
        let s = ActivityMetricStats(
            values: [v(-200, 40), v(-100, 40), v(100, 40), v(500, 60), v(900, 50)],
            direction: .higher, startedAt: start, endedAt: end)
        XCTAssertEqual(s.baseline!, 40, accuracy: 0.001)
        XCTAssertEqual(s.peakValue!, 60, accuracy: 0.001)
        XCTAssertEqual(s.peakUpliftPct!, 50, accuracy: 0.001)
        XCTAssertEqual(s.avgUpliftPct!, 25, accuracy: 0.001)
    }

    func testLowerBetterDropReadsAsPositiveUplift() {
        // HR-like: before 60, during trough 48 → +20% improvement; peak = lowest
        let s = ActivityMetricStats(
            values: [v(-100, 60), v(100, 60), v(500, 48), v(900, 54)],
            direction: .lower, startedAt: start, endedAt: end)
        XCTAssertEqual(s.peakValue!, 48, accuracy: 0.001)
        XCTAssertEqual(s.peakUpliftPct!, 20, accuracy: 0.001)
        XCTAssertGreaterThan(s.avgUpliftPct!, 0)
    }

    func testTargetGettingCloserIsPositive() {
        // DFA target 1.0: before 0.7 (gap .3), best 0.95 (gap .05) → +83.3%
        let s = ActivityMetricStats(
            values: [v(-100, 0.7), v(500, 0.95), v(900, 0.85)],
            direction: .target(1.0), startedAt: start, endedAt: end)
        XCTAssertEqual(s.peakValue!, 0.95, accuracy: 0.001)
        XCTAssertEqual(s.peakUpliftPct!, 83.333, accuracy: 0.01)
    }

    func testTargetBaselineAtTargetYieldsNilNotCrash() {
        let s = ActivityMetricStats(
            values: [v(-100, 1.0), v(500, 0.9)],
            direction: .target(1.0), startedAt: start, endedAt: end)
        XCTAssertNil(s.peakUpliftPct)
    }

    func testRetentionHalfDecay() {
        // before 40, peak 60 (gain 20), after mean 50 → retained 50%
        let s = ActivityMetricStats(
            values: [v(-100, 40), v(500, 60), v(1100, 50), v(1500, 50)],
            direction: .higher, startedAt: start, endedAt: end)
        XCTAssertEqual(s.retainedPct!, 50, accuracy: 0.001)
    }

    func testTimeToBaselineReturn() {
        // gain 20, threshold 2 → first after value <= 42 returns. v(1300)=41.
        let s = ActivityMetricStats(
            values: [v(-100, 40), v(500, 60), v(1100, 55), v(1300, 41)],
            direction: .higher, startedAt: start, endedAt: end)
        XCTAssertEqual(s.timeToBaselineSeconds!, 300, accuracy: 0.001)
    }

    func testWorsenedMetricHasNoRetentionOrReturn() {
        // during peak (55) worse than baseline (60): gain <= 0
        let s = ActivityMetricStats(
            values: [v(-100, 60), v(500, 55), v(1100, 58)],
            direction: .higher, startedAt: start, endedAt: end)
        XCTAssertNil(s.retainedPct)
        XCTAssertNil(s.timeToBaselineSeconds)
    }

    func testEmptyInputsAreNil() {
        let s = ActivityMetricStats(values: [], direction: .higher, startedAt: start, endedAt: end)
        XCTAssertNil(s.baseline)
        XCTAssertNil(s.peakValue)
        XCTAssertNil(s.peakUpliftPct)
        XCTAssertNil(s.retainedPct)
        XCTAssertNil(s.timeToBaselineSeconds)
    }

    func testNoBeforeYieldsNilUplift() {
        let s = ActivityMetricStats(values: [v(500, 60)], direction: .higher, startedAt: start, endedAt: end)
        XCTAssertNotNil(s.peakValue)
        XCTAssertNil(s.peakUpliftPct)
    }
}
```

- [ ] **Step 3: Register both files in `Wythin.xcodeproj/project.pbxproj`**

Addition A — PBXBuildFile for the source file, immediately after the `A150 /* ActivityWindowChart.swift in Sources */` line:
Find:
```
		A150 /* ActivityWindowChart.swift in Sources */ = {isa = PBXBuildFile; fileRef = F150 /* ActivityWindowChart.swift */; };
```
Replace with:
```
		A150 /* ActivityWindowChart.swift in Sources */ = {isa = PBXBuildFile; fileRef = F150 /* ActivityWindowChart.swift */; };
		A151 /* ActivityMetricStats.swift in Sources */ = {isa = PBXBuildFile; fileRef = F151 /* ActivityMetricStats.swift */; };
```

Addition B — PBXBuildFile for the test file, immediately after the `AT06 /* PayloadBuilderTests.swift in Sources */` line:
Find:
```
		AT06 /* PayloadBuilderTests.swift in Sources */ = {isa = PBXBuildFile; fileRef = FT06 /* PayloadBuilderTests.swift */; };
```
Replace with:
```
		AT06 /* PayloadBuilderTests.swift in Sources */ = {isa = PBXBuildFile; fileRef = FT06 /* PayloadBuilderTests.swift */; };
		AT07 /* ActivityMetricStatsTests.swift in Sources */ = {isa = PBXBuildFile; fileRef = FT07 /* ActivityMetricStatsTests.swift */; };
```

Addition C — PBXFileReference for both, immediately after the `F150 /* ActivityWindowChart.swift */ = {isa = PBXFileReference ...}` line:
Find:
```
		F150 /* ActivityWindowChart.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = ActivityWindowChart.swift; sourceTree = "<group>"; };
```
Replace with:
```
		F150 /* ActivityWindowChart.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = ActivityWindowChart.swift; sourceTree = "<group>"; };
		F151 /* ActivityMetricStats.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = ActivityMetricStats.swift; sourceTree = "<group>"; };
```

Addition D — PBXFileReference for the test, immediately after the `FT06 /* PayloadBuilderTests.swift */ = {isa = PBXFileReference ...}` line:
Find:
```
		FT06 /* PayloadBuilderTests.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = PayloadBuilderTests.swift; sourceTree = "<group>"; };
```
Replace with:
```
		FT06 /* PayloadBuilderTests.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = PayloadBuilderTests.swift; sourceTree = "<group>"; };
		FT07 /* ActivityMetricStatsTests.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = ActivityMetricStatsTests.swift; sourceTree = "<group>"; };
```

Addition E — add `F151` to the `Metrics` group (`GAPP_MET`), after the `F146 /* LiveStateTrendCompute.swift */,` child:
Find:
```
				F146 /* LiveStateTrendCompute.swift */,
			);
			path = Metrics;
```
Replace with:
```
				F146 /* LiveStateTrendCompute.swift */,
				F151 /* ActivityMetricStats.swift */,
			);
			path = Metrics;
```

Addition F — add `FT07` to the `WythinTests` group (`GTESTS`), after the `FT06 /* PayloadBuilderTests.swift */,` child:
Find:
```
				FT06 /* PayloadBuilderTests.swift */,
			);
			path = WythinTests;
```
Replace with:
```
				FT06 /* PayloadBuilderTests.swift */,
				FT07 /* ActivityMetricStatsTests.swift */,
			);
			path = WythinTests;
```

Addition G — add `A151` to the app target's Sources build phase, after the `A150 /* ActivityWindowChart.swift in Sources */,` entry:
Find:
```
				A150 /* ActivityWindowChart.swift in Sources */,
```
Replace with:
```
				A150 /* ActivityWindowChart.swift in Sources */,
				A151 /* ActivityMetricStats.swift in Sources */,
```

Addition H — add `AT07` to the test target's Sources build phase, after the `AT06 /* PayloadBuilderTests.swift in Sources */,` entry:
Find:
```
				AT06 /* PayloadBuilderTests.swift in Sources */,
```
Replace with:
```
				AT06 /* PayloadBuilderTests.swift in Sources */,
				AT07 /* ActivityMetricStatsTests.swift in Sources */,
```

- [ ] **Step 4: Run the new tests**

```bash
cd /Users/alexutkin/ios && xcodebuild test -project Wythin.xcodeproj -scheme Wythin -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:WythinTests/ActivityMetricStatsTests 2>&1 | grep -E "error:|failed \(|passed \(|Executed"
```
Expected: all `ActivityMetricStatsTests` cases pass, `Executed 9 tests, with 0 failures`.

- [ ] **Step 5: Commit**

```bash
cd /Users/alexutkin/ios && git add Wythin/Metrics/ActivityMetricStats.swift WythinTests/ActivityMetricStatsTests.swift Wythin.xcodeproj/project.pbxproj
git commit -m "feat(metrics): add ActivityMetricStats for benefit-aware peak/uplift/recovery"
```
(The test file lives at `ios/WythinTests/ActivityMetricStatsTests.swift` — a sibling of `Wythin/`, alongside `PayloadBuilderTests.swift` etc. — NOT nested under `Wythin/`.)

---

### Task 2: Add peak-mode display to MetricTile

**Files:**
- Modify: `UI/Design/MetricTile.swift`

**Interfaces:**
- Produces: `MetricTile` gains two optional params `peakUpliftPct: Float?` and `avgUpliftPct: Float?`. When `peakUpliftPct != nil`, the tile renders peak-forward: the passed `value` is treated as the peak value; a large bold arrow+percent (colored by the sign of `peakUpliftPct`: `>= 0` → `Theme.accent`, `< 0` → `Theme.warn`) is the headline; a small dim `avg ±N%` is the secondary line. Existing `delta`/`percent`/`higherBetter` behavior (used by the Live tab) is unchanged and used only when `peakUpliftPct == nil`.
- Consumes: nothing new.

- [ ] **Step 1: Replace the whole file `UI/Design/MetricTile.swift`**

```swift
import SwiftUI

struct MetricTile: View {
    let label:         String   // consumer name
    let techLabel:     String   // technical name shown in gray
    let value:         String
    let unit:          String
    let delta:         Float?
    let percent:       Float?   // legacy: when set (and no peakUpliftPct), shown large/bold
    let peakUpliftPct: Float?   // when set, tile renders peak-forward (benefit-signed %)
    let avgUpliftPct:  Float?   // small secondary line in peak mode
    let higherBetter:  Bool

    init(label: String, techLabel: String = "", value: String, unit: String,
         delta: Float? = nil, percent: Float? = nil,
         peakUpliftPct: Float? = nil, avgUpliftPct: Float? = nil,
         higherBetter: Bool = true) {
        self.label         = label
        self.techLabel     = techLabel
        self.value         = value
        self.unit          = unit
        self.delta         = delta
        self.percent       = percent
        self.peakUpliftPct = peakUpliftPct
        self.avgUpliftPct  = avgUpliftPct
        self.higherBetter  = higherBetter
    }

    private var hasData: Bool { value != "—" }
    private var isPeakMode: Bool { peakUpliftPct != nil }

    // Legacy delta coloring (Live tab)
    private var deltaColor: Color {
        guard let d = delta else { return Theme.dim }
        return (d >= 0) == higherBetter ? Theme.accent : Theme.warn
    }
    private var deltaText: String { delta.map { String(format: "%+.1f", $0) } ?? "" }
    private var percentText: String { percent.map { String(format: "%+.0f%%", $0) } ?? "" }

    // Peak mode: benefit-signed, so positive is always good.
    private var peakColor: Color {
        guard let p = peakUpliftPct else { return Theme.dim }
        return p >= 0 ? Theme.accent : Theme.warn
    }
    private var peakText: String {
        guard let p = peakUpliftPct else { return "" }
        return String(format: "%@ %+.0f%%", p >= 0 ? "▲" : "▼", p)
    }
    private var avgText: String {
        avgUpliftPct.map { String(format: "avg %+.0f%%", $0) } ?? ""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(Theme.text)
                .lineLimit(1)
                .truncationMode(.tail)
            if !techLabel.isEmpty {
                Text(techLabel)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(Theme.dim)
                    .lineLimit(1)
                    .padding(.top, -2)
            }

            Text(value)
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .foregroundStyle(hasData ? Theme.text : Theme.dim.opacity(0.4))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(minHeight: 28)

            // Primary line
            HStack(spacing: 4) {
                Text(unit.isEmpty ? " " : unit)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Theme.dim)
                if hasData, isPeakMode {
                    Text(peakText)
                        .font(.system(size: 15, weight: .bold, design: .monospaced))
                        .foregroundStyle(peakColor)
                } else if hasData, percent != nil {
                    Text(percentText)
                        .font(.system(size: 14, weight: .bold, design: .monospaced))
                        .foregroundStyle(deltaColor)
                } else if hasData, delta != nil {
                    Text(deltaText)
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(deltaColor)
                }
            }

            // Secondary line
            if hasData, isPeakMode, avgUpliftPct != nil {
                Text(avgText)
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundStyle(Theme.dim)
            } else if hasData, !isPeakMode, percent != nil, delta != nil {
                Text(deltaText + (unit.isEmpty ? "" : " \(unit)"))
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundStyle(deltaColor.opacity(0.7))
            }
        }
        .frame(maxWidth: .infinity, minHeight: (isPeakMode || percent != nil) ? 104 : 90, alignment: .leading)
        .padding(12)
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}
```

Note: `higherBetter` now defaults to `true` and `delta`/`percent` default to `nil`, so the Live tab's existing call sites (which pass `delta:` and `higherBetter:` positionally by label) still compile unchanged.

- [ ] **Step 2: Build**

```bash
cd /Users/alexutkin/ios && xcodebuild build -project Wythin.xcodeproj -scheme Wythin -destination 'platform=iOS Simulator,name=iPhone 17 Pro' 2>&1 | tail -40
```
Expected: `** BUILD SUCCEEDED **` (the Live tab's `MetricTile(... delta:... higherBetter:...)` calls and the current `ActivityMetricsGrid`'s `percent:` calls both still compile against the widened initializer). 

- [ ] **Step 3: Commit**

```bash
cd /Users/alexutkin/ios && git add Wythin/UI/Design/MetricTile.swift
git commit -m "feat(design): add peak-uplift display mode to MetricTile"
```

---

### Task 3: Shared metric definitions + wire grid, charts, and detail view

**Files:**
- Modify: `UI/Activities/ActivityMetricsGrid.swift`
- Modify: `UI/Activities/ActivityWindowChart.swift`
- Modify: `UI/Activities/ActivitiesView.swift`

These three must land together — the grid/chart API change and the call-site rewrite don't compile independently.

**Interfaces:**
- Produces: file-scope `struct ActivityMetricDef` + `let activityMetricDefs: [ActivityMetricDef]` (in ActivityMetricsGrid.swift); `ActivityMetricsGrid(metrics:)`; `ActivityWindowChart(def:color:points:startedAt:endedAt:stats:)`.
- Consumes: `ActivityMetricStats` / `BenefitDirection` (Task 1), `MetricTile` peak params (Task 2), `MetricsHistoryPoint`, `MetricFormat`.

- [ ] **Step 1: Replace `UI/Activities/ActivityMetricsGrid.swift`**

```swift
import SwiftUI

/// One metric's presentation + data-access definition. Shared by the tile
/// grid and the stacked charts so the two views cannot drift.
struct ActivityMetricDef: Identifiable {
    var id: String { label }
    let label:     String
    let techLabel: String
    let unit:      String
    let direction: BenefitDirection
    let extract:   (MetricsHistoryPoint) -> Double?
    let format:    (Double?) -> String
}

private func f2(_ v: Double?) -> String { v.map { String(format: "%.2f", $0) } ?? "—" }
private func f1(_ v: Double?) -> String { v.map { String(format: "%.1f", $0) } ?? "—" }
private func fFloat(_ v: Double?, _ fmt: (Float?) -> String) -> String { fmt(v.map { Float($0) }) }

/// The 9 metrics, in display order, matching LiveView's MetricsTableView.
let activityMetricDefs: [ActivityMetricDef] = [
    .init(label: "Harmony",             techLabel: "DFA α1", unit: "",    direction: .target(1.0), extract: { $0.dfa1.map(Double.init) },    format: f2),
    .init(label: "Conscious Breathing", techLabel: "RSA",    unit: "ms",  direction: .higher,      extract: { $0.rsaMs.map(Double.init) },   format: { fFloat($0, MetricFormat.ms) }),
    .init(label: "Energy Reserve",      techLabel: "HRV",    unit: "ms",  direction: .higher,      extract: { $0.rmssd.map(Double.init) },   format: { fFloat($0, MetricFormat.ms) }),
    .init(label: "Adaptive Power",      techLabel: "RCMSE",  unit: "",    direction: .higher,      extract: { $0.rcmse.map(Double.init) },   format: f2),
    .init(label: "Inner Noise",         techLabel: "PIP",    unit: "%",   direction: .lower,       extract: { $0.pip.map(Double.init) },     format: f1),
    .init(label: "Calm Reserve",        techLabel: "DC",     unit: "ms",  direction: .higher,      extract: { $0.dc.map(Double.init) },      format: f1),
    .init(label: "Calm Power",          techLabel: "VTI",    unit: "",    direction: .higher,      extract: { $0.vti.map(Double.init) },     format: { fFloat($0, MetricFormat.ratio) }),
    .init(label: "Stress Balance",      techLabel: "LF/HF",  unit: "",    direction: .lower,       extract: { $0.lfHF.map(Double.init) },    format: { fFloat($0, MetricFormat.ratio) }),
    .init(label: "Pulse",               techLabel: "HR",     unit: "bpm", direction: .lower,       extract: { $0.meanBPM.map(Double.init) }, format: { fFloat($0, MetricFormat.bpm) }),
]

/// 3×3 grid of the 9 metrics. Each tile shows the peak-during value with a
/// large benefit-signed peak-uplift % and a small avg-during %. Used inside
/// ActivityDetailView, which renders its own header separately.
struct ActivityMetricsGrid: View {
    let metrics: [(def: ActivityMetricDef, stats: ActivityMetricStats)]

    private let cols = Array(repeating: GridItem(.flexible(), spacing: 10), count: 3)

    var body: some View {
        LazyVGrid(columns: cols, spacing: 10) {
            ForEach(metrics, id: \.def.id) { m in
                MetricTile(
                    label:         m.def.label,
                    techLabel:     m.def.techLabel,
                    value:         m.def.format(m.stats.peakValue),
                    unit:          m.def.unit,
                    peakUpliftPct: m.stats.peakUpliftPct.map { Float($0) },
                    avgUpliftPct:  m.stats.avgUpliftPct.map { Float($0) }
                )
            }
        }
        .cardStyle()
    }
}
```

- [ ] **Step 2: Replace `UI/Activities/ActivityWindowChart.swift`**

```swift
import Charts
import SwiftUI

/// A single metric's before/during/after time series for one activity, with
/// the peak-during point marked and recovery (retention + return-to-baseline)
/// surfaced in the 10-min-after window. Purpose-built for an activity's
/// arbitrary past [start, end] span (not a reuse of MetricsChartsView's
/// day/now-anchored MetricChartCard).
struct ActivityWindowChart: View {
    let def:       ActivityMetricDef
    let color:     Color
    let points:    [MetricsHistoryPoint]
    let startedAt: Date
    let endedAt:   Date
    let stats:     ActivityMetricStats

    private struct Pt: Identifiable {
        let id:   Int
        let date: Date
        let val:  Double
    }

    private var windowStart: Date { startedAt.addingTimeInterval(-300) }
    private var windowEnd:   Date { endedAt.addingTimeInterval(600) }

    /// Buckets to ~120 points regardless of activity length.
    private var bucketed: [Pt] {
        let span = windowEnd.timeIntervalSince(windowStart)
        guard span > 0 else { return [] }
        let bucketSeconds = max(span / 120, 1)
        var sums:   [Int: Double] = [:]
        var counts: [Int: Int]    = [:]
        for pt in points {
            guard let v = def.extract(pt) else { continue }
            let key = Int(pt.timestamp.timeIntervalSince(windowStart) / bucketSeconds)
            sums[key]   = (sums[key]   ?? 0) + v
            counts[key] = (counts[key] ?? 0) + 1
        }
        return sums.keys.sorted().map { key in
            let date = windowStart.addingTimeInterval(Double(key) * bucketSeconds + bucketSeconds / 2)
            return Pt(id: key, date: date, val: sums[key]! / Double(counts[key]!))
        }
    }

    private func pctText(_ p: Double?) -> String? {
        p.map { String(format: "%+.0f%%", $0) }
    }

    private var returnDate: Date? {
        stats.timeToBaselineSeconds.map { endedAt.addingTimeInterval($0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(def.label)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Theme.text)
                if !def.techLabel.isEmpty {
                    Text(def.techLabel)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Theme.dim)
                }
                Spacer()
                if !def.unit.isEmpty {
                    Text(def.unit)
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
                .frame(height: 120)
            } else {
                Chart {
                    // Phase bands
                    RectangleMark(xStart: .value("bs", windowStart), xEnd: .value("be", startedAt))
                        .foregroundStyle(Theme.dim.opacity(0.06))
                    RectangleMark(xStart: .value("ds", startedAt), xEnd: .value("de", endedAt))
                        .foregroundStyle(color.opacity(0.08))
                    RectangleMark(xStart: .value("as", endedAt), xEnd: .value("ae", windowEnd))
                        .foregroundStyle(Theme.dim.opacity(0.06))

                    // Start / end rules
                    RuleMark(x: .value("start", startedAt))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        .foregroundStyle(Theme.dim.opacity(0.5))
                        .annotation(position: .top, alignment: .leading, spacing: 2) {
                            Text("START").font(.system(size: 8, design: .monospaced)).foregroundStyle(Theme.dim)
                        }
                    RuleMark(x: .value("end", endedAt))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        .foregroundStyle(Theme.dim.opacity(0.5))
                        .annotation(position: .top, alignment: .leading, spacing: 2) {
                            Text("END").font(.system(size: 8, design: .monospaced)).foregroundStyle(Theme.dim)
                        }

                    // Phase-average reference lines
                    if let b = stats.baseline {
                        RuleMark(y: .value("before avg", b))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                            .foregroundStyle(Theme.dim.opacity(0.5))
                            .annotation(position: .top, alignment: .trailing, spacing: 2) {
                                Text(String(format: "%.1f", b)).font(.system(size: 8, design: .monospaced)).foregroundStyle(Theme.dim)
                            }
                    }
                    if let d = stats.duringMean {
                        RuleMark(y: .value("during avg", d))
                            .lineStyle(StrokeStyle(lineWidth: 1.5))
                            .foregroundStyle(color.opacity(0.9))
                            .annotation(position: .top, alignment: .trailing, spacing: 2) {
                                HStack(spacing: 3) {
                                    if let p = pctText(stats.avgUpliftPct) {
                                        Text(p).font(.system(size: 11, weight: .bold, design: .monospaced)).foregroundStyle(color)
                                    }
                                    Text(String(format: "%.1f", d)).font(.system(size: 8, design: .monospaced)).foregroundStyle(Theme.dim)
                                }
                            }
                    }
                    if let a = stats.afterMean {
                        RuleMark(y: .value("after avg", a))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 2]))
                            .foregroundStyle(Theme.dim.opacity(0.5))
                            .annotation(position: .bottom, alignment: .trailing, spacing: 2) {
                                HStack(spacing: 3) {
                                    if let held = stats.retainedPct {
                                        Text(String(format: "%.0f%% held", max(0, min(held, 999))))
                                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                                            .foregroundStyle(Theme.dim)
                                    }
                                    Text(String(format: "%.1f", a)).font(.system(size: 8, design: .monospaced)).foregroundStyle(Theme.dim)
                                }
                            }
                    }

                    // The line
                    ForEach(pts) { pt in
                        LineMark(x: .value("time", pt.date), y: .value(def.label, pt.val))
                            .foregroundStyle(color)
                            .interpolationMethod(.catmullRom)
                            .lineStyle(StrokeStyle(lineWidth: 1.5))
                    }

                    // Peak dot (halo + point) with uplift annotation
                    if let pv = stats.peakValue, let pd = stats.peakDate {
                        PointMark(x: .value("peak time", pd), y: .value("peak", pv))
                            .symbolSize(160)
                            .foregroundStyle(color.opacity(0.25))
                        PointMark(x: .value("peak time", pd), y: .value("peak", pv))
                            .symbolSize(60)
                            .foregroundStyle(color)
                            .annotation(position: .top, spacing: 3) {
                                if let p = stats.peakUpliftPct {
                                    Text(String(format: "%@ %+.0f%%", p >= 0 ? "▲" : "▼", p))
                                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                                        .foregroundStyle(p >= 0 ? Theme.accent : Theme.warn)
                                }
                            }
                    }

                    // Return-to-baseline marker in the after window
                    if let rd = returnDate, let b = stats.baseline {
                        PointMark(x: .value("return", rd), y: .value("baseline", b))
                            .symbolSize(40)
                            .foregroundStyle(Theme.dim)
                            .annotation(position: .bottom, spacing: 2) {
                                Text(String(format: "↩ ~%.0fm", (stats.timeToBaselineSeconds ?? 0) / 60))
                                    .font(.system(size: 8, design: .monospaced))
                                    .foregroundStyle(Theme.dim)
                            }
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
                .frame(height: 120)
            }
        }
        .cardStyle()
    }
}
```

- [ ] **Step 3: Rewire `ActivityDetailView` in `UI/Activities/ActivitiesView.swift`**

Find (the grid + 9 chart call block):
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
Replace with:
```swift
                        // Compute peak/uplift/recovery once per metric, shared
                        // by the summary grid and the charts so they can't drift.
                        let windowEnd = entry.endedAt ?? entry.startedAt
                        let metrics = activityMetricDefs.map { def in
                            (def: def,
                             stats: ActivityMetricStats(points: chartPoints,
                                                        extract: def.extract,
                                                        direction: def.direction,
                                                        startedAt: entry.startedAt,
                                                        endedAt: windowEnd))
                        }

                        // 9-metric summary
                        ActivityMetricsGrid(metrics: metrics)

                        // Before/during/after charts, one per metric — same order.
                        ForEach(metrics, id: \.def.id) { m in
                            ActivityWindowChart(def: m.def,
                                                color: entry.activityTypeEnum.color,
                                                points: chartPoints,
                                                startedAt: entry.startedAt,
                                                endedAt: windowEnd,
                                                stats: m.stats)
                        }
```

- [ ] **Step 4: Build**

```bash
cd /Users/alexutkin/ios && xcodebuild build -project Wythin.xcodeproj -scheme Wythin -destination 'platform=iOS Simulator,name=iPhone 17 Pro' 2>&1 | tail -40
```
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 5: Full test run (guard against regressions)**

```bash
cd /Users/alexutkin/ios && xcodebuild test -project Wythin.xcodeproj -scheme Wythin -destination 'platform=iOS Simulator,name=iPhone 17 Pro' 2>&1 | grep -E "failed \(|Executed"
```
Expected: only the two known-unrelated failures (`testBreathingRateInBand`, `testECGFrameParsing`); `ActivityMetricStatsTests` all pass.

- [ ] **Step 6: Manual/visual check (best effort)**

If tap-automation tooling is unavailable (it has been in prior sessions), reaching `ActivityDetailView` requires tapping a logged activity row; fall back to build success + code reading, consistent with prior sub-projects. If a temporary default-tab change is used to screenshot, revert it before committing (`git diff` on `WythinApp.swift` must be empty). Confirm the grid tiles show a large ▲/▼ % with a small `avg ±%`, and (with data) the charts show a peak dot + phase-average lines + a recovery/return annotation. Report which verification path was taken.

- [ ] **Step 7: Commit**

```bash
cd /Users/alexutkin/ios && git add Wythin/UI/Activities/ActivityMetricsGrid.swift Wythin/UI/Activities/ActivityWindowChart.swift Wythin/UI/Activities/ActivitiesView.swift
git commit -m "feat(activities): peak-uplift tiles + peak dot & recovery on charts via shared metric defs"
```
