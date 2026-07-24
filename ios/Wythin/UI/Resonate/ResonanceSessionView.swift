import SwiftUI

// MARK: - Resonance Session
//
// Wraps the existing Resonance pacer as a loggable session. Records the start
// time on appear; on Stop, logs a breathwork/"Resonance" ActivityLog (which then
// appears in the Activities list) and dismisses.

struct ResonanceSessionView: View {
    @Environment(\.modelContext) var ctx
    @Environment(AppEnvironment.self) var env
    @Environment(\.dismiss) var dismiss

    @State private var startedAt = Date.now

    var body: some View {
        NavigationStack {
            ResonateView()
                .background(Theme.bg)
                .navigationTitle("RESONANCE")
                .navigationBarTitleDisplayMode(.inline)
                .toolbarBackground(Theme.bg, for: .navigationBar)
                .toolbarColorScheme(.dark, for: .navigationBar)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Stop") { stop() }
                            .font(Theme.monoLabel)
                            .foregroundStyle(Theme.warn)
                    }
                }
        }
        .onAppear { startedAt = .now }
    }

    private func stop() {
        ActivityLogging.logPast(type: .breathwork, subtype: "Resonance", customName: nil,
                                start: startedAt, end: .now,
                                context: ctx, client: env.sync.client)
        dismiss()
    }
}
