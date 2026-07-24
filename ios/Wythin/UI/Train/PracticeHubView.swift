import SwiftUI

// MARK: - Practices Hub
//
// Replaces the old single-screen Train view. Browse teacher-led practices by
// category, open one to Log it, or start a live biofeedback session (Resonance
// pacer / workout feedback). Content is served from the static PracticeCatalog.

struct PracticeHubView: View {
    @Environment(AppEnvironment.self) var env

    @State private var filter:   PracticeCategory? = nil     // nil = All
    @State private var selected: Practice?         = nil
    @State private var showBLESheet                = false

    /// Practices for the current filter. When unfiltered, Resonance is pulled
    /// out into the featured card so it isn't listed twice.
    private var visiblePractices: [Practice] {
        let all = filter.map { PracticeCatalog.practices(in: $0) } ?? PracticeCatalog.practices
        return filter == nil ? all.filter { !$0.isStarred } : all
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    categoryBar

                    if filter == nil, let resonance = PracticeCatalog.starred.first {
                        FeaturedPracticeCard(practice: resonance) { selected = resonance }
                    }

                    LazyVStack(spacing: 10) {
                        ForEach(visiblePractices) { practice in
                            Button { selected = practice } label: {
                                PracticeCard(practice: practice)
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    teachersStrip
                }
                .padding(.horizontal)
                .padding(.top, 12)
                .padding(.bottom, 24)
            }
            .background(Theme.bg)
            .navigationTitle("PRACTICE")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.bg, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    BLENavButton(state: env.ble.state,
                                 bpm: env.latestTick?.meanBPM) {
                        showBLESheet = true
                    }
                }
            }
            .sheet(isPresented: $showBLESheet) {
                BLEConnectionSheet(ble: env.ble)
            }
            .sheet(item: $selected) { practice in
                PracticeDetailView(practice: practice)
            }
        }
    }

    // MARK: Category bar

    private var categoryBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                CategoryCapsule(label: "All", isSelected: filter == nil) { filter = nil }
                ForEach(PracticeCategory.allCases) { cat in
                    CategoryCapsule(label: cat.label, isSelected: filter == cat) {
                        filter = (filter == cat) ? nil : cat
                    }
                }
            }
            .padding(.vertical, 2)
        }
    }

    // MARK: Teachers strip

    private var teachersStrip: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("TEACHERS")
                .font(Theme.monoLabel)
                .foregroundStyle(Theme.dim)
                .frame(maxWidth: .infinity, alignment: .leading)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    ForEach(PracticeCatalog.teachers) { teacher in
                        TeacherChip(teacher: teacher)
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .padding(.top, 4)
    }
}

// MARK: - Category capsule

private struct CategoryCapsule: View {
    let label:      String
    let isSelected: Bool
    let action:     () -> Void

    var body: some View {
        Button(action: action) {
            Text(label.uppercased())
                .font(Theme.monoLabel)
                .foregroundStyle(isSelected ? Theme.bg : Theme.accent)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(isSelected ? Theme.accent : Theme.card)
                .clipShape(Capsule())
                .overlay(Capsule().strokeBorder(Theme.border, lineWidth: 0.5))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Art thumbnail

/// The shared SF-symbol-over-gradient tile used for practices and teachers.
struct ArtThumb: View {
    let art:  PracticeArt
    var size: CGFloat = 48

    var body: some View {
        RoundedRectangle(cornerRadius: 12)
            .fill(art.gradient)
            .frame(width: size, height: size)
            .overlay(
                Image(systemName: art.symbol)
                    .font(.system(size: size * 0.4, weight: .medium))
                    .foregroundStyle(.white.opacity(0.95))
            )
    }
}

// MARK: - Practice card

private struct PracticeCard: View {
    let practice: Practice

    private var teacherName: String {
        PracticeCatalog.teacher(practice.teacherID)?.name ?? ""
    }

    var body: some View {
        HStack(spacing: 12) {
            ArtThumb(art: practice.art, size: 48)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(practice.title)
                        .font(.system(size: 14, weight: .medium, design: .monospaced))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                    if practice.isStarred {
                        Image(systemName: "star.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.accent)
                    } else if practice.isBiofeedback {
                        Image(systemName: "waveform.path.ecg")
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.breathe)
                    }
                }
                Text(practice.subtitle)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.dim)
                    .lineLimit(1)
                Text("\(teacherName) · \(practice.defaultDurationMins) min")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Theme.dim.opacity(0.8))
                    .lineLimit(1)
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.system(size: 11))
                .foregroundStyle(Theme.dim.opacity(0.4))
        }
        .padding(12)
        .background(Theme.card)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.border, lineWidth: 0.5))
    }
}

// MARK: - Featured card

private struct FeaturedPracticeCard: View {
    let practice: Practice
    let action:   () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                practice.art.gradient
                    .overlay(
                        Image(systemName: practice.art.symbol)
                            .font(.system(size: 50, weight: .light))
                            .foregroundStyle(.white.opacity(0.85))
                    )
                    .overlay(alignment: .topLeading) {
                        HStack(spacing: 5) {
                            Image(systemName: "star.fill").font(.system(size: 10))
                            Text("FEATURED").font(Theme.monoLabel)
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(.black.opacity(0.25), in: Capsule())
                        .padding(12)
                    }
                    .frame(height: 118)
                    .frame(maxWidth: .infinity)
                    .clipped()

                VStack(alignment: .leading, spacing: 4) {
                    Text(practice.title)
                        .font(Theme.mono(18))
                        .foregroundStyle(Theme.text)
                    Text(practice.subtitle)
                        .font(Theme.monoBody)
                        .foregroundStyle(Theme.dim)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Theme.card)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Theme.accent.opacity(0.3), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Teacher chip

private struct TeacherChip: View {
    let teacher: Teacher

    var body: some View {
        VStack(spacing: 8) {
            ArtThumb(art: teacher.art, size: 56)
            Text(teacher.name)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(Theme.text)
                .lineLimit(1)
            Text(teacher.title)
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(Theme.dim)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(width: 96)
    }
}
