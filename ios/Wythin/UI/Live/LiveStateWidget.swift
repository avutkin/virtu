import SwiftUI

/// Small, always-visible widget showing an OpenAI-generated, purely
/// descriptive account of the nervous-system trend over the last 10
/// minutes. Refreshes every 5 minutes (first pass after 2) while visible
/// and BLE-connected. Never shows a loading state on refresh — the
/// previous description stays until a new one replaces it.
struct LiveStateWidget: View {
    @Environment(AppEnvironment.self) var env
    @State private var description: String?
    @State private var refreshTask: Task<Void, Never>?

    private var isConnected: Bool {
        if case .connected = env.ble.state { return true }
        return false
    }

    var body: some View {
        Group {
            if let description {
                structured(description)
            } else {
                Text("Gathering data…")
                    .font(Theme.monoBody)
                    .foregroundStyle(Theme.dim)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
        .onAppear {
            if isConnected { startLoop() }
        }
        .onDisappear {
            stopLoop()
        }
        .onChange(of: env.ble.state) { _, newValue in
            if case .connected = newValue {
                startLoop()
            } else {
                stopLoop()
            }
        }
    }

    // MARK: - Rendering

    /// Renders the parsed insight: a colored state-icon badge + personalized
    /// title, the trend bullets, and a distinct, state-tinted "right now"
    /// recommendation block.
    @ViewBuilder
    private func structured(_ text: String) -> some View {
        let insight = LiveStateInsight(raw: text)
        let accent  = insight.state?.color ?? Theme.accent
        VStack(alignment: .leading, spacing: 14) {
            header(insight, accent: accent)

            if !insight.bullets.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(insight.bullets.enumerated()), id: \.offset) { _, bullet in
                        HStack(alignment: .top, spacing: 8) {
                            Circle()
                                .fill(accent.opacity(0.7))
                                .frame(width: 5, height: 5)
                                .padding(.top, 6)
                            Text(bullet)
                                .font(.system(size: 14))
                                .foregroundStyle(Theme.dim)
                                .fixedSize(horizontal: false, vertical: true)
                                .lineSpacing(3)
                        }
                    }
                }
            }

            if let recommendation = insight.recommendation {
                recommendationBlock(recommendation, accent: accent)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func header(_ insight: LiveStateInsight, accent: Color) -> some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(accent.opacity(0.16))
                    .frame(width: 44, height: 44)
                Image(systemName: insight.state?.iconName ?? "waveform.path.ecg")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(accent)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("CURRENT STATE")
                    .font(Theme.monoLabel)
                    .foregroundStyle(Theme.dim)
                Text(insight.title)
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(Theme.text)
            }
        }
    }

    @ViewBuilder
    private func recommendationBlock(_ text: String, accent: Color) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "arrow.right.circle.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(accent)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                Text("RIGHT NOW")
                    .font(Theme.monoLabel)
                    .foregroundStyle(accent)
                Text(text)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Theme.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineSpacing(3)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(accent.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12)
            .strokeBorder(accent.opacity(0.25), lineWidth: 0.5))
    }

    // MARK: - Refresh loop

    private func startLoop() {
        guard refreshTask == nil else { return }
        refreshTask = Task {
            while !Task.isCancelled {
                // Poll quickly until the first description lands (so the user
                // isn't stuck on "Gathering data…"), then settle to a 5-minute
                // refresh cadence.
                try? await Task.sleep(for: .seconds(description == nil ? 30 : 300))
                guard !Task.isCancelled else { break }

                let filtered = MetricsQualityFilter.filter(env.tickHistory)
                guard let trends = LiveStateTrendCompute.summarize(filtered) else { continue }

                let payload = LiveStateInsightPayload(windowMinutes: 10, trends: trends)
                if let response = try? await env.sync.client.generateLiveStateInsight(payload) {
                    description = response.text
                }
            }
        }
    }

    private func stopLoop() {
        refreshTask?.cancel()
        refreshTask = nil
    }
}
