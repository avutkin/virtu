# Signal Quality Indicator Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a live Signal Quality indicator (Good/Okay/Poor) to the LIVE screen, combining the existing RR-artifact quality metric with a new raw-ECG-waveform flatline/clipping check.

**Architecture:** A new pure-function module `ECGQualityCompute` analyzes the raw ECG buffer already flowing through `MetricsEngine` for flatline (lead-off) and clipping, and combines that with the existing `HRVCompute`-derived `signalQuality` into a single tier. The result surfaces as a colored dot on the existing BLE nav-bar pill, with a breakdown in the existing BLE connection sheet.

**Design doc:** `docs/plans/2026-07-16-signal-quality-indicator-design.md`

**Tech Stack:** Swift 5.9+, SwiftUI, XCTest

## Global Constraints

- Target: `arm64-apple-ios17.0-simulator` (iOS 17+), Swift 5.
- `ios/JustBreathe.xcodeproj/project.pbxproj` uses manual `PBXFileReference`/`PBXBuildFile` entries — **no** synchronized file groups. Every new `.swift` file must be registered by hand (see Critical Context below) or the build won't see it.
- No hardcoded ADC/hardware clipping-rail constant — all ECG thresholds are relative to the window's own statistics (per design doc; a previous attempt to add a global 20%-successive-difference RR filter caused a real regression by using an inappropriate universal threshold — don't repeat that mistake here).
- UI colors: reuse `Theme.accent` (good/green), `Theme.rsa` (okay/amber), `Theme.warn` (poor/red) — no new palette entries.
- No SwiftData schema changes and no persistence of the ECG check — it's a live-only "right now" signal (per design's Not-in-Scope).
- This project has no UI snapshot-testing infrastructure. Pure-logic changes (`ECGQualityCompute`) get real XCTest TDD; UI wiring changes are verified by `xcodebuild build` + manual check in the simulator, matching how `docs/plans/2026-04-06-train-polyvagal-save.md` (the project's own prior plan) verified its UI tasks.

---

## Critical Context

### Existing patterns to follow

- **`*Compute.swift` pattern:** `Metrics/HRVCompute.swift`, `Metrics/DFACompute.swift`, `Metrics/AdvancedHRVCompute.swift` are all `enum`s with `static func compute(...) -> SomeResult?` returning `nil` when there isn't enough data. `ECGQualityCompute` follows the same shape.
- **`MetricsEngine.compute(from snapshot: DataSnapshot) -> MetricsTick`** (`Metrics/MetricsEngine.swift`) already receives `snapshot.ecg: [Float]` (raw ECG samples, ~10s at 130 Hz, from `DataBuffer.ecgBuf`) but currently doesn't use it for any metric — only for waveform display via `dataBuffer.ecgDisplay(samples:)`. This task is the first consumer of `snapshot.ecg` inside `MetricsEngine.compute`.
- **`HRVCompute.compute(rrMs:)`** already returns `HRVMetrics.artifactRate: Float` and `MetricsTick.signalQuality: Float? = 1 - artifactRate` (`Metrics/MetricsEngine.swift:127`). This already exists — do not recompute it, just consume `tick.signalQuality`.
- **Xcode project file** is at `ios/JustBreathe.xcodeproj/project.pbxproj`. New files need four edits each: a `PBXBuildFile` entry, a `PBXFileReference` entry, an entry in the relevant `PBXGroup`'s `children`, and an entry in the relevant target's `PBXSourcesBuildPhase` `files` list. Next available tokens: **F143/A143** (main target), **FT03/AT03** (test target).
- **Tests** live in `ios/JustBreatheTests/`, use `import XCTest` + `@testable import JustBreathe`, `XCTestCase` subclasses. See `ios/JustBreatheTests/MetricsTests.swift` for the exact style used in this project.
- **Test runner:** `cd /Users/alexutkin/ios && xcodebuild test -project JustBreathe.xcodeproj -scheme JustBreathe -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:JustBreatheTests/ECGQualityComputeTests`
- **Full build check:** `cd /Users/alexutkin/ios && xcodebuild -project JustBreathe.xcodeproj -scheme JustBreathe -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' -configuration Debug build`
- **Theme colors available:** `Theme.accent` (green), `Theme.warn` (red), `Theme.rsa` (amber), `Theme.dim`, `Theme.text`, `Theme.card`, `Theme.border`, `Theme.bg`. `.cardStyle()` is an existing view modifier used by `BLEConnectionSheet`'s other cards.
- **`BLENavButton`** (`UI/Design/BLENavButton.swift`) is shared across three call sites: `UI/Live/LiveView.swift:71`, `UI/Train/TrainView.swift:205`, `UI/Actions/ActionsView.swift:108`. Only the Live screen is in scope for this feature (per design doc's Overview) — the new parameter must default to `nil` so the other two call sites keep compiling unchanged.
- **`BLEConnectionSheet`** is defined inline in `UI/Live/LiveView.swift` (not its own file), instantiated once at `UI/Live/LiveView.swift:78`.

---

## Task 1: `ECGQualityCompute` — flatline detection + test harness

**Files:**
- Create: `ios/JustBreathe/Metrics/ECGQualityCompute.swift`
- Create: `ios/JustBreatheTests/ECGQualityComputeTests.swift`
- Modify: `ios/JustBreathe.xcodeproj/project.pbxproj`

**Interfaces:**
- Produces: `enum SignalQualityTier: Int, Comparable { case poor = 0, okay = 1, good = 2 }`; `struct ECGQualityResult { let tier: SignalQualityTier; let reason: String }`; `enum ECGQualityCompute { static func compute(ecg: [Float]) -> ECGQualityResult? }`

- [ ] **Step 1: Register both new files in the Xcode project**

In `ios/JustBreathe.xcodeproj/project.pbxproj`, make these edits:

**a)** In the `PBXBuildFile` section, find:
```
		A142 /* AdvancedHRVCompute.swift in Sources */ = {isa = PBXBuildFile; fileRef = F142 /* AdvancedHRVCompute.swift */; };
		ARES1 /* Assets.xcassets in Resources */ = {isa = PBXBuildFile; fileRef = FRES1 /* Assets.xcassets */; };
		AT01 /* MetricsTests.swift in Sources */ = {isa = PBXBuildFile; fileRef = FT01 /* MetricsTests.swift */; };
		AT02 /* BLETests.swift in Sources */ = {isa = PBXBuildFile; fileRef = FT02 /* BLETests.swift */; };
```
Replace with:
```
		A142 /* AdvancedHRVCompute.swift in Sources */ = {isa = PBXBuildFile; fileRef = F142 /* AdvancedHRVCompute.swift */; };
		A143 /* ECGQualityCompute.swift in Sources */ = {isa = PBXBuildFile; fileRef = F143 /* ECGQualityCompute.swift */; };
		ARES1 /* Assets.xcassets in Resources */ = {isa = PBXBuildFile; fileRef = FRES1 /* Assets.xcassets */; };
		AT01 /* MetricsTests.swift in Sources */ = {isa = PBXBuildFile; fileRef = FT01 /* MetricsTests.swift */; };
		AT02 /* BLETests.swift in Sources */ = {isa = PBXBuildFile; fileRef = FT02 /* BLETests.swift */; };
		AT03 /* ECGQualityComputeTests.swift in Sources */ = {isa = PBXBuildFile; fileRef = FT03 /* ECGQualityComputeTests.swift */; };
```

**b)** In the `PBXFileReference` section, find:
```
		F142 /* AdvancedHRVCompute.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = AdvancedHRVCompute.swift; sourceTree = "<group>"; };
		FRES1 /* Assets.xcassets */ = {isa = PBXFileReference; lastKnownFileType = folder.assetcatalog; path = Assets.xcassets; sourceTree = "<group>"; };
		FAPP /* JustBreathe.app */ = {isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = JustBreathe.app; sourceTree = BUILT_PRODUCTS_DIR; };
		FINFO /* Info.plist */ = {isa = PBXFileReference; lastKnownFileType = text.plist.xml; path = Info.plist; sourceTree = "<group>"; };
		FT01 /* MetricsTests.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = MetricsTests.swift; sourceTree = "<group>"; };
		FT02 /* BLETests.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = BLETests.swift; sourceTree = "<group>"; };
```
Replace with:
```
		F142 /* AdvancedHRVCompute.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = AdvancedHRVCompute.swift; sourceTree = "<group>"; };
		F143 /* ECGQualityCompute.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = ECGQualityCompute.swift; sourceTree = "<group>"; };
		FRES1 /* Assets.xcassets */ = {isa = PBXFileReference; lastKnownFileType = folder.assetcatalog; path = Assets.xcassets; sourceTree = "<group>"; };
		FAPP /* JustBreathe.app */ = {isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = JustBreathe.app; sourceTree = BUILT_PRODUCTS_DIR; };
		FINFO /* Info.plist */ = {isa = PBXFileReference; lastKnownFileType = text.plist.xml; path = Info.plist; sourceTree = "<group>"; };
		FT01 /* MetricsTests.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = MetricsTests.swift; sourceTree = "<group>"; };
		FT02 /* BLETests.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = BLETests.swift; sourceTree = "<group>"; };
		FT03 /* ECGQualityComputeTests.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = ECGQualityComputeTests.swift; sourceTree = "<group>"; };
```

