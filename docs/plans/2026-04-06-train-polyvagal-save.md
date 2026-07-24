# Train — Polyvagal Monitoring + Session Save

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add an AutonomicCard (sympathetic/parasympathetic balance) to the Train tab and the ability to save training sessions (set count, recovery times, autonomic indices) to SwiftData and view them in the History tab.

**Architecture:** Pure-function autonomic index computation from existing `lfPower`/`hfPower` in `MetricsTick`. New `TrainSession` SwiftData model stores session summaries. `HistoryView` gains a HRV|TRAIN picker.

**Design doc:** `docs/plans/2026-04-06-train-polyvagal-save-design.md`

**Tech Stack:** Swift 5.9+, SwiftUI, SwiftData, Swift Charts, XCTest

---

## Critical Context

### Existing patterns to follow

- **SwiftData models** live in `ios/Wythin/Models/`. Each uses `@Model final class` with `@Attribute(.unique) var id: UUID`. See `HRVSession.swift` for the exact pattern.
- **Schema registration** is in `WythinApp.swift` line `Schema([HRVSession.self, HRVSample.self, ResonanceResult.self])` — new models must be added here **and** to both `container` and `_env` initializers (both have the same schema).
- **Xcode project file** is at `ios/Wythin.xcodeproj/project.pbxproj`. Every new `.swift` file must be registered there manually (the project doesn't auto-discover). Next available IDs are **F135 / A135**. Pattern:
  - Add `F135 /* TrainSession.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = TrainSession.swift; sourceTree = "<group>"; };` to the PBXFileReference section
  - Add `A135 /* TrainSession.swift in Sources */ = {isa = PBXBuildFile; fileRef = F135 /* TrainSession.swift */; };` to the PBXBuildFile section
  - Add `F135 /* TrainSession.swift */,` inside `GAPP_MOD /* Models */` group children
  - Add `A135 /* TrainSession.swift in Sources */,` inside the main target's `BSAPP /* Sources */` build phase
- **Theme colors available:** `Theme.accent` (green), `Theme.warn` (red), `Theme.rsa` (amber), `Theme.hrv` (indigo), `Theme.dim`, `Theme.text`, `Theme.breathe` (blue), `Theme.card`, `Theme.border`, `Theme.bg`
- **`MetricsTick` fields relevant to polyvagal:** `lfPower: Float?`, `hfPower: Float?`, `rmssd: Float?`, `meanBPM: Float?`
- **`TrainBaseline`** is a struct defined in `TrainView.swift`: `{ hr: Float, rmssd: Float?, timestamp: Date }`
- **`@Environment(\.modelContext)`** is available inside views that sit under `.modelContainer(container)` in the app root — all existing views use this to save to SwiftData.

---

## Task 1: `TrainSession` SwiftData Model

**Files:**
- Create: `ios/Wythin/Models/TrainSession.swift`
- Modify: `ios/Wythin.xcodeproj/project.pbxproj`
- Modify: `ios/Wythin/App/WythinApp.swift`

### Step 1: Create the model file

Create `ios/Wythin/Models/TrainSession.swift`:

```swift
import Foundation
import SwiftData

/// Summary of one training session recorded on the Train tab.
@Model
final class TrainSession {
    @Attribute(.unique) var id: UUID
    var startedAt:      Date
    var endedAt:        Date?
    var baselineHR:     Float
    var baselineRMSSD:  Float?
    var setCount:       Int        // number of ACTIVE→RECOVER transitions logged
    var avgSNSIndex:    Float      // mean LFnu (0–1) over session
    var avgPNSIndex:    Float      // mean HFnu (0–1) over session
    var avgRecoveryMin: Float      // mean recovery duration in minutes
    var recoveryMins:   String     // JSON-encoded [Float], e.g. "[3.2,4.8,5.1]"

    init(
        id:            UUID  = UUID(),
        startedAt:     Date  = Date(),
        baselineHR:    Float,
        baselineRMSSD: Float? = nil
    ) {
        self.id            = id
        self.startedAt     = startedAt
        self.baselineHR    = baselineHR
        self.baselineRMSSD = baselineRMSSD
        self.setCount      = 0
        self.avgSNSIndex   = 0
        self.avgPNSIndex   = 0
        self.avgRecoveryMin = 0
        self.recoveryMins  = "[]"
    }

    var duration: TimeInterval {
        (endedAt ?? Date()).timeIntervalSince(startedAt)
    }

    var durationString: String {
        let mins = Int(duration / 60)
        return "\(mins) min"
    }

    var recoveryMinArray: [Float] {
        (try? JSONDecoder().decode([Float].self, from: Data(recoveryMins.utf8))) ?? []
    }
}
```

### Step 2: Register in pbxproj

In `ios/Wythin.xcodeproj/project.pbxproj`, make **four** edits:

**a)** In the PBXBuildFile section (near `A132`/`A133`/`A134` lines), add:
```
		A135 /* TrainSession.swift in Sources */ = {isa = PBXBuildFile; fileRef = F135 /* TrainSession.swift */; };
```

