import SwiftUI

// MARK: - BLE Nav Bar Button
//
// Shared across Live and Train tabs. Shows BLE connection state
// with animated icons and optional BPM readout.

struct BLENavButton: View {
    let state:  BLEState
    let bpm:    Float?
    let action: () -> Void

    @State private var pulse       = false
    @State private var spinAngle   = 0.0

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if case .connected = state, let bpm {
                    Text("\(Int(bpm.rounded()))")
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Theme.accent)
                        .transition(.opacity.combined(with: .scale(scale: 0.8)))
                }

                ZStack {
                    switch state {
                    case .connected:
                        Image(systemName: "waveform.path.ecg")
                            .font(.system(size: 17, weight: .light))
                            .foregroundStyle(Theme.accent)
                            .scaleEffect(pulse ? 1.08 : 1.0)
                            .animation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true),
                                       value: pulse)

                    case .scanning:
                        Image(systemName: "dot.radiowaves.left.and.right")
                            .font(.system(size: 17, weight: .light))
                            .foregroundStyle(Theme.warn)
                            .opacity(pulse ? 1.0 : 0.45)
                            .animation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true),
                                       value: pulse)

                    case .connecting:
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.system(size: 17, weight: .light))
                            .foregroundStyle(Theme.warn)
                            .rotationEffect(.degrees(spinAngle))

                    case .disconnected:
                        Image(systemName: "waveform.path.ecg")
                            .font(.system(size: 17, weight: .light))
                            .foregroundStyle(Theme.dim)
                            .overlay(
                                Image(systemName: "line.diagonal")
                                    .font(.system(size: 20, weight: .thin))
                                    .foregroundStyle(Theme.warn.opacity(0.7))
                            )

                    case .unauthorized:
                        Image(systemName: "lock.slash")
                            .font(.system(size: 17, weight: .light))
                            .foregroundStyle(Theme.warn)

                    default:
                        Image(systemName: "antenna.radiowaves.left.and.right.slash")
                            .font(.system(size: 17, weight: .light))
                            .foregroundStyle(Theme.dim)
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(stateBackground)
            .clipShape(Capsule())
        }
        .onAppear { startAnimations() }
        .onChange(of: state) { startAnimations() }
        .animation(.easeInOut(duration: 0.25), value: stateSeed)
    }

    private var stateBackground: some View {
        switch state {
        case .connected:
            return AnyView(Capsule().fill(Theme.accent.opacity(0.12)))
        case .scanning, .connecting:
            return AnyView(Capsule().fill(Theme.warn.opacity(0.10)))
        case .disconnected:
            return AnyView(Capsule().fill(Theme.warn.opacity(0.07)))
        default:
            return AnyView(Capsule().fill(Theme.dim.opacity(0.08)))
        }
    }

    private var stateSeed: Int {
        switch state {
        case .idle:          return 0
        case .scanning:      return 1
        case .connecting:    return 2
        case .connected:     return 3
        case .disconnected:  return 4
        case .unauthorized:  return 5
        case .unsupported:   return 6
        }
    }

    private func startAnimations() {
        pulse = false
        spinAngle = 0
        switch state {
        case .connected:
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { pulse = true }
        case .scanning:
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { pulse = true }
        case .connecting:
            withAnimation(.linear(duration: 1.0).repeatForever(autoreverses: false)) {
                spinAngle = 360
            }
        default:
            break
        }
    }
}
