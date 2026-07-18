# Activities Tab Restructure Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rename the "Actions" tab to "Activities", remove the Log/Impact section picker and the Impact section entirely, move the BLE indicator to the trailing toolbar position, show an all-time day-grouped activity list, and stub the "Suggested Now" tap to switch to the Train tab.

**Architecture:** Single-file SwiftUI view restructure (`ActionsView.swift` → `ActivitiesView.swift`), plus a small `@Observable` cross-tab signaling property on the existing `AppEnvironment` so a leaf view (Activities) can request a tab switch owned by the root `ContentView`, without introducing a new state-management layer.

**Tech Stack:** Swift 5 / SwiftUI, SwiftData (`@Query`, `@Model`), Xcode project with explicit `PBXFileReference`/`PBXGroup` entries (no synchronized folder groups — file moves must be reflected in `project.pbxproj` by hand).

## Global Constraints

- No unit-test target covers SwiftUI view files in this codebase today (`JustBreatheTests` only covers BLE parsing and metrics compute logic) — verification for every task in this plan is **build success** (`xcodebuild build`) plus, where noted, a manual Simulator check. Do not invent a SwiftUI view-testing harness that doesn't exist in this project.
- Build verification command (use for every task):
  ```bash
  cd /Users/alexutkin/ios && xcodebuild build -project JustBreathe.xcodeproj -scheme JustBreathe -destination 'platform=iOS Simulator,name=iPhone 17 Pro' 2>&1 | tail -40
  ```
  Expected final line: `** BUILD SUCCEEDED **`
- Commit after every task with a message describing that task only — do not batch multiple tasks into one commit.
- The spec is `docs/superpowers/specs/2026-07-17-activities-tab-restructure-design.md` — re-read it if anything here seems ambiguous.
- Do not touch `StartActivitySheet`, `LogPastSheet`, `EditActivitySheet`, or `ActivityDetailView` internals — out of scope.
- Do not build any new Train-side content — the Train tab renders exactly what it renders today; only the tab switch itself is wired.

---

### Task 1: Add cross-tab hand-off property to AppEnvironment

**Files:**
- Modify: `App/AppEnvironment.swift:38-39`
- Modify: `App/JustBreatheApp.swift:67-86`

**Interfaces:**
- Produces: `AppEnvironment.pendingTabRequest: AppTab?` — any view with access to `env` can set this to request a tab switch. `ContentView` clears it back to `nil` after acting on it.

- [ ] **Step 1: Add the property to AppEnvironment**

In `App/AppEnvironment.swift`, the session-state block currently reads:

```swift
    // MARK: Session state (updated at ~2 s)

    var currentSession:  HRVSession?
    var latestTick:      MetricsTick?
```

Change to:

```swift
    // MARK: Session state (updated at ~2 s)

    var currentSession:  HRVSession?
    var latestTick:      MetricsTick?

    // MARK: Cross-tab navigation

    /// Set by any tab to request ContentView switch the selected tab.
    /// ContentView observes this and resets it to nil after acting on it.
    var pendingTabRequest: AppTab? = nil
```

- [ ] **Step 2: Observe it in ContentView**

In `App/JustBreatheApp.swift`, `ContentView.body` currently ends with:

```swift
        .tint(Theme.accent)
        .toolbar(.hidden, for: .tabBar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            AppTabBar(selected: $selectedTab)
        }
    }
}
```

Change to:

```swift
        .tint(Theme.accent)
        .toolbar(.hidden, for: .tabBar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            AppTabBar(selected: $selectedTab)
        }
        .onChange(of: env.pendingTabRequest) { _, newValue in
            guard let tab = newValue else { return }
            selectedTab = tab
            env.pendingTabRequest = nil
        }
    }
}
```

- [ ] **Step 3: Build to verify**

```bash
cd /Users/alexutkin/ios && xcodebuild build -project JustBreathe.xcodeproj -scheme JustBreathe -destination 'platform=iOS Simulator,name=iPhone 17 Pro' 2>&1 | tail -40
```
Expected: `** BUILD SUCCEEDED **` (the new property is unused by any UI yet — that's expected, it's wired up in Task 6)

- [ ] **Step 4: Commit**

