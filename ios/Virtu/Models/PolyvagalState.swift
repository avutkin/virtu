import SwiftUI

// MARK: - Cause

struct PolyvagalCause: Identifiable {
    let id = UUID()
    let icon:        String
    let title:       String
    let description: String
    let time:        String
}

// MARK: - Science Fact

struct ScienceFact: Identifiable {
    let id = UUID()
    let title:       String
    let description: String
    let source:      String?
}

// MARK: - PolyvagalState

enum PolyvagalState {
    case regulated
    case elevated
    case low
    case unknown

    // MARK: Inference (priority-ordered — first match wins)

    static func infer(from tick: MetricsTick?) -> PolyvagalState {
        guard let t = tick, let rmssd = t.rmssd, let bpm = t.meanBPM else { return .unknown }
        let coh = t.coherenceScore ?? 0
        if rmssd < 25 && bpm < 62 && coh < 0.3 { return .low }
        if rmssd < 30 && bpm > 80               { return .elevated }
        if rmssd < 30                            { return .elevated }
        if rmssd > 35 && coh > 0.5              { return .regulated }
        return .regulated
    }

    // MARK: Display

    var displayName: String {
        switch self {
        case .regulated: return "Balanced"
        case .elevated:  return "Elevated"
        case .low:       return "Quiet"
        case .unknown:   return "Reading..."
        }
    }

    var severity: String {
        switch self {
        case .regulated: return "Optimal"
        case .elevated:  return "Moderate"
        case .low:       return "Low"
        case .unknown:   return "—"
        }
    }

    var severityProgress: Float {
        switch self {
        case .regulated: return 0.85
        case .elevated:  return 0.45
        case .low:       return 0.20
        case .unknown:   return 0.0
        }
    }

    var stateDescription: String {
        switch self {
        case .regulated: return "Your nervous system is calm and regulated. You're ready to focus or connect."
        case .elevated:  return "Your body is responding to stress. Your nervous system is in an activated state right now."
        case .low:       return "Your nervous system appears quiet or fatigued. Energy and engagement are low."
        case .unknown:   return "Connect your Polar H10 to see your current nervous system state."
        }
    }

    var color: Color {
        switch self {
        case .regulated: return Color(red: 0.18, green: 0.78, blue: 0.60)
        case .elevated:  return Color(red: 1.00, green: 0.62, blue: 0.22)
        case .low:       return Color(red: 0.42, green: 0.62, blue: 0.90)
        case .unknown:   return Color.gray
        }
    }

    // MARK: Causes

    func causes(from tick: MetricsTick?) -> [PolyvagalCause] {
        let timeFmt = DateFormatter()
        timeFmt.dateFormat = "HH:mm"
        let now = timeFmt.string(from: Date())

        switch self {
        case .elevated:
            var result: [PolyvagalCause] = []
            if let bpm = tick?.meanBPM, bpm > 74 {
                result.append(PolyvagalCause(
                    icon: "heart.fill",
                    title: "Elevated heart activity",
                    description: "HR above your baseline for 4+ min",
                    time: now))
            }
            if let rmssd = tick?.rmssd, rmssd < 35 {
                result.append(PolyvagalCause(
                    icon: "waveform.path.ecg",
                    title: "Reduced recovery response",
                    description: "Parasympathetic activity is suppressed",
                    time: now))
            }
            if let coh = tick?.coherenceScore, coh < 0.4 {
                result.append(PolyvagalCause(
                    icon: "lungs.fill",
                    title: "Breathing rhythm mismatch",
                    description: "Irregular breath-heart coupling detected",
                    time: now))
            }
            return result
        case .low:
            return [
                PolyvagalCause(icon: "battery.25", title: "Low energy state",
                               description: "Parasympathetic tone without activation", time: now),
                PolyvagalCause(icon: "waveform", title: "Suppressed HRV",
                               description: "Overall autonomic output is diminished", time: now),
            ]
        case .regulated:
            return [
                PolyvagalCause(icon: "checkmark.circle.fill", title: "Strong vagal tone",
                               description: "Parasympathetic system is active and balanced", time: now),
                PolyvagalCause(icon: "waveform.path.ecg", title: "Coherent HRV pattern",
                               description: "Heart rhythm is synchronized with breathing", time: now),
            ]
        case .unknown:
            return []
        }
    }