**b)** In the PBXFileReference section (near `F132`/`F133`/`F134` lines), add:
```
		F135 /* TrainSession.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = TrainSession.swift; sourceTree = "<group>"; };
```

**c)** Inside `GAPP_MOD /* Models */` group children, add `F135 /* TrainSession.swift */,`

**d)** In the `BSAPP /* Sources */` build phase files list (near `A116 /* ResonanceResult.swift in Sources */`), add:
```
				A135 /* TrainSession.swift in Sources */,
```

### Step 3: Add to SwiftData schema

In `WythinApp.swift`, find **both** `Schema([HRVSession.self, HRVSample.self, ResonanceResult.self])` occurrences (one at line ~8, one in `init()`) and change both to:
```swift
Schema([HRVSession.self, HRVSample.self, ResonanceResult.self, TrainSession.self])
```

### Step 4: Verify build

Build the app (⌘B). Expected: zero errors. The new model is inert — nothing uses it yet.

### Step 5: Commit

```bash
git add ios/Wythin/Models/TrainSession.swift \
        ios/Wythin.xcodeproj/project.pbxproj \
        ios/Wythin/App/WythinApp.swift
git commit -m "feat(train): add TrainSession SwiftData model"
```

---

## Task 2: Polyvagal Autonomic Computation + AutonomicCard

**Files:**
- Modify: `ios/Wythin/UI/Train/TrainView.swift`

All new code goes inside `TrainView.swift` as private types/structs.

### Step 1: Add `PolyvagalState` enum and `AutonomicIndices` struct

Insert after the `TrainBaseline` struct (around line 20):

```swift
// MARK: - Polyvagal State

enum PolyvagalState: Equatable {
    case ventralVagal   // parasympathetic brake ON — HFnu ≥ 0.55
    case sympathetic    // SNS dominant — LFnu ≥ 0.65
    case dorsalVagal    // very low HRV + HR not elevated — shutdown warning
    case mixed          // transitioning
}

struct AutonomicIndices: Equatable {
    let sns:   Float           // LFnu 0–1
    let pns:   Float           // HFnu 0–1
    let state: PolyvagalState
}

// MARK: - Autonomic Compute

enum AutonomicCompute {
    /// Derives LFnu/HFnu balance from MetricsTick.
    /// Falls back to RMSSD-relative-to-baseline when freq-domain is absent.
    static func compute(tick: MetricsTick, baseline: TrainBaseline?) -> AutonomicIndices? {
        // Preferred: frequency-domain normalized units
        if let lf = tick.lfPower, let hf = tick.hfPower, (lf + hf) > 0 {
            let total = lf + hf
            let pns   = hf / total
            let sns   = lf / total
            return AutonomicIndices(sns: sns, pns: pns, state: classify(pns: pns, sns: sns, tick: tick, baseline: baseline))
        }
        // Fallback: RMSSD vs baseline
        if let rmssd = tick.rmssd, let b = baseline, let bRmssd = b.rmssd, bRmssd > 0 {
            let pns = min(1, rmssd / bRmssd)
            let sns = 1 - pns
            return AutonomicIndices(sns: sns, pns: pns, state: classify(pns: pns, sns: sns, tick: tick, baseline: baseline))
        }
        return nil
    }

    private static func classify(pns: Float, sns: Float, tick: MetricsTick, baseline: TrainBaseline?) -> PolyvagalState {
        if pns >= 0.55 { return .ventralVagal }
        if sns >= 0.65 { return .sympathetic }
        if let rmssd = tick.rmssd, rmssd < 10,
           let hr = tick.meanBPM, let b = baseline, hr <= b.hr + 20 {
            return .dorsalVagal
        }
        return .mixed
    }
}
```

