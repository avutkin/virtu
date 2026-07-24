import Foundation
import SwiftUI
import SwiftData

// MARK: - ActivityType

enum ActivityType: String, CaseIterable, Codable {
    case exercise     = "Exercise"
    case walk         = "Walk"
    case run          = "Run"
    case meditation   = "Meditation"
    case breathwork   = "Breathwork"
    case meal         = "Meal"
    case nap          = "Nap"
    case coldExposure = "Cold Exposure"
    case sauna        = "Sauna"
    case alcohol      = "Alcohol"
    case custom       = "Custom"

    var icon: String {
        switch self {
        case .exercise:     return "dumbbell"
        case .walk:         return "figure.walk"
        case .run:          return "figure.run"
        case .meditation:   return "brain.head.profile"
        case .breathwork:   return "lungs"
        case .meal:         return "fork.knife"
        case .nap:          return "moon.zzz"
        case .coldExposure: return "thermometer.snowflake"
        case .sauna:        return "flame"
        case .alcohol:      return "wineglass"
        case .custom:       return "pencil.circle"
        }
    }

    var color: Color {
        switch self {
        case .exercise, .run:    return Theme.warn
        case .walk:              return Theme.accent
        case .meditation:        return Theme.hrv
        case .breathwork:        return Theme.breathe
        case .meal:              return Theme.rsa
        case .nap:               return Theme.ulf
        case .coldExposure:      return Color(hex: "#67E8F9")
        case .sauna:             return Color(hex: "#FCD34D")
        case .alcohol:           return Color(hex: "#F9A8D4")
        case .custom:            return Theme.dim
        }
    }

    var subtypes: [String] {
        switch self {
        case .exercise:
            return ["Yoga", "HIIT", "Power Lifting", "Pilates", "Cycling",
                    "Swimming", "Stretching", "CrossFit", "Boxing",
                    "Rowing", "Climbing", "Martial Arts"]
        case .walk:
            return ["Nature Walk", "City Walk", "Hiking", "Treadmill"]
        case .run:
            return ["Easy Run", "Tempo Run", "Intervals", "Long Run", "Trail Run", "Race"]
        case .meditation:
            return ["Vipassana", "Guided", "Body Scan", "Loving-Kindness",
                    "Transcendental", "Zen", "Mantra", "Open Awareness", "Yoga Nidra"]
        case .breathwork:
            return ["Resonance", "Wim Hof", "Box Breathing", "4-7-8", "Holotropic",
                    "Pranayama", "Coherent Breathing", "Tummo", "Nadi Shodhana"]
        case .meal:
            return ["Breakfast", "Lunch", "Dinner", "Snack", "Fast Breaking"]
        case .nap:
            return ["Power Nap", "Full Cycle"]
        case .coldExposure:
            return ["Cold Shower", "Ice Bath", "Cold Plunge", "Cryotherapy"]
        case .sauna:
            return ["Finnish", "Infrared", "Steam"]
        case .alcohol:
            return ["Beer", "Wine", "Spirits", "Cocktail"]
        case .custom:
            return []
        }
    }

    // Hour ranges (start inclusive) for time-of-day fallback pre-selection
    var defaultHours: [Int] {
        switch self {
        case .meditation:   return [5, 6, 7, 8, 21, 22]
        case .walk:         return [7, 8, 9, 16, 17, 18]
        case .exercise:     return [9, 10, 15, 16, 17]
        case .run:          return [6, 7, 8, 17, 18]
        case .meal:         return [7, 8, 12, 13, 18, 19, 20]
        case .breathwork:   return [6, 7, 21, 22]
        case .nap:          return [13, 14, 15]
        case .coldExposure: return [7, 8, 9]
        case .sauna:        return [18, 19, 20]
        case .alcohol:      return [19, 20, 21]
        case .custom:       return []
        }
    }
}

// MARK: - ActivityLog

/// One logged activity entry (live-tracked or retrospective).
@Model
final class ActivityLog {