**c)** In the `GAPP_MET /* Metrics */` group's `children`, find:
```
				F110 /* CoherenceCompute.swift */,
				F141 /* DFACompute.swift */,
				F142 /* AdvancedHRVCompute.swift */,
			);
			path = Metrics;
```
Replace with:
```
				F110 /* CoherenceCompute.swift */,
				F141 /* DFACompute.swift */,
				F142 /* AdvancedHRVCompute.swift */,
				F143 /* ECGQualityCompute.swift */,
			);
			path = Metrics;
```

**d)** In the `GTESTS /* JustBreatheTests */` group's `children`, find:
```
				FT01 /* MetricsTests.swift */,
				FT02 /* BLETests.swift */,
			);
			path = JustBreatheTests;
```
Replace with:
```
				FT01 /* MetricsTests.swift */,
				FT02 /* BLETests.swift */,
				FT03 /* ECGQualityComputeTests.swift */,
			);
			path = JustBreatheTests;
```

**e)** In the main target's `PBXSourcesBuildPhase`, find:
```
				A141 /* DFACompute.swift in Sources */,
				A142 /* AdvancedHRVCompute.swift in Sources */,
				A123 /* ResonateView.swift in Sources */,
```
Replace with:
```
				A141 /* DFACompute.swift in Sources */,
				A142 /* AdvancedHRVCompute.swift in Sources */,
				A143 /* ECGQualityCompute.swift in Sources */,
				A123 /* ResonateView.swift in Sources */,
```