```bash
cd /Users/alexutkin/ios && git add JustBreathe/App/AppEnvironment.swift JustBreathe/App/JustBreatheApp.swift
git commit -m "feat(app): add pendingTabRequest for cross-tab navigation"
```

---

### Task 2: Physically rename Actions → Activities (folder, file, Xcode project)

**Files:**
- Rename: `UI/Actions/ActionsView.swift` → `UI/Activities/ActivitiesView.swift`
- Modify: `JustBreathe.xcodeproj/project.pbxproj`

**Interfaces:**
- No Swift-level interface changes in this task — struct name stays `ActionsView` for now (renamed in Task 4). This task is a pure file/project-reference move so it can be verified independently of any code changes.

- [ ] **Step 1: Move the file with git**

```bash
cd /Users/alexutkin/ios/JustBreathe/UI
git mv Actions Activities
git mv Activities/ActionsView.swift Activities/ActivitiesView.swift
```

- [ ] **Step 2: Update the Xcode project file**

In `JustBreathe.xcodeproj/project.pbxproj`, there are 4 places referencing the old path/name. Make these exact replacements:

Replacement 1 (PBXBuildFile entry):
```
			A137 /* ActionsView.swift in Sources */ = {isa = PBXBuildFile; fileRef = F137 /* ActionsView.swift */; };
```
→
```
			A137 /* ActivitiesView.swift in Sources */ = {isa = PBXBuildFile; fileRef = F137 /* ActivitiesView.swift */; };
```

Replacement 2 (PBXFileReference entry):
```
			F137 /* ActionsView.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = ActionsView.swift; sourceTree = "<group>"; };
```
→
```
			F137 /* ActivitiesView.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = ActivitiesView.swift; sourceTree = "<group>"; };
```

Replacement 3 (PBXGroup definition — group name and `path`):
```
		GAPP_ACT /* Actions */ = {
			isa = PBXGroup;
			children = (
				F137 /* ActionsView.swift */,
			);
			path = Actions;
			sourceTree = "<group>";
		};
```
→
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

Replacement 4 (reference to the group from the parent `UI` group):
```
				GAPP_ACT /* Actions */,
```
→
```
				GAPP_ACT /* Activities */,
```

Replacement 5 (Sources build phase entry):
```
				A137 /* ActionsView.swift in Sources */,
```
→
```
				A137 /* ActivitiesView.swift in Sources */,
```

- [ ] **Step 3: Build to verify**

```bash
cd /Users/alexutkin/ios && xcodebuild build -project JustBreathe.xcodeproj -scheme JustBreathe -destination 'platform=iOS Simulator,name=iPhone 17 Pro' 2>&1 | tail -40
```
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Commit**

```bash
cd /Users/alexutkin/ios && git add -A JustBreathe/UI/Activities JustBreathe/UI/Actions JustBreathe.xcodeproj/project.pbxproj
git commit -m "refactor(activities): move ActionsView.swift to UI/Activities/ActivitiesView.swift"
```

---

### Task 3: Remove the Log/Impact section picker and the entire Impact section

**Files:**
- Modify: `UI/Activities/ActivitiesView.swift`

**Interfaces:**
- Consumes: nothing new.
- Produces: the view body now renders `logSection` unconditionally (no section switch). `ActionsSection`, `ImpactSort`, `ActivityTypeSummary`, `rankedActivities()`, `ActivityImpactCard`, `MiniDeltaRow`, `impactSection`, and the `section`/`impactSort` `@State` are all deleted — later tasks must not reference them.

- [ ] **Step 1: Delete the `ActionsSection` and `ImpactSort` enums**

Remove this block near the top of the file (right after the imports):

```swift
// MARK: - Actions Section

private enum ActionsSection: String, CaseIterable {
    case log    = "LOG"
    case impact = "IMPACT"
}

// MARK: - Impact Sort

private enum ImpactSort: String, CaseIterable {
    case rsa  = "RSA"
    case vti  = "VTI"
    case sdnn = "SDNN"

    var unit: String {
        switch self {
        case .rsa, .sdnn: return "ms"
        case .vti:        return ""
        }
    }
}

```

(leave the `// MARK: - ActionSheet` comment and everything below it in place)

