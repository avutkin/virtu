# New-Client Onboarding — Design Spec
Date: 2026-07-23

## Overview

A mandatory, first-launch onboarding flow for new clients: Instagram-reels-style, one bold question per full screen, tap-to-advance, with a progress bar. It collects contact details (phone, email) and a short profile (goals, practices to build, tracking devices, age/gender), then guides the user to connect their Polar H10. All data is stored locally on device; no backend changes.

Matches the app's existing dark visual language (`Theme.bg`/`Theme.accent`/mono labels). Shown once — gated on a persisted flag.

---

## 1. Gating & placement

- New flag: `@AppStorage("hasCompletedOnboarding") var hasCompletedOnboarding = false`.
- In `ContentView` (`App/WythinApp.swift`), branch at the top of `body`:
  - `hasCompletedOnboarding == false` → show `OnboardingFlow` full-screen (no tab bar).
  - `true` → the existing `TabView` + `AppTabBar`.
- `OnboardingFlow` calls a completion closure when finished; `ContentView` saves the profile (already saved incrementally, see §4) and sets `hasCompletedOnboarding = true`, which swaps in the app with a cross-fade.
- The splash (`SplashView`) is unchanged and still shows first; onboarding appears after it dismisses.

---

## 2. Flow (ordered steps)

The order follows the client's explicit request to lead with contact details.

1. **Welcome** — app name, one-line value proposition ("Understand your nervous system, one breath at a time"), a single *Get Started* button. No progress bar on this screen.
2. **Phone number** — numeric keyboard field; *Continue* enabled only when the entry passes light validation (≥ 7 digits after stripping non-digits).
3. **Email** — email keyboard field; *Continue* enabled only when it matches a basic email regex.
4. **Goals** (reels Q1, multi-select) — "What do you want to work on?": Improve sleep · Be more present · More resilient to stress · Reduce anxiety · Sharpen focus · Boost energy.
5. **Build a habit** (reels Q2, multi-select) — "Which practices would you like to do more?": Meditation · Breathwork · Yoga · Gym · Running · Cold exposure · Walking.
6. **Tracking** (reels Q3, multi-select) — "What do you track with?": Oura Ring · Whoop · Apple Watch · Garmin · Fitbit · Just this app.
7. **About you** (reels Q4, one screen) — age range single-select (18–24 / 25–34 / 35–44 / 45–54 / 55+) and gender single-select (Female / Male / Non-binary / Prefer not to say).
8. **Connect Polar H10** — reuses the existing `BLEConnectionSheet` content (presented inline or as a sheet); includes a *Skip for now* affordance so it never dead-ends. Finishing (connected or skipped) completes onboarding.

Steps 2–8 show a progress bar reflecting position (step index / total). Multi-select steps (4–6) require *Continue*; single-select choices within step 7 do not auto-advance (two independent pickers on one screen, then *Continue*). Steps are navigable backward with a *Back* control that preserves entered answers.

The "4 reels-style questions" are steps 4–7.

---

## 3. Reels-question screen — structure & interaction

Reusable `ReelsQuestionScreen` view, configured per step:

```
┌─────────────────────────────┐
│ ▓▓▓▓▓▓░░░░░  progress        │
│                             │
│  What do you want           │  big bold display font (Theme.display)
│  to work on?                │
│  Pick all that apply        │  dim subtitle (Theme.dim)
│                             │
│  ┌───────────────────────┐  │  large tappable option cards;
│  │ 🌙  Improve sleep   ✓ │  │  selected = accent fill + check,
│  ├───────────────────────┤  │  unselected = Theme.surface + border
│  │ 🧘  Be more present   │  │
│  │ ...                   │  │
│  └───────────────────────┘  │
│                             │
│   ‹ Back        Continue ›  │
└─────────────────────────────┘
```

- Each option is a card: SF Symbol/emoji icon + label, min tap height ~52pt, `RoundedRectangle` with `Theme.cardRadius`.
- Tap toggles selection with a spring animation (scale/opacity). Multi-select allows any number; the two single-select pickers in step 7 allow one each.
- *Continue* is disabled until the step's minimum is met (≥ 1 selection for multi-select; both pickers set for step 7). Contact steps gate on validation (§2).
- Transitions between steps use a horizontal slide + fade; the progress bar animates.

