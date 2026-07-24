# Extended Activity Card with 9 Live Metrics Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the compact `ActivityLogRow` in the Activities tab's day-grouped list with an extended card showing the same 9 key metrics displayed live in the Live tab (Harmony/DFA α1, Conscious Breathing/RSA, Energy Reserve/HRV, Adaptive Power/RCMSE, Inner Noise/PIP, Calm Reserve/DC, Calm Power/VTI, Stress Balance/LF/HF, Pulse/HR), in a 3×3 grid.

**Architecture:** Extend `ActivityLog`'s existing before/during/after averaging pattern with 5 more metrics (all already present on `HRVSample`, no new sensor computation). Extract the existing `MetricTile` view out of `LiveView.swift` into a shared file so both the Live tab and the new Activities card render identical tiles. Add one new card view that reuses the shared tile.

**Tech Stack:** Swift 5 / SwiftUI, SwiftData (`@Model`, `computeHRVWindows`), Xcode project with explicit `PBXFileReference`/`PBXGroup` entries (no synchronized folder groups — new files must be registered in `project.pbxproj` by hand).

## Global Constraints

- No unit-test target covers SwiftUI view/model files in this codebase (`WythinTests` only covers BLE parsing and metrics compute logic) — verification for every task is **build success** (`xcodebuild build`) plus, where noted, a manual Simulator check.
- Build verification command (use for every task):
  ```bash
  cd /Users/alexutkin/ios && xcodebuild build -project Wythin.xcodeproj -scheme Wythin -destination 'platform=iOS Simulator,name=iPhone 17 Pro' 2>&1 | tail -40
  ```
  Expected final line: `** BUILD SUCCEEDED **`
- Commit after every task with a message describing that task only.
- The spec is `docs/superpowers/specs/2026-07-17-activity-metrics-card-design.md` — re-read it if anything here seems ambiguous.
- Do not change `ActivityDetailView`'s existing before/during/after table (still HR/SDNN/RSA/VTI/LF/HF) — untouched in this sub-project.
- Do not change day-grouping, section headers, Suggested Now, START/LOG PAST, or the active-activity banner — all unchanged from sub-project 1.
- The 9 tiles' labels, order, formats, units, and higher-better direction must match the table in the spec exactly — this mirrors `LiveView.swift`'s existing `MetricsTableView` verbatim, it is not a new design.

---

### Task 1: Extend ActivityLog with 5 new before/during/after metrics

**Files:**
- Modify: `Models/ActivityLog.swift`

**Interfaces:**
- Produces: `ActivityLog.{before,during,after}RMSSD`, `{before,during,after}RCMSE`, `{before,during,after}PIP`, `{before,during,after}DC`, `{before,during,after}DFA1` — all `Float?`. Populated by `computeHRVWindows(context:)` alongside the existing 5 metrics.

- [ ] **Step 1: Add the 5 new property triplets**

Find:
```swift
    // HRV averages: 5-min before / during / 10-min after
    var beforeHR:    Float?;  var duringHR:    Float?;  var afterHR:    Float?
    var beforeSDNN:  Float?;  var duringSDNN:  Float?;  var afterSDNN:  Float?
    var beforeRSA:   Float?;  var duringRSA:   Float?;  var afterRSA:   Float?
    var beforeVTI:   Float?;  var duringVTI:   Float?;  var afterVTI:   Float?
    var beforeLFHF:  Float?;  var duringLFHF:  Float?;  var afterLFHF:  Float?
```
Replace with:
```swift
    // HRV averages: 5-min before / during / 10-min after
    var beforeHR:    Float?;  var duringHR:    Float?;  var afterHR:    Float?
    var beforeSDNN:  Float?;  var duringSDNN:  Float?;  var afterSDNN:  Float?
    var beforeRSA:   Float?;  var duringRSA:   Float?;  var afterRSA:   Float?
    var beforeVTI:   Float?;  var duringVTI:   Float?;  var afterVTI:   Float?
    var beforeLFHF:  Float?;  var duringLFHF:  Float?;  var afterLFHF:  Float?
    var beforeRMSSD: Float?;  var duringRMSSD: Float?;  var afterRMSSD: Float?
    var beforeRCMSE: Float?;  var duringRCMSE: Float?;  var afterRCMSE: Float?
    var beforePIP:   Float?;  var duringPIP:   Float?;  var afterPIP:   Float?
    var beforeDC:    Float?;  var duringDC:    Float?;  var afterDC:    Float?
    var beforeDFA1:  Float?;  var duringDFA1:  Float?;  var afterDFA1:  Float?
```

