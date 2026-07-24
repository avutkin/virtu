import Foundation

// MARK: - PracticeCatalog
//
// Seed content for the Practices hub. All teachers and practices here are
// original placeholders (fictional names, original copy) so the hub is
// browsable and testable before any real content pipeline exists.

enum PracticeCatalog {

    static let teachers: [Teacher] = [
        Teacher(id: "mara-quinn",  name: "Mara Quinn",  title: "Breathwork Guide",
                bio: "Mara teaches slow, paced breathing to steady the nervous system and build calm you can return to any time.",
                art: PracticeArt(symbol: "lungs", hexStops: ["#58A6FF", "#1E3A5F"])),
        Teacher(id: "elias-vance", name: "Elias Vance", title: "Meditation Teacher",
                bio: "Elias offers quiet, unforced meditations — space to notice the mind and let it settle.",
                art: PracticeArt(symbol: "brain.head.profile", hexStops: ["#818CF8", "#312E81"])),
        Teacher(id: "noor-haddad", name: "Noor Haddad", title: "Movement Coach",
                bio: "Noor blends mobility and mindful movement to release tension and reconnect body and breath.",
                art: PracticeArt(symbol: "figure.yoga", hexStops: ["#34D399", "#065F46"])),
        Teacher(id: "theo-brandt", name: "Theo Brandt", title: "Strength & Endurance",
                bio: "Theo coaches strength and easy-pace endurance work, with live biofeedback to keep effort honest.",
                art: PracticeArt(symbol: "figure.strengthtraining.traditional", hexStops: ["#FB7185", "#7F1D1D"])),
    ]