- [ ] **Step 2: Remove the `section` state and simplify `body`**

Find:

```swift
    @State private var section:      ActionsSection = .log
    @State private var activeSheet:  ActionSheet?   = nil
```

Replace with:

```swift
    @State private var activeSheet:  ActionSheet?   = nil
```

Find the `body` property:

```swift
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // ── Section picker ────────────────────────────────
                HStack(spacing: 0) {
                    ForEach(ActionsSection.allCases, id: \.self) { s in
                        Button(s.rawValue) {
                            withAnimation(.easeInOut(duration: 0.2)) { section = s }
                        }
                        .font(Theme.monoLabel)
                        .foregroundStyle(section == s ? Theme.bg : Theme.accent)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity)
                        .background(section == s ? Theme.accent : Color.clear)
                    }
                }
                .background(Theme.card)
                .clipShape(Capsule())
                .overlay(Capsule().strokeBorder(Theme.border, lineWidth: 0.5))
                .padding(.horizontal, 16)
                .padding(.top, 10)
                .padding(.bottom, 6)

                if section == .log {
                    logSection
                } else {
                    impactSection
                }
            }
            .background(Theme.bg)
            .navigationTitle("ACTIONS")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.bg, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    BLENavButton(state: env.ble.state,
                                 bpm: env.latestTick?.meanBPM) {
                        activeSheet = .ble
                    }
                }
            }
            .sheet(item: $activeSheet) { sheet in
                sheetContent(sheet)
            }
        }
    }
```

Replace with:

```swift
    var body: some View {
        NavigationStack {
            logSection
                .navigationTitle("ACTIONS")
                .navigationBarTitleDisplayMode(.inline)
                .toolbarBackground(Theme.bg, for: .navigationBar)
                .toolbarColorScheme(.dark, for: .navigationBar)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        BLENavButton(state: env.ble.state,
                                     bpm: env.latestTick?.meanBPM) {
                            activeSheet = .ble
                        }
                    }
                }
                .sheet(item: $activeSheet) { sheet in
                    sheetContent(sheet)
                }
        }
    }
```

(The BLE button stays `.topBarLeading` here — moving it to trailing happens in Task 5, together with the other layout changes, to keep this task focused on removing Impact.)

- [ ] **Step 3: Delete the `impactSection` computed property and its `impactSort` state**

Remove this entire block:

```swift
    // MARK: - Impact Section

    @State private var impactSort: ImpactSort = .rsa

    private var impactSection: some View {
        ScrollView {
            VStack(spacing: 14) {

                // Sort picker
                VStack(alignment: .leading, spacing: 6) {
                    Text("RANKED BY")
                        .font(Theme.monoLabel)
                        .foregroundStyle(Theme.dim)

                    HStack(spacing: 8) {
                        ForEach(ImpactSort.allCases, id: \.self) { s in
                            Button(s.rawValue) { impactSort = s }
                                .font(Theme.monoLabel)
                                .foregroundStyle(impactSort == s ? Theme.bg : Theme.accent)
                                .padding(.vertical, 6)
                                .padding(.horizontal, 12)
                                .background(impactSort == s ? Theme.accent : Theme.card)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .cardStyle()

                let ranked = rankedActivities()
                if ranked.isEmpty {
                    Text("Log activities to see their HRV impact.")
                        .font(Theme.monoBody)
                        .foregroundStyle(Theme.dim)
                        .multilineTextAlignment(.center)
                        .padding(.vertical, 40)
                } else {
                    ForEach(ranked, id: \.type) { summary in
                        ActivityImpactCard(summary: summary, sortBy: impactSort)
                    }
                }
            }
            .padding(.horizontal)
            .padding(.top, 8)
            .padding(.bottom, 20)
        }
        .background(Theme.bg)
    }

```

(leave the `// MARK: - Sheet content` comment and everything below it in place)

- [ ] **Step 4: Delete `ActivityTypeSummary` and `rankedActivities()`**

Remove this entire block (the closing `}` of the `ActionsView` struct must remain — only delete the marked content):

