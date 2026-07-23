# Live State Widget Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A small widget above `CurrentStateCard` on the Live tab's today page shows an OpenAI-generated, purely descriptive account of the user's nervous-system trend over the last 10 minutes, refreshing every 5 minutes while the tab is visible and a Polar H10 is connected.

**Architecture:** Extends the existing stateless `POST /insights` endpoint with a `mode` field ("activity" | "live_state") rather than adding a new endpoint. The iOS app computes per-metric trend summaries (start/end/min/max/mean/direction) from `env.tickHistory` client-side, sends only that compact summary, and a view-local `Task` loop (not `AppEnvironment`-owned, since this feature is explicitly Live-tab-visibility-scoped) drives the refresh cadence.

**Tech Stack:** FastAPI + `openai` Python SDK (backend, already in place), Swift 5.9 / SwiftUI (iOS), `pytest` (backend tests), `XCTest` (iOS tests).

## Global Constraints

- OpenAI model `gpt-4o-mini`, `max_tokens=150`, `temperature=0.6` — same as the existing activity-mode call (spec §1).
- `mode == "live_state"` system prompt is purely descriptive — explicitly no recommendations/suggested actions (spec §1).
- Core metric set: HR (`meanBPM`), RMSSD, RSA (`rsaMs`), SDNN, LF/HF (`lfHF`), coherence, breath BPM (`breathBPM`), CBI. Wire keys: `hr`, `rmssd`, `rsa`, `sdnn`, `lf_hf`, `coherence`, `breath_bpm`, `cbi` (spec §2).
- Minimum data gate: fewer than 60 quality-passing points (≈2 minutes at 2 s/tick) in the window → `LiveStateTrendCompute.summarize` returns `nil`, widget shows placeholder, no network call (spec §2).
- `direction` classification: split window in half by index; `"rising"`/`"falling"` if `|secondMean - firstMean| / max(|firstMean|, 1e-6) > 0.05`, else `"stable"` (spec §2).
- Refresh cadence: 2 minutes after the loop starts (first pass), 5 minutes every pass after that, regardless of whether the previous pass succeeded, failed, or was skipped (spec §4).
- No loading spinner on refresh — previous description stays visible until replaced; only the pre-first-description state shows a placeholder (spec §5).
- Timer runs only while the widget is visible (Live tab, today page) AND BLE is connected; stops otherwise but never clears `description` (spec §4, §5).
- No new persistence — `description` is transient `@State`, not written to SwiftData (spec §10).
- No recommendation copy, no tap target, no manual refresh button in this version (spec §10).

---

### Task 1: Backend — extend `POST /insights` with `mode`

**Files:**
- Modify: `server/models.py`
- Modify: `server/routers/insights.py`
- Modify: `server/tests/test_insights.py`

**Interfaces:**
- Produces: `InsightRequest.mode: str = "activity"`, `MetricTrend` (Pydantic model with `start`/`end`/`min`/`max`/`mean`/`direction`, all `Optional`), `InsightRequest.window_minutes: Optional[int]`, `InsightRequest.metrics: Optional[dict[str, MetricTrend]]`. `activity_type` changes from required `str` to `Optional[str]`.
- `POST /insights` with `mode: "live_state"` requires non-empty `metrics` (else 422); with `mode: "activity"` (or omitted) requires `activity_type` (else 422) — same as before, just now enforced in code instead of by Pydantic's required-field validation.

- [ ] **Step 1: Write the failing tests**

Add to `server/tests/test_insights.py`, after the existing `_PAYLOAD` constant:

```python
_LIVE_STATE_PAYLOAD = {
    "mode": "live_state",
    "window_minutes": 10,
    "metrics": {
        "hr":  {"start": 68.0, "end": 62.0, "min": 60.0, "max": 70.0, "mean": 65.0, "direction": "falling"},
        "rsa": {"start": 22.0, "end": 34.0, "min": 20.0, "max": 36.0, "mean": 28.0, "direction": "rising"},
    },
}
```

Add these test functions at the end of the file:

```python
@pytest.mark.asyncio
async def test_generate_live_state_insight_success():
    app.dependency_overrides[get_openai_client] = lambda: _FakeOpenAIClient(
        content="  Your heart rate has been gradually settling over the last 10 minutes.  "
    )
    try:
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
            r = await client.post("/insights", json=_LIVE_STATE_PAYLOAD)
    finally:
        app.dependency_overrides.pop(get_openai_client, None)

    assert r.status_code == 200
    assert r.json()["text"] == "Your heart rate has been gradually settling over the last 10 minutes."


@pytest.mark.asyncio
async def test_generate_live_state_insight_missing_metrics_returns_422():
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        r = await client.post("/insights", json={"mode": "live_state", "window_minutes": 10})
    assert r.status_code == 422


@pytest.mark.asyncio
async def test_generate_activity_insight_missing_activity_type_returns_422():
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        r = await client.post("/insights", json={"mode": "activity"})
    assert r.status_code == 422
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd /Users/alexutkin && python3 -m venv .venv 2>/dev/null; source .venv/bin/activate && pip install --quiet --upgrade pip && pip install --quiet -r requirements.txt -r server/requirements.txt pytest pytest-asyncio httpx openai && python3 -m pytest server/tests/test_insights.py -v`
(If `.venv` already exists from earlier work in this checkout, the `python3 -m venv` call is a harmless no-op — `2>/dev/null` swallows its "already exists" message.)
Expected: the 3 new tests fail — `test_generate_live_state_insight_success` and `test_generate_live_state_insight_missing_metrics_returns_422` fail because `mode`/`metrics`/`window_minutes` aren't valid `InsightRequest` fields yet (Pydantic validation error, unexpected status code); `test_generate_activity_insight_missing_activity_type_returns_422` fails because Pydantic currently rejects a missing `activity_type` with its own 422 shape by coincidence — that's fine, either way this step confirms the suite runs; the important new-behavior tests are the first two.

- [ ] **Step 3: Add `MetricTrend` and update `InsightRequest`**

In `server/models.py`, replace:

```python
class InsightRequest(BaseModel):
    activity_type:    str
    activity_subtype: Optional[str] = None
    duration_min:     Optional[int] = None
    before_hr:    Optional[float] = None
    during_hr:    Optional[float] = None
    after_hr:     Optional[float] = None
    before_rsa:   Optional[float] = None
    during_rsa:   Optional[float] = None
    after_rsa:    Optional[float] = None
    before_sdnn:  Optional[float] = None
    during_sdnn:  Optional[float] = None
    after_sdnn:   Optional[float] = None
    before_lf_hf: Optional[float] = None
    during_lf_hf: Optional[float] = None
    after_lf_hf:  Optional[float] = None
```

with:

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

    # "activity" mode fields
    activity_type:    Optional[str] = None
    activity_subtype: Optional[str] = None
    duration_min:     Optional[int] = None
    before_hr:    Optional[float] = None
    during_hr:    Optional[float] = None
    after_hr:     Optional[float] = None
    before_rsa:   Optional[float] = None
    during_rsa:   Optional[float] = None
    after_rsa:    Optional[float] = None
    before_sdnn:  Optional[float] = None
    during_sdnn:  Optional[float] = None
    after_sdnn:   Optional[float] = None
    before_lf_hf: Optional[float] = None
    during_lf_hf: Optional[float] = None
    after_lf_hf:  Optional[float] = None

    # "live_state" mode fields
    window_minutes: Optional[int] = None
    metrics: Optional[dict[str, MetricTrend]] = None
```

- [ ] **Step 4: Add live-state prompt, formatter, and mode branching**

In `server/routers/insights.py`, replace the import line:

```python
from ..models import InsightRequest, InsightResponse
```

with:

```python
from ..models import InsightRequest, InsightResponse, MetricTrend
```

Add after the existing `_SYSTEM_PROMPT` constant:

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
```

Add after the existing `_format_metrics` function:

```python
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

Replace the `generate_insight` handler body:

```python
@router.post("/insights", response_model=InsightResponse)
async def generate_insight(
    req: InsightRequest,
    client: AsyncOpenAI = Depends(get_openai_client),
):
    if req.mode == "live_state":
        if not req.metrics:
            raise HTTPException(status_code=422, detail="metrics is required for live_state mode")
        system_prompt = _LIVE_STATE_SYSTEM_PROMPT
        user_content = _format_live_state(req)
    else:
        if not req.activity_type:
            raise HTTPException(status_code=422, detail="activity_type is required for activity mode")
        system_prompt = _SYSTEM_PROMPT
        user_content = _format_metrics(req)

    try:
        response = await client.chat.completions.create(
            model="gpt-4o-mini",
            max_tokens=150,
            temperature=0.6,
            messages=[
                {"role": "system", "content": system_prompt},
                {"role": "user", "content": user_content},
            ],
        )
    except OpenAIError as e:
        raise HTTPException(status_code=502, detail=str(e))

    text = response.choices[0].message.content
    if not text or not text.strip():
        raise HTTPException(status_code=502, detail="Empty response from OpenAI")
    return InsightResponse(text=text.strip())
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `python3 -m pytest server/tests/test_insights.py -v`
Expected: `7 passed` (4 existing + 3 new)