### Step 2: Add `AutonomicCard` private struct

Add before the `StateBanner` struct:

```swift
// MARK: - Autonomic Card

private struct AutonomicCard: View {
    let indices: AutonomicIndices?

    private var state: PolyvagalState { indices?.state ?? .mixed }

    private var stateLabel: String {
        switch state {
        case .ventralVagal: return "VENTRAL VAGAL"
        case .sympathetic:  return "SYMPATHETIC"
        case .dorsalVagal:  return "DORSAL VAGAL"
        case .mixed:        return "TRANSITIONING"
        }
    }

    private var stateColor: Color {
        switch state {
        case .ventralVagal: return Theme.accent
        case .sympathetic:  return Theme.warn
        case .dorsalVagal:  return Theme.hrv
        case .mixed:        return Theme.rsa
        }
    }

    private var tipText: String {
        switch state {
        case .ventralVagal: return "Parasympathetic brake ON — good time to push"
        case .sympathetic:  return "Sympathetic dominant — complete your set"
        case .dorsalVagal:  return "HRV very low — consider stopping"
        case .mixed:        return "Autonomic transition — extend rest"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header row
            HStack(spacing: 8) {
                Text("AUTONOMIC BALANCE")
                    .font(Theme.monoLabel)
                    .foregroundStyle(Theme.dim)
                Spacer()
            }

            // State badge
            HStack(spacing: 6) {
                Circle()
                    .fill(stateColor)
                    .frame(width: 8, height: 8)
                Text(stateLabel)
                    .font(Theme.mono(14))
                    .fontWeight(.medium)
                    .foregroundStyle(stateColor)
            }

            // SNS bar
            IndexBar(label: "SNS", value: indices?.sns, color: Theme.warn)
            // PNS bar
            IndexBar(label: "PNS", value: indices?.pns, color: Theme.accent)

            // Tip
            Text(tipText)
                .font(Theme.monoLabel)
                .foregroundStyle(Theme.breathe.opacity(0.8))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(Theme.cardPad)
        .background(Theme.card)
        .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius))
        .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius)
            .strokeBorder(stateColor.opacity(0.25), lineWidth: 0.5))
        .animation(.easeInOut(duration: 0.4), value: indices?.state)
    }
}

private struct IndexBar: View {
    let label: String
    let value: Float?
    let color: Color

    var body: some View {
        HStack(spacing: 10) {
            Text(label)
                .font(Theme.monoLabel)
                .foregroundStyle(Theme.dim)
                .frame(width: 30, alignment: .leading)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Theme.border)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(color.opacity(0.7))
                        .frame(width: geo.size.width * CGFloat(value ?? 0))
                        .animation(.easeInOut(duration: 0.5), value: value)
                }
            }
            .frame(height: 8)

            Text(value.map { String(format: "%.2f", $0) } ?? "—")
                .font(Theme.monoLabel)
                .foregroundStyle(Theme.text)
                .frame(width: 36, alignment: .trailing)
        }
    }
}
```

### Step 3: Wire `AutonomicCard` into `TrainView.body`

In `TrainView`, add a new `@State` for the computed indices:

```swift
@State private var autonomicIndices: AutonomicIndices? = nil
```

In `appendTick(_:)`, after `trainState = deriveState(tick: tick)`, add:
```swift
autonomicIndices = AutonomicCompute.compute(tick: tick, baseline: baseline)
```

In `TrainView.body` `VStack`, insert `AutonomicCard` between `HRPanel` and `HRRecoveryChart`:
```swift
AutonomicCard(indices: autonomicIndices)
```

### Step 4: Verify build

Build (⌘B) — zero errors expected. Open Train tab in simulator — card shows "TRANSITIONING" until BLE connects and HRV data flows.

### Step 5: Commit

```bash
git add ios/Wythin/UI/Train/TrainView.swift
git commit -m "feat(train): add polyvagal AutonomicCard with SNS/PNS balance"
```

---

## Task 3: Session Recording — START / END TRAINING

**Files:**
- Modify: `ios/Wythin/UI/Train/TrainView.swift`

### Step 1: Add session state to `TrainView`

Add to `TrainView`'s `@State` block:

```swift
// Session recording
@State private var isSessionActive:  Bool     = false
@State private var sessionStartedAt: Date     = .now
@State private var sessionSNSAccum:  [Float]  = []
@State private var sessionPNSAccum:  [Float]  = []
@State private var setCount:         Int      = 0
@State private var recoveryStart:    Date?    = nil
@State private var setRecoveryMins:  [Float]  = []
@State private var prevTrainState:   TrainState = .calibrating
```

Add `@Environment(\.modelContext) var ctx` to the view.

### Step 2: Track state transitions in `appendTick`

In `appendTick(_:)`, after computing `trainState`, add:

```swift
// Track set/recovery transitions for session recording
if isSessionActive {
    // ACTIVE → RECOVER: a set just ended, start recovery timer
    if prevTrainState == .active && trainState == .recover {
        recoveryStart = .now
        setCount += 1
    }
    // RECOVER → READY: recovery complete, log duration
    if prevTrainState == .recover && trainState == .ready, let rs = recoveryStart {
        let mins = Float(Date().timeIntervalSince(rs) / 60)
        setRecoveryMins.append(mins)
        recoveryStart = nil
    }
    // Accumulate autonomic indices
    if let idx = autonomicIndices {
        sessionSNSAccum.append(idx.sns)
        sessionPNSAccum.append(idx.pns)
    }
}
prevTrainState = trainState
```

### Step 3: Add `startSession` and `endSession` helpers

Add as private methods of `TrainView`:

```swift
private func startSession() {
    guard let b = baseline else { return }
    isSessionActive  = true
    sessionStartedAt = .now
    sessionSNSAccum  = []
    sessionPNSAccum  = []
    setCount         = 0
    setRecoveryMins  = []
    recoveryStart    = nil
    prevTrainState   = trainState
}

private func endSession() {
    guard isSessionActive, let b = baseline else { return }
    isSessionActive = false

    let avgSNS = sessionSNSAccum.isEmpty ? 0 : sessionSNSAccum.reduce(0, +) / Float(sessionSNSAccum.count)
    let avgPNS = sessionPNSAccum.isEmpty ? 0 : sessionPNSAccum.reduce(0, +) / Float(sessionPNSAccum.count)
    let avgRec = setRecoveryMins.isEmpty ? 0 : setRecoveryMins.reduce(0, +) / Float(setRecoveryMins.count)

    let rec = (try? String(data: JSONEncoder().encode(setRecoveryMins), encoding: .utf8)) ?? "[]"

    let session = TrainSession(baselineHR: b.hr, baselineRMSSD: b.rmssd)
    session.endedAt        = .now
    session.setCount       = setCount
    session.avgSNSIndex    = avgSNS
    session.avgPNSIndex    = avgPNS
    session.avgRecoveryMin = avgRec
    session.recoveryMins   = rec
    ctx.insert(session)
    try? ctx.save()

    // Reset accumulators
    sessionSNSAccum = []
    sessionPNSAccum = []
    setCount        = 0
    setRecoveryMins = []
}
```

### Step 4: Extend `CalibrationBar` with START/END buttons

`CalibrationBar` currently takes `(baseline:, isCollecting:, onRecalibrate:)`. Add two more parameters:

```swift
private struct CalibrationBar: View {
    let baseline:       TrainBaseline?
    let isCollecting:   Bool
    let isSessionActive: Bool
    let onRecalibrate:  () -> Void
    let onStartSession: () -> Void
    let onEndSession:   () -> Void
    // ... existing body ...
```

At the bottom of the card's `HStack` (after the RECALIBRATE button), add:

```swift
if !isCollecting && baseline != nil {
    if isSessionActive {
        Button("END TRAINING", action: onEndSession)
            .font(Theme.monoLabel)
            .foregroundStyle(Theme.warn)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Theme.warn.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Theme.warn.opacity(0.3), lineWidth: 0.5))
    } else {
        Button("START TRAINING", action: onStartSession)
            .font(Theme.monoLabel)
            .foregroundStyle(Theme.accent)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Theme.accent.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Theme.accent.opacity(0.3), lineWidth: 0.5))
    }
}
```

Update the `CalibrationBar` call-site in `TrainView.body`:

```swift
CalibrationBar(
    baseline:        baseline,
    isCollecting:    trainHistory.count < 15 && baseline == nil,
    isSessionActive: isSessionActive,
    onRecalibrate:   recalibrate,
    onStartSession:  startSession,
    onEndSession:    endSession
)
```

### Step 5: Verify build

