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

    /// Renders the structured insight: first line = state headline (bold),
    /// "•" lines = trend bullets, "→" line = the recommendation (accented).
    @ViewBuilder
    private func structured(_ text: String) -> some View {
        let lines = text
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        VStack(alignment: .leading, spacing: 7) {
            ForEach(Array(lines.enumerated()), id: \.offset) { idx, line in
                if idx == 0 {
                    Text(line)
                        .font(.system(size: 19, weight: .bold))
                        .foregroundStyle(Theme.text)
                } else if line.hasPrefix("→") {
                    Text(line)
                        .font(Theme.monoBody)
                        .foregroundStyle(Theme.accent)
                } else {
                    Text(line)
                        .font(Theme.monoBody)
                        .foregroundStyle(Theme.dim)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
