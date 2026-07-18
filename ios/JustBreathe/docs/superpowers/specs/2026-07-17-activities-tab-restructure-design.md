# Activities Tab Restructure — Design Spec
Date: 2026-07-17

## Overview

Rename the "Actions" tab to "Activities" and restructure its layout. This is sub-project 1 of 4 in a larger Activities redesign:

1. **This spec** — rename + layout restructure (remove Log/Impact toggle, move BLE indicator, all-time list)
2. Extended activity card with 9 key metrics (future spec)
3. Per-activity before/during/after chart detail view (future spec)
4. OpenAI-backed insights/recommendations section + progress chart (future spec)

The Train-side destination for "Suggested Now" taps is explicitly deferred — Train section content is a separate future conversation. This spec only wires the tab switch as a stub.

---

## 1. Renames

Full rename through the codebase (folder, types, tab enum, labels):

| Old | New |
|---|---|
| `UI/Actions/ActionsView.swift` | `UI/Activities/ActivitiesView.swift` |
| `ActionsView` (struct) | `ActivitiesView` |
| `ActionSheet` (enum) + its cases | `ActivitySheet` |
| `AppTab.actions` | `AppTab.activities` |
| Tab bar label `"Actions"` | `"Activities"` |
| Nav title `"ACTIONS"` | `"ACTIVITIES"` |

`ActionsSection` and `ImpactSort` enums are deleted (see §3 — the Impact section is retired, not renamed).

`ActivityDetailView` (already correctly named) is untouched by the rename; it keeps its current before/during/after table content in this sub-project — the chart-based detail view is sub-project 3.

---

## 2. Layout

Single scrolling `List`, no top-level section picker (the `LOG`/`IMPACT` capsule toggle is removed entirely):

```
NavigationStack
  [Active activity banner]       — existing ActiveActivityBanner, shown when isActive
  SUGGESTED NOW card              — existing suggestion chips + START / LOG PAST buttons
  [Day-grouped activity list]     — NEW: all-time, replaces "TODAY"-only section
```

Toolbar: BLE nav button moves from `.topBarLeading` to `.topBarTrailing`. No leading toolbar item remains.

### Suggested Now chip behavior (stub)

Tapping a `SuggestionChip` no longer opens `.startWith(type)` directly. Instead:

```swift
env.pendingTabRequest = .train
selectedTab = .train   // via existing tab-selection mechanism, see §4
```

No new Train content is built in this sub-project — Train renders whatever it renders today. This is intentionally a stub pending a future conversation about Train's content.

START and LOG PAST buttons are unchanged — they continue to open `StartActivitySheet` / `LogPastSheet` exactly as today, independent of the Train hand-off.

### Day-grouped activity list

Replaces the current `todayEntries`-only "TODAY" `Section`. Groups `allEntries` (excluding the active entry, which stays in the banner) by calendar day:

- Header label: `"TODAY"`, `"YESTERDAY"`, or the date (e.g. `"JUL 15"`) for older days
- Each row uses the existing `ActivityLogRow` view, unchanged (tap → `.detail(entry)`, swipe actions for edit/delete unchanged)
- Sub-project 2 replaces `ActivityLogRow` with the new 9-metric extended card — out of scope here

---

## 3. Removed: Impact section

Deleted entirely, not preserved elsewhere:

- `impactSection` (computed view)
- `ImpactSort` enum
- `ActivityImpactCard`, `MiniDeltaRow` views
- `rankedActivities()`, `ActivityTypeSummary`
- `impactSort` state

---

## 4. Cross-tab hand-off mechanism

`AppEnvironment` (already `@Observable`, already shared across all tabs via `.environment(env)`) gains:

```swift
var pendingTabRequest: AppTab? = nil
```

`ContentView` (in `JustBreatheApp.swift`) observes it:

```swift
.onChange(of: env.pendingTabRequest) { _, newValue in
    guard let tab = newValue else { return }
    selectedTab = tab
    env.pendingTabRequest = nil
}
```

This keeps `selectedTab` owned by `ContentView` (no behavior change for the tab bar itself) while letting any tab request a switch through the environment, consistent with how `env` is already used for cross-view state (`latestTick`, `ble`, `isInForeground`).

---

## 5. Files Changed / Created

| Action | File |
|---|---|
| Rename | `UI/Actions/ActionsView.swift` → `UI/Activities/ActivitiesView.swift` |
| Modify | (renamed file) — struct/type renames, remove Impact section, remove section picker, day-grouped list, toolbar move, Suggested Now stub hand-off |
| Modify | `App/JustBreatheApp.swift` — `AppTab.actions` → `.activities`, tab label, `ActionsView()` → `ActivitiesView()`, `.onChange(of: env.pendingTabRequest)` |
| Modify | `App/AppEnvironment.swift` — add `pendingTabRequest: AppTab?` |

---

## 6. Out of Scope

- 9-metric extended activity cards (sub-project 2)
- Before/during/after chart detail view (sub-project 3)
- OpenAI insights/recommendations section, progress chart (sub-project 4)
- Any new Train-side content for the Suggested Now destination (separate future conversation)
- Changes to `StartActivitySheet`, `LogPastSheet`, `EditActivitySheet`, `ActivityDetailView` internals
