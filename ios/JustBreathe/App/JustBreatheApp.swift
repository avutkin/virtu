import SwiftUI
import SwiftData

@main
struct JustBreatheApp: App {

    private let container: ModelContainer

    @Environment(\.scenePhase) private var scenePhase
    @State private var env: AppEnvironment
    @State private var showSplash = true

    init() {
        let schema = Schema([HRVSession.self, HRVSample.self, ResonanceResult.self, TrainSession.self, ActivityLog.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        let c = try! ModelContainer(for: schema, configurations: [config])
        container = c
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

// MARK: - App Tab

enum AppTab: Hashable { case train, actions, live, track, settings }

// MARK: - Root Tab View

struct ContentView: View {
    @Environment(AppEnvironment.self) var env
    @State private var selectedTab: AppTab = .live

    var body: some View {
        TabView(selection: $selectedTab) {
            TrainView()
                .tag(AppTab.train)
            ActionsView()
                .tag(AppTab.actions)
            LiveView()
                .tag(AppTab.live)
            HistoryView()
                .tag(AppTab.track)
            SettingsView()
                .tag(AppTab.settings)
        }
        .tint(Theme.accent)
        .toolbar(.hidden, for: .tabBar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            AppTabBar(selected: $selectedTab)
        }
    }
}

// MARK: - Custom Tab Bar

struct AppTabBar: View {
    @Binding var selected: AppTab

    var body: some View {
        HStack(spacing: 0) {
            // Left pair
            TabBarButton(tab: .train,   icon: "figure.run",                label: "Train",   selected: $selected)
            TabBarButton(tab: .actions, icon: "list.bullet.clipboard",     label: "Actions", selected: $selected)

            // Live — prominent center button (position 3 of 5)
            Button { selected = .live } label: {
                ZStack {
                    Circle()
                        .fill(selected == .live ? Theme.accent : Theme.card)
                        .frame(width: 56, height: 56)
                        .shadow(color: selected == .live ? Theme.accent.opacity(0.35) : .clear,
                                radius: 10, y: 3)
                    Image(systemName: "waveform.path.ecg")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(selected == .live ? Color.black : Theme.dim)
                }
                .offset(y: -10)
            }
            .frame(maxWidth: .infinity)
            .animation(.easeInOut(duration: 0.2), value: selected)

            // Right pair
            TabBarButton(tab: .track,    icon: "chart.line.uptrend.xyaxis", label: "Track",    selected: $selected)
            TabBarButton(tab: .settings, icon: "gear",                      label: "Settings", selected: $selected)
        }
        .padding(.horizontal, 8)
        .padding(.top, 12)
        .padding(.bottom, 6)
        .background {
            Theme.bg
                .ignoresSafeArea(edges: .bottom)
                .overlay(alignment: .top) {
                    Theme.border.frame(height: 0.5)
                }
        }
    }
}

private struct TabBarButton: View {
    let tab:    AppTab
    let icon:   String
    let label:  String
    @Binding var selected: AppTab

    var isSelected: Bool { selected == tab }

    var body: some View {
        Button { selected = tab } label: {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 20))
                Text(label)
                    .font(Theme.monoLabel)
            }
            .foregroundStyle(isSelected ? Theme.accent : Theme.dim)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .animation(.easeInOut(duration: 0.15), value: isSelected)
    }
}
