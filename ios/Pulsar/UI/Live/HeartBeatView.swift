import SwiftUI

/// Pulsing heart icon that animates in sync with the current RR interval.
struct HeartBeatView: View {
    let bpm: Float?

    @State private var scale:     CGFloat = 1.0
    @State private var beatTask:  Task<Void, Never>? = nil

    private var interval: Double {
        guard let bpm, bpm > 20 else { return 1.0 }
        return 60.0 / Double(bpm)
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "heart.fill")
                .font(.system(size: 20))
                .foregroundStyle(Theme.warn)
                .scaleEffect(scale)
                .onAppear   { startBeating() }
                .onDisappear { beatTask?.cancel(); beatTask = nil }
                .onChange(of: bpm) { startBeating() }

            VStack(alignment: .leading, spacing: 1) {
                Text(MetricFormat.bpm(bpm))
                    .font(Theme.monoBody)
                    .foregroundStyle(Theme.text)
                Text("BPM")
                    .font(Theme.monoLabel)
                    .foregroundStyle(Theme.dim)
            }
        }
    }

    private func startBeating() {
        beatTask?.cancel()
        let iv = interval
        // Single long-running Task replaces recursive DispatchQueue blocks.
        // Cancelled cleanly on onDisappear or bpm change.
        beatTask = Task { @MainActor in
            while !Task.isCancelled {
                withAnimation(.easeIn(duration: 0.1))  { scale = 1.2 }
                try? await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled else { break }
                withAnimation(.easeOut(duration: 0.15)) { scale = 1.0 }
                let restMs = max(300, Int((iv - 0.25) * 1_000))
                try? await Task.sleep(for: .milliseconds(restMs))
            }
        }
    }
}
