import SwiftUI

struct CurrentStateCard: View {
    let tick:  MetricsTick?
    let state: PolyvagalState

    private var autonomic: AutonomicIndices? {
        guard let t = tick else { return nil }
        return AutonomicCompute.compute(tick: t, baseline: nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            stateHeader
                .padding(.bottom, 18)

            if autonomic != nil {
                Divider().background(Theme.border)
                autonomicSection
                    .padding(.vertical, 18)
            }
        }
        .padding(18)
        .background(Theme.card)
        .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius))
        .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius)
            .strokeBorder(Theme.border, lineWidth: 0.5))
        .animation(.easeInOut(duration: 0.4), value: autonomic?.state)
    }

    // MARK: - State Header

    private var stateHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(state.displayName)
                .font(.system(size: 42, weight: .bold))
                .foregroundStyle(Theme.text)

            HStack(spacing: 10) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Theme.surface).frame(height: 4)
                        Capsule()
                            .fill(state.color)
                            .frame(width: geo.size.width * CGFloat(state.severityProgress), height: 4)
                            .animation(.spring(duration: 0.6), value: state.severityProgress)
                    }
                }
                .frame(width: 72, height: 4)

                Text(state.severity)
                    .font(Theme.monoLabel)
                    .foregroundStyle(Theme.dim)
            }
        }
    }

    // MARK: - Autonomic Balance

    private var autonomicSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("AUTONOMIC BALANCE")
                .font(Theme.monoLabel)
                .foregroundStyle(Theme.dim)

            // Split balance bar
            BalanceBar(pns: autonomic?.pns ?? 0, sns: autonomic?.sns ?? 0)

            // Value tiles
            HStack(spacing: 10) {
                AutonomicTile(
                    label: "PNS",
                    sublabel: "Parasympathetic",
                    value: autonomic?.pns,
                    color: Theme.accent
                )
                AutonomicTile(
                    label: "SNS",
                    sublabel: "Sympathetic",
                    value: autonomic?.sns,
                    color: Theme.warn
                )
            }

            // State label
            if let idx = autonomic {
                HStack(spacing: 6) {
                    Circle()
                        .fill(ansColor(idx.state))
                        .frame(width: 7, height: 7)
                    Text(ansLabel(idx.state))
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(ansColor(idx.state))
                }
            }
        }
    }

    // MARK: - Causes

    private func causeSection(_ causes: [PolyvagalCause]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Why is this happening?")
                .font(.system(size: 15))
                .foregroundStyle(Theme.text)

            ForEach(causes) { cause in
                CauseRow(cause: cause)
            }
        }
    }

    // MARK: - ANS helpers

    private func ansLabel(_ s: ANSState) -> String {
        switch s {
        case .ventralVagal: return "PARASYMPATHETIC DOMINANT"
        case .sympathetic:  return "SYMPATHETIC DOMINANT"
        case .dorsalVagal:  return "DORSAL VAGAL — LOW AROUSAL"
        case .mixed:        return "BALANCED / TRANSITIONING"
        }
    }

    private func ansColor(_ s: ANSState) -> Color {
        switch s {
        case .ventralVagal: return Theme.accent
        case .sympathetic:  return Theme.warn
        case .dorsalVagal:  return Theme.hrv
        case .mixed:        return Theme.dim
        }
    }
}

// MARK: - Balance Bar

private struct BalanceBar: View {
    let pns: Float
    let sns: Float

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let pnsW = CGFloat(pns) * w
            HStack(spacing: 0) {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Theme.accent.opacity(0.75))
                    .frame(width: max(4, pnsW))
                RoundedRectangle(cornerRadius: 6)
                    .fill(Theme.warn.opacity(0.75))
                    .frame(width: max(4, w - pnsW))
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                // Balance centre line
                Rectangle()
                    .fill(Theme.card)
                    .frame(width: 2)
                    .offset(x: pnsW - w / 2),
                alignment: .center
            )
        }
        .frame(height: 12)
        .animation(.spring(duration: 0.5), value: pns)
    }
}

// MARK: - Autonomic Tile

private struct AutonomicTile: View {
    let label:    String
    let sublabel: String
    let value:    Float?
    let color:    Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Circle().fill(color).frame(width: 6, height: 6)
                Text(label)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(color)
            }

            Text(value.map { String(format: "%.2f", $0) } ?? "—")
                .font(.system(size: 26, weight: .bold, design: .rounded))
                .foregroundStyle(Theme.text)

            // Mini fill bar
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3).fill(Theme.surface).frame(height: 4)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(color.opacity(0.7))
                        .frame(width: geo.size.width * CGFloat(min(1, max(0, value ?? 0))), height: 4)
                        .animation(.spring(duration: 0.5), value: value)
                }
            }
            .frame(height: 4)

            Text(sublabel)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Theme.dim)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - Cause Row

private struct CauseRow: View {
    let cause: PolyvagalCause

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Theme.surface)
                    .frame(width: 38, height: 38)
                Image(systemName: cause.icon)
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.text)
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(cause.title)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Theme.text)
                    Spacer()
                    Text(cause.time)
                        .font(Theme.monoLabel)
                        .foregroundStyle(Theme.dim)
                }
                Text(cause.description)
                    .font(Theme.monoLabel)
                    .foregroundStyle(Theme.dim)
            }
        }
        .padding(12)
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}
