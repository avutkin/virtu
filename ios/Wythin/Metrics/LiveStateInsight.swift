import SwiftUI

// MARK: - LiveState

/// One of the nine canonical nervous-system states the live insight can report.
/// The server sends the snake_case key on the first line; the app owns the
/// icon, accent color and emotional tone so rendering stays consistent even as
/// the LLM varies the wording.
enum LiveState: String, CaseIterable {
    case overloadedExhausted  = "overloaded_exhausted"
    case stressedActivated    = "stressed_activated"
    case engagedPerforming    = "engaged_performing"
    case depletedNumb         = "depleted_numb"
    case stableNeutral        = "stable_neutral"
    case calmAlert            = "calm_alert"
    case shutdownBurnout      = "shutdown_burnout"
    case recoveringResetting  = "recovering_resetting"
    case renewedThriving      = "renewed_thriving"

    /// How the copy should feel — drives the recommendation block's accent.
    enum Tone { case supportive, steady, pushing }

    /// Canonical name, used as a fallback when the LLM omits a personal title.
    var canonicalName: String {
        switch self {
        case .overloadedExhausted: return "Overloaded & Exhausted"
        case .stressedActivated:   return "Stressed & Activated"
        case .engagedPerforming:   return "Engaged & Performing"
        case .depletedNumb:        return "Depleted & Numb"
        case .stableNeutral:       return "Stable & Neutral"
        case .calmAlert:           return "Calm & Alert"
        case .shutdownBurnout:     return "Shutdown & Burnout"
        case .recoveringResetting: return "Recovering & Resetting"
        case .renewedThriving:     return "Renewed & Thriving"
        }
    }

    var iconName: String {
        switch self {
        case .overloadedExhausted: return "exclamationmark.triangle.fill"
        case .stressedActivated:   return "bolt.fill"
        case .engagedPerforming:   return "target"
        case .depletedNumb:        return "battery.25percent"
        case .stableNeutral:       return "equal.circle.fill"
        case .calmAlert:           return "sparkles"
        case .shutdownBurnout:     return "moon.zzz.fill"
        case .recoveringResetting: return "arrow.clockwise.heart.fill"
        case .renewedThriving:     return "sun.max.fill"
        }
    }

    var color: Color {
        switch self {
        case .overloadedExhausted: return Theme.warn
        case .stressedActivated:   return Theme.rsa
        case .engagedPerforming:   return Theme.accent
        case .depletedNumb:        return Theme.hrv
        case .stableNeutral:       return Theme.breathe
        case .calmAlert:           return Theme.accent
        case .shutdownBurnout:     return Theme.warn
        case .recoveringResetting: return Theme.coh
        case .renewedThriving:     return Theme.accent
        }
    }

    var tone: Tone {
        switch self {
        case .overloadedExhausted, .stressedActivated, .depletedNumb, .shutdownBurnout:
            return .supportive
        case .stableNeutral, .recoveringResetting:
            return .steady
        case .engagedPerforming, .calmAlert, .renewedThriving:
            return .pushing
        }
    }
}

// MARK: - LiveStateInsight

/// Parsed form of the server's live-state reply:
///   `<state_key> | <title>` / `• bullet` lines / `→ recommendation`.
struct LiveStateInsight {
    let state: LiveState?     // nil when the key isn't recognized
    let title: String
    let bullets: [String]
    let recommendation: String?

    /// Best-effort parse. Never throws — an unexpected shape still yields a
    /// title (so the widget shows something) with whatever bullets it found.
    init(raw: String) {
        let lines = raw
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        var state: LiveState?
        var title = ""
        var bullets: [String] = []
        var recommendation: String?

        for (idx, line) in lines.enumerated() {
            if idx == 0 {
                // "<key> | <title>" — either part may be missing.
                if let sep = line.range(of: "|") {
                    let key = String(line[..<sep.lowerBound]).trimmingCharacters(in: .whitespaces)
                    let rest = String(line[sep.upperBound...]).trimmingCharacters(in: .whitespaces)
                    state = LiveState(rawValue: key)
                    title = rest.isEmpty ? (state?.canonicalName ?? key) : rest
                } else {
                    state = LiveState(rawValue: line)
                    title = state?.canonicalName ?? line
                }
            } else if line.hasPrefix("→") {
                recommendation = String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("•") {
                bullets.append(String(line.dropFirst()).trimmingCharacters(in: .whitespaces))
            } else {
                bullets.append(line)
            }
        }

        self.state = state
        self.title = title
        self.bullets = bullets
        self.recommendation = recommendation
    }
}
