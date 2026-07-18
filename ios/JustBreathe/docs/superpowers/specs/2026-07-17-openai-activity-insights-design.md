# OpenAI-Backed Activity Insights — Design Spec
Date: 2026-07-17

## Overview

This is sub-project 4 of the Activities redesign (see `2026-07-17-activities-tab-restructure-design.md`), scoped down to just the insights/recommendations half — the progress chart is deferred to its own future spec.

When a logged activity finishes and its before/during/after HRV windows are computed, the app asks a backend endpoint to generate a short, personalized interpretation of the HRV response plus a forward-looking recommendation, using OpenAI. The text is stored on the `ActivityLog` entry and shown in `ActivityDetailView`.

Generation is per-activity only (no cross-activity trend context in this version), backend-proxied (API key never ships in the app), and fully stateless server-side (no new database tables — the backend calls OpenAI and returns text, nothing is persisted there).

---

## 1. Backend — `POST /insights`

New `server/routers/insights.py`, registered in `server/main.py` alongside `sessions`, `stream`, `admin`.

### Request / response schemas (`server/models.py`)

```python
class InsightRequest(BaseModel):
    activity_type:    str
    activity_subtype: Optional[str] = None
    duration_min:     Optional[int] = None
    before_hr:   Optional[float] = None; during_hr:   Optional[float] = None; after_hr:   Optional[float] = None
    before_rsa:  Optional[float] = None; during_rsa:  Optional[float] = None; after_rsa:  Optional[float] = None
    before_sdnn: Optional[float] = None; during_sdnn: Optional[float] = None; after_sdnn: Optional[float] = None
    before_lf_hf: Optional[float] = None; during_lf_hf: Optional[float] = None; after_lf_hf: Optional[float] = None

class InsightResponse(BaseModel):
    text: str
```

No user identifier in the request — the endpoint doesn't need to associate the insight with anyone, since nothing is stored.

### Handler behavior

- Builds a system prompt instructing the model to act as a physiologist interpreting HRV deltas around a logged activity, and to end with one concrete, forward-looking suggestion — target 2-3 sentences total.
- Sends the request metrics as the user message to OpenAI Chat Completions, model `gpt-4o-mini` (cheap, low-latency, sufficient for short structured text), `max_tokens≈150`, `temperature≈0.6`.
- Returns `{"text": "..."}` on success.
- On any OpenAI error (timeout, rate limit, malformed response), returns HTTP 502. The handler does not retry internally — retry policy lives on the iOS side (§3).
- `OPENAI_API_KEY` read via `os.getenv("OPENAI_API_KEY")`, same convention as `DATABASE_URL` in `server/db.py`. Missing key at startup should fail loudly (raise on first request, not a silent no-op) rather than returning a confusing 502 for an unrelated reason.

### Out of scope for the backend

- No caching, no rate limiting beyond what OpenAI itself enforces, no persistence of requests or responses.
- No auth beyond whatever already protects `/sessions` and `/stream` (i.e., none currently) — this endpoint carries the same trust level as the rest of the sync API.

---

## 2. iOS data model

`ActivityLog` (`ios/JustBreathe/Models/ActivityLog.swift`) gains one field:

```swift
var insightText: String?
```

`nil` means "not yet generated, eligible for retry." There is no separate failure flag — a failed attempt simply leaves this `nil`, which is indistinguishable from "not yet attempted" and is intentionally so (§3 retries treat them identically).

---

## 3. Trigger and retry flow

### Wire types (`ios/JustBreathe/Sync/APIClient.swift`)

Add `InsightPayload` (request) / `InsightResponse` (response) Codable structs mirroring the backend schema, and:

```swift
func generateInsight(_ payload: InsightPayload) async throws -> InsightResponse
```
POSTing to `/insights`, following the same `request(path:method:)` helper pattern as `uploadSession`.

### Generation trigger

At each of the three `entry.computeHRVWindows(context: ctx)` call sites in `ios/JustBreathe/UI/Actions/ActionsView.swift` (lines 309, 368, 383), immediately after the windows are computed, fire a background `Task`:

```swift
Task { await InsightGenerator.generate(for: entry, client: env.sync.client, context: ctx) }
```

`InsightGenerator.generate` builds an `InsightPayload` from the entry's before/during/after fields, calls `generateInsight`, and on success sets `entry.insightText` and saves the context. On failure, it does nothing further — no error surfaced, no state recorded beyond `insightText` remaining `nil`.

This is fire-and-forget by design: logging an activity should never be blocked or slowed by a network call, and manual/retrospective entries (`isManual == true`) get insights the same way as live-tracked ones since they also go through `computeHRVWindows`.