```swift
    // MARK: - Impact aggregation

    struct ActivityTypeSummary {
        let type:  String
        let icon:  String
        let color: Color
        let count: Int
        // during - before: what changed while the activity was happening
        let duringRSADelta:  Float?
        let duringVTIDelta:  Float?
        let duringSDNNDelta: Float?
        // after - before: net recovery / adaptation effect
        let afterRSADelta:   Float?
        let afterVTIDelta:   Float?
        let afterSDNNDelta:  Float?
    }

    private func rankedActivities() -> [ActivityTypeSummary] {
        let completed = allEntries.filter { $0.endedAt != nil }
        var grouped: [String: [ActivityLog]] = [:]
        for e in completed { grouped[e.activityType, default: []].append(e) }

        var summaries = grouped.compactMap { (type, entries) -> ActivityTypeSummary? in
            guard !entries.isEmpty else { return nil }

            func avgDelta(_ a: KeyPath<ActivityLog, Float?>, _ b: KeyPath<ActivityLog, Float?>) -> Float? {
                let vals = entries.compactMap { e -> Float? in
                    guard let av = e[keyPath: a], let bv = e[keyPath: b] else { return nil }
                    return av - bv
                }
                guard !vals.isEmpty else { return nil }
                return vals.reduce(0, +) / Float(vals.count)
            }

            let typeEnum = ActivityType(rawValue: type) ?? .custom
            return ActivityTypeSummary(
                type:  type,
                icon:  typeEnum.icon,
                color: typeEnum.color,
                count: entries.count,
                // during - before
                duringRSADelta:  avgDelta(\.duringRSA,  \.beforeRSA),
                duringVTIDelta:  avgDelta(\.duringVTI,  \.beforeVTI),
                duringSDNNDelta: avgDelta(\.duringSDNN, \.beforeSDNN),
                // after - before
                afterRSADelta:   avgDelta(\.afterRSA,   \.beforeRSA),
                afterVTIDelta:   avgDelta(\.afterVTI,   \.beforeVTI),
                afterSDNNDelta:  avgDelta(\.afterSDNN,  \.beforeSDNN)
            )
        }

        // Sort by during-delta of selected metric (descending)
        summaries.sort {
            let a: Float?
            let b: Float?
            switch impactSort {
            case .rsa:  a = $0.duringRSADelta;  b = $1.duringRSADelta
            case .vti:  a = $0.duringVTIDelta;  b = $1.duringVTIDelta
            case .sdnn: a = $0.duringSDNNDelta; b = $1.duringSDNNDelta
            }
            return (a ?? -.infinity) > (b ?? -.infinity)
        }
        return summaries
    }
}
```

Replace with just the closing brace of the struct:

```swift
}
```

- [ ] **Step 5: Delete the `ActivityImpactCard` and `MiniDeltaRow` view structs**

Remove this entire block (bounded by its own `// MARK:` comments):