**f)** In the `BSTST /* Sources */` test-target build phase, find:
```
		BSTST /* Sources */ = {
			isa = PBXSourcesBuildPhase;
			buildActionMask = 2147483647;
			files = (
				AT01 /* MetricsTests.swift in Sources */,
				AT02 /* BLETests.swift in Sources */,
			);
```
Replace with:
```
		BSTST /* Sources */ = {
			isa = PBXSourcesBuildPhase;
			buildActionMask = 2147483647;
			files = (
				AT01 /* MetricsTests.swift in Sources */,
				AT02 /* BLETests.swift in Sources */,
				AT03 /* ECGQualityComputeTests.swift in Sources */,
			);
```

- [ ] **Step 2: Write the failing tests**

Create `ios/JustBreatheTests/ECGQualityComputeTests.swift`:

```swift
import XCTest
@testable import JustBreathe

final class ECGQualityComputeTests: XCTestCase {

    func testInsufficientSamplesReturnsNil() {
        let ecg: [Float] = Array(repeating: 0, count: 50)   // below the 130-sample (~1s) minimum
        XCTAssertNil(ECGQualityCompute.compute(ecg: ecg))
    }

    func testFlatlineDetected() {
        // Constant signal — no cardiac variability, simulates lead-off/no contact
        let ecg: [Float] = Array(repeating: 120, count: 200)
        let result = ECGQualityCompute.compute(ecg: ecg)
        XCTAssertEqual(result?.tier, .poor)
        XCTAssertEqual(result?.reason, "lead-off")
    }
}
```

- [ ] **Step 3: Run the tests and verify they fail to compile**