    @Attribute(.unique) var id: UUID
    var activityType:    String   // ActivityType.rawValue; "Custom" uses customName
    var activitySubtype: String? // optional subtype, e.g. "Yoga" for Exercise
    var customName:      String? // only set when activityType == "Custom"
    var startedAt:       Date
    var endedAt:         Date?
    var notes:           String?
    var isManual:        Bool    // true = retrospective entry

    /// OpenAI-generated interpretation + recommendation for this activity's
    /// HRV response. `nil` means "not yet generated" — eligible for retry
    /// by `InsightGenerator.flushPending`.
    var insightText:     String?

    // HRV averages: 5-min before / during / 10-min after
    var beforeHR:    Float?;  var duringHR:    Float?;  var afterHR:    Float?
    var beforeSDNN:  Float?;  var duringSDNN:  Float?;  var afterSDNN:  Float?
    var beforeRSA:   Float?;  var duringRSA:   Float?;  var afterRSA:   Float?
    var beforeVTI:   Float?;  var duringVTI:   Float?;  var afterVTI:   Float?
    var beforeLFHF:  Float?;  var duringLFHF:  Float?;  var afterLFHF:  Float?
    // Stress Balance as the Live view shows it: the breathing-robust 0–100
    // autonomic dial (SNS %), not the raw LF/HF ratio.
    var beforeStress: Float?;  var duringStress: Float?;  var afterStress: Float?
    var beforeRMSSD: Float?;  var duringRMSSD: Float?;  var afterRMSSD: Float?
    var beforeRCMSE: Float?;  var duringRCMSE: Float?;  var afterRCMSE: Float?
    var beforePIP:   Float?;  var duringPIP:   Float?;  var afterPIP:   Float?
    var beforeDC:    Float?;  var duringDC:    Float?;  var afterDC:    Float?
    var beforeDFA1:  Float?;  var duringDFA1:  Float?;  var afterDFA1:  Float?

    init(activityType:    String,
         activitySubtype: String? = nil,
         customName:      String? = nil,
         startedAt:       Date    = .now,
         endedAt:         Date?   = nil,
         isManual:        Bool    = false) {
        self.id              = UUID()
        self.activityType    = activityType
        self.activitySubtype = activitySubtype
        self.customName      = customName
        self.startedAt       = startedAt
        self.endedAt         = endedAt
        self.isManual        = isManual
    }

    var isActive: Bool { endedAt == nil && !isManual }

    var displayName: String {
        if let sub = activitySubtype { return sub }
        if activityType == ActivityType.custom.rawValue { return customName ?? "Custom" }
        return activityType
    }

    /// The parent type label (e.g. "Exercise" even when displayName is "Yoga")
    var typeLabel: String {
        activityType == ActivityType.custom.rawValue ? (customName ?? "Custom") : activityType
    }

    var activityTypeEnum: ActivityType {
        ActivityType(rawValue: activityType) ?? .custom
    }

    var duration: TimeInterval? {
        endedAt.map { $0.timeIntervalSince(startedAt) }
    }

    var durationString: String {
        guard let d = duration else { return "—" }
        let mins = Int((d / 60).rounded())
        return mins < 60 ? "\(mins) min" : String(format: "%d h %02d min", mins / 60, mins % 60)
    }

    /// RSA delta during practice (during − before). Positive = nervous system activated/improved.
    var rsaDelta: Float? {
        guard let a = duringRSA, let b = beforeRSA else { return nil }
        return a - b
    }

    var vtiDelta: Float? {
        guard let a = duringVTI, let b = beforeVTI else { return nil }
        return a - b
    }

    var sdnnDelta: Float? {
        guard let a = duringSDNN, let b = beforeSDNN else { return nil }
        return a - b
    }

    /// RSA recovery delta (after − before).
    var rsaRecoveryDelta: Float? {
        guard let a = afterRSA, let b = beforeRSA else { return nil }
        return a - b
    }

    // MARK: HRV window computation

