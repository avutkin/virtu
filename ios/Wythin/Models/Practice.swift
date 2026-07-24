import SwiftUI

// MARK: - Practice content domain
//
// Static, in-app content (teacher-led practices) — NOT SwiftData records, so no
// @Model and no schema entry. Each Practice maps to an existing `ActivityType`
// (+ optional subtype) so logging reuses the whole ActivityLog pipeline.

struct Teacher: Identifiable, Hashable {
    let id:    String          // stable slug, e.g. "mara-quinn"
    let name:  String
    let title: String          // e.g. "Breathwork Guide"
    let bio:   String
    let art:   PracticeArt
}

enum PracticeCategory: String, CaseIterable, Identifiable {
    case breathwork, meditation, movement, recovery
    var id: String { rawValue }
    var label: String {
        switch self {
        case .breathwork: return "Breathwork"
        case .meditation: return "Meditation"
        case .movement:   return "Movement"
        case .recovery:   return "Recovery"
        }
    }
}

enum BiofeedbackMode: Equatable, Hashable { case resonance, workout }

enum PracticeKind: Equatable, Hashable {
    case content                        // browse + Log it
    case biofeedback(BiofeedbackMode)   // live session (resonance pacer / workout feedback)
}

/// Local art token — an SF Symbol over a two-stop gradient. There is no remote
/// image loading in the app, so every practice/teacher paints from this.
struct PracticeArt: Hashable {
    let symbol:   String       // SF Symbol name
    let hexStops: [String]     // two hex colours → LinearGradient via Color(hex:)

    var gradient: LinearGradient {
        LinearGradient(colors: hexStops.map { Color(hex: $0) },
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

struct Practice: Identifiable, Hashable {
    let id:                  String
    let title:               String
    let subtitle:            String
    let teacherID:           String
    let category:            PracticeCategory
    let activityType:        ActivityType   // reuse the logging enum
    let subtype:             String?        // must be a member of activityType.subtypes
    let defaultDurationMins: Int
    let description:         String
    let tags:                [String]
    let art:                 PracticeArt
    let kind:                PracticeKind

    /// Resonance is the featured biofeedback practice — shown with a ★.
    var isStarred: Bool { kind == .biofeedback(.resonance) }

    var isBiofeedback: Bool {
        if case .biofeedback = kind { return true }
        return false
    }
}