Run:
```bash
cd /Users/alexutkin/ios && xcodebuild test -project JustBreathe.xcodeproj -scheme JustBreathe -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:JustBreatheTests/ECGQualityComputeTests
```
Expected: **BUILD FAILED** — `Cannot find 'ECGQualityCompute' in scope` (the type doesn't exist yet).

- [ ] **Step 4: Implement `ECGQualityCompute` (flatline check only)**

Create `ios/JustBreathe/Metrics/ECGQualityCompute.swift`:

```swift
import Foundation

// MARK: - Signal Quality Tier

/// Shared three-level tier for both the RR-artifact and ECG-waveform quality checks.
/// Ordered so `.min()` over an array picks the worst tier.
enum SignalQualityTier: Int, Comparable {
    case poor = 0
    case okay = 1
    case good = 2

    static func < (lhs: SignalQualityTier, rhs: SignalQualityTier) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

// MARK: - ECG Quality Output

struct ECGQualityResult {
    let tier:   SignalQualityTier
    let reason: String   // "clean" | "clipping" | "lead-off"
}

// MARK: - Combined Output (RR-artifact + ECG-waveform)

struct CombinedSignalQuality {
    let tier:              SignalQualityTier
    let rrArtifactPercent: Int?     // nil if the RR side is unavailable
    let ecgReason:         String?  // nil if the ECG side is unavailable
}

// MARK: - ECGQualityCompute

/// Raw ECG waveform quality check: flatline/lead-off and clipping/saturation.
/// Deliberately relative to the window's own statistics rather than a hardcoded
/// hardware ADC rail constant (unverifiable from this codebase, and a hardcoded
/// universal threshold is exactly the kind of assumption that caused the RR
/// artifact-filter regression this indicator is meant to help catch).
enum ECGQualityCompute {

    /// Minimum samples needed to evaluate a window (~1 s at 130 Hz).
    static let minSamples = 130

    /// Below this population stddev (µV), treat the window as flatline/lead-off.
    /// Resting ECG is typically hundreds of µV peak-to-peak, so this cleanly
    /// separates "no real cardiac signal" from any real reading.
    private static let flatlineStddevThreshold: Float = 3.0

    static func compute(ecg: [Float]) -> ECGQualityResult? {
        guard ecg.count >= minSamples else { return nil }

        let mean = ecg.reduce(0, +) / Float(ecg.count)
        let variance = ecg.reduce(Float(0)) { $0 + ($1 - mean) * ($1 - mean) } / Float(ecg.count)
        let stddev = sqrt(variance)

        guard stddev >= flatlineStddevThreshold else {
            return ECGQualityResult(tier: .poor, reason: "lead-off")
        }

        return ECGQualityResult(tier: .good, reason: "clean")
    }
}
```

- [ ] **Step 5: Run the tests and verify they pass**

Run the same command as Step 3.
Expected: **TEST SUCCEEDED** — both tests pass.

- [ ] **Step 6: Commit**

```bash
git add ios/JustBreathe/Metrics/ECGQualityCompute.swift \
        ios/JustBreatheTests/ECGQualityComputeTests.swift \
        ios/JustBreathe.xcodeproj/project.pbxproj
git commit -m "feat(metrics): add ECGQualityCompute with flatline/lead-off detection"
```

---

## Task 2: Clipping detection

**Files:**
- Modify: `ios/JustBreathe/Metrics/ECGQualityCompute.swift`
- Modify: `ios/JustBreatheTests/ECGQualityComputeTests.swift`

**Interfaces:**
- Consumes: `ECGQualityResult`, `SignalQualityTier` from Task 1.
- Produces: `ECGQualityCompute.compute(ecg:)` now also detects clipping (no signature change).

- [ ] **Step 1: Write the failing tests**

Add to `ios/JustBreatheTests/ECGQualityComputeTests.swift` (inside the `ECGQualityComputeTests` class):

```swift
    func testCleanSignalIsGood() {
        // Deterministic non-repeating pattern — no two consecutive samples are
        // ever within clipping tolerance of each other, so no run can form.
        let ecg: [Float] = (0..<200).map { i in Float(i % 37) * 17.3 - 300 }
        let result = ECGQualityCompute.compute(ecg: ecg)
        XCTAssertEqual(result?.tier, .good)
        XCTAssertEqual(result?.reason, "clean")
    }

    func testSustainedClippingDetectedAsPoor() {
        var ecg: [Float] = (0..<200).map { i in Float(i % 37) * 17.3 - 300 }
        let railValue: Float = 1000   // clearly outside the base signal's own range
        for i in 50..<90 { ecg[i] = railValue }   // 40 consecutive pinned samples (20% of window)
        let result = ECGQualityCompute.compute(ecg: ecg)
        XCTAssertEqual(result?.tier, .poor)
        XCTAssertEqual(result?.reason, "clipping")
    }

    func testBriefClippingDetectedAsOkay() {
        var ecg: [Float] = (0..<200).map { i in Float(i % 37) * 17.3 - 300 }
        let railValue: Float = 1000
        for i in 50..<56 { ecg[i] = railValue }   // 6 consecutive pinned samples (3% of window)
        let result = ECGQualityCompute.compute(ecg: ecg)
        XCTAssertEqual(result?.tier, .okay)
        XCTAssertEqual(result?.reason, "clipping")
    }

    func testShortPinnedRunIsIgnored() {
        var ecg: [Float] = (0..<200).map { i in Float(i % 37) * 17.3 - 300 }
        let railValue: Float = 1000
        for i in 50..<53 { ecg[i] = railValue }   // only 3 consecutive — below the run-length gate
        let result = ECGQualityCompute.compute(ecg: ecg)
        XCTAssertEqual(result?.tier, .good)
        XCTAssertEqual(result?.reason, "clean")
    }
```

- [ ] **Step 2: Run the tests and verify the new ones fail**

Run:
```bash
cd /Users/alexutkin/ios && xcodebuild test -project JustBreathe.xcodeproj -scheme JustBreathe -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:JustBreatheTests/ECGQualityComputeTests
```
Expected: `testCleanSignalIsGood`, `testSustainedClippingDetectedAsPoor`, `testBriefClippingDetectedAsOkay` FAIL (current implementation always returns `"clean"` for non-flatline input, so the two clipping tests fail; `testShortPinnedRunIsIgnored` happens to pass already but re-run to confirm the suite state). The two pre-existing tests from Task 1 still pass.

- [ ] **Step 3: Implement clipping detection**

In `ios/JustBreathe/Metrics/ECGQualityCompute.swift`, replace:
```swift
        guard stddev >= flatlineStddevThreshold else {
            return ECGQualityResult(tier: .poor, reason: "lead-off")
        }

        return ECGQualityResult(tier: .good, reason: "clean")
    }
}
```
with:
```swift
        guard stddev >= flatlineStddevThreshold else {
            return ECGQualityResult(tier: .poor, reason: "lead-off")
        }

        let clippedFraction = clippedSampleFraction(ecg)
        if clippedFraction >= clipPoorFraction {
            return ECGQualityResult(tier: .poor, reason: "clipping")
        } else if clippedFraction > 0 {
            return ECGQualityResult(tier: .okay, reason: "clipping")
        }
        return ECGQualityResult(tier: .good, reason: "clean")
    }

    /// A run of `clipMinRunLength`+ consecutive samples within `clipRunTolerance`
    /// of the window's own min or max counts as "pinned" (saturated at a rail).
    /// Short runs are ignored — a real QRS peak can briefly touch the window max
    /// without that being clipping.
    private static let clipRunTolerance: Float = 0.5
    private static let clipMinRunLength: Int   = 5
    private static let clipPoorFraction: Float = 0.10

    private static func clippedSampleFraction(_ ecg: [Float]) -> Float {
        guard let maxVal = ecg.max(), let minVal = ecg.min() else { return 0 }

        func pinnedCount(near rail: Float) -> Int {
            var total = 0
            var runLength = 0
            for v in ecg {
                if abs(v - rail) <= clipRunTolerance {
                    runLength += 1
                } else {
                    if runLength >= clipMinRunLength { total += runLength }
                    runLength = 0
                }
            }
            if runLength >= clipMinRunLength { total += runLength }
            return total
        }

        let pinned = pinnedCount(near: maxVal) + pinnedCount(near: minVal)
        return Float(pinned) / Float(ecg.count)
    }
}
```

- [ ] **Step 4: Run the tests and verify they all pass**

Run the same command as Step 2.
Expected: **TEST SUCCEEDED** — all 6 tests pass.

- [ ] **Step 5: Commit**

```bash
git add ios/JustBreathe/Metrics/ECGQualityCompute.swift ios/JustBreatheTests/ECGQualityComputeTests.swift
git commit -m "feat(metrics): add ECG clipping detection to ECGQualityCompute"
```

---

## Task 3: RR tiering + combined tier

**Files:**
- Modify: `ios/JustBreathe/Metrics/ECGQualityCompute.swift`
- Modify: `ios/JustBreatheTests/ECGQualityComputeTests.swift`

**Interfaces:**
- Consumes: `SignalQualityTier`, `ECGQualityResult`, `CombinedSignalQuality` from Task 1.
- Produces: `ECGQualityCompute.rrTier(fromSignalQuality:) -> SignalQualityTier` and `ECGQualityCompute.combinedTier(rrSignalQuality: Float?, ecgResult: ECGQualityResult?) -> CombinedSignalQuality?` — used by Tasks 5 and 6.

- [ ] **Step 1: Write the failing tests**

Add to `ios/JustBreatheTests/ECGQualityComputeTests.swift`:

```swift
    func testRRTierBoundaries() {
        XCTAssertEqual(ECGQualityCompute.rrTier(fromSignalQuality: 0.97), .good)
        XCTAssertEqual(ECGQualityCompute.rrTier(fromSignalQuality: 0.95), .good)
        XCTAssertEqual(ECGQualityCompute.rrTier(fromSignalQuality: 0.85), .okay)
        XCTAssertEqual(ECGQualityCompute.rrTier(fromSignalQuality: 0.80), .okay)
        XCTAssertEqual(ECGQualityCompute.rrTier(fromSignalQuality: 0.50), .poor)
    }

    func testCombinedTierNilWhenNoData() {
        XCTAssertNil(ECGQualityCompute.combinedTier(rrSignalQuality: nil, ecgResult: nil))
    }

    func testCombinedTierTakesWorseOfTwo() {
        let ecgGood = ECGQualityResult(tier: .good, reason: "clean")
        let combined = ECGQualityCompute.combinedTier(rrSignalQuality: 0.50, ecgResult: ecgGood)
        XCTAssertEqual(combined?.tier, .poor)     // RR side is worse (50% artifacts)
        XCTAssertEqual(combined?.rrArtifactPercent, 50)
        XCTAssertEqual(combined?.ecgReason, "clean")
    }

    func testCombinedTierUsesOnlyAvailableSide() {
        let combined = ECGQualityCompute.combinedTier(rrSignalQuality: 0.97, ecgResult: nil)
        XCTAssertEqual(combined?.tier, .good)
        XCTAssertNil(combined?.ecgReason)
    }
```

- [ ] **Step 2: Run the tests and verify they fail to compile**

Run:
```bash
cd /Users/alexutkin/ios && xcodebuild test -project JustBreathe.xcodeproj -scheme JustBreathe -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:JustBreatheTests/ECGQualityComputeTests
```
Expected: **BUILD FAILED** — `Cannot find 'rrTier' in scope` / `Cannot find 'combinedTier' in scope`.

- [ ] **Step 3: Implement `rrTier` and `combinedTier`**

In `ios/JustBreathe/Metrics/ECGQualityCompute.swift`, add these two static functions inside `enum ECGQualityCompute` (after `compute(ecg:)`):

```swift
    /// Tiers the existing RR-artifact-based `MetricsTick.signalQuality`
    /// (`1 - artifactRate`, already computed by `HRVCompute`).
    static func rrTier(fromSignalQuality q: Float) -> SignalQualityTier {
        if q >= 0.95 { return .good }
        if q >= 0.80 { return .okay }
        return .poor
    }

    /// Combines the RR-artifact tier and the ECG-waveform tier into one
    /// overall tier — the worse of the two, since either signal alone being
    /// bad means the reading can't be fully trusted.
    static func combinedTier(rrSignalQuality: Float?, ecgResult: ECGQualityResult?) -> CombinedSignalQuality? {
        let rr  = rrSignalQuality.map(rrTier(fromSignalQuality:))
        let ecg = ecgResult?.tier
        guard let overall = [rr, ecg].compactMap({ $0 }).min() else { return nil }
        return CombinedSignalQuality(
            tier: overall,
            rrArtifactPercent: rrSignalQuality.map { Int(((1 - $0) * 100).rounded()) },
            ecgReason: ecgResult?.reason
        )
    }
```

- [ ] **Step 4: Run the tests and verify they all pass**

Run the same command as Step 2.
Expected: **TEST SUCCEEDED** — all 10 tests pass.

- [ ] **Step 5: Commit**

```bash
git add ios/JustBreathe/Metrics/ECGQualityCompute.swift ios/JustBreatheTests/ECGQualityComputeTests.swift
git commit -m "feat(metrics): add RR tiering and combined signal quality tier"
```

---

## Task 4: Wire into `MetricsEngine`

**Files:**
- Modify: `ios/JustBreathe/Metrics/MetricsEngine.swift`
- Modify: `ios/JustBreatheTests/MetricsTests.swift`
- Modify: `ios/JustBreathe/UI/Live/LiveView.swift` (two pre-existing `MetricsTick` construction sites need the new field)
- Modify: `ios/JustBreathe/UI/Live/MetricsChartsView.swift` (one pre-existing `MetricsTick` construction site needs the new field)

**Interfaces:**
- Consumes: `ECGQualityCompute.compute(ecg:) -> ECGQualityResult?` from Task 1.
- Produces: `MetricsTick.ecgQuality: ECGQualityResult?` — a new, **not-persisted** field (not added to `MetricsHistoryPoint`/`HRVSample`, per design). Used by Tasks 5 and 6 via `tick.signalQuality` (existing) and `tick.ecgQuality` (new).

- [ ] **Step 1: Write the failing test**

Add to `ios/JustBreatheTests/MetricsTests.swift` (inside `MetricsTests`, e.g. after `testCBIRange`):

```swift
    // MARK: - ECG quality wiring

    func testMetricsEngineComputesECGQuality() {
        let flatEcg = [Float](repeating: 50, count: 200)   // flatline — simulates lead-off
        let snapshot = DataSnapshot(ecg: flatEcg, accZ: [], accXYZ: [], rr: [], bpm: [])
        let tick = MetricsEngine.compute(from: snapshot)
        XCTAssertEqual(tick.ecgQuality?.tier, .poor)
        XCTAssertEqual(tick.ecgQuality?.reason, "lead-off")
    }
```

- [ ] **Step 2: Run the test and verify it fails to compile**

Run:
```bash
cd /Users/alexutkin/ios && xcodebuild test -project JustBreathe.xcodeproj -scheme JustBreathe -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:JustBreatheTests/MetricsTests/testMetricsEngineComputesECGQuality
```
Expected: **BUILD FAILED** — `value of type 'MetricsTick' has no member 'ecgQuality'`.

- [ ] **Step 3: Add the field and wire the call**

In `ios/JustBreathe/Metrics/MetricsEngine.swift`, add the new field to `MetricsTick` (after the existing `signalQuality` field):
```swift
    // Signal quality
    let signalQuality: Float?

    /// ECG waveform quality (flatline/clipping check) — live-only, not persisted.
    let ecgQuality: ECGQualityResult?
```

In `MetricsEngine.compute(from:)`, add the call alongside the other per-tick computations (after the `--- DFA α1 ---` block):
```swift
        // --- ECG waveform quality ---
        let ecgQuality = ECGQualityCompute.compute(ecg: snapshot.ecg)
```

And add it to the returned `MetricsTick` (after `signalQuality:`):
```swift
            signalQuality:  hrv.map { 1 - $0.artifactRate },
            ecgQuality:     ecgQuality,
```

- [ ] **Step 4: Run the test and verify it passes**

Run the same command as Step 2.
Expected: **TEST SUCCEEDED**.

- [ ] **Step 5: Update the three other `MetricsTick(...)` construction sites**

Adding a new non-defaulted field to `MetricsTick` makes it a required argument everywhere the struct is built. Three other places build one directly (`grep -rn "MetricsTick(" ios/JustBreathe` to confirm no others exist beyond these plus `MetricsEngine.swift`):

**a)** In `ios/JustBreathe/UI/Live/LiveView.swift`, `dayAverageTick(from:)` builds a `MetricsTick` averaged from `MetricsHistoryPoint`s, which don't carry ECG-quality data (it's live-only, per design) — pass `nil`. Replace:
```swift
            signalQuality:   avg(history.compactMap(\.signalQuality)),
            rcmse:           avg(history.compactMap(\.rcmse)),
```
with:
```swift
            signalQuality:   avg(history.compactMap(\.signalQuality)),
            ecgQuality:      nil,
            rcmse:           avg(history.compactMap(\.rcmse)),
```