```swift
// MARK: - ActivityImpactCard

private struct ActivityImpactCard: View {
    let summary: ActionsView.ActivityTypeSummary
    let sortBy:  ImpactSort

    private var duringDelta: Float? {
        switch sortBy {
        case .rsa:  return summary.duringRSADelta
        case .vti:  return summary.duringVTIDelta
        case .sdnn: return summary.duringSDNNDelta
        }
    }

    private var afterDelta: Float? {
        switch sortBy {
        case .rsa:  return summary.afterRSADelta
        case .vti:  return summary.afterVTIDelta
        case .sdnn: return summary.afterSDNNDelta
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header
            HStack {
                HStack(spacing: 8) {
                    ZStack {
                        Circle()
                            .fill(summary.color.opacity(0.15))
                            .frame(width: 30, height: 30)
                        Image(systemName: summary.icon)
                            .font(.system(size: 13))
                            .foregroundStyle(summary.color)
                    }
                    Text(summary.type)
                        .font(Theme.mono(13))
                        .foregroundStyle(Theme.text)
                }
                Spacer()
                Text("\(summary.count) log\(summary.count == 1 ? "" : "s")")
                    .font(Theme.monoLabel)
                    .foregroundStyle(Theme.dim)
            }

            // Primary: during delta (big)
            if let d = duringDelta {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    let sign = d >= 0 ? "+" : ""
                    Text("\(sign)\(String(format: "%.1f", d))")
                        .font(Theme.mono(28))
                        .foregroundStyle(d >= 0 ? Theme.accent : Theme.warn)
                    if !sortBy.unit.isEmpty {
                        Text(sortBy.unit)
                            .font(Theme.monoLabel)
                            .foregroundStyle(Theme.dim)
                    }
                    Text("\(sortBy.rawValue) during")
                        .font(Theme.monoLabel)
                        .foregroundStyle(Theme.dim)
                        .padding(.leading, 4)
                }
            } else {
                Text("Not enough data")
                    .font(Theme.monoLabel)
                    .foregroundStyle(Theme.dim)
            }

            // Supplemental: during vs after for all three metrics
            VStack(spacing: 0) {
                HStack {
                    Text("")
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text("DURING")
                        .frame(width: 70, alignment: .center)
                    Text("AFTER")
                        .frame(width: 70, alignment: .center)
                }
                .font(Theme.monoLabel)
                .foregroundStyle(Theme.dim.opacity(0.6))
                .padding(.bottom, 4)

                MiniDeltaRow(label: "RSA",  unit: "ms",
                             during: summary.duringRSADelta,  after: summary.afterRSADelta)
                MiniDeltaRow(label: "VTI",  unit: "",
                             during: summary.duringVTIDelta,  after: summary.afterVTIDelta)
                MiniDeltaRow(label: "SDNN", unit: "ms",
                             during: summary.duringSDNNDelta, after: summary.afterSDNNDelta)
            }
        }
        .cardStyle()
    }
}

private struct MiniDeltaRow: View {
    let label:  String
    let unit:   String
    let during: Float?
    let after:  Float?

    var body: some View {
        HStack {
            Text(label)
                .font(Theme.monoLabel)
                .foregroundStyle(Theme.dim)
                .frame(maxWidth: .infinity, alignment: .leading)
            deltaText(during)
                .frame(width: 70, alignment: .center)
            deltaText(after)
                .frame(width: 70, alignment: .center)
        }
        .padding(.vertical, 3)
    }

    @ViewBuilder
    private func deltaText(_ v: Float?) -> some View {
        if let v {
            let sign = v >= 0 ? "+" : ""
            Text("\(sign)\(String(format: "%.1f", v))\(unit.isEmpty ? "" : " \(unit)")")
                .font(Theme.monoLabel)
                .foregroundStyle(v >= 0 ? Theme.accent : Theme.warn)
        } else {
            Text("—")
                .font(Theme.monoLabel)
                .foregroundStyle(Theme.dim)
        }
    }
}

```

(leave the `// MARK: - ActivityDetailView` comment and everything below it in place — `DeltaChip`, just above this block, is pre-existing dead code unrelated to Impact and is out of scope; leave it as-is)

- [ ] **Step 6: Build to verify**

```bash
cd /Users/alexutkin/ios && xcodebuild build -project JustBreathe.xcodeproj -scheme JustBreathe -destination 'platform=iOS Simulator,name=iPhone 17 Pro' 2>&1 | tail -40
```
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 7: Commit**

```bash
cd /Users/alexutkin/ios && git add JustBreathe/UI/Activities/ActivitiesView.swift
git commit -m "refactor(activities): remove Log/Impact section picker and Impact section"
```

---

### Task 4: Rename internal identifiers (ActionsView → ActivitiesView, ActionSheet → ActivitySheet) and update the tab title

**Files:**
- Modify: `UI/Activities/ActivitiesView.swift`
- Modify: `App/JustBreatheApp.swift`

**Interfaces:**
- Produces: `struct ActivitiesView: View` (was `ActionsView`), `private enum ActivitySheet` (was `ActionSheet`), `AppTab.activities` (was `AppTab.actions`).
- Consumes: nothing from prior tasks except the file already living at `UI/Activities/ActivitiesView.swift` (Task 2) with the Impact section already removed (Task 3).

- [ ] **Step 1: Rename `ActionSheet` → `ActivitySheet` in ActivitiesView.swift**

