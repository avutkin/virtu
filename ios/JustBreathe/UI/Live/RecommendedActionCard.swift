import SwiftUI

struct RecommendedActionCard: View {
    let state:    PolyvagalState
    let onAction: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Section header
            HStack {
                Text("Recommended Action")
                    .font(Theme.monoLabel)
                    .foregroundStyle(Theme.dim)
                Spacer()
                if !state.actionDuration.isEmpty {
                    Text(state.actionDuration)
                        .font(Theme.monoLabel)
                        .foregroundStyle(Theme.dim)
                }
            }
            .padding(.bottom, 10)

            // Main card
            VStack(alignment: .leading, spacing: 0) {
                actionHeader
                Divider().background(Theme.border).padding(.vertical, 14)
                scienceSection
                Divider().background(Theme.border).padding(.vertical, 14)
                buttons
            }
            .padding(16)
            .background(Theme.card)
            .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius))
            .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius)
                .strokeBorder(Theme.border, lineWidth: 0.5))
        }
    }

    // MARK: - Header

    private var actionHeader: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(state.actionTitle)
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(Theme.text)

            Text(state.actionDescription)
                .font(.system(size: 14))
                .foregroundStyle(Theme.dim)
                .fixedSize(horizontal: false, vertical: true)
                .lineSpacing(4)

            HStack(spacing: 8) {
                if !state.actionDuration.isEmpty {
                    PillBadge(icon: "clock", label: state.actionDuration)
                }
                PillBadge(icon: "chart.line.downtrend.xyaxis",
                          label: state.actionOutcome.components(separatedBy: " · ").first ?? "")
            }
        }
    }

    // MARK: - Science Section

    private var scienceSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Why it works?")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.text)

            ForEach(state.scienceFacts) { fact in
                ScienceCard(fact: fact)
            }
        }
    }

    // MARK: - Buttons

    private var buttons: some View {
        VStack(spacing: 8) {
            Button(action: onAction) {
                HStack(spacing: 8) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 13, weight: .semibold))
                    Text(state.actionButtonLabel)
                        .font(.system(size: 15, weight: .semibold))
                }
                .foregroundStyle(Color.black)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 15)
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }

            Button {  } label: {
                HStack(spacing: 6) {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .medium))
                    Text("Not now")
                        .font(.system(size: 15, weight: .medium))
                }
                .foregroundStyle(Theme.dim)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 15)
                .background(Theme.surface)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
        }
    }
}

// MARK: - Science Card

private struct ScienceCard: View {
    let fact: ScienceFact

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(fact.title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.text)
            Text(fact.description)
                .font(.system(size: 13))
                .foregroundStyle(Theme.dim)
                .fixedSize(horizontal: false, vertical: true)
                .lineSpacing(3)
            if let source = fact.source {
                Text("Source: \(source)")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.dim.opacity(0.6))
                    .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - Pill Badge

private struct PillBadge: View {
    let icon:  String
    let label: String

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundStyle(Theme.dim)
            Text(label)
                .font(Theme.monoLabel)
                .foregroundStyle(Theme.dim)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Theme.surface)
        .clipShape(Capsule())
        .overlay(Capsule().strokeBorder(Theme.border, lineWidth: 0.5))
    }
}