**b)** In the same file, `createMockEnvironment()` (the `#Preview` mock) builds a hardcoded `MetricsTick`. Replace:
```swift
        regularity: 0.85, coherenceScore: 0.76, cbi: 0.82, dfa1: 1.02, signalQuality: 0.97,
        rcmse: 1.45, pip: 54.2, ials: 0.51, dc: 7.2,
```
with:
```swift
        regularity: 0.85, coherenceScore: 0.76, cbi: 0.82, dfa1: 1.02, signalQuality: 0.97,
        ecgQuality: ECGQualityResult(tier: .good, reason: "clean"),
        rcmse: 1.45, pip: 54.2, ials: 0.51, dc: 7.2,
```

**c)** In `ios/JustBreathe/UI/Live/MetricsChartsView.swift`, `mockHistory()` (another preview mock) builds a `MetricsTick` per synthetic data point — same reasoning as (a), pass `nil`. Replace:
```swift
            dfa1:           Float(1.0 + 0.15 * sin(phase * 0.15)),
            signalQuality:  Float(0.95 + 0.05 * sin(phase * 0.2)),
            rcmse:          Float(1.4 + 0.2 * sin(phase * 0.12)),
```
with:
```swift
            dfa1:           Float(1.0 + 0.15 * sin(phase * 0.15)),
            signalQuality:  Float(0.95 + 0.05 * sin(phase * 0.2)),
            ecgQuality:     nil,
            rcmse:          Float(1.4 + 0.2 * sin(phase * 0.12)),
```