Find:
```swift
// MARK: - ActionSheet

// Single sheet enum — prevents SwiftUI multiple-sheet chaining bug.
// Optional associated values cause type-inference issues in @ViewBuilder;
// use two explicit cases instead.
private enum ActionSheet: Identifiable {
```
Replace with:
```swift
// MARK: - ActivitySheet

// Single sheet enum — prevents SwiftUI multiple-sheet chaining bug.
// Optional associated values cause type-inference issues in @ViewBuilder;
// use two explicit cases instead.
private enum ActivitySheet: Identifiable {
```

Find:
```swift
// MARK: - ActionsView

struct ActionsView: View {
```
Replace with:
```swift
// MARK: - ActivitiesView

struct ActivitiesView: View {
```

Find:
```swift
    @State private var activeSheet:  ActionSheet?   = nil
```
Replace with:
```swift
    @State private var activeSheet:  ActivitySheet?   = nil
```

Find:
```swift
    private func sheetContent(_ sheet: ActionSheet) -> some View {
```
Replace with:
```swift
    private func sheetContent(_ sheet: ActivitySheet) -> some View {
```

Find:
```swift
                .navigationTitle("ACTIONS")
```
Replace with:
```swift
                .navigationTitle("ACTIVITIES")
```

- [ ] **Step 2: Update JustBreatheApp.swift**

Find:
```swift
enum AppTab: Hashable { case train, actions, live, track, settings }
```
Replace with:
```swift
enum AppTab: Hashable { case train, activities, live, track, settings }
```

Find:
```swift
            TrainView()
                .tag(AppTab.train)
            ActionsView()
                .tag(AppTab.actions)
            LiveView()
                .tag(AppTab.live)
```
Replace with:
```swift
            TrainView()
                .tag(AppTab.train)
            ActivitiesView()
                .tag(AppTab.activities)
            LiveView()
                .tag(AppTab.live)
```

Find:
```swift
            TabBarButton(tab: .train,   icon: "figure.run",                label: "Train",   selected: $selected)
            TabBarButton(tab: .actions, icon: "list.bullet.clipboard",     label: "Actions", selected: $selected)
```
Replace with:
```swift
            TabBarButton(tab: .train,      icon: "figure.run",                label: "Train",      selected: $selected)
            TabBarButton(tab: .activities, icon: "list.bullet.clipboard",     label: "Activities", selected: $selected)
```

- [ ] **Step 3: Build to verify**

```bash
cd /Users/alexutkin/ios && xcodebuild build -project JustBreathe.xcodeproj -scheme JustBreathe -destination 'platform=iOS Simulator,name=iPhone 17 Pro' 2>&1 | tail -40
```
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Manual check in Simulator**

```bash
cd /Users/alexutkin/ios && xcrun simctl boot "iPhone 17 Pro" 2>/dev/null; open -a Simulator
xcodebuild -project JustBreathe.xcodeproj -scheme JustBreathe -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -derivedDataPath /tmp/jb-build build 2>&1 | tail -5
xcrun simctl install "iPhone 17 Pro" /tmp/jb-build/Build/Products/Debug-iphonesimulator/JustBreathe.app
BUNDLE_ID=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" /tmp/jb-build/Build/Products/Debug-iphonesimulator/JustBreathe.app/Info.plist)
xcrun simctl launch "iPhone 17 Pro" "$BUNDLE_ID"
```
Confirm: the tab bar's second item reads "Activities" (not "Actions"), and tapping it shows nav title "ACTIVITIES".

- [ ] **Step 5: Commit**

```bash
cd /Users/alexutkin/ios && git add JustBreathe/UI/Activities/ActivitiesView.swift JustBreathe/App/JustBreatheApp.swift
git commit -m "refactor(activities): rename ActionsView to ActivitiesView, ActionSheet to ActivitySheet"
```

---

### Task 5: Move BLE button to top-right, show all-time day-grouped activity list

**Files:**
- Modify: `UI/Activities/ActivitiesView.swift`

**Interfaces:**
- Produces: `ActivitiesView.dayGroups: [DayGroup]` (private computed property), `private struct DayGroup: Identifiable`. Replaces `todayEntries`.
- Consumes: `ActivityLog.startedAt`, `ActivityLog.isActive` (existing model fields, unchanged).

- [ ] **Step 1: Move the BLE nav button to trailing**

