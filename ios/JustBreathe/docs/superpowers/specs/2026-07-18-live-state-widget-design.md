# Live State Widget — Design Spec
Date: 2026-07-18

## Overview

Adds a small, always-on-top widget to the Live tab's "today" page that shows an OpenAI-generated, one-to-few-sentence description of the user's nervous-system state trend over the last 10 minutes — descriptive only, no recommendation (that's the Activity Insights card's job). It sits above the existing `CurrentStateCard` and refreshes automatically every 5 minutes while the tab is visible and a Polar H10 is connected.

This reuses the OpenAI proxy architecture built for Activity Insights (`docs/superpowers/specs/2026-07-17-openai-activity-insights-design.md`): the backend stays a stateless pass-through to OpenAI, no API key ships in the app, and the same `/insights` endpoint is extended rather than duplicated.

---

## 1. Backend — extend `POST /insights` with `mode`

### Schema (`server/models.py`)

```python
class MetricTrend(BaseModel):
    start: Optional[float] = None
    end:   Optional[float] = None
    min:   Optional[float] = None
    max:   Optional[float] = None
    mean:  Optional[float] = None
    direction: Optional[str] = None   # "rising" | "falling" | "stable"


class InsightRequest(BaseModel):
    mode: str = "activity"            # "activity" | "live_state"

    # "activity" mode fields — activity_type changes from required to Optional
    # here; all others were already Optional. Existing callers (Activity
    # Insights, already shipped) are unaffected since they always send it.
    activity_type:    Optional[str] = None
    activity_subtype: Optional[str] = None
    duration_min:     Optional[int] = None
    before_hr: Optional[float] = None; during_hr: Optional[float] = None; after_hr: Optional[float] = None
    before_rsa: Optional[float] = None; during_rsa: Optional[float] = None; after_rsa: Optional[float] = None
    before_sdnn: Optional[float] = None; during_sdnn: Optional[float] = None; after_sdnn: Optional[float] = None
    before_lf_hf: Optional[float] = None; during_lf_hf: Optional[float] = None; after_lf_hf: Optional[float] = None

    # "live_state" mode fields
    window_minutes: Optional[int] = None
    metrics: Optional[dict[str, MetricTrend]] = None
    # metrics keys: hr, rmssd, rsa, sdnn, lf_hf, coherence, breath_bpm, cbi
```

### Handler (`server/routers/insights.py`)

`generate_insight` branches on `req.mode`:

- `mode == "activity"` (default): existing behavior, existing `_SYSTEM_PROMPT`, existing `_format_metrics`, unchanged.
- `mode == "live_state"`: new `_LIVE_STATE_SYSTEM_PROMPT` and new `_format_live_state(req)`:

```python
_LIVE_STATE_SYSTEM_PROMPT = (
    "You are a physiologist describing a live trend in heart-rate-variability "
    "(HRV) metrics over the last few minutes. Interpret the direction and "
    "magnitude of change across the metrics provided into a short, purely "
    "descriptive account of the person's current nervous-system state — no "
    "recommendations or suggested actions, this is a live status readout, not "
    "post-activity feedback. Keep the whole reply to 2-3 sentences. Do not "
    "use markdown formatting."
)

def _format_live_state(req: InsightRequest) -> str:
    lines = [f"Window: last {req.window_minutes} minutes"]
    for name, trend in (req.metrics or {}).items():
        lines.append(
            f"{name}: start={trend.start} end={trend.end} "
            f"min={trend.min} max={trend.max} mean={trend.mean} "
            f"direction={trend.direction}"
        )
    return "\n".join(lines)
```

Both modes share the same OpenAI call parameters (`gpt-4o-mini`, `max_tokens=150`, `temperature=0.6`), the same `OpenAIError` → 502 handling, and the same empty-response → 502 check. `InsightResponse{text}` is returned unchanged in both modes.

### Validation

