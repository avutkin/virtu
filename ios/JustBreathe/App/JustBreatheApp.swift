import SwiftUI
import SwiftData

@main
struct JustBreatheApp: App {

    private let container: ModelContainer = {
        let schema = Schema([HRVSession.self, HRVSample.self, ResonanceResult.self, TrainSession.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        return try! ModelContainer(for: schema, configurations: [config])
    }()

    @Environment(\.scenePhase) private var scenePhase
    @State private var env: AppEnvironment
    @State private var showSplash = true

    init() {
        let c: ModelContainer = {
            let schema = Schema([HRVSession.self, HRVSample.self, ResonanceResult.self, TrainSession.self])
            let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
            return try! ModelContainer(for: schema, configurations: [config])
        }()
        _env = State(initialValue: AppEnvironment(modelContainer: c))
    }

    var body: some Scene {
        WindowGroup {
            ZStack {
                ContentView()
                    .environment(env)
                    .modelContainer(container)
                    .preferredColorScheme(.dark)

                if showSplash {
                    SplashView {
                        showSplash = false
                    }
                    .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.4), value: showSplash)
            .preferredColorScheme(.dark)
        }
        .onChange(of: scenePhase) { _, newPhase in
            env.isInForeground = (newPhase == .active)
        }
    }
}

// MARK: - Root Tab View

struct ContentView: View {
    @Environment(AppEnvironment.self) var env

    var body: some View {
        TabView {
            LiveView()
                .tabItem { Label("Live", systemImage: "waveform.path.ecg") }

            TrainView()
                .tabItem { Label("Train", systemImage: "figure.run") }

            ResonateView()
                .tabItem { Label("Resonate", systemImage: "circle.dotted") }

            HistoryView()
                .tabItem { Label("History", systemImage: "chart.line.uptrend.xyaxis") }

            SettingsView()
                .tabItem { Label("Settings", systemImage: "gear") }
        }
        .tint(Theme.accent)
        .background(Theme.bg)
    }
}