Build (⌘B). Run in simulator: tap START TRAINING → do jumping jacks → tap END TRAINING. No crash expected. (History verification comes in Task 4.)

### Step 6: Commit

```bash
git add ios/Wythin/UI/Train/TrainView.swift
git commit -m "feat(train): START/END TRAINING session recording with set+recovery tracking"
```

---

## Task 4: TRAIN Section in History Tab

**Files:**
- Modify: `ios/Wythin/UI/History/HistoryView.swift`

### Step 1: Add the `HistoryTab` enum and `@Query` for `TrainSession`

At the top of `HistoryView`:

```swift
@Query(sort: \TrainSession.startedAt, order: .reverse)
var trainSessions: [TrainSession]

@State private var selectedTab: HistoryTab = .hrv

enum HistoryTab: String, CaseIterable {
    case hrv   = "HRV"
    case train = "TRAIN"
}
```

### Step 2: Add tab picker to the List

Insert a new `Section` before the existing range picker section:

```swift
Section {
    Picker("Tab", selection: $selectedTab) {
        ForEach(HistoryTab.allCases, id: \.self) {
            Text($0.rawValue).tag($0)
        }
    }
    .pickerStyle(.segmented)
    .padding(.vertical, 4)
}
.listRowBackground(Theme.card)
```

### Step 3: Wrap existing content in `if selectedTab == .hrv` and add TRAIN content

Wrap the three existing `Section` blocks (RSA TREND, COHERENCE, SESSIONS) in:
```swift
if selectedTab == .hrv {
    // ... existing three sections ...
}
```

After that closing brace, add:

```swift
if selectedTab == .train {
    Section("TRAIN SESSIONS") {
        if trainSessions.isEmpty {
            Text("No training sessions yet")
                .font(Theme.monoLabel)
                .foregroundStyle(Theme.dim)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 20)
        } else {
            ForEach(trainSessions) { session in
                TrainSessionRow(session: session)
            }
        }
    }
    .listRowBackground(Theme.card)
}
```

### Step 4: Add `TrainSessionRow` private struct

```swift
private struct TrainSessionRow: View {
    let session: TrainSession

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Date + duration
            HStack {
                Text(session.startedAt, format: .dateTime.month().day().hour().minute())
                    .font(Theme.monoBody)
                    .foregroundStyle(Theme.text)
                Spacer()
                Text(session.durationString)
                    .font(Theme.monoLabel)
                    .foregroundStyle(Theme.dim)
            }

            // Sets
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

            // Autonomic indices
            HStack(spacing: 16) {
                Text(String(format: "SNS %.2f", session.avgSNSIndex))
                    .font(Theme.monoLabel)
                    .foregroundStyle(Theme.warn.opacity(0.8))
                Text(String(format: "PNS %.2f", session.avgPNSIndex))
                    .font(Theme.monoLabel)
                    .foregroundStyle(Theme.accent.opacity(0.8))
            }

            // Per-set recovery times
            let recs = session.recoveryMinArray
            if !recs.isEmpty {
                Text("Sets: " + recs.enumerated().map { String(format: "%.1f", $0.element) }.joined(separator: " → ") + " min")
                    .font(Theme.monoLabel)
                    .foregroundStyle(Theme.dim)
            }
        }
        .padding(.vertical, 4)
    }
}
```

### Step 5: Verify end-to-end

1. Build (⌘B) — zero errors.
2. In simulator: Train tab → tap START TRAINING → simulate exercise → tap END TRAINING.
3. Switch to History tab → tap TRAIN segment → row appears with set count, indices, recovery times.

### Step 6: Commit

```bash
git add ios/Wythin/UI/History/HistoryView.swift
git commit -m "feat(history): add TRAIN session list with set/recovery/autonomic summary"
```

---

## Final Checklist

- [ ] `TrainSession.swift` created and registered in pbxproj
- [ ] `TrainSession` added to both `Schema(...)` calls in `WythinApp.swift`
- [ ] `AutonomicCompute` correctly uses LFnu/HFnu with RMSSD fallback
- [ ] `AutonomicCard` visible in Train tab, updates live, animates
- [ ] START TRAINING button appears after baseline calibration
- [ ] END TRAINING saves `TrainSession` to SwiftData
- [ ] History tab shows HRV | TRAIN picker
- [ ] TRAIN list shows session rows with all fields
- [ ] No regressions in Live, Resonate, or History (HRV) tabs