- [ ] **Step 2: Extend `computeHRVWindows` to populate them**

Find:
```swift
        beforeHR    = avg(before, \.meanBPM);   duringHR    = avg(during, \.meanBPM);   afterHR    = avg(after, \.meanBPM)
        beforeSDNN  = avg(before, \.sdnn);       duringSDNN  = avg(during, \.sdnn);       afterSDNN  = avg(after, \.sdnn)
        beforeRSA   = avg(before, \.rsaMs);      duringRSA   = avg(during, \.rsaMs);      afterRSA   = avg(after, \.rsaMs)
        beforeVTI   = vtiFromRMSSD(before);      duringVTI   = vtiFromRMSSD(during);      afterVTI   = vtiFromRMSSD(after)
        beforeLFHF  = avg(before, \.lfHF);       duringLFHF  = avg(during, \.lfHF);       afterLFHF  = avg(after, \.lfHF)
    }
}
```
Replace with:
```swift
        beforeHR    = avg(before, \.meanBPM);   duringHR    = avg(during, \.meanBPM);   afterHR    = avg(after, \.meanBPM)
        beforeSDNN  = avg(before, \.sdnn);       duringSDNN  = avg(during, \.sdnn);       afterSDNN  = avg(after, \.sdnn)
        beforeRSA   = avg(before, \.rsaMs);      duringRSA   = avg(during, \.rsaMs);      afterRSA   = avg(after, \.rsaMs)
        beforeVTI   = vtiFromRMSSD(before);      duringVTI   = vtiFromRMSSD(during);      afterVTI   = vtiFromRMSSD(after)
        beforeLFHF  = avg(before, \.lfHF);       duringLFHF  = avg(during, \.lfHF);       afterLFHF  = avg(after, \.lfHF)
        beforeRMSSD = avg(before, \.rmssd);      duringRMSSD = avg(during, \.rmssd);      afterRMSSD = avg(after, \.rmssd)
        beforeRCMSE = avg(before, \.rcmse);      duringRCMSE = avg(during, \.rcmse);      afterRCMSE = avg(after, \.rcmse)
        beforePIP   = avg(before, \.pip);        duringPIP   = avg(during, \.pip);        afterPIP   = avg(after, \.pip)
        beforeDC    = avg(before, \.dc);         duringDC    = avg(during, \.dc);         afterDC    = avg(after, \.dc)
        beforeDFA1  = avg(before, \.dfa1);       duringDFA1  = avg(during, \.dfa1);       afterDFA1  = avg(after, \.dfa1)
    }
}
```

- [ ] **Step 3: Build to verify**

```bash
cd /Users/alexutkin/ios && xcodebuild build -project Wythin.xcodeproj -scheme Wythin -destination 'platform=iOS Simulator,name=iPhone 17 Pro' 2>&1 | tail -40
```
Expected: `** BUILD SUCCEEDED **`. `rmssd`, `rcmse`, `pip`, `dc`, `dfa1` already exist as `Float?` fields on `HRVSample` (confirmed present in `Models/HRVSample.swift`), so no other file needs to change for this to compile.

- [ ] **Step 4: Commit**

```bash
cd /Users/alexutkin/ios && git add Wythin/Models/ActivityLog.swift
git commit -m "feat(models): add RMSSD/RCMSE/PIP/DC/DFA1 before-during-after tracking to ActivityLog"
```

---

### Task 2: Extract MetricTile into a shared file

**Files:**
- Create: `UI/Design/MetricTile.swift`
- Modify: `UI/Live/LiveView.swift`
- Modify: `Wythin.xcodeproj/project.pbxproj`

**Interfaces:**
- Produces: `MetricTile` (no longer `private`, usable from any file in the module). Same initializer and rendering as before — this task moves code, it does not change behavior.
- Consumes: `Theme.dim`, `Theme.text`, `Theme.surface` (existing, unchanged).

- [ ] **Step 1: Create the new file**

Write `ios/Wythin/UI/Design/MetricTile.swift`:

```swift
import SwiftUI

struct MetricTile: View {
    let label:        String   // consumer name
    let techLabel:    String   // technical name shown in gray
    let value:        String
    let unit:         String
    let delta:        Float?
    let higherBetter: Bool

    init(label: String, techLabel: String = "", value: String, unit: String,
         delta: Float?, higherBetter: Bool) {
        self.label        = label
        self.techLabel    = techLabel
        self.value        = value
        self.unit         = unit
        self.delta        = delta
        self.higherBetter = higherBetter
    }

    private var deltaColor: Color {
        guard let d = delta else { return Theme.dim }
        let positive = d >= 0
        return (positive == higherBetter) ? Theme.accent : Theme.warn
    }

    private var deltaText: String {
        guard let d = delta else { return "" }
        return String(format: "%+.1f", d)
    }

    private var hasData: Bool { value != "—" }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Line 1 — white consumer name
            Text(label)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(Theme.text)
                .lineLimit(1)
                .truncationMode(.tail)
            // Line 2 — gray technical term (tight spacing so they read as one label)
            if !techLabel.isEmpty {
                Text(techLabel)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(Theme.dim)
                    .lineLimit(1)
                    .padding(.top, -2)
            }

            // Value — fixed height so all tiles are the same size
            Text(value)
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .foregroundStyle(hasData ? Theme.text : Theme.dim.opacity(0.4))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(minHeight: 28)

            // Unit + delta — always rendered to lock row height
            HStack(spacing: 4) {
                Text(unit.isEmpty ? " " : unit)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Theme.dim)
                if hasData, delta != nil {
                    Text(deltaText)
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(deltaColor)
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 90, alignment: .leading)
        .padding(12)
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}
```

- [ ] **Step 2: Remove the old definition from LiveView.swift**

In `ios/Wythin/UI/Live/LiveView.swift`, find and delete this entire block (it currently sits directly after `MetricsTableView`, just before `// MARK: - Preview`):

```swift
private struct MetricTile: View {
    let label:        String   // consumer name
    let techLabel:    String   // technical name shown in gray
    let value:        String
    let unit:         String
    let delta:        Float?
    let higherBetter: Bool

    init(label: String, techLabel: String = "", value: String, unit: String,
         delta: Float?, higherBetter: Bool) {
        self.label        = label
        self.techLabel    = techLabel
        self.value        = value
        self.unit         = unit
        self.delta        = delta
        self.higherBetter = higherBetter
    }

    private var deltaColor: Color {
        guard let d = delta else { return Theme.dim }
        let positive = d >= 0
        return (positive == higherBetter) ? Theme.accent : Theme.warn
    }

    private var deltaText: String {
        guard let d = delta else { return "" }
        return String(format: "%+.1f", d)
    }

    private var hasData: Bool { value != "—" }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Line 1 — white consumer name
            Text(label)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(Theme.text)
                .lineLimit(1)
                .truncationMode(.tail)
            // Line 2 — gray technical term (tight spacing so they read as one label)
            if !techLabel.isEmpty {
                Text(techLabel)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(Theme.dim)
                    .lineLimit(1)
                    .padding(.top, -2)
            }

            // Value — fixed height so all tiles are the same size
            Text(value)
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .foregroundStyle(hasData ? Theme.text : Theme.dim.opacity(0.4))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(minHeight: 28)

            // Unit + delta — always rendered to lock row height
            HStack(spacing: 4) {
                Text(unit.isEmpty ? " " : unit)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Theme.dim)
                if hasData, delta != nil {
                    Text(deltaText)
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(deltaColor)
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 90, alignment: .leading)
        .padding(12)
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

```

Leave the `// MARK: - Preview` comment and everything below/above it (including `MetricsTableView` itself and its `// MARK: - Metrics Table` header) untouched — `MetricsTableView`'s call sites reference `MetricTile` by name and need no changes since the type is now just defined in a different file in the same module.

- [ ] **Step 3: Register the new file in the Xcode project**

In `Wythin.xcodeproj/project.pbxproj`, make these 4 additions (new unique IDs `F145`/`A145` — confirmed not already used by `grep -oE "F1[0-9]+|A1[0-9]+" Wythin.xcodeproj/project.pbxproj`, current highest is `F144`/`A144`):

Addition 1 — add a PBXBuildFile entry immediately after the `A144` line:
Find:
```
		A144 /* SignalQualityTier+Theme.swift in Sources */ = {isa = PBXBuildFile; fileRef = F144 /* SignalQualityTier+Theme.swift */; };
```
Replace with:
```
		A144 /* SignalQualityTier+Theme.swift in Sources */ = {isa = PBXBuildFile; fileRef = F144 /* SignalQualityTier+Theme.swift */; };
		A145 /* MetricTile.swift in Sources */ = {isa = PBXBuildFile; fileRef = F145 /* MetricTile.swift */; };
```