- [ ] **Step 6: Commit**

```bash
git add server/models.py server/routers/insights.py server/tests/test_insights.py
git commit -m "feat(server): extend POST /insights with live_state mode"
```

---

### Task 2: iOS — `LiveStateTrendCompute`

**Files:**
- Create: `ios/Pulsar/Metrics/LiveStateTrendCompute.swift`
- Modify: `ios/Pulsar/Models/MetricsHistoryPoint.swift`
- Test: `ios/PulsarTests/LiveStateTrendComputeTests.swift`

**Interfaces:**
- Produces: `struct MetricTrend { let start, end, min, max, mean: Float?; let direction: String }`, `enum LiveStateTrendCompute { static let minimumPoints = 60; static func summarize(_ history: [MetricsHistoryPoint], windowMinutes: Int = 10, now: Date = .now) -> [String: MetricTrend]? }`. Task 3 (`APIClient`'s payload builder) and Task 4 (`LiveStateWidget`) consume both.
- `MetricsHistoryPoint` gains a convenience initializer (used by this task's tests and available generally) since its only existing initializers (`init(from: MetricsTick)`, `init(from: HRVSample)`) suppress the compiler-synthesized memberwise init.

- [ ] **Step 1: Add a convenience initializer to `MetricsHistoryPoint`**

In `ios/Pulsar/Models/MetricsHistoryPoint.swift`, add after the existing `init(from sample: HRVSample)` initializer (before the closing brace of the struct):

```swift
    /// Convenience initializer for constructing a snapshot directly by field,
    /// without going through MetricsTick's full field list. Unlisted fields
    /// default to nil.
    init(
        timestamp: Date,
        meanBPM:   Float? = nil,
        rmssd:     Float? = nil,
        rsaMs:     Float? = nil,
        sdnn:      Float? = nil,
        lfHF:      Float? = nil,
        coherence: Float? = nil,
        breathBPM: Float? = nil,
        cbi:       Float? = nil
    ) {
        self.timestamp = timestamp
        self.ieRatio = nil
        self.vti = nil
        self.rmssd = rmssd
        self.rsaMs = rsaMs
        self.sdnn = sdnn
        self.pnn50 = nil
        self.ulfPower = nil
        self.vlfPower = nil
        self.lfPower = nil
        self.hfPower = nil
        self.lfHF = lfHF
        self.coherence = coherence
        self.cbi = cbi
        self.breathBPM = breathBPM
        self.meanBPM = meanBPM
        self.dfa1 = nil
        self.signalQuality = nil
        self.rcmse = nil
        self.pip = nil
        self.ials = nil
        self.dc = nil
    }
```

- [ ] **Step 2: Write the failing tests**

Create `ios/PulsarTests/LiveStateTrendComputeTests.swift`:

```swift
import XCTest
@testable import Pulsar

final class LiveStateTrendComputeTests: XCTestCase {

    /// Builds `count` points spaced 2s apart, ending at `now`, with the given
    /// HR values in chronological order (oldest first).
    private func points(count: Int, hrValues: [Float], now: Date = Date()) -> [MetricsHistoryPoint] {
        (0..<count).map { i in
            MetricsHistoryPoint(
                timestamp: now.addingTimeInterval(-Double(count - i) * 2),
                meanBPM: hrValues[i]
            )
        }
    }

    func testReturnsNilBelowMinimumPoints() {
        let history = points(count: 30, hrValues: Array(repeating: 70, count: 30))
        XCTAssertNil(LiveStateTrendCompute.summarize(history, windowMinutes: 10))
    }

    func testComputesStartEndMinMaxMean() {
        let values: [Float] = (0..<60).map { Float(60 + $0) }   // 60...119, ascending
        let history = points(count: 60, hrValues: values)
        let result = LiveStateTrendCompute.summarize(history, windowMinutes: 10)
        let hr = result?["hr"]
        XCTAssertEqual(hr?.start, 60)
        XCTAssertEqual(hr?.end, 119)
        XCTAssertEqual(hr?.min, 60)
        XCTAssertEqual(hr?.max, 119)
        XCTAssertEqual(hr?.mean ?? 0, 89.5, accuracy: 0.01)
    }

    func testDetectsRisingDirection() {
        let values = [Float](repeating: 60, count: 30) + [Float](repeating: 80, count: 30)
        let history = points(count: 60, hrValues: values)
        let result = LiveStateTrendCompute.summarize(history, windowMinutes: 10)
        XCTAssertEqual(result?["hr"]?.direction, "rising")
    }

    func testDetectsFallingDirection() {
        let values = [Float](repeating: 80, count: 30) + [Float](repeating: 60, count: 30)
        let history = points(count: 60, hrValues: values)
        let result = LiveStateTrendCompute.summarize(history, windowMinutes: 10)
        XCTAssertEqual(result?["hr"]?.direction, "falling")
    }

    func testDetectsStableDirection() {
        let values = [Float](repeating: 70, count: 60)
        let history = points(count: 60, hrValues: values)
        let result = LiveStateTrendCompute.summarize(history, windowMinutes: 10)
        XCTAssertEqual(result?["hr"]?.direction, "stable")
    }

    func testOmitsMetricWithNoValuesInWindow() {
        let history = points(count: 60, hrValues: Array(repeating: 70, count: 60))
        let result = LiveStateTrendCompute.summarize(history, windowMinutes: 10)
        XCTAssertNotNil(result?["hr"])
        XCTAssertNil(result?["rsa"])
    }

    func testExcludesPointsOutsideWindow() {
        let now = Date()
        // 60 points 20 minutes old (outside a 10-min window) + 60 recent points.
        let old = (0..<60).map { i in
            MetricsHistoryPoint(timestamp: now.addingTimeInterval(-1200 - Double(60 - i) * 2), meanBPM: 40)
        }
        let recent = (0..<60).map { i in
            MetricsHistoryPoint(timestamp: now.addingTimeInterval(-Double(60 - i) * 2), meanBPM: 70)
        }
        let result = LiveStateTrendCompute.summarize(old + recent, windowMinutes: 10, now: now)
        XCTAssertEqual(result?["hr"]?.mean, 70)
    }
}
```

- [ ] **Step 3: Register the new files in the Xcode project**

`LiveStateTrendCompute.swift` (Step 5 below) goes in the app target's `Metrics/` group; `LiveStateTrendComputeTests.swift` goes in the `PulsarTests` target. Follow the exact 4-location pattern already used for every other file in `ios/Pulsar.xcodeproj/project.pbxproj` (`PBXBuildFile`, `PBXFileReference`, the group's `children` list, the target's `Sources` build phase `files` list) — search the file for an existing entry in the relevant group (e.g. `RSACompute.swift` for the app target, `InsightGeneratorTests.swift` for the test target) to find the exact 4 spots and copy the pattern with new unique identifiers.

- [ ] **Step 4: Run the tests to verify they fail**

Run: `xcodebuild test -project ios/Pulsar.xcodeproj -scheme Pulsar -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:PulsarTests/LiveStateTrendComputeTests CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO 2>&1 | tail -30`
Expected: build failure — `cannot find 'LiveStateTrendCompute' in scope` (the type doesn't exist yet).

- [ ] **Step 5: Create `LiveStateTrendCompute`**

Create `ios/Pulsar/Metrics/LiveStateTrendCompute.swift`:

```swift
import Foundation

// MARK: - MetricTrend

struct MetricTrend {
    let start: Float?
    let end:   Float?
    let min:   Float?
    let max:   Float?
    let mean:  Float?
    let direction: String   // "rising" | "falling" | "stable"
}

// MARK: - LiveStateTrendCompute

enum LiveStateTrendCompute {

    /// Metric keys, matching the backend's expected `metrics` dict keys.
    private static let keyPaths: [(key: String, path: (MetricsHistoryPoint) -> Float?)] = [
        ("hr",         { $0.meanBPM }),
        ("rmssd",      { $0.rmssd }),
        ("rsa",        { $0.rsaMs }),
        ("sdnn",       { $0.sdnn }),
        ("lf_hf",      { $0.lfHF }),
        ("coherence",  { $0.coherence }),
        ("breath_bpm", { $0.breathBPM }),
        ("cbi",        { $0.cbi }),
    ]

    /// Minimum quality-passing points required in the window before summarizing
    /// (≈2 minutes at 2 s/tick).
    static let minimumPoints = 60

    /// Summarizes the last `windowMinutes` of quality-filtered history into one
    /// MetricTrend per core metric. Returns nil if there isn't enough valid
    /// data yet.
    static func summarize(_ history: [MetricsHistoryPoint], windowMinutes: Int = 10, now: Date = .now) -> [String: MetricTrend]? {
        let cutoff = now.addingTimeInterval(-Double(windowMinutes) * 60)
        let window = history.filter { $0.timestamp >= cutoff }
        guard window.count >= minimumPoints else { return nil }

        var result: [String: MetricTrend] = [:]
        for (key, path) in keyPaths {
            let values = window.compactMap(path)
            guard !values.isEmpty else { continue }
            result[key] = trend(for: values)
        }
        guard !result.isEmpty else { return nil }
        return result
    }

    private static func trend(for values: [Float]) -> MetricTrend {
        let startVal = values.first
        let endVal   = values.last
        let minVal   = values.min()
        let maxVal   = values.max()
        let meanVal  = values.reduce(0, +) / Float(values.count)

        let direction: String
        if values.count >= 2 {
            let mid = values.count / 2
            let firstHalf  = Array(values[..<mid])
            let secondHalf = Array(values[mid...])
            let firstMean  = firstHalf.reduce(0, +) / Float(firstHalf.count)
            let secondMean = secondHalf.reduce(0, +) / Float(secondHalf.count)
            let relChange  = abs(secondMean - firstMean) / max(abs(firstMean), 1e-6)
            if relChange > 0.05 {
                direction = secondMean > firstMean ? "rising" : "falling"
            } else {
                direction = "stable"
            }
        } else {
            direction = "stable"
        }

        return MetricTrend(start: startVal, end: endVal, min: minVal, max: maxVal, mean: meanVal, direction: direction)
    }
}
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `xcodebuild test -project ios/Pulsar.xcodeproj -scheme Pulsar -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:PulsarTests/LiveStateTrendComputeTests CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO 2>&1 | tail -30`
Expected: `** TEST SUCCEEDED **`, 7 tests passed.

- [ ] **Step 7: Commit**

```bash
git add ios/Pulsar/Metrics/LiveStateTrendCompute.swift ios/Pulsar/Models/MetricsHistoryPoint.swift ios/PulsarTests/LiveStateTrendComputeTests.swift ios/Pulsar.xcodeproj/project.pbxproj
git commit -m "feat(metrics): add LiveStateTrendCompute for 10-minute trend summaries"
```

---

### Task 3: iOS — `APIClient` wire types for live-state insights

**Files:**
- Modify: `ios/Pulsar/Sync/APIClient.swift`
- Modify: `ios/PulsarTests/InsightGeneratorTests.swift`
- Test: `ios/PulsarTests/PayloadBuilderTests.swift`

**Interfaces:**
- Consumes: `MetricTrend`, `LiveStateTrendCompute` from Task 2.
- Produces: `MetricTrendPayload: Codable`, `LiveStateInsightPayload: Codable`, `APIClient.generateLiveStateInsight(_:) async throws -> InsightResponse`, `MetricTrendPayload.init(from: MetricTrend)`, `LiveStateInsightPayload.init(windowMinutes:trends:)`. `InsightAPIClient` protocol gains `generateLiveStateInsight` as a second required method — this is a breaking change to the protocol that the existing `FakeClient` in `InsightGeneratorTests.swift` must be updated to satisfy (Step 3 below), or the whole test target fails to compile.

The network call itself (`generateLiveStateInsight`'s body) isn't unit-tested — matches the precedent set for `generateInsight`, no network-layer tests exist anywhere in this codebase. The payload *construction/mapping* (`MetricTrendPayload.init(from:)`, `LiveStateInsightPayload.init(windowMinutes:trends:)`) is plain value-mapping code and is tested (Steps 4-7).

- [ ] **Step 1: Add the wire types**

In `ios/Pulsar/Sync/APIClient.swift`, insert after the `InsightPayload` struct (after its closing brace, before `struct InsightResponse`):

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

- [ ] **Step 2: Add `generateLiveStateInsight` and expand the protocol**

In the same file, add this method inside `struct APIClient { ... }`, right after `generateInsight` (still under `// MARK: Insights`):

```swift
    func generateLiveStateInsight(_ payload: LiveStateInsightPayload) async throws -> InsightResponse {
        var req = request(path: "/insights", method: "POST")
        req.httpBody = try JSONEncoder().encode(payload)
        let (data, _) = try await session.data(for: req)
        return try JSONDecoder().decode(InsightResponse.self, from: data)
    }
```

Change the `InsightAPIClient` protocol:

```swift
protocol InsightAPIClient {
    func generateInsight(_ payload: InsightPayload) async throws -> InsightResponse
}
```

to:

```swift
protocol InsightAPIClient {
    func generateInsight(_ payload: InsightPayload) async throws -> InsightResponse
    func generateLiveStateInsight(_ payload: LiveStateInsightPayload) async throws -> InsightResponse
}
```

(`extension APIClient: InsightAPIClient {}` needs no change — `APIClient` already implements both required methods directly in its body.)

- [ ] **Step 3: Fix the existing `FakeClient` in `InsightGeneratorTests.swift`**

In `ios/PulsarTests/InsightGeneratorTests.swift`, change:

```swift
    private final class FakeClient: InsightAPIClient {
        let result: Result<InsightResponse, Error>
        init(result: Result<InsightResponse, Error>) { self.result = result }
        func generateInsight(_ payload: InsightPayload) async throws -> InsightResponse {
            try result.get()
        }
    }
```

to:

```swift
    private final class FakeClient: InsightAPIClient {
        let result: Result<InsightResponse, Error>
        init(result: Result<InsightResponse, Error>) { self.result = result }
        func generateInsight(_ payload: InsightPayload) async throws -> InsightResponse {
            try result.get()
        }
        func generateLiveStateInsight(_ payload: LiveStateInsightPayload) async throws -> InsightResponse {
            try result.get()
        }
    }
```

(This fake is never exercised via `generateLiveStateInsight` in the existing Activity-Insights tests — it only needs to compile against the now-larger protocol. Reusing the same `result` keeps the change minimal.)

- [ ] **Step 4: Write the failing payload-builder tests**

Create `ios/PulsarTests/PayloadBuilderTests.swift`:

```swift
import XCTest
@testable import Pulsar

final class PayloadBuilderTests: XCTestCase {

    func testMetricTrendPayloadMapsAllFields() {
        let trend = MetricTrend(start: 60, end: 70, min: 55, max: 75, mean: 65, direction: "rising")
        let payload = MetricTrendPayload(from: trend)
        XCTAssertEqual(payload.start, 60)
        XCTAssertEqual(payload.end, 70)
        XCTAssertEqual(payload.min, 55)
        XCTAssertEqual(payload.max, 75)
        XCTAssertEqual(payload.mean, 65)
        XCTAssertEqual(payload.direction, "rising")
    }

    func testLiveStateInsightPayloadMapsModeWindowAndMetrics() {
        let trends: [String: MetricTrend] = [
            "hr": MetricTrend(start: 60, end: 70, min: 55, max: 75, mean: 65, direction: "rising")
        ]
        let payload = LiveStateInsightPayload(windowMinutes: 10, trends: trends)
        XCTAssertEqual(payload.mode, "live_state")
        XCTAssertEqual(payload.windowMinutes, 10)
        XCTAssertEqual(payload.metrics["hr"]?.direction, "rising")
        XCTAssertEqual(payload.metrics["hr"]?.mean, 65)
    }
}
```

Register this file in the Xcode project's `PulsarTests` target, same 4-location `project.pbxproj` pattern as before.

- [ ] **Step 5: Run the tests to verify they fail**

Run: `xcodebuild test -project ios/Pulsar.xcodeproj -scheme Pulsar -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:PulsarTests/PayloadBuilderTests CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO 2>&1 | tail -30`
Expected: build failure — `init(from:)` and `init(windowMinutes:trends:)` don't exist yet.

- [ ] **Step 6: Add the payload builder**

At the bottom of `APIClient.swift`, after the `InsightPayload` extension (`init(from entry: ActivityLog)`), add:

```swift
extension MetricTrendPayload {
    init(from trend: MetricTrend) {
        self.start = trend.start
        self.end   = trend.end
        self.min   = trend.min
        self.max   = trend.max
        self.mean  = trend.mean
        self.direction = trend.direction
    }
}

extension LiveStateInsightPayload {
    init(windowMinutes: Int, trends: [String: MetricTrend]) {
        self.mode = "live_state"
        self.windowMinutes = windowMinutes
        self.metrics = trends.mapValues { MetricTrendPayload(from: $0) }
    }
}
```

- [ ] **Step 7: Run the tests to verify they pass, then re-verify the existing insight tests still compile and pass**

Run: `xcodebuild test -project ios/Pulsar.xcodeproj -scheme Pulsar -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:PulsarTests/PayloadBuilderTests CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO 2>&1 | tail -30`
Expected: `** TEST SUCCEEDED **`, 2/2 passing.

Run: `xcodebuild test -project ios/Pulsar.xcodeproj -scheme Pulsar -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:PulsarTests/InsightGeneratorTests CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO 2>&1 | tail -30`
Expected: `** TEST SUCCEEDED **`, 5/5 passing (unchanged behavior, now compiling against the expanded protocol thanks to Step 3's `FakeClient` fix).

- [ ] **Step 8: Commit**

```bash
git add ios/Pulsar/Sync/APIClient.swift ios/PulsarTests/InsightGeneratorTests.swift ios/PulsarTests/PayloadBuilderTests.swift ios/Pulsar.xcodeproj/project.pbxproj
git commit -m "feat(sync): add LiveStateInsightPayload wire types and generateLiveStateInsight"
```

---

### Task 4: iOS — `LiveStateWidget` and `LiveView` wiring

**Files:**
- Create: `ios/Pulsar/UI/Live/LiveStateWidget.swift`
- Modify: `ios/Pulsar/UI/Live/LiveView.swift`

**Interfaces:**
- Consumes: `LiveStateTrendCompute.summarize` (Task 2), `MetricsQualityFilter.filter` (existing, `ios/Pulsar/Models/MetricsHistoryPoint.swift`), `LiveStateInsightPayload.init(windowMinutes:trends:)` and `APIClient.generateLiveStateInsight` (Task 3), `env.tickHistory`, `env.ble.state` (`BLEState`, existing, `ios/Pulsar/BLE/BLEService.swift` — `.connected(name: String)` is an associated-value case, requires `if case` pattern matching, not `==`), `env.sync.client` (existing), `.cardStyle()`/`Theme.monoBody`/`Theme.dim`/`Theme.text` (existing, `ios/Pulsar/UI/Design/Theme.swift`).

No automated test for this task — view-level `Task` loop lifecycle isn't unit-tested anywhere else in this codebase either (e.g. `AppEnvironment.metricsTask` isn't directly tested). Verified by build + the manual check in the next task.

- [ ] **Step 1: Create `LiveStateWidget`**

Create `ios/Pulsar/UI/Live/LiveStateWidget.swift`:

```swift
import SwiftUI

/// Small, always-visible widget showing an OpenAI-generated, purely
/// descriptive account of the nervous-system trend over the last 10
/// minutes. Refreshes every 5 minutes (first pass after 2) while visible
/// and BLE-connected. Never shows a loading state on refresh — the
/// previous description stays until a new one replaces it.
struct LiveStateWidget: View {
    @Environment(AppEnvironment.self) var env
    @State private var description: String?
    @State private var refreshTask: Task<Void, Never>?

    private var isConnected: Bool {
        if case .connected = env.ble.state { return true }
        return false
    }

    var body: some View {
        Group {
            if let description {
                Text(description)
                    .font(Theme.monoBody)
                    .foregroundStyle(Theme.text)
            } else {
                Text("Gathering data…")
                    .font(Theme.monoBody)
                    .foregroundStyle(Theme.dim)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
        .onAppear {
            if isConnected { startLoop() }
        }
        .onDisappear {
            stopLoop()
        }
        .onChange(of: env.ble.state) { _, newValue in
            if case .connected = newValue {
                startLoop()
            } else {
                stopLoop()
            }
        }
    }

    // MARK: - Refresh loop

    private func startLoop() {
        guard refreshTask == nil else { return }
        refreshTask = Task {
            var isFirstIteration = true
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(isFirstIteration ? 120 : 300))
                isFirstIteration = false
                guard !Task.isCancelled else { break }

                let filtered = MetricsQualityFilter.filter(env.tickHistory)
                guard let trends = LiveStateTrendCompute.summarize(filtered) else { continue }

                let payload = LiveStateInsightPayload(windowMinutes: 10, trends: trends)
                if let response = try? await env.sync.client.generateLiveStateInsight(payload) {
                    description = response.text
                }
            }
        }
    }

    private func stopLoop() {
        refreshTask?.cancel()
        refreshTask = nil
    }
}
```

- [ ] **Step 2: Wire it into `LiveView`**

In `ios/Pulsar/UI/Live/LiveView.swift`, change:

```swift
                // ── Autonomic state (today only) ────────────────────
                if isToday {
                    let state = PolyvagalState.infer(from: env.latestTick)
                    CurrentStateCard(tick: env.latestTick, state: state)
                        .padding(.horizontal)
                }
```

to:

```swift
                // ── Autonomic state (today only) ────────────────────
                if isToday {
                    LiveStateWidget()
                        .padding(.horizontal)
                    let state = PolyvagalState.infer(from: env.latestTick)
                    CurrentStateCard(tick: env.latestTick, state: state)
                        .padding(.horizontal)
                }
```

- [ ] **Step 3: Register the new file in the Xcode project**

Add `LiveStateWidget.swift` to the app target following the same 4-location `project.pbxproj` pattern as Task 2's Step 3 (e.g. use `CurrentStateCard.swift`'s entries as the template, since it's in the same `UI/Live` group).

- [ ] **Step 4: Build to verify it compiles**

Run: `xcodebuild build -project ios/Pulsar.xcodeproj -scheme Pulsar -destination 'platform=iOS Simulator,name=iPhone 17' CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO 2>&1 | tail -20`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 5: Commit**

```bash
git add ios/Pulsar/UI/Live/LiveStateWidget.swift ios/Pulsar/UI/Live/LiveView.swift ios/Pulsar.xcodeproj/project.pbxproj
git commit -m "feat(live): add LiveStateWidget above CurrentStateCard"
```

---

### Task 5: Manual end-to-end verification

No code changes. Confirms the whole chain works with a real OpenAI key, since Tasks 1-4 only prove each piece in isolation with fakes.

- [ ] **Step 1: Start Postgres and the backend with a real key**

If the local Postgres set up during the Activity Insights E2E check is still installed but stopped:

```bash
export PATH="/opt/homebrew/opt/postgresql@16/bin:$PATH"
LC_ALL="en_US.UTF-8" postgres -D /opt/homebrew/var/postgresql@16 > /tmp/postgres.log 2>&1 &
sleep 2
```

Then, from the repo root, with a Python venv that has `server/requirements.txt` + `uvicorn` installed:

```bash
export OPENAI_API_KEY=<your key>
export DATABASE_URL="postgresql://postgres:postgres@localhost:5432/pulsar"
uvicorn server.main:app --host 0.0.0.0 --port 8000
```

Expected: `GET http://localhost:8000/health` returns `{"status":"ok"}`.

- [ ] **Step 2: Smoke-test the live_state mode directly**

```bash
curl -s -X POST http://localhost:8000/insights \
  -H "Content-Type: application/json" \
  -d '{
    "mode": "live_state",
    "window_minutes": 10,
    "metrics": {
      "hr": {"start": 74.0, "end": 66.0, "min": 65.0, "max": 76.0, "mean": 70.0, "direction": "falling"},
      "rsa": {"start": 20.0, "end": 30.0, "min": 19.0, "max": 31.0, "mean": 25.0, "direction": "rising"},
      "coherence": {"start": 0.3, "end": 0.55, "min": 0.28, "max": 0.6, "mean": 0.42, "direction": "rising"}
    }
  }'
```

Expected: `200` with a `{"text": "..."}` response that reads as a purely descriptive 2-3 sentence account (no recommendation/suggested action).

- [ ] **Step 3: Run the app and observe the widget**

Build and run the `Pulsar` scheme on a physical device or simulator, with `serverURL` pointing at this machine's local IP on port 8000 (a simulator can reach `localhost:8000` directly since the Mac is the host; a physical device needs the Mac's LAN IP — set via Settings if the app exposes a server URL field, or `UserDefaults.standard.set(...)` for `"serverURL"` during a debug session). Pair a Polar H10 (simulator can't — this step needs a physical device with real BLE hardware, or previously-recorded HRV samples already in the SwiftData store from an earlier session so `env.tickHistory` has ≥60 quality-passing points once merged in on foreground).

Open the Live tab, today page. Confirm:
- Immediately: the widget shows "Gathering data…".
- After ~2 minutes with a connected strap: the widget shows real generated text, positioned above `CurrentStateCard`.
- ~5 minutes later: the text updates again (no flicker/loading state observed in between).
- Disconnect the strap: the last text remains visible, doesn't clear or error.

- [ ] **Step 4: Shut down**

```bash
pkill -f "uvicorn server.main:app"
pkill -f "postgres -D /opt/homebrew/var/postgresql@16"
```