    static let practices: [Practice] = [
        // ── Featured biofeedback ──────────────────────────────────────────
        Practice(
            id: "resonance", title: "Resonance", subtitle: "Find your coherent breath",
            teacherID: "mara-quinn", category: .recovery,
            activityType: .breathwork, subtype: "Resonance", defaultDurationMins: 10,
            description: "A guided pacer that walks your breath toward ~6 breaths a minute — the rhythm where heart-rate variability peaks. Live coherence, breath rate and RSA show you when you've found the groove.",
            tags: ["Coherence", "Vagal Tone", "Calm"],
            art: PracticeArt(symbol: "sparkles", hexStops: ["#00E5A0", "#134E4A"]),
            kind: .biofeedback(.resonance)),

        // ── Breathwork ────────────────────────────────────────────────────
        Practice(
            id: "coherent-calm", title: "Coherent Calm", subtitle: "Even in, even out",
            teacherID: "mara-quinn", category: .breathwork,
            activityType: .breathwork, subtype: "Coherent Breathing", defaultDurationMins: 8,
            description: "A simple equal-ratio breath to down-shift the stress response and steady your focus in a few minutes.",
            tags: ["Focus", "Down-regulate"],
            art: PracticeArt(symbol: "wind", hexStops: ["#58A6FF", "#1E3A5F"]),
            kind: .content),
        Practice(
            id: "wind-down-breath", title: "Wind-Down Breath", subtitle: "4-7-8 before sleep",
            teacherID: "mara-quinn", category: .recovery,
            activityType: .breathwork, subtype: "4-7-8", defaultDurationMins: 6,
            description: "A longer-exhale pattern to release the day and prime your body for rest.",
            tags: ["Sleep", "Relax"],
            art: PracticeArt(symbol: "moon.stars", hexStops: ["#A78BFA", "#312E81"]),
            kind: .content),

        // ── Meditation ────────────────────────────────────────────────────
        Practice(
            id: "body-scan", title: "Body Scan", subtitle: "Settle into the body",
            teacherID: "elias-vance", category: .meditation,
            activityType: .meditation, subtype: "Body Scan", defaultDurationMins: 15,
            description: "Move attention slowly through the body, softening what's held and returning to the present.",
            tags: ["Grounding", "Awareness"],
            art: PracticeArt(symbol: "figure.mind.and.body", hexStops: ["#818CF8", "#312E81"]),
            kind: .content),
        Practice(
            id: "morning-stillness", title: "Morning Stillness", subtitle: "Begin with clarity",
            teacherID: "elias-vance", category: .meditation,
            activityType: .meditation, subtype: "Guided", defaultDurationMins: 10,
            description: "A short guided sit to clear mental clutter and set a steady tone for the day.",
            tags: ["Morning", "Clarity"],
            art: PracticeArt(symbol: "sunrise", hexStops: ["#FCD34D", "#78350F"]),
            kind: .content),
        Practice(
            id: "loving-kindness", title: "Loving-Kindness", subtitle: "Warmth toward yourself",
            teacherID: "elias-vance", category: .meditation,
            activityType: .meditation, subtype: "Loving-Kindness", defaultDurationMins: 12,
            description: "Offer simple phrases of goodwill — to yourself and outward — to soften a busy or critical mind.",
            tags: ["Compassion", "Heart"],
            art: PracticeArt(symbol: "heart", hexStops: ["#F9A8D4", "#831843"]),
            kind: .content),

        // ── Movement ──────────────────────────────────────────────────────
        Practice(
            id: "grounding-flow", title: "Grounding Flow", subtitle: "Slow, breath-led yoga",
            teacherID: "noor-haddad", category: .movement,
            activityType: .exercise, subtype: "Yoga", defaultDurationMins: 20,
            description: "A gentle flow that links movement to breath, releasing the hips, spine and shoulders.",
            tags: ["Mobility", "Flexibility"],
            art: PracticeArt(symbol: "figure.yoga", hexStops: ["#34D399", "#065F46"]),
            kind: .content),
        Practice(
            id: "slow-mobility", title: "Slow Mobility", subtitle: "Open and reset",
            teacherID: "noor-haddad", category: .movement,
            activityType: .exercise, subtype: "Stretching", defaultDurationMins: 15,
            description: "Unhurried mobility work to undo the stiffness of sitting and move more freely.",
            tags: ["Recovery", "Range"],
            art: PracticeArt(symbol: "figure.flexibility", hexStops: ["#6EE7B7", "#065F46"]),
            kind: .content),

        // ── Movement · biofeedback workouts ───────────────────────────────
        Practice(
            id: "strength-set", title: "Strength Set", subtitle: "Lift with live feedback",
            teacherID: "theo-brandt", category: .movement,
            activityType: .exercise, subtype: "Power Lifting", defaultDurationMins: 30,
            description: "Run a strength session with live autonomic balance and heart-rate recovery so you can gauge effort and rest between sets.",
            tags: ["Strength", "Biofeedback"],
            art: PracticeArt(symbol: "figure.strengthtraining.traditional", hexStops: ["#FB7185", "#7F1D1D"]),
            kind: .biofeedback(.workout)),
        Practice(
            id: "zone-2-run", title: "Zone 2 Run", subtitle: "Easy aerobic pace",
            teacherID: "theo-brandt", category: .movement,
            activityType: .run, subtype: "Easy Run", defaultDurationMins: 30,
            description: "Keep it conversational. Live HR and recovery help you hold an easy aerobic zone and build a base.",
            tags: ["Endurance", "Biofeedback"],
            art: PracticeArt(symbol: "figure.run", hexStops: ["#F97316", "#7C2D12"]),
            kind: .biofeedback(.workout)),
    ]

    // MARK: Lookups

    static func teacher(_ id: String) -> Teacher? {
        teachers.first { $0.id == id }
    }

    static func practices(in category: PracticeCategory) -> [Practice] {
        practices.filter { $0.category == category }
    }

    static func practices(byTeacher id: String) -> [Practice] {
        practices.filter { $0.teacherID == id }
    }

    static var starred: [Practice] {
        practices.filter(\.isStarred)
    }
}