### Retry sweep

Hooks into the existing `isInForeground` `didSet` in `ios/JustBreathe/App/AppEnvironment.swift:46-61`, in the same branch that already calls `reloadRecentHistory()` on return-to-foreground:

```swift
var isInForeground: Bool = true {
    didSet {
        if !isInForeground {
            // existing flush logic
        } else {
            reloadRecentHistory()
            retryPendingInsights()   // NEW
        }
    }
}
```

`retryPendingInsights()` fetches `ActivityLog` where `endedAt != nil && insightText == nil`, sorted by `startedAt` descending, capped to the most recent 10 — bounding the retry burst after a long offline period rather than replaying an unbounded backlog. Each match gets the same `InsightGenerator.generate` call as the original trigger.

There is no separate scheduler, no exponential backoff, no persisted retry count. A foreground event is the only retry signal; this matches the "silent, non-blocking" requirement and keeps the mechanism simple.

---

## 4. UI — `ActivityDetailView`

New "Insight" section, rendered only when `entry.insightText != nil`:

- No loading spinner and no error state — the section simply doesn't exist until text arrives, then appears once the background task completes, since the view observes the `@Model` entry directly.
- Placed as a new section in the existing table-based detail view. This view's current before/during/after table content is explicitly unaffected — the chart-based rework is sub-project 3 and out of scope here.

---

## 5. Privacy

The request payload is numeric HRV metrics plus activity type/subtype/duration — no name, device ID, user ID, or session history. Still, this is physiological data leaving the device to a third party (OpenAI) on every completed activity. This should be called out in user-facing privacy documentation if the app has any; not addressed further in this spec beyond flagging it.

---

## 6. Error Handling Summary

| Failure point | Behavior |
|---|---|
| OpenAI API error/timeout (backend) | Backend returns 502, no retry server-side |
| Network error / 502 (iOS) | `insightText` stays `nil`, no error shown to user |
| Missing `OPENAI_API_KEY` at startup | Backend fails loudly, not a silent no-op |
| App backgrounded before insight arrives | In-flight `Task` continues on iOS's background execution grace period; if killed, picked up by the next foreground retry sweep |
| Long offline period, many pending insights | Retry sweep caps to the 10 most recent, oldest beyond that never retried automatically |

---

## 7. Testing

- Backend: unit test the handler with a mocked OpenAI client — verify request/response shape, verify 502 on OpenAI failure, verify missing-API-key startup failure.
- iOS: unit test `InsightGenerator.generate` success path (sets `insightText`, saves context) and failure path (leaves `insightText` nil, no crash) with a mocked `APIClient`.
- iOS: unit test `retryPendingInsights()` query — correct filter (`endedAt != nil && insightText == nil`), correct cap (10), correct ordering (most recent first).
- Manual: log an activity end-to-end with a real backend + OpenAI key, confirm the Insight section appears in `ActivityDetailView` without a visible loading state.

---

## 8. Files Changed / Created

| Action | File |
|---|---|
| Create | `server/routers/insights.py` |
| Modify | `server/models.py` — add `InsightRequest`, `InsightResponse` |
| Modify | `server/main.py` — register `insights` router |
| Modify | `server/db.py`-adjacent config — `OPENAI_API_KEY` env var read (in `insights.py`, following `db.py`'s `os.getenv` convention) |
| Modify | `ios/JustBreathe/Models/ActivityLog.swift` — add `insightText: String?` |
| Modify | `ios/JustBreathe/Sync/APIClient.swift` — add `InsightPayload`, `InsightResponse`, `generateInsight` |
| Create | `ios/JustBreathe/Sync/InsightGenerator.swift` (or similar) — `generate(for:client:context:)` |
| Modify | `ios/JustBreathe/UI/Actions/ActionsView.swift` — fire generation `Task` at 3 `computeHRVWindows` call sites; add new Insight section to the `ActivityDetailView` struct defined in this same file |
| Modify | `ios/JustBreathe/App/AppEnvironment.swift` — `retryPendingInsights()` call in `isInForeground.didSet` |

---

## 9. Out of Scope

- Progress chart / cross-activity trend visualization (separate future sub-project).
- Trend-aware recommendations using recent same-type activity history (deferred; v1 is single-activity context only).
- Live in-session coaching using the real-time tick stream (separate, larger scope — not this spec).
- Caching, rate limiting, or persistence of insights on the backend.
- Changes to `PolyvagalState`'s existing rule-based causes/facts/actions — that system is unrelated to `ActivityLog` insights and untouched here.
- Any UI beyond the new Insight section in `ActivityDetailView` (no settings toggle, no manual "regenerate" button in v1).