Addition 2 — add a PBXFileReference entry immediately after the `F144` line:
Find:
```
		F144 /* SignalQualityTier+Theme.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = "SignalQualityTier+Theme.swift"; sourceTree = "<group>"; };
```
Replace with:
```
		F144 /* SignalQualityTier+Theme.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = "SignalQualityTier+Theme.swift"; sourceTree = "<group>"; };
		F145 /* MetricTile.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = MetricTile.swift; sourceTree = "<group>"; };
```

Addition 3 — add it as a child of the `Design` group:
Find:
```
		GAPP_DES /* Design */ = {
			isa = PBXGroup;
			children = (
				F117 /* Theme.swift */,
				F118 /* WaveformRenderer.swift */,
				F132 /* SplashView.swift */,
				F133 /* BLENavButton.swift */,
				F144 /* SignalQualityTier+Theme.swift */,
			);
```
Replace with:
```
		GAPP_DES /* Design */ = {
			isa = PBXGroup;
			children = (
				F117 /* Theme.swift */,
				F118 /* WaveformRenderer.swift */,
				F132 /* SplashView.swift */,
				F133 /* BLENavButton.swift */,
				F144 /* SignalQualityTier+Theme.swift */,
				F145 /* MetricTile.swift */,
			);
```

Addition 4 — add it to the Sources build phase (find the line for `A144` in the Sources phase's `files = (...)` list and add `A145` after it):
Find:
```
				A144 /* SignalQualityTier+Theme.swift in Sources */,
```
Replace with:
```
				A144 /* SignalQualityTier+Theme.swift in Sources */,
				A145 /* MetricTile.swift in Sources */,
```

- [ ] **Step 4: Build to verify**

```bash
cd /Users/alexutkin/ios && xcodebuild build -project Wythin.xcodeproj -scheme Wythin -destination 'platform=iOS Simulator,name=iPhone 17 Pro' 2>&1 | tail -40
```
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 5: Commit**

```bash
cd /Users/alexutkin/ios && git add Wythin/UI/Design/MetricTile.swift Wythin/UI/Live/LiveView.swift Wythin.xcodeproj/project.pbxproj
git commit -m "refactor(design): extract MetricTile from LiveView into a shared UI/Design file"
```

---

### Task 3: Create ActivityMetricsCard

**Files:**
- Create: `UI/Activities/ActivityMetricsCard.swift`
- Modify: `Wythin.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: `MetricTile` (Task 2), `ActivityLog.{during,before}{HR,RSA,RMSSD,RCMSE,PIP,DC,VTI,LFHF,DFA1}` (Task 1), `MetricFormat.{bpm,ms,ratio}` (existing, `UI/Design/Theme.swift`), `Theme.cardStyle()` (existing).
- Produces: `ActivityMetricsCard(entry: ActivityLog): View` — not yet used anywhere (wired into `ActivitiesView.swift` in Task 4). It compiling standing alone is the deliverable for this task.

- [ ] **Step 1: Create the file**

Write `ios/Wythin/UI/Activities/ActivityMetricsCard.swift`:

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

- [ ] **Step 2: Register the new file in the Xcode project**

In `Wythin.xcodeproj/project.pbxproj`, make these 4 additions (new IDs `F146`/`A146` — one past the `F145`/`A145` pair added in Task 2):

Addition 1 — PBXBuildFile, immediately after the `A145` line added in Task 2:
Find:
```
		A145 /* MetricTile.swift in Sources */ = {isa = PBXBuildFile; fileRef = F145 /* MetricTile.swift */; };
```
Replace with:
```
		A145 /* MetricTile.swift in Sources */ = {isa = PBXBuildFile; fileRef = F145 /* MetricTile.swift */; };
		A146 /* ActivityMetricsCard.swift in Sources */ = {isa = PBXBuildFile; fileRef = F146 /* ActivityMetricsCard.swift */; };
```

Addition 2 — PBXFileReference, immediately after the `F145` line added in Task 2:
Find:
```
		F145 /* MetricTile.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = MetricTile.swift; sourceTree = "<group>"; };
```
Replace with:
```
		F145 /* MetricTile.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = MetricTile.swift; sourceTree = "<group>"; };
		F146 /* ActivityMetricsCard.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = ActivityMetricsCard.swift; sourceTree = "<group>"; };
```

Addition 3 — add as a child of the `Activities` group:
Find:
```
		GAPP_ACT /* Activities */ = {
			isa = PBXGroup;
			children = (
				F137 /* ActivitiesView.swift */,
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
				F146 /* ActivityMetricsCard.swift */,
			);
			path = Activities;
			sourceTree = "<group>";
		};
```

Addition 4 — add to the Sources build phase (immediately after the `A145` entry added in Task 2):
Find:
```
				A145 /* MetricTile.swift in Sources */,
```
Replace with:
```
				A145 /* MetricTile.swift in Sources */,
				A146 /* ActivityMetricsCard.swift in Sources */,
```

- [ ] **Step 3: Build to verify**

```bash
cd /Users/alexutkin/ios && xcodebuild build -project Wythin.xcodeproj -scheme Wythin -destination 'platform=iOS Simulator,name=iPhone 17 Pro' 2>&1 | tail -40
```
Expected: `** BUILD SUCCEEDED **`. The new type is unused so far — that's expected, it's wired in Task 4.

- [ ] **Step 4: Commit**

```bash
cd /Users/alexutkin/ios && git add Wythin/UI/Activities/ActivityMetricsCard.swift Wythin.xcodeproj/project.pbxproj
git commit -m "feat(activities): add ActivityMetricsCard with 9-tile live-metrics grid"
```

---

### Task 4: Wire ActivityMetricsCard into the day-grouped list

**Files:**
- Modify: `UI/Activities/ActivitiesView.swift`

**Interfaces:**
- Consumes: `ActivityMetricsCard(entry:)` (Task 3).
- Produces: nothing new — `ActivityLogRow` and `LogMetricCell` are deleted since nothing calls them after this task.

- [ ] **Step 1: Swap the row view and its list-row background**

Find:
```swift
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
```
Replace with:
```swift
            // ── Activity history, grouped by day ──────────────────
            ForEach(dayGroups) { group in
                Section {
                    ForEach(group.entries) { entry in
                        ActivityMetricsCard(entry: entry)
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
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                            .listRowInsets(.init(top: 4, leading: 16, bottom: 4, trailing: 16))
                    }
                } header: {
```

(`listRowBackground` changes from `Theme.card` to `Color.clear` because `ActivityMetricsCard` now applies its own `.cardStyle()`, which already draws `Theme.card` plus a border — this matches the existing pattern used by other card-shaped rows in this same file, e.g. the Suggested Now card a few lines above uses `.cardStyle()` + `.listRowBackground(Color.clear)`.)

- [ ] **Step 2: Delete the now-unused `ActivityLogRow` and `LogMetricCell`**

Find:
```swift
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

```
Replace with nothing (delete the whole block). Leave the `// MARK: - DeltaChip` comment and everything below/above it untouched.

- [ ] **Step 3: Build to verify**

```bash
cd /Users/alexutkin/ios && xcodebuild build -project Wythin.xcodeproj -scheme Wythin -destination 'platform=iOS Simulator,name=iPhone 17 Pro' 2>&1 | tail -40
```
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Manual check in Simulator**

```bash
cd /Users/alexutkin/ios
xcrun simctl boot "iPhone 17 Pro" 2>/dev/null; open -a Simulator
xcodebuild -project Wythin.xcodeproj -scheme Wythin -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -derivedDataPath /tmp/jb-build-t2t4 build 2>&1 | tail -5
xcrun simctl install "iPhone 17 Pro" /tmp/jb-build-t2t4/Build/Products/Debug-iphonesimulator/Wythin.app
BUNDLE_ID=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" /tmp/jb-build-t2t4/Build/Products/Debug-iphonesimulator/Wythin.app/Info.plist)
xcrun simctl launch "iPhone 17 Pro" "$BUNDLE_ID"
```
If UI-automation tooling is unavailable in the environment (a known limitation from the prior sub-project), it's acceptable to verify visually via a screenshot only if the Activities tab is reachable without a tap (e.g. temporarily setting the default tab, screenshotting, then reverting before commit — do not leave that change committed), or otherwise to verify by careful code reading plus confirming build success, same as the fallback used in sub-project 1's Task 5/6. Confirm: each activity row now shows a 9-tile grid below its header (icon/name/time/duration), with no clipped or overlapping tiles, and Live tab's own metrics table still renders normally (unaffected by the MetricTile move).

- [ ] **Step 5: Commit**

```bash
cd /Users/alexutkin/ios && git add Wythin/UI/Activities/ActivitiesView.swift
git commit -m "feat(activities): use ActivityMetricsCard in the day-grouped history list"
```