Find:
```swift
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        BLENavButton(state: env.ble.state,
                                     bpm: env.latestTick?.meanBPM) {
                            activeSheet = .ble
                        }
                    }
                }
```
Replace with:
```swift
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        BLENavButton(state: env.ble.state,
                                     bpm: env.latestTick?.meanBPM) {
                            activeSheet = .ble
                        }
                    }
                }
```

- [ ] **Step 2: Replace `todayEntries` with `dayGroups`**

Find:
```swift
    private var todayEntries: [ActivityLog] {
        allEntries.filter { Calendar.current.isDateInToday($0.startedAt) && !$0.isActive }
    }
```
Replace with:
```swift
    private struct DayGroup: Identifiable {
        let id:      Date
        let label:   String
        let entries: [ActivityLog]
    }

    private var dayGroups: [DayGroup] {
        let cal = Calendar.current
        let history = allEntries.filter { !$0.isActive }
        let grouped = Dictionary(grouping: history) { cal.startOfDay(for: $0.startedAt) }

        return grouped.keys.sorted(by: >).map { day in
            let label: String
            if cal.isDateInToday(day) {
                label = "TODAY"
            } else if cal.isDateInYesterday(day) {
                label = "YESTERDAY"
            } else {
                let fmt = DateFormatter()
                fmt.dateFormat = "MMM d"
                label = fmt.string(from: day).uppercased()
            }
            let entries = (grouped[day] ?? []).sorted { $0.startedAt > $1.startedAt }
            return DayGroup(id: day, label: label, entries: entries)
        }
    }
```

- [ ] **Step 3: Replace the "Today's log" section with the day-grouped list**

Find:
```swift
            // ── Today's log ───────────────────────────────────────
            if !todayEntries.isEmpty {
                Section {
                    ForEach(todayEntries) { entry in
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
                    Text("TODAY")
                        .font(Theme.monoLabel)
                        .foregroundStyle(Theme.dim)
                        .textCase(nil)
                }
                .listSectionSeparator(.hidden)
            }
```
Replace with:
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
                    Text(group.label)
                        .font(Theme.monoLabel)
                        .foregroundStyle(Theme.dim)
                        .textCase(nil)
                }
                .listSectionSeparator(.hidden)
            }
```

- [ ] **Step 4: Build to verify**

```bash
cd /Users/alexutkin/ios && xcodebuild build -project JustBreathe.xcodeproj -scheme JustBreathe -destination 'platform=iOS Simulator,name=iPhone 17 Pro' 2>&1 | tail -40
```
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 5: Manual check in Simulator**

Reinstall and relaunch as in Task 4 Step 4. Confirm: the BLE indicator is now top-right of the Activities nav bar, and the list below Suggested Now shows entries from multiple days (if test data spans days) grouped under "TODAY" / "YESTERDAY" / date headers, instead of only today's entries.

- [ ] **Step 6: Commit**

```bash
cd /Users/alexutkin/ios && git add JustBreathe/UI/Activities/ActivitiesView.swift
git commit -m "feat(activities): move BLE indicator to top-right, show all-time day-grouped history"
```

---

### Task 6: Wire Suggested Now to switch to the Train tab (stub), remove unused `.startWith` case

**Files:**
- Modify: `UI/Activities/ActivitiesView.swift`

**Interfaces:**
- Consumes: `AppEnvironment.pendingTabRequest` (from Task 1).
- Produces: nothing new — `.startWith` case removed since no code path constructs it anymore.

- [ ] **Step 1: Change the Suggested Now chip action**

Find:
```swift
                        HStack(spacing: 10) {
                            ForEach(suggested, id: \.self) { type in
                                SuggestionChip(type: type) {
                                    activeSheet = .startWith(type)
                                }
                            }
                        }
```
Replace with:
```swift
                        HStack(spacing: 10) {
                            ForEach(suggested, id: \.self) { type in
                                SuggestionChip(type: type) {
                                    env.pendingTabRequest = .train
                                }
                            }
                        }
```

- [ ] **Step 2: Remove the now-unused `.startWith` case from `ActivitySheet`**

Find:
```swift
private enum ActivitySheet: Identifiable {
    case ble
    case start
    case startWith(ActivityType)
    case logPast
    case detail(ActivityLog)
    case edit(ActivityLog)

