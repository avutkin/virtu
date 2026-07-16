# Signal Quality Indicator

**Date:** 2026-07-16
**Status:** Approved

---

## Overview

Add a live Signal Quality indicator to the LIVE screen, combining two independent checks:

1. **RR-artifact quality** — how many RR intervals are being rejected as artifacts (already computed, never surfaced).
2. **ECG waveform quality** — whether the raw ECG signal itself looks physically wrong (lead-off / no contact, or clipping).

Both combine into a single Good/Okay/Poor tier shown as a colored dot on the existing BLE/heart-rate pill, with a breakdown and improvement tips available in the existing BLE connection sheet.

---

## Computation

### 1. RR-artifact quality (existing, just newly surfaced)

`HRVCompute.compute` already returns `artifactRate` (fraction of raw RR intervals rejected by `cleanRR`'s physiological range check) and `signalQuality = 1 - artifactRate`, threaded through `MetricsTick` → `MetricsHistoryPoint` → `HRVSample`. No new computation needed — only new tiering:

| Tier | Condition |
|------|-----------|
| Good | `signalQuality ≥ 0.95` (< 5% artifacts) |
| Okay | `signalQuality ≥ 0.80` (< 20% artifacts) — matches the existing poor-quality chart-band threshold |
| Poor | `signalQuality < 0.80` |

### 2. ECG waveform quality (new — `Metrics/ECGQualityCompute.swift`)

Mirrors the existing `*Compute.swift` pattern (`HRVCompute`, `DFACompute`, etc). Runs on `snapshot.ecg` — the raw ECG buffer (~10s at 130 Hz) that's already passed into `MetricsEngine.compute` via `DataSnapshot` but currently unused for metrics.

```swift
enum ECGSignalTier { case good, okay, poor }

struct ECGQualityResult {
    let tier:   ECGSignalTier
    let reason: String   // "clean" | "clipping" | "lead-off"
}

enum ECGQualityCompute {
    static func compute(ecg: [Float]) -> ECGQualityResult?
}
```

Two heuristics, both relative to the window's own statistics — no hardcoded Polar ADC rail constant (not verifiable from this codebase, and hardcoding a guessed hardware limit risks exactly the kind of false-positive regression the RR artifact filter just caused):

- **Flatline / lead-off**: population standard deviation of the window `< 3 µV` (near-zero variance — resting ECG is typically hundreds of µV peak-to-peak, so this cleanly separates "no real cardiac signal" from any real reading). → forces **Poor**, `reason: "lead-off"`, regardless of RR-side tier.
- **Clipping**: a run of `≥ 5` consecutive samples within `0.5 µV` of the window's own min or max counts as "pinned". Sum the fraction of the window covered by such runs: `≥ 10%` → **Poor**, `reason: "clipping"`; `> 0% and < 10%` → **Okay**; `0%` → **Good**, `reason: "clean"`.
- Returns `nil` when fewer than 130 samples (~1s at 130 Hz) are available (insufficient data — same convention as other `*Compute` functions).
- These constants (3 µV, 5-sample run, 0.5 µV tolerance, 10% coverage) are starting points to tune against a real recording during implementation, same as the tunable constants already in `HRVCompute`/`AdvancedHRVCompute` (e.g. `rcmseR`).

### Combining

Overall tier = the **worse** of the RR-side tier and the ECG-side tier (flatline always wins as Poor since it means nothing downstream can be trusted). No new SwiftData fields or schema migration:
- The RR side is already persisted via `HRVSample.signalQuality`.
- Lead-off/clipping is inherently a "right now" condition — not charted historically, computed live each tick only.

`MetricsEngine.compute` calls `ECGQualityCompute.compute(ecg: snapshot.ecg)` alongside the existing per-tick computations and adds the result to `MetricsTick` (new field, live-only — not persisted to `MetricsHistoryPoint`/`HRVSample`).

---

## UI

### Nav bar pill

Small colored dot (green / amber / red) overlaid on the existing `BLENavButton` pill (`UI/Design/BLENavButton.swift`), reflecting the combined live tier. Hidden when not connected or insufficient data (mirrors existing nil-handling conventions elsewhere in the app).

### Detail — `BLEConnectionSheet`

Tapping the pill keeps its existing behavior (opens `BLEConnectionSheet`). Add a new "Signal Quality" section there:

```
SIGNAL QUALITY                                    ● GOOD

RR artifacts     3%              Good
ECG waveform     clean           Good

Improving signal quality
 Limit movement during measurement
 Ensure the chest strap is moist
 Ensure the strap is tightened appropriately
 Check and replace worn-out chest straps
 Check and replace HR monitor batteries that are low
```

Tips list is adapted from the reference text provided, keeping only the chest-strap-relevant items (CorSense/finger-sensor tips dropped — not applicable hardware for this app).

---

## Files Changed

| File | Change |
|------|--------|
| `Metrics/ECGQualityCompute.swift` | NEW — flatline/clipping heuristic on raw ECG window |
| `Metrics/MetricsEngine.swift` | Call `ECGQualityCompute.compute`, add result to `MetricsTick` |
| `UI/Design/BLENavButton.swift` | Add colored quality dot overlay |
| `UI/Live/LiveView.swift` (`BLEConnectionSheet`) | Add "Signal Quality" section with breakdown + tips |

---

## Not in Scope

- Historical charting of ECG waveform quality (RR-side quality is already charted via existing `signalQuality` bands)
- SwiftData schema changes / persistence of the new ECG check
- SNR-based/filtered ECG quality estimation (heuristic-only, per approved design)
- CorSense/finger-sensor-specific guidance (chest strap only)
