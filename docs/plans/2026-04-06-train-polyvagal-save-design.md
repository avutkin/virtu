# Train Page — Polyvagal Autonomic Monitoring + Session Save

**Date:** 2026-04-06
**Status:** Approved

---

## Overview

Extend the Train tab with two features:

1. **AutonomicCard** — real-time polyvagal state indicator showing sympathetic/parasympathetic balance during exercise, derived from HRV frequency-domain data per Polyvagal Theory.
2. **Training session save** — START / END TRAINING buttons that persist session summaries (set count, recovery times, autonomic indices) to SwiftData, viewable in the History tab.

---

## Feature 1 — Polyvagal Autonomic Card

### Computation

Use normalized HRV frequency-domain units, computable from existing `MetricsTick` fields:

```
PNSIndex (HFnu) = hfPower / (lfPower + hfPower)   → 0.0 – 1.0
SNSIndex (LFnu) = lfPower / (lfPower + hfPower)   → 0.0 – 1.0
```

Fallback when freq-domain unavailable (< 30 RR intervals):
`PNSIndex = clamp(rmssd / baselineRMSSD, 0, 1)`,  `SNSIndex = 1 - PNSIndex`

### State Classification

| State | Condition | Color |
|-------|-----------|-------|
| Ventral Vagal | HFnu ≥ 0.55 | `Theme.accent` (green) |
| Sympathetic | LFnu ≥ 0.65 | `Theme.warn` (red) |
| Dorsal Vagal | RMSSD < 10 ms AND HR ≤ baseline + 20 | `Theme.hrv` (indigo) |
| Mixed / Transitioning | all other cases | `Theme.rsa` (amber) |

### UI Card — `AutonomicCard` (always visible)

```
┌─ AUTONOMIC BALANCE ─────────────────────────────────┐
│  ⬤  VENTRAL VAGAL  — parasympathetic brake ON       │
│                                                      │
│  SNS  ████░░░░░░░░░░░  0.32                         │
│  PNS  ██████████░░░░░  0.68                         │
│                                                      │
│  "HRV recovery on track — good time to push"        │
└─────────────────────────────────────────────────────┘
```

- Placed between `HRPanel` and `HRRecoveryChart`
- Always visible (autonomic state is informative in all TrainStates)
- Bars animate with `.animation(.easeInOut, value:)`
- Tip text per state:
  - Ventral Vagal: "Parasympathetic brake ON — good time to push"
  - Sympathetic: "Sympathetic dominant — complete your set"
  - Mixed: "Autonomic transition — extend rest"
  - Dorsal: "HRV very low — consider stopping"
- Graceful `—` fallback when data absent

---

## Feature 2 — Training Session Save

### New SwiftData Model — `TrainSession`

```swift
@Model final class TrainSession {
    var startedAt:      Date
    var endedAt:        Date?
    var baselineHR:     Float
    var baselineRMSSD:  Float?
    var setCount:       Int        // number of ACTIVE→RECOVER transitions
    var avgSNSIndex:    Float      // mean LFnu over session
    var avgPNSIndex:    Float      // mean HFnu over session
    var avgRecoveryMin: Float      // mean recovery duration in minutes
    var recoveryMins:   String     // JSON-encoded [Float] e.g. "[3.2, 4.8]"
}
```

Added to the existing `Schema` in `VirtuApp.swift`.

### Session Lifecycle in TrainView

**State added to TrainView:**
```swift
@State private var activeSession:    TrainSession? = nil
@State private var sessionSNSAccum:  [Float] = []
@State private var sessionPNSAccum:  [Float] = []
@State private var setRecoveries:    [Float] = []  // minutes per set
@State private var recoveryStart:    Date?   = nil
```

**Transitions that trigger recording:**
- `ACTIVE → RECOVER`: set `recoveryStart = .now`, increment intent to log
- `RECOVER → READY`: log `(Date.now - recoveryStart).minutes` to `setRecoveries`, increment `setCount`

**START TRAINING button** — shown in `CalibrationBar` after baseline is established
**END TRAINING button** — replaces START; saves session to SwiftData via `@Environment(\.modelContext)`

### History Tab Extension

Add a segmented picker to `HistoryView`: **HRV | TRAIN**

TRAIN segment shows a list of `TrainSession` records:

```
● Apr 6  42 min  3 sets
  SNS 0.74  PNS 0.31  avg recovery 4.4 min
  Sets: 3.2 → 4.8 → 5.1 min

● Apr 4  38 min  4 sets
  ...
```

---

## Files Changed

| File | Change |
|------|--------|
| `Models/TrainSession.swift` | NEW — SwiftData model |
| `UI/Train/TrainView.swift` | Add `AutonomicCard`, START/END buttons, session recording logic |
| `UI/History/HistoryView.swift` | Add TRAIN segment with `TrainSession` list |
| `App/VirtuApp.swift` | Add `TrainSession` to SwiftData schema |

---

## Not in Scope

- Tick-level export (no CSV/JSON export)
- Server sync of train sessions
- Editing or deleting saved sessions