    var id: String {
        switch self {
        case .ble:              return "ble"
        case .start:            return "start"
        case .startWith(let t): return "startWith-\(t.rawValue)"
        case .logPast:          return "logPast"
        case .detail(let e):    return "detail-\(e.id)"
        case .edit(let e):      return "edit-\(e.id)"
        }
    }
}
```
Replace with:
```swift
private enum ActivitySheet: Identifiable {
    case ble
    case start
    case logPast
    case detail(ActivityLog)
    case edit(ActivityLog)

    var id: String {
        switch self {
        case .ble:           return "ble"
        case .start:         return "start"
        case .logPast:       return "logPast"
        case .detail(let e): return "detail-\(e.id)"
        case .edit(let e):   return "edit-\(e.id)"
        }
    }
}
```

- [ ] **Step 3: Remove the now-unreachable `.startWith` case from `sheetContent`**

Find:
```swift
        case .startWith(let type):
            StartActivitySheet(preselected: type) { type, subtype, name in
                beginActivity(type: type, subtype: subtype, customName: name)
            }
```
Delete this block entirely (it sits between the `.start` case and the `.logPast` case in the `switch sheet` inside `sheetContent`).

- [ ] **Step 4: Build to verify**

```bash
cd /Users/alexutkin/ios && xcodebuild build -project JustBreathe.xcodeproj -scheme JustBreathe -destination 'platform=iOS Simulator,name=iPhone 17 Pro' 2>&1 | tail -40
```
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 5: Manual check in Simulator**

Reinstall and relaunch as before. On the Activities tab, tap a Suggested Now chip. Confirm: the app switches to the Train tab (not the Start-activity sheet). Confirm START and LOG PAST buttons still open their sheets as before.

- [ ] **Step 6: Commit**

```bash
cd /Users/alexutkin/ios && git add JustBreathe/UI/Activities/ActivitiesView.swift
git commit -m "feat(activities): switch Suggested Now taps to open Train tab, drop unused startWith sheet case"
```

---

### Task 7: Final end-to-end manual QA pass

**Files:** none (verification only)

- [ ] **Step 1: Full clean build**

```bash
cd /Users/alexutkin/ios && xcodebuild clean build -project JustBreathe.xcodeproj -scheme JustBreathe -destination 'platform=iOS Simulator,name=iPhone 17 Pro' 2>&1 | tail -40
```
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 2: Install and launch in Simulator, walk the whole flow**

```bash
cd /Users/alexutkin/ios && xcrun simctl boot "iPhone 17 Pro" 2>/dev/null; open -a Simulator
xcodebuild -project JustBreathe.xcodeproj -scheme JustBreathe -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -derivedDataPath /tmp/jb-build build 2>&1 | tail -5
xcrun simctl install "iPhone 17 Pro" /tmp/jb-build/Build/Products/Debug-iphonesimulator/JustBreathe.app
BUNDLE_ID=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" /tmp/jb-build/Build/Products/Debug-iphonesimulator/JustBreathe.app/Info.plist)
xcrun simctl launch "iPhone 17 Pro" "$BUNDLE_ID"
```

Walk through and confirm each item from the spec:
- [ ] Tab bar shows "Activities" (not "Actions"), icon unchanged
- [ ] Nav title reads "ACTIVITIES"
- [ ] No LOG/IMPACT segmented picker anywhere on the screen
- [ ] BLE connection indicator is in the top-right of the nav bar
- [ ] SUGGESTED NOW card still shows suggestion chips, START, and LOG PAST
- [ ] Tapping a suggestion chip switches to the Train tab
- [ ] START still opens the activity picker sheet; LOG PAST still opens the retrospective-entry sheet
- [ ] The list below Suggested Now shows activities from all days (not just today), grouped under day headers ("TODAY", "YESTERDAY", or a date)
- [ ] Tapping an activity row still opens its detail sheet; swipe actions (edit/delete) still work

- [ ] **Step 3: Report results**

If every item above passes, the sub-project is complete. If anything fails, note which checklist item and return to the relevant task above to fix it before considering this sub-project done.