- [ ] **Step 6: Run the full test suite and full build**

```bash
cd /Users/alexutkin/ios && xcodebuild test -project JustBreathe.xcodeproj -scheme JustBreathe -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 17'
cd /Users/alexutkin/ios && xcodebuild -project JustBreathe.xcodeproj -scheme JustBreathe -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' -configuration Debug build
```
Expected: both **SUCCEEDED**, with zero missing-argument errors.

- [ ] **Step 7: Commit**

```bash
git add ios/JustBreathe/Metrics/MetricsEngine.swift ios/JustBreatheTests/MetricsTests.swift \
        ios/JustBreathe/UI/Live/LiveView.swift ios/JustBreathe/UI/Live/MetricsChartsView.swift
git commit -m "feat(metrics): wire ECGQualityCompute into MetricsEngine"
```

---

## Task 5: Quality dot on the nav-bar pill

**Files:**
- Modify: `ios/JustBreathe/UI/Design/BLENavButton.swift`
- Modify: `ios/JustBreathe/UI/Live/LiveView.swift`

**Interfaces:**
- Consumes: `CombinedSignalQuality`, `SignalQualityTier` from Task 3; `MetricsTick.signalQuality` (existing), `MetricsTick.ecgQuality` (Task 4).
- Produces: `BLENavButton(state:bpm:quality:action:)` — `quality` defaults to `nil`. `LiveView.currentQuality: CombinedSignalQuality?` — a computed property reused by Task 6.