If `mode == "live_state"` and `metrics` is `None`/empty, or `mode == "activity"` and `activity_type` is `None`, return HTTP 422 (a plain `HTTPException(status_code=422, detail=...)` check at the top of the handler, before calling OpenAI) — mode-specific required fields, checked in code rather than expressed in Pydantic's type system (which can't cleanly express "required if mode == X" across a flat optional schema).

---

## 2. iOS — trend computation

New file `ios/JustBreathe/Metrics/LiveStateTrendCompute.swift`, alongside the existing `HRVCompute.swift`/`RSACompute.swift`/etc. — pure computation, no I/O, matching that directory's existing convention.

```swift
struct MetricTrend {
    let start: Float?
    let end:   Float?
    let min:   Float?
    let max:   Float?
    let mean:  Float?
    let direction: String   // "rising" | "falling" | "stable"
}

enum LiveStateTrendCompute {
    /// Summarizes the last `windowMinutes` of quality-filtered history into
    /// one MetricTrend per core metric. Returns nil if there isn't enough
    /// valid data yet (fewer than 2 minutes of quality-passing ticks).
    static func summarize(_ history: [MetricsHistoryPoint], windowMinutes: Int = 10) -> [String: MetricTrend]?
}
```

- Input: `env.tickHistory` (already the source `CurrentStateCard`'s sibling views use), filtered through the existing `MetricsQualityFilter.filter` before being passed in, then sliced to `timestamp >= now - windowMinutes`.
- Minimum data gate: fewer than 60 quality-passing points in the window (≈2 minutes at 2 s/tick) → return `nil`. The widget interprets `nil` as "keep showing the placeholder."
- Per metric (`hr` ← `meanBPM`, `rmssd`, `rsa` ← `rsaMs`, `sdnn`, `lf_hf` ← `lfHF`, `coherence`, `breath_bpm` ← `breathBPM`, `cbi`): `start`/`end` are the first/last non-nil values in the window, `min`/`max`/`mean` computed over all non-nil values. A metric with zero non-nil values in the window is omitted from the dictionary entirely (not sent as all-nil).
- `direction`: split the window in half by time; compare the mean of the first half to the mean of the second half. If `|second - first| / max(|first|, 1e-6) > 0.05` (5% relative change), direction is `"rising"` or `"falling"` accordingly; otherwise `"stable"`.

---

## 3. iOS — wire types (`ios/JustBreathe/Sync/APIClient.swift`)

```swift
struct MetricTrendPayload: Codable {
    let start: Float?
    let end:   Float?
    let min:   Float?
    let max:   Float?
    let mean:  Float?
    let direction: String?
}

struct LiveStateInsightPayload: Codable {
    let mode: String            // always "live_state"
    let windowMinutes: Int
    let metrics: [String: MetricTrendPayload]

    enum CodingKeys: String, CodingKey {
        case mode
        case windowMinutes = "window_minutes"
        case metrics
    }
}
```

`APIClient` gains `func generateLiveStateInsight(_ payload: LiveStateInsightPayload) async throws -> InsightResponse` — same `request(path: "/insights", method: "POST")` pattern as `generateInsight`, reusing the existing `InsightResponse` decode. `InsightAPIClient` protocol gains this method too (so the same fake used for Activity Insights tests can be reused/extended here).

A small conversion helper maps `LiveStateTrendCompute`'s `[String: MetricTrend]` (a pure-Swift/no-Foundation-dependency type, kept in `Metrics/`) to `[String: MetricTrendPayload]` (the wire type, kept in `Sync/`) — this lives in `APIClient.swift` next to the other payload-builder extensions, mirroring `InsightPayload.init(from: ActivityLog)`.

---

## 4. iOS — widget component and lifecycle

New file `ios/JustBreathe/UI/Live/LiveStateWidget.swift`:

```swift
struct LiveStateWidget: View {
    @Environment(AppEnvironment.self) var env
    @State private var description: String?
    @State private var refreshTask: Task<Void, Never>?

    var body: some View { ... }   // see §5 for states/styling

    private func startLoop() { ... }   // cancels any existing refreshTask, starts a new one
    private func stopLoop()  { refreshTask?.cancel(); refreshTask = nil }
}
```

- **Lifecycle:** `.onAppear` calls `startLoop()` if `isConnected`; `.onDisappear` calls `stopLoop()`. Also observe `env.ble.state` via `.onChange` — start the loop when it transitions into `.connected`, stop it (without clearing `description`) when it transitions out.
- `isConnected`: `if case .connected = env.ble.state { true } else { false }` — `BLEState.connected` carries an associated `name: String`, so this needs pattern matching, not `==`.
- **Loop body** (`refreshTask`): an infinite loop, matching the existing `AppEnvironment.metricsTask` convention (`while !Task.isCancelled { try? await Task.sleep(...); ... }`). A loop-local `isFirstIteration` flag (starts `true`) controls the wait: 2 minutes on the first pass through the loop (to get an earlier first description once the minimum-data gate is likely to pass), 5 minutes on every pass after that — regardless of whether the previous pass succeeded, failed, or was skipped for insufficient data:
  1. `try? await Task.sleep(for: .seconds(isFirstIteration ? 120 : 300))`, then set `isFirstIteration = false`.
  2. Compute `LiveStateTrendCompute.summarize(MetricsQualityFilter.filter(env.tickHistory))`. If `nil`, skip the rest of this pass (leave `description` untouched) and loop back to step 1.
  3. Build `LiveStateInsightPayload`, call `env.sync.client.generateLiveStateInsight(_:)`.
  4. On success, set `description` to the returned text. On failure (`try?` swallows), leave `description` untouched — the next pass (5 minutes later) retries.
- This is view-owned, not `AppEnvironment`-owned: unlike `InsightGenerator`, this feature is explicitly Live-tab-visibility-scoped (per your call on the "Timer scope" question), so it doesn't belong on the app-wide `AppEnvironment`. No `ModelContext`/SwiftData involved at all — `description` is transient `@State`, not persisted, so there's no `@MainActor`/actor-isolation hazard analogous to `InsightGenerator`'s (Swift `Task` inherits the view's `@MainActor` context already; no explicit `@MainActor` annotation is needed on the widget itself beyond what SwiftUI already provides for `View`s).

