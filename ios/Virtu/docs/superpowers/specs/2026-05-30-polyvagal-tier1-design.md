# Polyvagal Tier 1 — Design Spec
Date: 2026-05-30

## Overview

Add three Tier 1 features to the Just Breathe iOS app, integrated into the existing Live tab as additive cards below the HRV ring grid (today-only). No existing views are removed or replaced.

**Features:**
1. Polyvagal State Display — 3-state ladder showing ventral / sympathetic / dorsal
2. Guidance Engine — single "What next?" sentence driven by state + time of day
3. Context Tags — 6 fixed chip tags saved as timestamped SwiftData records

**Source research:** Just Breath Brand Book, Real-Time ECG brief, Polyvagal Theory (Porges).

---

## 1. State Inference

### File: `Models/PolyvagalState.swift`

A pure enum + static inference function. No network, no side effects.

```swift
enum PolyvagalState {
    case ventral      // safe, social, regulated
    case sympathetic  // mobilized, fight/flight
    case dorsal       // shutdown, flat, freeze
    case unknown      // insufficient data
}
```

**Inference logic (priority-ordered — first match wins):**

1. `unknown` — if `rmssd` or `meanBPM` is nil
2. `dorsal` — `rmssd < 25` AND `meanBPM < 62` AND `coherence < 0.3` (or coherence nil)
3. `sympathetic` — `rmssd < 30` AND `meanBPM > 80`
4. `ventral` — `rmssd > 35` AND `coherence > 0.5`
5. `sympathetic` — `rmssd < 30` (fallback: low HRV regardless of HR)
6. `ventral` — all other cases (moderate-to-good HRV, no strong stress signal)

Dorsal (rule 2) is evaluated before sympathetic (rule 3) because both share low RMSSD but diverge on HR direction — freeze shows low HR, fight/flight shows high HR. This is the core Polyvagal distinction.

**Guidance messages** by state + time of day (morning 05–11, afternoon 11–17, evening 17–23, night 23–05):

| State | Morning | Afternoon | Evening | Night |
|---|---|---|---|---|
| ventral | Great start — good time to connect or plan | Steady. Stay present and engaged | Wind down gently — you're well regulated | Nervous system is calm. Rest well |
| sympathetic | Elevated arousal. Try 90 seconds of paced breathing | Stress detected. Pause and take 3 slow breaths | High activation — a short exhale practice can help | Elevated before sleep. Try extended exhale breathing |
| dorsal | System is quiet. A short walk or gentle movement can help | Low energy detected. Light movement or a breath can activate you | Good time for gentle rest — avoid screens | Deep quiet. Rest is appropriate |
| unknown | Connect your Polar H10 to see your nervous system state | Connect your Polar H10 to see your nervous system state | Connect your Polar H10 to see your nervous system state | Connect your Polar H10 to see your nervous system state |

---

## 2. Context Tags

### File: `Models/TaggedMoment.swift`

SwiftData model. Two fields only.

```swift
@Model class TaggedMoment {
    var timestamp: Date
    var tag: String
}
```

**Fixed tag set (MVP):** `Meeting`, `Caffeine`, `Workout`, `Conflict`, `Poor Sleep`, `Commute`

Tags are toggled: tapping a tag that already has a record within the last 5 minutes deletes it; tapping a new one inserts it. This gives toggle UX without a separate "selected" state in memory.

The `TaggedMoment` model must be registered in the SwiftData `ModelContainer` alongside existing models.

---

## 3. UI Components

### Placement in `LiveView.swift` — `DayScrollView`

Inserted today-only, between `HRVRingGrid` and `SecondaryMetricsRow`:

```
TodayLiveSection          (existing — waveforms)
HRVRingGrid               (existing — 4 rings)
PolyvagalStateCard        ← NEW
GuidanceCard              ← NEW
SecondaryMetricsRow       (existing — SDNN, pNN50, RSA IDX, CBI)
MetricsChartsView         (existing)
HRVAnalysisView           (existing)
```

### File: `UI/Live/PolyvagalStateCard.swift`

- Section label: `NERVOUS SYSTEM STATE`
- Three segments in a horizontal HStack: Dorsal · Sympathetic · Ventral
- Active segment: filled color circle + bold label
- Inactive segments: dim circle + muted label
- Below segments: one-line description of the active state
- Colors: ventral = `Theme.accent`, sympathetic = `Theme.warn`, dorsal = `Color(red: 0.3, green: 0.5, blue: 0.8)`
- Card uses existing `.cardStyle()` modifier
- Receives `PolyvagalState` as input — no environment reads inside this view

### File: `UI/Live/GuidanceCard.swift`

- Section label: `WHAT NEXT`
- Guidance sentence (derived from state + current hour)
- Divider
- Label: `TAG THIS MOMENT`
- Chip row of 6 fixed tags laid out as a two-row HStack (3 chips per row) — avoids a custom flow layout while fitting all tags on any screen width
- Each chip: rounded rect, border, tag label. Active = accent-tinted background. Inactive = card background.
- Tag toggle writes/deletes `TaggedMoment` via `modelContext`
- Receives `PolyvagalState` and `modelContext` as inputs

---

## 4. Files Changed / Created

| Action | File |
|---|---|
| Create | `Models/PolyvagalState.swift` |
| Create | `Models/TaggedMoment.swift` |
| Create | `UI/Live/PolyvagalStateCard.swift` |
| Create | `UI/Live/GuidanceCard.swift` |
| Modify | `UI/Live/LiveView.swift` — insert two cards in `DayScrollView` |
| Modify | `App/VirtuApp.swift` — add `TaggedMoment.self` to the `Schema([...])` array |

---

## 5. Out of Scope (Tier 2+)

- Trigger discovery / cross-session pattern insights
- Morning check-in / mood input
- Pre-sleep downregulation protocol
- Adaptive thresholds based on user baseline
- Custom tag text input