- [ ] **Step 1: Add the `quality` parameter and dot overlay to `BLENavButton`**

In `ios/JustBreathe/UI/Design/BLENavButton.swift`, replace:
```swift
struct BLENavButton: View {
    let state:  BLEState
    let bpm:    Float?
    let action: () -> Void

    @State private var pulse       = false
    @State private var spinAngle   = 0.0

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
```
with:
```swift
struct BLENavButton: View {
    let state:   BLEState
    let bpm:     Float?
    let quality: CombinedSignalQuality? = nil
    let action:  () -> Void

    @State private var pulse       = false
    @State private var spinAngle   = 0.0

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
```

Then replace:
```swift
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(stateBackground)
            .clipShape(Capsule())
        }
        .onAppear { startAnimations() }
```
with:
```swift
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(stateBackground)
            .clipShape(Capsule())
            .overlay(alignment: .topTrailing) {
                if case .connected = state, let quality {
                    Circle()
                        .fill(qualityColor(quality.tier))
                        .frame(width: 7, height: 7)
                        .overlay(Circle().strokeBorder(Theme.bg, lineWidth: 1.5))
                        .offset(x: 2, y: -2)
                }
            }
        }
        .onAppear { startAnimations() }
```

Add this helper method inside `BLENavButton` (after `startAnimations()`):
```swift

    private func qualityColor(_ tier: SignalQualityTier) -> Color {
        switch tier {
        case .good: return Theme.accent
        case .okay: return Theme.rsa
        case .poor: return Theme.warn
        }
    }
```

> Note: `BLENavButton` has no explicit `init` — Swift synthesizes a memberwise one. A non-private stored property with a default value (like `quality: CombinedSignalQuality? = nil` here, or `state`/`bpm` if they had defaults) becomes an *optional* argument in that synthesized initializer, so existing call sites that don't pass `quality:` keep compiling unchanged. This is the same mechanism already at work for `pulse`/`spinAngle` below (those are `private`, so they're excluded from the memberwise init entirely rather than being optional).

- [ ] **Step 2: Add `currentQuality` to `LiveView` and pass it to `BLENavButton`**

In `ios/JustBreathe/UI/Live/LiveView.swift`, add this computed property to `LiveView` (after `private func goForward() { ... }`):
```swift
    private var currentQuality: CombinedSignalQuality? {
        ECGQualityCompute.combinedTier(
            rrSignalQuality: env.latestTick?.signalQuality,
            ecgResult:       env.latestTick?.ecgQuality
        )
    }
```

Replace:
```swift
                ToolbarItem(placement: .navigationBarTrailing) {
                    BLENavButton(state: env.ble.state,
                                 bpm: env.latestTick?.meanBPM) {
                        showBLESheet = true
                    }
                }
```
with:
```swift
                ToolbarItem(placement: .navigationBarTrailing) {
                    BLENavButton(state: env.ble.state,
                                 bpm: env.latestTick?.meanBPM,
                                 quality: currentQuality) {
                        showBLESheet = true
                    }
                }
```

- [ ] **Step 3: Build and verify in the simulator**

```bash
cd /Users/alexutkin/ios && xcodebuild -project JustBreathe.xcodeproj -scheme JustBreathe -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' -configuration Debug build
```
Expected: **BUILD SUCCEEDED**, and the two other `BLENavButton` call sites (`TrainView.swift:205`, `ActionsView.swift:108`) still compile unchanged since `quality` defaults to `nil`.

Run the app in the simulator (or on device with a Polar H10 connected): confirm the nav-bar pill shows no dot when disconnected, and shows a small dot once connected and enough data has accumulated for `latestTick.signalQuality`/`ecgQuality` to be non-nil.

- [ ] **Step 4: Commit**

```bash
git add ios/JustBreathe/UI/Design/BLENavButton.swift ios/JustBreathe/UI/Live/LiveView.swift
git commit -m "feat(live): show signal quality dot on BLE nav pill"
```

---

## Task 6: Signal Quality section in `BLEConnectionSheet`

**Files:**
- Modify: `ios/JustBreathe/UI/Live/LiveView.swift`

