import SwiftUI

/// Shared holder for the live-state insight so the widget's timed loop and the
/// Live tab's pull-to-refresh drive the same fetch and gating.
@MainActor
@Observable
final class LiveStateStore {
    var text: String?

    private var lastRefresh = Date.distantPast
    private var inFlight = false

    /// Never update the current state more often than this.
    private let minInterval: TimeInterval = 300   // 5 minutes

    /// Fetch a new insight, but never more often than once every 5 minutes.
    /// The very first reading still populates an empty widget immediately, and a
    /// pull-to-refresh takes effect once the 5-minute window has elapsed.
    func refresh(env: AppEnvironment) async {
        guard !inFlight else { return }

        let filtered = MetricsQualityFilter.filter(env.tickHistory)
        guard let trends = LiveStateTrendCompute.summarize(filtered) else { return }

        guard text == nil || Date().timeIntervalSince(lastRefresh) >= minInterval else { return }

        inFlight = true
        defer { inFlight = false }

        let payload = LiveStateInsightPayload(windowMinutes: 10, trends: trends)
        if let response = try? await env.sync.client.generateLiveStateInsight(payload) {
            text = response.text
            lastRefresh = Date()
        }
    }
}

/// Small, always-visible widget showing an OpenAI-generated, purely
/// descriptive account of the nervous-system trend over the last 10 minutes.
/// Updates at most once every 5 minutes while visible and BLE-connected (the
/// first reading appears as soon as there's enough data). Never shows a loading
/// state on refresh — the previous description stays until a new one replaces it.
struct LiveStateWidget: View {
    @Environment(AppEnvironment.self) var env
    let store: LiveStateStore
    @State private var refreshTask: Task<Void, Never>?

    private var isConnected: Bool {
        if case .connected = env.ble.state { return true }
        return false
    }

    var body: some View {
        Group {
            if let text = store.text {
                structured(text)
            } else {
                Text("Gathering data… pull down to refresh")
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
                            Text(styledBullet(bullet))
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

    /// Renders `**bold**` markdown in a bullet and brightens the bold spans to
    /// the primary text color so the key idea stands out against the dim body.
    private func styledBullet(_ s: String) -> AttributedString {
        var attr = (try? AttributedString(
            markdown: s,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(s)
        for run in attr.runs where run.inlinePresentationIntent?.contains(.stronglyEmphasized) == true {
            attr[run.range].foregroundColor = Theme.text
        }
        return attr
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
                // Poll on a short tick; the store decides whether to actually
                // fetch. Faster ticks until the first description lands.
                try? await Task.sleep(for: .seconds(store.text == nil ? 15 : 20))
                guard !Task.isCancelled else { break }
                await store.refresh(env: env)
            }
        }
    }

    private func stopLoop() {
        refreshTask?.cancel()
        refreshTask = nil
    }
}