    /// Queries HRVSample records for the three windows around this activity
    /// and stores per-metric averages. Call after setting `endedAt`.
    func computeHRVWindows(context: ModelContext) {
        guard let end = endedAt else { return }
        let beforeStart = startedAt.addingTimeInterval(-300)   // 5 min before
        let afterEnd    = end.addingTimeInterval(600)           // 10 min after

        let allPredicate = #Predicate<HRVSample> {
            $0.timestamp >= beforeStart && $0.timestamp <= afterEnd
        }
        var desc = FetchDescriptor<HRVSample>(
            predicate: allPredicate,
            sortBy: [SortDescriptor(\.timestamp)]
        )
        desc.fetchLimit = 2_000
        guard let samples = try? context.fetch(desc) else { return }

        let before = samples.filter { $0.timestamp >= beforeStart && $0.timestamp < startedAt }
        let during = samples.filter { $0.timestamp >= startedAt   && $0.timestamp <= end       }
        let after  = samples.filter { $0.timestamp > end          && $0.timestamp <= afterEnd  }

        func avg(_ arr: [HRVSample], _ kp: KeyPath<HRVSample, Float?>) -> Float? {
            let vals = arr.compactMap { $0[keyPath: kp] }
            guard !vals.isEmpty else { return nil }
            return vals.reduce(0, +) / Float(vals.count)
        }

        // VTI must be computed as ln(mean(RMSSD)), NOT mean(ln(RMSSD)),
        // to preserve the nonlinear relationship between VTI and RMSSD.
        func vtiFromRMSSD(_ arr: [HRVSample]) -> Float? {
            guard let meanRMSSD = avg(arr, \.rmssd), meanRMSSD > 0 else { return nil }
            return log(meanRMSSD)
        }

        // Stress Balance dial (0–100 SNS %), matching the Live view: compute the
        // breathing-robust balance per sample, then average over the window.
        func stressDial(_ arr: [HRVSample]) -> Float? {
            let vals = arr.compactMap { s in
                AutonomicCompute.balance(rmssd: s.rmssd, lf: s.lfPower, hf: s.hfPower,
                                         breathBPM: s.breathBPM, meanBPM: s.meanBPM,
                                         baselineRmssd: nil).map { $0.sns * 100 }
            }
            guard !vals.isEmpty else { return nil }
            return vals.reduce(0, +) / Float(vals.count)
        }

        beforeHR    = avg(before, \.meanBPM);   duringHR    = avg(during, \.meanBPM);   afterHR    = avg(after, \.meanBPM)
        beforeSDNN  = avg(before, \.sdnn);       duringSDNN  = avg(during, \.sdnn);       afterSDNN  = avg(after, \.sdnn)
        beforeRSA   = avg(before, \.rsaMs);      duringRSA   = avg(during, \.rsaMs);      afterRSA   = avg(after, \.rsaMs)
        beforeVTI   = vtiFromRMSSD(before);      duringVTI   = vtiFromRMSSD(during);      afterVTI   = vtiFromRMSSD(after)
        beforeLFHF  = avg(before, \.lfHF);       duringLFHF  = avg(during, \.lfHF);       afterLFHF  = avg(after, \.lfHF)
        beforeStress = stressDial(before);       duringStress = stressDial(during);       afterStress = stressDial(after)
        beforeRMSSD = avg(before, \.rmssd);      duringRMSSD = avg(during, \.rmssd);      afterRMSSD = avg(after, \.rmssd)
        beforeRCMSE = avg(before, \.rcmse);      duringRCMSE = avg(during, \.rcmse);      afterRCMSE = avg(after, \.rcmse)
        beforePIP   = avg(before, \.pip);        duringPIP   = avg(during, \.pip);        afterPIP   = avg(after, \.pip)
        beforeDC    = avg(before, \.dc);         duringDC    = avg(during, \.dc);         afterDC    = avg(after, \.dc)
        beforeDFA1  = avg(before, \.dfa1);       duringDFA1  = avg(during, \.dfa1);       afterDFA1  = avg(after, \.dfa1)
    }
}