**Interfaces:**
- Consumes: `CombinedSignalQuality`, `SignalQualityTier` (Task 3); `LiveView.currentQuality` (Task 5).

- [ ] **Step 1: Add the `quality` parameter to `BLEConnectionSheet` and render the new card**

Replace:
```swift
struct BLEConnectionSheet: View {
    let ble: BLEService
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.bg.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 16) {
                        statusCard
                        actionSection
                        if let err = ble.lastError { errorCard(err) }
                    }
                    .padding()
                }
            }
```
with:
```swift
struct BLEConnectionSheet: View {
    let ble:     BLEService
    let quality: CombinedSignalQuality?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.bg.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 16) {
                        statusCard
                        if let quality { signalQualityCard(quality) }
                        actionSection
                        if let err = ble.lastError { errorCard(err) }
                    }
                    .padding()
                }
            }
```

Add this new view builder method (after `statusCard`, before `actionSection`):
```swift

    private func signalQualityCard(_ q: CombinedSignalQuality) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("SIGNAL QUALITY")
                    .font(Theme.monoLabel)
                    .foregroundStyle(Theme.dim)
                Spacer()
                HStack(spacing: 5) {
                    Circle().fill(qualityColor(q.tier)).frame(width: 7, height: 7)
                    Text(qualityLabel(q.tier))
                        .font(Theme.monoBody)
                        .foregroundStyle(qualityColor(q.tier))
                }
            }
            HStack {
                Text("RR artifacts")
                    .font(Theme.monoLabel)
                    .foregroundStyle(Theme.dim)
                Spacer()
                Text(q.rrArtifactPercent.map { "\($0)%" } ?? "—")
                    .font(Theme.monoBody)
                    .foregroundStyle(Theme.text)
            }
            HStack {
                Text("ECG waveform")
                    .font(Theme.monoLabel)
                    .foregroundStyle(Theme.dim)
                Spacer()
                Text(q.ecgReason ?? "—")
                    .font(Theme.monoBody)
                    .foregroundStyle(Theme.text)
            }
            if q.tier != .good {
                Divider().background(Theme.border)
                Text("Improving signal quality")
                    .font(Theme.monoLabel)
                    .foregroundStyle(Theme.dim)
                ForEach(Self.improvementTips, id: \.self) { tip in
                    Text("•  \(tip)")
                        .font(Theme.monoLabel)
                        .foregroundStyle(Theme.text.opacity(0.85))
                }
            }
        }
        .cardStyle()
    }

    private static let improvementTips = [
        "Limit movement during measurement",
        "Ensure the chest strap is moist",
        "Ensure the strap is tightened appropriately",
        "Check and replace worn-out chest straps",
        "Check and replace HR monitor batteries that are low",
    ]

    private func qualityColor(_ tier: SignalQualityTier) -> Color {
        switch tier {
        case .good: return Theme.accent
        case .okay: return Theme.rsa
        case .poor: return Theme.warn
        }
    }

    private func qualityLabel(_ tier: SignalQualityTier) -> String {
        switch tier {
        case .good: return "GOOD"
        case .okay: return "OKAY"
        case .poor: return "POOR"
        }
    }
```

- [ ] **Step 2: Update the call site**

Replace:
```swift
            .sheet(isPresented: $showBLESheet) {
                BLEConnectionSheet(ble: env.ble)
            }
```
with:
```swift
            .sheet(isPresented: $showBLESheet) {
                BLEConnectionSheet(ble: env.ble, quality: currentQuality)
            }
```

- [ ] **Step 3: Build and verify in the simulator**

```bash
cd /Users/alexutkin/ios && xcodebuild -project JustBreathe.xcodeproj -scheme JustBreathe -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' -configuration Debug build
```
Expected: **BUILD SUCCEEDED**.

Run the app: tap the nav-bar pill to open the BLE sheet. With no data yet, no Signal Quality card shows. Once connected with data flowing, the card appears with tier, RR-artifact %, ECG reason, and (when not Good) the improvement tips.

- [ ] **Step 4: Commit**

```bash
git add ios/JustBreathe/UI/Live/LiveView.swift
git commit -m "feat(live): add Signal Quality breakdown to BLE connection sheet"
```

---

## Final Checklist

- [ ] `ECGQualityCompute.swift` created and registered in `project.pbxproj`; `ECGQualityComputeTests.swift` created and registered
- [ ] Flatline/lead-off detection: constant/near-zero-variance ECG window → Poor
- [ ] Clipping detection: sustained pinned-run → Poor; brief pinned-run → Okay; short run below the length gate → ignored (Good)
- [ ] `rrTier(fromSignalQuality:)` matches the design doc's 95%/80% thresholds
- [ ] `combinedTier` returns nil only when both sides are unavailable, and always reflects the worse of the two tiers
- [ ] `MetricsTick.ecgQuality` computed every tick in `MetricsEngine.compute`, not persisted to `MetricsHistoryPoint`/`HRVSample`
- [ ] Nav-bar pill shows a colored dot only when connected and data is available; Train/Actions tabs unaffected (default `nil`)
- [ ] BLE connection sheet shows the Signal Quality breakdown + tips when data is available
- [ ] Full test suite passes; full build succeeds
- [ ] No regressions in Live, Train, Actions, History, or Resonate tabs