    // MARK: Action

    var actionTitle: String {
        switch self {
        case .regulated: return "Maintain Coherence"
        case .elevated:  return "90-Second Breathing Reset"
        case .low:       return "Activation Breath"
        case .unknown:   return "Connect Sensor"
        }
    }

    var actionDescription: String {
        switch self {
        case .regulated: return "You're in a great state. A short resonance session will deepen and sustain this."
        case .elevated:  return "A short guided breathing cycle to activate your parasympathetic nervous system and lower arousal."
        case .low:       return "Use energizing breath cycles to raise arousal and increase engagement."
        case .unknown:   return "Pair your Polar H10 to get personalized real-time recommendations."
        }
    }

    var actionOutcome: String {
        switch self {
        case .regulated: return "Sustained HRV · Peak focus"
        case .elevated:  return "Reduced arousal · Improved HRV"
        case .low:       return "Increased energy · Better focus"
        case .unknown:   return "Real-time guidance"
        }
    }

    var actionDuration: String {
        switch self {
        case .regulated: return "~5 min"
        case .elevated:  return "90 sec"
        case .low:       return "~2 min"
        case .unknown:   return ""
        }
    }

    var actionIcon: String {
        switch self {
        case .regulated: return "waveform.path.ecg"
        case .elevated:  return "wind"
        case .low:       return "bolt.fill"
        case .unknown:   return "antenna.radiowaves.left.and.right"
        }
    }

    var actionButtonLabel: String {
        switch self {
        case .regulated: return "Start Breathing Session"
        case .elevated:  return "Start Breathing Reset"
        case .low:       return "Start Activation"
        case .unknown:   return "Connect Device"
        }
    }

    // MARK: Science Facts

    var scienceFacts: [ScienceFact] {
        switch self {
        case .elevated:
            return [
                ScienceFact(title: "Vagus Nerve Activation",
                            description: "Stimulates the parasympathetic system to signal your body to relax.",
                            source: "Journal of Inflammation Research"),
                ScienceFact(title: "CO2 Regulation",
                            description: "Balances blood chemistry to physically reduce the fight-or-flight response.",
                            source: "Journal of Applied Physiology"),
                ScienceFact(title: "Heart-Breath Coupling",
                            description: "Synchronizes heart and breath rhythms to improve stress resilience.",
                            source: nil),
            ]
        case .regulated:
            return [
                ScienceFact(title: "RSA Amplification",
                            description: "Slow breathing at resonance maximizes respiratory sinus arrhythmia amplitude.",
                            source: "Applied Psychophysiology and Biofeedback"),
                ScienceFact(title: "Baroreflex Sensitivity",
                            description: "Coherent HRV training increases baroreflex gain for better blood pressure regulation.",
                            source: "Journal of Human Hypertension"),
                ScienceFact(title: "Prefrontal Engagement",
                            description: "High vagal tone supports executive function, focus, and emotional regulation.",
                            source: nil),
            ]
        case .low:
            return [
                ScienceFact(title: "Sympathetic Activation",
                            description: "Short bursts of fast breathing temporarily increase arousal and alertness.",
                            source: "Frontiers in Human Neuroscience"),
                ScienceFact(title: "Oxygen Delivery",
                            description: "Rhythmic diaphragmatic movement improves venous return and cerebral oxygenation.",
                            source: nil),
                ScienceFact(title: "Arousal Regulation",
                            description: "Controlled breathing cycles can shift the nervous system from dorsal to ventral vagal state.",
                            source: nil),
            ]
        case .unknown:
            return []
        }
    }
}
