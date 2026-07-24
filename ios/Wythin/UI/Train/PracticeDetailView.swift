import SwiftUI

// MARK: - Practice Detail
//
// Opened from the hub. Shows the practice hero, teacher, meta and description,
// then dispatches actions on the practice's kind:
//   .content              → Log it (prefilled)
//   .biofeedback(.resonance) → Start Resonance pacer  + Log it
//   .biofeedback(.workout)   → Start live workout feedback + Log it

struct PracticeDetailView: View {
    let practice: Practice

    @Environment(\.modelContext) var ctx
    @Environment(AppEnvironment.self) var env
    @Environment(\.dismiss) var dismiss

    @State private var showLogSheet    = false
    @State private var showResonance   = false
    @State private var showBiofeedback = false

    private var teacher: Teacher? { PracticeCatalog.teacher(practice.teacherID) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    hero
                    if let t = teacher { teacherRow(t) }
                    metaRow
                    if !practice.tags.isEmpty { tagRow }
                    Text(practice.description)
                        .font(Theme.monoBody)
                        .foregroundStyle(Theme.text.opacity(0.85))
                        .fixedSize(horizontal: false, vertical: true)
                    VStack(spacing: 10) { actions }
                        .padding(.top, 4)
                }
                .padding(.horizontal)
                .padding(.top, 12)
                .padding(.bottom, 28)
            }
            .background(Theme.bg)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.bg, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Close") { dismiss() }
                        .font(Theme.monoLabel)
                        .foregroundStyle(Theme.dim)
                }
            }
        }
        .sheet(isPresented: $showLogSheet) {
            LogPastSheet(prefill: ActivityPrefill(type: practice.activityType,
                                                  subtype: practice.subtype,
                                                  durationMins: Double(practice.defaultDurationMins))) {
                type, subtype, name, start, end in
                ActivityLogging.logPast(type: type, subtype: subtype, customName: name,
                                        start: start, end: end,
                                        context: ctx, client: env.sync.client)
            }
        }
        .fullScreenCover(isPresented: $showResonance) {
            ResonanceSessionView()
        }
        .fullScreenCover(isPresented: $showBiofeedback) {
            BiofeedbackSessionView(activityType: practice.activityType,
                                   subtype: practice.subtype)
        }
    }

    // MARK: Hero

    private var hero: some View {
        ZStack(alignment: .bottomLeading) {
            practice.art.gradient
                .overlay(
                    Image(systemName: practice.art.symbol)
                        .font(.system(size: 60, weight: .light))
                        .foregroundStyle(.white.opacity(0.85))
                )
                .overlay(
                    LinearGradient(colors: [.clear, .black.opacity(0.55)],
                                   startPoint: .center, endPoint: .bottom)
                )

            VStack(alignment: .leading, spacing: 5) {
                if practice.isStarred {
                    HStack(spacing: 5) {
                        Image(systemName: "star.fill").font(.system(size: 10))
                        Text("FEATURED").font(Theme.monoLabel)
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.black.opacity(0.25), in: Capsule())
                }
                Text(practice.title)
                    .font(Theme.display(26))
                    .foregroundStyle(.white)
                Text(practice.subtitle)
                    .font(Theme.monoBody)
                    .foregroundStyle(.white.opacity(0.9))
            }
            .padding(16)
        }
        .frame(height: 190)
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 18))
    }

    // MARK: Teacher row

    private func teacherRow(_ t: Teacher) -> some View {
        HStack(spacing: 10) {
            ArtThumb(art: t.art, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(t.name).font(Theme.mono(14)).foregroundStyle(Theme.text)
                Text(t.title).font(Theme.monoLabel).foregroundStyle(Theme.dim)
            }
            Spacer()
        }
    }

    // MARK: Meta + tags

    private var metaRow: some View {
        HStack(spacing: 16) {
            metaItem(icon: "clock", text: "\(practice.defaultDurationMins) min")
            metaItem(icon: practice.activityType.icon,
                     text: practice.subtype ?? practice.activityType.rawValue)
            metaItem(icon: "square.grid.2x2", text: practice.category.label)
            Spacer()
        }
    }

    private func metaItem(icon: String, text: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon).font(.system(size: 11)).foregroundStyle(Theme.accent)
            Text(text).font(Theme.monoLabel).foregroundStyle(Theme.dim)
        }
    }

    private var tagRow: some View {
        HStack(spacing: 8) {
            ForEach(practice.tags, id: \.self) { tag in
                Text(tag)
                    .font(Theme.monoLabel)
                    .foregroundStyle(Theme.breathe)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Theme.breathe.opacity(0.12))
                    .clipShape(Capsule())
            }
            Spacer()
        }
    }

    // MARK: Actions

    @ViewBuilder
    private var actions: some View {
        switch practice.kind {
        case .content:
            actionButton(title: "Log it", icon: "checkmark.circle", filled: true) {
                showLogSheet = true
            }
        case .biofeedback(.resonance):
            actionButton(title: "Start Resonance", icon: "sparkles", filled: true) {
                showResonance = true
            }
            actionButton(title: "Log it", icon: "checkmark.circle", filled: false) {
                showLogSheet = true
            }
        case .biofeedback(.workout):
            actionButton(title: "Start Session", icon: "waveform.path.ecg", filled: true) {
                showBiofeedback = true
            }
            actionButton(title: "Log it", icon: "checkmark.circle", filled: false) {
                showLogSheet = true
            }
        }
    }

    private func actionButton(title: String, icon: String, filled: Bool,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                Text(title)
            }
            .font(Theme.mono(15))
            .fontWeight(.medium)
            .foregroundStyle(filled ? Theme.bg : Theme.accent)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(filled ? Theme.accent : Theme.card)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14)
                .strokeBorder(filled ? Color.clear : Theme.accent.opacity(0.4), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}
