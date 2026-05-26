import SwiftUI

struct SettingsView: View {
    @Environment(AppEnvironment.self) var env

    @State private var serverURLText: String = ""

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.bg.ignoresSafeArea()

                List {
                    // ── Device ────────────────────────────────────────
                    Section("POLAR H10") {
                        HStack {
                            Text("Status")
                                .font(Theme.monoBody)
                                .foregroundStyle(Theme.text)
                            Spacer()
                            Text(bleStatusLabel)
                                .font(Theme.monoLabel)
                                .foregroundStyle(bleStatusColor)
                        }

                        if case .connected = env.ble.state {
                            HStack {
                                Text("Battery")
                                    .font(Theme.monoBody)
                                    .foregroundStyle(Theme.text)
                                Spacer()
                                Text(env.ble.batteryLevel.map { "\($0)%" } ?? "—")
                                    .font(Theme.monoLabel)
                                    .foregroundStyle(Theme.dim)
                            }
                        }

                        Text("Use the  ⌁  icon on the Live tab to connect or switch devices.")
                            .font(Theme.monoLabel)
                            .foregroundStyle(Theme.dim)
                    }
                    .listRowBackground(Theme.card)

                    // ── Server ────────────────────────────────────────
                    Section("SERVER SYNC") {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Server URL")
                                .font(Theme.monoLabel)
                                .foregroundStyle(Theme.dim)
                            TextField("http://your-server:8000", text: $serverURLText)
                                .font(Theme.monoBody)
                                .foregroundStyle(Theme.text)
                                .keyboardType(.URL)
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.never)
                                .onSubmit { saveServerURL() }
                        }

                        HStack {
                            Text("User ID")
                                .font(Theme.monoBody)
                                .foregroundStyle(Theme.text)
                            Spacer()
                            Text(env.userID.prefix(8) + "…")
                                .font(Theme.monoLabel)
                                .foregroundStyle(Theme.dim)
                        }
                    }
                    .listRowBackground(Theme.card)

                    // ── About ─────────────────────────────────────────
                    Section("ABOUT") {
                        HStack {
                            Text("Version")
                                .font(Theme.monoBody)
                                .foregroundStyle(Theme.text)
                            Spacer()
                            Text(appVersion)
                                .font(Theme.monoLabel)
                                .foregroundStyle(Theme.dim)
                        }
                        HStack {
                            Text("Device")
                                .font(Theme.monoBody)
                                .foregroundStyle(Theme.text)
                            Spacer()
                            Text(UIDevice.current.model)
                                .font(Theme.monoLabel)
                                .foregroundStyle(Theme.dim)
                        }
                    }
                    .listRowBackground(Theme.card)
                }
                .scrollContentBackground(.hidden)
                .background(Theme.bg)
            }
            .navigationTitle("SETTINGS")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.bg, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .onAppear {
                serverURLText = env.serverURL.absoluteString
            }
        }
    }

    private var bleStatusLabel: String {
        switch env.ble.state {
        case .idle:              return "IDLE"
        case .scanning:          return "SCANNING…"
        case .connecting(let n): return "CONNECTING \(n)"
        case .connected(let n):  return n.uppercased()
        case .disconnected(let r): return "OFF — \(r)"
        case .unauthorized:      return "NO PERMISSION"
        case .unsupported:       return "UNSUPPORTED"
        }
    }

    private var bleStatusColor: Color {
        switch env.ble.state {
        case .connected:    return Theme.accent
        case .scanning,
             .connecting:   return Theme.warn
        default:            return Theme.dim
        }
    }

    private func saveServerURL() {
        if let url = URL(string: serverURLText) {
            env.serverURL = url
        }
    }

    private var appVersion: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(v) (\(b))"
    }
}