The contact steps (phone, email) reuse the same chrome (progress bar, Back/Continue, big question header) but render a styled `TextField` instead of option cards, so the whole flow feels like one system.

---

## 4. Data model & persistence

No SwiftData schema change — the app's `ModelContainer` deletes the store on schema mismatch (`WythinApp.init`), which would risk HRV data. Use plain `Codable` + `UserDefaults` instead.

```swift
struct ClientProfile: Codable, Equatable {
    var phone:     String = ""
    var email:     String = ""
    var ageRange:  String? = nil
    var gender:    String? = nil
    var goals:     [String] = []
    var practices: [String] = []
    var devices:   [String] = []
}
```

- A small `ClientProfileStore` persists it as JSON under `UserDefaults` key `"clientProfile"` (load on init, `save()` writes JSON). Also exposes/uses the `hasCompletedOnboarding` flag conceptually alongside it, though the flag itself lives in `@AppStorage`.
- `OnboardingFlow` holds a `@State private var profile = ClientProfile()` (or loads any partial), mutated as the user answers, and saves on each *Continue* (so a mid-flow app kill doesn't lose prior answers) and finally on completion.
- The store is the single source of truth for the profile; later backend sync can read from it without touching the UI.

---

## 5. Visual style

- Background `Theme.bg`; selection/progress/primary buttons `Theme.accent`; option cards `Theme.surface` with `Theme.border`; question text large and bold (`Theme.display(28–32)`), subtitles `Theme.dim`.
- Progress bar: a thin `Capsule` track (`Theme.surface`) with an accent fill, animated on step change.
- Full-screen, edge-to-edge, `.preferredColorScheme(.dark)` (already app-wide).
- Buttons match existing button styling (accent fill for primary, subtle outline for secondary/Back/Skip).

---

## 6. Validation & edge cases

| Case | Behavior |
|---|---|
| Phone < 7 digits | *Continue* disabled |
| Email fails basic regex | *Continue* disabled |
| Multi-select with 0 chosen | *Continue* disabled |
| Step 7 with age or gender unset | *Continue* disabled |
| BLE step: user taps *Skip for now* | Onboarding completes; user can connect later from Live/Settings |
| App killed mid-flow | Answers so far are persisted (saved per step); on relaunch onboarding restarts from step 1 but fields are pre-filled from the saved profile |

(Onboarding always restarts from step 1 if not completed — we persist answers, not the step index; simplest and low-risk. Pre-filling from the saved profile avoids re-typing.)

---

## 7. Files Changed / Created

| Action | File |
|---|---|
| Create | `ios/Wythin/Models/ClientProfile.swift` — `ClientProfile` Codable + `ClientProfileStore` (UserDefaults JSON) |
| Create | `ios/Wythin/UI/Onboarding/OnboardingFlow.swift` — container, step enum, progress bar, navigation, completion |
| Create | `ios/Wythin/UI/Onboarding/OnboardingScreens.swift` — Welcome, contact (phone/email) screen, `ReelsQuestionScreen`, About-you screen, Connect step |
| Modify | `ios/Wythin/App/WythinApp.swift` — `ContentView` gate on `hasCompletedOnboarding`; add the three new files to the Xcode target |
| Modify | `ios/Wythin.xcodeproj/project.pbxproj` — register the new files (app target) |
| Test | `ios/WythinTests/ClientProfileTests.swift` — `ClientProfileStore` round-trip (save/load), validation helpers (phone/email) |

---

## 8. Out of Scope

- Backend storage / sync of the profile (local-only for now; clean add-on later).
- Editing the profile after onboarding (a Settings screen for it is a future addition).
- Accounts / real authentication (the app remains anonymous-UUID based).
- A dedicated animated "finish/success" screen (not requested); completing the Connect step drops straight into the app.
- Localization of the question copy.
