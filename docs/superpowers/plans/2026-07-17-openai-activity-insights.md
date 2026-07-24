# OpenAI Activity Insights Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** After a logged activity's before/during/after HRV windows are computed, generate a short OpenAI-backed interpretation + recommendation and show it in the activity detail view.

**Architecture:** A stateless FastAPI endpoint (`POST /insights`) on the existing sync server proxies to OpenAI so the API key never ships in the app. The iOS app fires a background request when an activity ends, storing the result on the `ActivityLog` entry; a foreground-triggered retry sweep (mirroring the existing `SessionUploader` pattern) catches anything that failed while offline. The UI shows the text once it exists — no loading state, no error state.

**Tech Stack:** FastAPI + `openai` Python SDK (backend), Swift 5.9 / SwiftUI / SwiftData (iOS), `pytest` + `pytest-asyncio` + `httpx` (backend tests, already used by `server/tests/test_sessions.py`), `XCTest` (iOS tests).

## Global Constraints

- Backend config via `os.getenv`, matching `DATABASE_URL` in `server/db.py` — use `OPENAI_API_KEY` the same way.
- OpenAI model `gpt-4o-mini`, `max_tokens=150`, `temperature=0.6` (spec §1).
- Backend is fully stateless for insights — no new DB tables, no persistence of requests/responses (spec §1).
- Insight request payload carries no user/device identifier (spec §1, §5).
- `ActivityLog.insightText: String?` — `nil` means "not yet generated, eligible for retry"; no separate failure flag (spec §2).
- Generation is fire-and-forget from the 3 `computeHRVWindows` call sites in `ios/Wythin/UI/Actions/ActionsView.swift` (lines 309, 368, 383) — never blocks activity logging (spec §3).
- Retry sweep caps at the 10 most recent pending activities, triggered only by `AppEnvironment.isInForeground` transitioning to `true` (spec §3).
- No loading spinner, no error UI in `ActivityDetailView` — the Insight section renders only when `insightText != nil` (spec §4).
- `PolyvagalState.swift`'s rule-based causes/facts/actions are untouched — unrelated system (spec §9).

---

### Task 1: Backend — `POST /insights` endpoint

**Files:**
- Create: `server/tests/test_insights.py`
- Modify: `server/models.py` — add `InsightRequest`, `InsightResponse`
- Create: `server/routers/insights.py`
- Modify: `server/main.py` — register the router
- Modify: `server/requirements.txt` — add `openai`

**Interfaces:**
- Produces: `POST /insights` accepting `InsightRequest` JSON, returning `InsightResponse` (`{"text": str}`) on success, HTTP 502 on any OpenAI failure or empty completion, HTTP 500 (uncaught `RuntimeError`) if `OPENAI_API_KEY` is unset.
- Produces: `server.routers.insights.get_openai_client` — a FastAPI dependency, overridable in tests.

- [ ] **Step 1: Write the failing tests**

Create `server/tests/test_insights.py`:

```python
"""
Tests for POST /insights — the OpenAI client is swapped for a fake via
FastAPI's dependency_overrides, so no real API calls are made.
"""
from __future__ import annotations

import pytest
from httpx import AsyncClient, ASGITransport
from openai import OpenAIError

from server.main import app
from server.routers.insights import get_openai_client


class _FakeMessage:
    def __init__(self, content):
        self.content = content


class _FakeChoice:
    def __init__(self, content):
        self.message = _FakeMessage(content)


class _FakeCompletion:
    def __init__(self, content):
        self.choices = [_FakeChoice(content)]


class _FakeChatCompletions:
    def __init__(self, content=None, raise_error=False):
        self._content = content
        self._raise_error = raise_error

    async def create(self, **kwargs):
        if self._raise_error:
            raise OpenAIError("boom")
        return _FakeCompletion(self._content)


class _FakeChat:
    def __init__(self, completions):
        self.completions = completions


class _FakeOpenAIClient:
    def __init__(self, content=None, raise_error=False):
        self.chat = _FakeChat(_FakeChatCompletions(content=content, raise_error=raise_error))


_PAYLOAD = {
    "activity_type": "Breathwork",
    "activity_subtype": "Box Breathing",
    "duration_min": 10,
    "before_rsa": 20.0,
    "during_rsa": 32.0,
    "after_rsa": 28.0,
}


@pytest.mark.asyncio
async def test_generate_insight_success():
    app.dependency_overrides[get_openai_client] = lambda: _FakeOpenAIClient(
        content="  Solid session — your RSA improved nicely.  "
    )
    try:
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
            r = await client.post("/insights", json=_PAYLOAD)
    finally:
        app.dependency_overrides.pop(get_openai_client, None)

    assert r.status_code == 200
    assert r.json()["text"] == "Solid session — your RSA improved nicely."


@pytest.mark.asyncio
async def test_generate_insight_openai_error_returns_502():
    app.dependency_overrides[get_openai_client] = lambda: _FakeOpenAIClient(raise_error=True)
    try:
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
            r = await client.post("/insights", json=_PAYLOAD)
    finally:
        app.dependency_overrides.pop(get_openai_client, None)

    assert r.status_code == 502


@pytest.mark.asyncio
async def test_generate_insight_empty_response_returns_502():
    app.dependency_overrides[get_openai_client] = lambda: _FakeOpenAIClient(content="")
    try:
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
            r = await client.post("/insights", json=_PAYLOAD)
    finally:
        app.dependency_overrides.pop(get_openai_client, None)

    assert r.status_code == 502


def test_get_openai_client_requires_api_key(monkeypatch):
    monkeypatch.delenv("OPENAI_API_KEY", raising=False)
    with pytest.raises(RuntimeError):
        get_openai_client()
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd /Users/alexutkin && python3 -m pytest server/tests/test_insights.py -v`
Expected: collection error — `ModuleNotFoundError: No module named 'server.routers.insights'` (the module doesn't exist yet).

- [ ] **Step 3: Add the request/response schemas**

In `server/models.py`, add after the existing `AdminUserRow` class:

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


class InsightResponse(BaseModel):
    text: str
```

- [ ] **Step 4: Create the router**

Create `server/routers/insights.py`:

```python
"""
POST /insights — generates a short OpenAI-backed interpretation +
recommendation for one completed activity's HRV response.

Fully stateless: nothing here is persisted. The request carries no user
or device identifier because nothing needs to associate the response
with anyone.
"""
from __future__ import annotations

import os
from fastapi import APIRouter, Depends, HTTPException
from openai import AsyncOpenAI, OpenAIError

from ..models import InsightRequest, InsightResponse

router = APIRouter(tags=["insights"])

_SYSTEM_PROMPT = (
    "You are a physiologist explaining heart-rate-variability (HRV) changes "
    "around a logged activity. Interpret the before/during/after deltas the "
    "user provides, then end with exactly one concrete, forward-looking "
    "suggestion for their next session. Keep the whole reply to 2-3 sentences. "
    "Do not use markdown formatting."
)


def get_openai_client() -> AsyncOpenAI:
    """FastAPI dependency — overridden with a fake in tests."""
    api_key = os.getenv("OPENAI_API_KEY")
    if not api_key:
        raise RuntimeError("OPENAI_API_KEY is not set")
    return AsyncOpenAI(api_key=api_key)


def _format_metrics(req: InsightRequest) -> str:
    lines = [f"Activity: {req.activity_type}"]
    if req.activity_subtype:
        lines.append(f"Subtype: {req.activity_subtype}")
    if req.duration_min is not None:
        lines.append(f"Duration: {req.duration_min} min")

    def metric(label: str, unit: str, before, during, after):
        if before is None and during is None and after is None:
            return
        lines.append(f"{label}: before={before}{unit} during={during}{unit} after={after}{unit}")

    metric("HR", "bpm", req.before_hr, req.during_hr, req.after_hr)
    metric("RSA", "ms", req.before_rsa, req.during_rsa, req.after_rsa)
    metric("SDNN", "ms", req.before_sdnn, req.during_sdnn, req.after_sdnn)
    metric("LF/HF", "", req.before_lf_hf, req.during_lf_hf, req.after_lf_hf)
    return "\n".join(lines)


@router.post("/insights", response_model=InsightResponse)
async def generate_insight(
    req: InsightRequest,
    client: AsyncOpenAI = Depends(get_openai_client),
):
    try:
        response = await client.chat.completions.create(
            model="gpt-4o-mini",
            max_tokens=150,
            temperature=0.6,
            messages=[
                {"role": "system", "content": _SYSTEM_PROMPT},
                {"role": "user", "content": _format_metrics(req)},
            ],
        )
    except OpenAIError as e:
        raise HTTPException(status_code=502, detail=str(e))

    text = response.choices[0].message.content
    if not text or not text.strip():
        raise HTTPException(status_code=502, detail="Empty response from OpenAI")
    return InsightResponse(text=text.strip())
```

- [ ] **Step 5: Register the router**

In `server/main.py`, change:

```python
from .routers import sessions, stream, admin
```
to:
```python
from .routers import sessions, stream, admin, insights
```

And change:
```python
app.include_router(sessions.router)
app.include_router(stream.router)
app.include_router(admin.router)
```
to:
```python
app.include_router(sessions.router)
app.include_router(stream.router)
app.include_router(admin.router)
app.include_router(insights.router)
```

- [ ] **Step 6: Add the `openai` dependency**

In `server/requirements.txt`, add a new line:

```
openai>=1.35.0
```

- [ ] **Step 7: Run the tests to verify they pass**

Run: `cd /Users/alexutkin && python3 -m pytest server/tests/test_insights.py -v`
Expected: `4 passed`

- [ ] **Step 8: Commit**

```bash
git add server/models.py server/routers/insights.py server/main.py server/requirements.txt server/tests/test_insights.py
git commit -m "feat(server): add POST /insights OpenAI-backed activity insight endpoint"
```

---

### Task 2: iOS — `APIClient` wire types and `generateInsight`

**Files:**
- Modify: `ios/Wythin/Sync/APIClient.swift`

**Interfaces:**
- Consumes: `ActivityLog` fields (`activityType`, `activitySubtype`, `duration`, `beforeHR`/`duringHR`/`afterHR`, `beforeRSA`/`duringRSA`/`afterRSA`, `beforeSDNN`/`duringSDNN`/`afterSDNN`, `beforeLFHF`/`duringLFHF`/`afterLFHF`) — all already defined in `ios/Wythin/Models/ActivityLog.swift`.
- Produces: `InsightPayload`, `InsightResponse` (Codable), `InsightAPIClient` protocol with `func generateInsight(_ payload: InsightPayload) async throws -> InsightResponse`, and `APIClient: InsightAPIClient` conformance. `InsightPayload.init(from: ActivityLog)` builder.

No automated test in this task — network-layer calls aren't unit-tested anywhere else in this codebase either (`uploadSession`/`fetchSessions` are untested directly); the meaningful, spec-required coverage is on `InsightGenerator` in Task 3, which exercises this protocol through a fake. This task is verified by a successful build.

- [ ] **Step 1: Add the wire types**

In `ios/Wythin/Sync/APIClient.swift`, insert after the `TickPayload` struct (after line 38, before `struct ServerSession`):

```swift
struct InsightPayload: Codable {
    let activityType:    String
    let activitySubtype: String?
    let durationMin:     Int?
    let beforeHR: Float?;    let duringHR: Float?;    let afterHR: Float?
    let beforeRSA: Float?;   let duringRSA: Float?;   let afterRSA: Float?
    let beforeSDNN: Float?;  let duringSDNN: Float?;  let afterSDNN: Float?
    let beforeLFHF: Float?;  let duringLFHF: Float?;  let afterLFHF: Float?

    enum CodingKeys: String, CodingKey {
        case activityType    = "activity_type"
        case activitySubtype = "activity_subtype"
        case durationMin     = "duration_min"
        case beforeHR = "before_hr"; case duringHR = "during_hr"; case afterHR = "after_hr"
        case beforeRSA = "before_rsa"; case duringRSA = "during_rsa"; case afterRSA = "after_rsa"
        case beforeSDNN = "before_sdnn"; case duringSDNN = "during_sdnn"; case afterSDNN = "after_sdnn"
        case beforeLFHF = "before_lf_hf"; case duringLFHF = "during_lf_hf"; case afterLFHF = "after_lf_hf"
    }
}

struct InsightResponse: Codable {
    let text: String
}
```

- [ ] **Step 2: Add the protocol and `generateInsight` method**

In the same file, add this method inside `struct APIClient { ... }`, right before `// MARK: Helpers` (after `fetchSessions`):

```swift
    // MARK: Insights

    func generateInsight(_ payload: InsightPayload) async throws -> InsightResponse {
        var req = request(path: "/insights", method: "POST")
        req.httpBody = try JSONEncoder().encode(payload)
        let (data, _) = try await session.data(for: req)
        return try JSONDecoder().decode(InsightResponse.self, from: data)
    }
```

Then, after the closing brace of `struct APIClient`, before `// MARK: - Payload builders`, add:

```swift
// MARK: - InsightAPIClient

/// Narrow protocol over `APIClient.generateInsight` so `InsightGenerator`
/// can be tested with a fake instead of a real network call.
protocol InsightAPIClient {
    func generateInsight(_ payload: InsightPayload) async throws -> InsightResponse
}

extension APIClient: InsightAPIClient {}
```

- [ ] **Step 3: Add the payload builder**

At the bottom of the file, after the `TickPayload` extension, add:

```swift
extension InsightPayload {
    init(from entry: ActivityLog) {
        self.activityType    = entry.activityType
        self.activitySubtype = entry.activitySubtype
        self.durationMin     = entry.duration.map { Int($0 / 60) }
        self.beforeHR   = entry.beforeHR;   self.duringHR   = entry.duringHR;   self.afterHR   = entry.afterHR
        self.beforeRSA  = entry.beforeRSA;  self.duringRSA  = entry.duringRSA;  self.afterRSA  = entry.afterRSA
        self.beforeSDNN = entry.beforeSDNN; self.duringSDNN = entry.duringSDNN; self.afterSDNN = entry.afterSDNN
        self.beforeLFHF = entry.beforeLFHF; self.duringLFHF = entry.duringLFHF; self.afterLFHF = entry.afterLFHF
    }
}
```

- [ ] **Step 4: Build to verify it compiles**

Run: `xcodebuild build -project ios/Wythin.xcodeproj -scheme Wythin -destination 'platform=iOS Simulator,name=iPhone 17' | tail -20`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 5: Commit**

```bash
git add ios/Wythin/Sync/APIClient.swift
git commit -m "feat(sync): add InsightPayload/InsightResponse wire types and generateInsight"
```

---

### Task 3: iOS — `ActivityLog.insightText` field and `InsightGenerator`

**Files:**
- Modify: `ios/Wythin/Models/ActivityLog.swift`
- Create: `ios/Wythin/Sync/InsightGenerator.swift`
- Test: `ios/WythinTests/InsightGeneratorTests.swift`

**Interfaces:**
- Consumes: `InsightAPIClient` protocol and `InsightPayload`/`InsightResponse` from Task 2.
- Produces: `ActivityLog.insightText: String?`. `actor InsightGenerator` with `init(client: InsightAPIClient)`, `func generate(for: ActivityLog, context: ModelContext) async`, `func flushPending(context: ModelContext, limit: Int = 10) async`, and `static func pendingActivities(context: ModelContext, limit: Int = 10) -> [ActivityLog]` — these four are what Task 4 and Task 5 call.

This mirrors the existing `SessionUploader` actor (`ios/Wythin/Sync/SessionUploader.swift`) — same shape, same pattern, for unsynced insights instead of unsynced sessions.

- [ ] **Step 1: Add the field to `ActivityLog`**

In `ios/Wythin/Models/ActivityLog.swift`, change:

```swift
    var notes:           String?
    var isManual:        Bool    // true = retrospective entry
```
to:
```swift
    var notes:           String?
    var isManual:        Bool    // true = retrospective entry

    /// OpenAI-generated interpretation + recommendation for this activity's
    /// HRV response. `nil` means "not yet generated" — eligible for retry
    /// by `InsightGenerator.flushPending`.
    var insightText:     String?
```

- [ ] **Step 2: Write the failing tests**

Create `ios/WythinTests/InsightGeneratorTests.swift`:

```swift
import XCTest
import SwiftData
@testable import Wythin

final class InsightGeneratorTests: XCTestCase {

    private func makeContext() -> ModelContext {
        let schema = Schema([ActivityLog.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try! ModelContainer(for: schema, configurations: [config])
        return ModelContext(container)
    }

    private struct StubError: Error {}

    private final class FakeClient: InsightAPIClient {
        let result: Result<InsightResponse, Error>
        init(result: Result<InsightResponse, Error>) { self.result = result }
        func generateInsight(_ payload: InsightPayload) async throws -> InsightResponse {
            try result.get()
        }
    }

    func testGenerateSetsInsightTextOnSuccess() async {
        let context = makeContext()
        let entry = ActivityLog(activityType: "Breathwork", startedAt: .now, endedAt: .now, isManual: true)
        context.insert(entry)

        let generator = InsightGenerator(client: FakeClient(result: .success(InsightResponse(text: "Nice recovery."))))
        await generator.generate(for: entry, context: context)

        XCTAssertEqual(entry.insightText, "Nice recovery.")
    }

    func testGenerateLeavesInsightTextNilOnFailure() async {
        let context = makeContext()
        let entry = ActivityLog(activityType: "Breathwork", startedAt: .now, endedAt: .now, isManual: true)
        context.insert(entry)

        let generator = InsightGenerator(client: FakeClient(result: .failure(StubError())))
        await generator.generate(for: entry, context: context)

        XCTAssertNil(entry.insightText)
    }

    func testFlushPendingGeneratesForAllPendingActivities() async {
        let context = makeContext()
        let a = ActivityLog(activityType: "Walk", startedAt: .now, endedAt: .now, isManual: true)
        let b = ActivityLog(activityType: "Walk",
                             startedAt: .now.addingTimeInterval(60),
                             endedAt: .now.addingTimeInterval(90), isManual: true)
        context.insert(a)
        context.insert(b)

        let generator = InsightGenerator(client: FakeClient(result: .success(InsightResponse(text: "Solid."))))
        await generator.flushPending(context: context)

        XCTAssertEqual(a.insightText, "Solid.")
        XCTAssertEqual(b.insightText, "Solid.")
    }

    func testPendingActivitiesFiltersEndedAndMissingInsight() {
        let context = makeContext()

        let notEnded = ActivityLog(activityType: "Walk", startedAt: .now, isManual: false)
        let alreadyInsighted = ActivityLog(activityType: "Walk", startedAt: .now, endedAt: .now, isManual: true)
        alreadyInsighted.insightText = "Already have one."
        let pending = ActivityLog(activityType: "Walk", startedAt: .now, endedAt: .now, isManual: true)

        context.insert(notEnded)
        context.insert(alreadyInsighted)
        context.insert(pending)

        let result = InsightGenerator.pendingActivities(context: context)

        XCTAssertEqual(result.map(\.id), [pending.id])
    }

    func testPendingActivitiesOrdersMostRecentFirstAndCaps() {
        let context = makeContext()
        let base = Date()
        var entries: [ActivityLog] = []
        for i in 0..<12 {
            let entry = ActivityLog(activityType: "Walk",
                                     startedAt: base.addingTimeInterval(TimeInterval(i) * 60),
                                     endedAt: base.addingTimeInterval(TimeInterval(i) * 60 + 30),
                                     isManual: true)
            context.insert(entry)
            entries.append(entry)
        }

        let result = InsightGenerator.pendingActivities(context: context, limit: 10)

        XCTAssertEqual(result.count, 10)
        XCTAssertEqual(result.first?.id, entries.last?.id)
    }
}
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `xcodebuild test -project ios/Wythin.xcodeproj -scheme Wythin -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:WythinTests/InsightGeneratorTests 2>&1 | tail -30`
Expected: build failure — `cannot find 'InsightGenerator' in scope` (the type doesn't exist yet).

- [ ] **Step 4: Create `InsightGenerator`**

Create `ios/Wythin/Sync/InsightGenerator.swift`:

```swift
import Foundation
import SwiftData

/// Generates OpenAI-backed insights for completed activities, and retries
/// any that failed while offline. Same shape as `SessionUploader` — an
/// actor wrapping a client, used for foreground-triggered catch-up work.
actor InsightGenerator {

    private let client: InsightAPIClient

    init(client: InsightAPIClient) {
        self.client = client
    }

    /// Generate and persist an insight for one activity. Leaves
    /// `entry.insightText` nil on any failure — picked up by the next
    /// `flushPending` call on foreground.
    func generate(for entry: ActivityLog, context: ModelContext) async {
        guard let response = try? await client.generateInsight(InsightPayload(from: entry)) else { return }
        entry.insightText = response.text
        try? context.save()
    }

    /// Retry every completed activity still missing an insight.
    func flushPending(context: ModelContext, limit: Int = 10) async {
        for entry in Self.pendingActivities(context: context, limit: limit) {
            await generate(for: entry, context: context)
        }
    }

    /// Completed activities still missing an insight, most recent first,
    /// capped to bound the retry burst after a long offline period.
    static func pendingActivities(context: ModelContext, limit: Int = 10) -> [ActivityLog] {
        var descriptor = FetchDescriptor<ActivityLog>(
            predicate: #Predicate { $0.endedAt != nil && $0.insightText == nil },
            sortBy: [SortDescriptor(\.startedAt, order: .reverse)]
        )
        descriptor.fetchLimit = limit
        return (try? context.fetch(descriptor)) ?? []
    }
}
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `xcodebuild test -project ios/Wythin.xcodeproj -scheme Wythin -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:WythinTests/InsightGeneratorTests 2>&1 | tail -30`
Expected: `** TEST SUCCEEDED **`, 5 tests passed.

- [ ] **Step 6: Commit**

```bash
git add ios/Wythin/Models/ActivityLog.swift ios/Wythin/Sync/InsightGenerator.swift ios/WythinTests/InsightGeneratorTests.swift
git commit -m "feat(activities): add InsightGenerator actor and ActivityLog.insightText"
```

---

### Task 4: iOS — Trigger generation when an activity ends

**Files:**
- Modify: `ios/Wythin/UI/Actions/ActionsView.swift`

**Interfaces:**
- Consumes: `InsightGenerator(client:)`, `.generate(for:context:)` from Task 3; `env.sync.client` (`APIClient`, already `InsightAPIClient`-conforming from Task 2).

No new automated test — this is thin fire-and-forget UI wiring around the already-tested `InsightGenerator.generate`. Verified by build + the manual check in Task 7.

- [ ] **Step 1: Wire the three call sites**

In `ios/Wythin/UI/Actions/ActionsView.swift`, change the `.edit` case (around line 307):

```swift
        case .edit(let entry):
            EditActivitySheet(entry: entry) { ctx in
                entry.computeHRVWindows(context: ctx)
                try? ctx.save()
            }
```
to:
```swift
        case .edit(let entry):
            EditActivitySheet(entry: entry) { ctx in
                entry.computeHRVWindows(context: ctx)
                try? ctx.save()
                Task { await InsightGenerator(client: env.sync.client).generate(for: entry, context: ctx) }
            }
```

Change `endActivity` (around line 366):

```swift
    private func endActivity(_ entry: ActivityLog) {
        entry.endedAt = .now
        entry.computeHRVWindows(context: ctx)
        try? ctx.save()
    }
```
to:
```swift
    private func endActivity(_ entry: ActivityLog) {
        entry.endedAt = .now
        entry.computeHRVWindows(context: ctx)
        try? ctx.save()
        Task { await InsightGenerator(client: env.sync.client).generate(for: entry, context: ctx) }
    }
```

Change `logPast` (around line 372):

```swift
        entry.notes = notes
        entry.computeHRVWindows(context: ctx)
        ctx.insert(entry)
        try? ctx.save()
    }
```
to:
```swift
        entry.notes = notes
        entry.computeHRVWindows(context: ctx)
        ctx.insert(entry)
        try? ctx.save()
        Task { await InsightGenerator(client: env.sync.client).generate(for: entry, context: ctx) }
    }
```

- [ ] **Step 2: Build to verify it compiles**

Run: `xcodebuild build -project ios/Wythin.xcodeproj -scheme Wythin -destination 'platform=iOS Simulator,name=iPhone 17' | tail -20`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add ios/Wythin/UI/Actions/ActionsView.swift
git commit -m "feat(activities): trigger insight generation when an activity ends"
```

---

### Task 5: iOS — Retry sweep on foreground

**Files:**
- Modify: `ios/Wythin/App/AppEnvironment.swift`

**Interfaces:**
- Consumes: `InsightGenerator(client:)`, `.flushPending(context:)` from Task 3.

No new automated test — the query logic it delegates to (`InsightGenerator.pendingActivities`) is already covered in Task 3; this is just the foreground hook. Verified by build + manual check in Task 7.

- [ ] **Step 1: Hook into `isInForeground`**

In `ios/Wythin/App/AppEnvironment.swift`, change:

```swift
    var isInForeground: Bool = true {
        didSet {
            if !isInForeground {
                // Flush pending writes immediately when leaving foreground
                // so data isn't lost if the OS terminates the process.
                if pendingSaveCount > 0 {
                    try? modelContainer.mainContext.save()
                    pendingSaveCount = 0
                }
            } else {
                // Returning to foreground — merge any samples saved during background
                // into tickHistory so intraday charts show the full picture.
                reloadRecentHistory()
            }
        }
    }
```
to:
```swift
    var isInForeground: Bool = true {
        didSet {
            if !isInForeground {
                // Flush pending writes immediately when leaving foreground
                // so data isn't lost if the OS terminates the process.
                if pendingSaveCount > 0 {
                    try? modelContainer.mainContext.save()
                    pendingSaveCount = 0
                }
            } else {
                // Returning to foreground — merge any samples saved during background
                // into tickHistory so intraday charts show the full picture.
                reloadRecentHistory()
                retryPendingInsights()
            }
        }
    }
```

- [ ] **Step 2: Add `retryPendingInsights`**

In the same file, add this method right after `reloadRecentHistory()` (in the "History loading" section):

```swift
    /// Retry any activities that finished without a generated insight,
    /// e.g. because the device was offline when the activity ended.
    private func retryPendingInsights() {
        let context = modelContainer.mainContext
        Task { await InsightGenerator(client: sync.client).flushPending(context: context) }
    }
```

- [ ] **Step 3: Build to verify it compiles**

Run: `xcodebuild build -project ios/Wythin.xcodeproj -scheme Wythin -destination 'platform=iOS Simulator,name=iPhone 17' | tail -20`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Commit**

```bash
git add ios/Wythin/App/AppEnvironment.swift
git commit -m "feat(activities): retry pending insight generation on app foreground"
```

---

### Task 6: iOS — Insight section in `ActivityDetailView`

**Files:**
- Modify: `ios/Wythin/UI/Actions/ActionsView.swift`

**Interfaces:**
- Consumes: `entry.insightText` (from Task 3), `Theme.monoLabel`/`Theme.monoBody`/`Theme.dim`/`Theme.text` and `.cardStyle()` (existing, `ios/Wythin/UI/Design/Theme.swift`).

- [ ] **Step 1: Add the Insight section**

In `ios/Wythin/UI/Actions/ActionsView.swift`, inside `ActivityDetailView.body`, change:

```swift
                        .cardStyle()

                        // Notes
                        VStack(alignment: .leading, spacing: 6) {
                            Text("NOTES")
```
to:
```swift
                        .cardStyle()

                        // Insight
                        if let insight = entry.insightText {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("INSIGHT")
                                    .font(Theme.monoLabel)
                                    .foregroundStyle(Theme.dim)
                                Text(insight)
                                    .font(Theme.monoBody)
                                    .foregroundStyle(Theme.text)
                            }
                            .cardStyle()
                        }

                        // Notes
                        VStack(alignment: .leading, spacing: 6) {
                            Text("NOTES")
```

- [ ] **Step 2: Build to verify it compiles**

Run: `xcodebuild build -project ios/Wythin.xcodeproj -scheme Wythin -destination 'platform=iOS Simulator,name=iPhone 17' | tail -20`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add ios/Wythin/UI/Actions/ActionsView.swift
git commit -m "feat(activities): show generated insight in ActivityDetailView"
```

---

### Task 7: Manual end-to-end verification

No code changes. Confirms the whole chain works with a real OpenAI key, since Tasks 1-6 only prove each piece in isolation with fakes.

- [ ] **Step 1: Start the backend with a real key**

```bash
cd /Users/alexutkin && OPENAI_API_KEY=<your key> DATABASE_URL=<your local postgres url> uvicorn server.main:app --host 0.0.0.0 --port 8000 --reload
```
Expected: server starts without error, `GET http://localhost:8000/health` returns `{"status":"ok"}`.

- [ ] **Step 2: Run the app in the simulator and log a past activity**

Build and run the `Wythin` scheme in a simulator (no BLE hardware needed — the simulator can't pair a Polar H10, so use the "Log Past" flow, which is `isManual` and goes through the same `computeHRVWindows` + insight-generation path as a live-tracked activity). In the Activities/Actions tab, tap **LOG PAST**, fill in an activity type and a start/end time, save.

- [ ] **Step 3: Confirm the insight appears**

Open the just-logged entry's detail view (tap the row). Within a few seconds, an **INSIGHT** card should appear above the Notes section with 2-3 sentences of OpenAI-generated text, with no loading spinner ever shown. If it doesn't appear, background the app and foreground it again — this exercises the Task 5 retry sweep.

- [ ] **Step 4: Confirm silent failure behavior**

Stop the backend (`Ctrl-C` the `uvicorn` process), log another past activity. Confirm the app doesn't show any error, crash, or block — the detail view simply has no Insight card. Restart the backend, background/foreground the app, and confirm the Insight card appears for that entry once the retry sweep runs.