---

## 5. UI states and styling

Placed in `DayScrollView`'s `isToday` branch, in `ios/JustBreathe/UI/Live/LiveView.swift`, directly above the existing `CurrentStateCard`:

```swift
if isToday {
    LiveStateWidget()
        .padding(.horizontal)
    let state = PolyvagalState.infer(from: env.latestTick)
    CurrentStateCard(tick: env.latestTick, state: state)
        .padding(.horizontal)
}
```

Styling: smaller/lighter than `CurrentStateCard` — a single `Text` in `Theme.monoBody`/`Theme.text` (no header, no bars, no tiles), wrapped in `Theme.card` background + `Theme.cardRadius` clip + `Theme.border` stroke, matching the existing card idiom but with much less internal structure/padding (e.g. 12pt padding vs `CurrentStateCard`'s 18pt).

| State | Widget shows |
|---|---|
| `description == nil` (< ~2 min of data, or first call still in flight) | Placeholder text, e.g. "Gathering data…" in `Theme.dim` |
| `description` set, next refresh in flight | Previous text, unchanged — no loading indicator |
| `description` set, refresh fails | Previous text stays; silent retry in 5 minutes |
| BLE disconnects | Loop stops; last `description` remains visible, untouched |
| BLE reconnects | Loop restarts; existing `description` stays visible until the next successful refresh replaces it |

No tap target, no navigation, no error affordance — purely a passive readout, consistent with the "silent, non-blocking" pattern already established for Activity Insights.

---

## 6. Privacy

Same posture as Activity Insights: the request carries per-metric numeric trend stats and a window length, no user/device identifier. This is physiological data leaving the device to OpenAI on a recurring 5-minute cadence while the Live tab is open and connected (higher frequency than Activity Insights' per-activity cadence) — worth noting in user-facing privacy documentation if the app has any, same caveat as the prior spec.

---

## 7. Error Handling Summary

| Failure point | Behavior |
|---|---|
| `mode == "live_state"` with missing/empty `metrics` (backend) | 422 |
| OpenAI API error/timeout (backend) | 502, no server-side retry |
| Network error / non-2xx (iOS) | `description` untouched, silent, next 5-min iteration retries |
| Fewer than 2 minutes of valid data | Widget shows placeholder, no API call made |
| BLE disconnects mid-loop | Loop stops cleanly via `Task.isCancelled`/`.onChange`; no dangling requests continue after disconnect (in-flight request, if any, still completes — its result is simply discarded into `description` even if BLE has since dropped, which is harmless) |

---

## 8. Testing

- Backend: unit test `_format_live_state` output shape; unit test the handler for `mode == "live_state"` success (mocked OpenAI client, same `dependency_overrides` pattern as existing `test_insights.py`), 422 on missing `metrics`, 502 on OpenAI failure. Existing `mode == "activity"` tests are unaffected (default value keeps old callers passing).
- iOS: unit test `LiveStateTrendCompute.summarize` — direction classification (rising/falling/stable) against constructed `MetricsHistoryPoint` sequences, minimum-data-gate returning `nil` below the 60-point threshold, per-metric omission when all values are nil, start/end/min/max/mean correctness.
- iOS: unit test the payload conversion (`MetricTrend` → `MetricTrendPayload`) for correct field mapping.
- No automated test for `LiveStateWidget`'s timer loop itself (view-level `Task` lifecycle isn't practically unit-testable in this codebase's existing patterns — none of the other `Task`-based loops, e.g. `AppEnvironment.metricsTask`, are tested directly either). Verified manually (§9).
- Manual: pair a Polar H10, sit on the Live tab for 10+ minutes, confirm the widget replaces its placeholder with real generated text, confirm it updates again after 5 more minutes, confirm disconnecting the strap leaves the last text in place rather than clearing it.

---

## 9. Files Changed / Created

| Action | File |
|---|---|
| Modify | `server/models.py` — `InsightRequest.mode`, `MetricTrend`, `activity_type` → Optional |
| Modify | `server/routers/insights.py` — mode branch, `_LIVE_STATE_SYSTEM_PROMPT`, `_format_live_state`, mode-specific 422 validation |
| Modify | `server/tests/test_insights.py` — live_state mode test cases |
| Create | `ios/JustBreathe/Metrics/LiveStateTrendCompute.swift` |
| Create | `ios/JustBreatheTests/LiveStateTrendComputeTests.swift` |
| Modify | `ios/JustBreathe/Sync/APIClient.swift` — `MetricTrendPayload`, `LiveStateInsightPayload`, `generateLiveStateInsight`, `InsightAPIClient` protocol addition, `MetricTrendPayload(from: MetricTrend)` builder |
| Create | `ios/JustBreathe/UI/Live/LiveStateWidget.swift` |
| Modify | `ios/JustBreathe/UI/Live/LiveView.swift` — insert `LiveStateWidget()` above `CurrentStateCard` in `DayScrollView`'s `isToday` branch |

---

## 10. Out of Scope

- Any change to `CurrentStateCard` or `PolyvagalState`'s existing rule-based logic — untouched, this widget is purely additive.
- Persisting the live-state description across app restarts — it's transient `@State`, recomputed from scratch each time the Live tab appears.
- Showing this widget on past-day pages (only "today" — a rolling 10-minute window has no meaning for a historical day).
- Any recommendation/action copy in the live-state text (descriptive only — recommendations remain the Activity Insights card's role).
- A manual refresh affordance (no tap target on the widget in this version).
- Rate-limiting or cost caps beyond the 5-minute cadence itself.
