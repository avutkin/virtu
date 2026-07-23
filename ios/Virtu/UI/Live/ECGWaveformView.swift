import SwiftUI

/// Scrolling ECG strip at 60 fps using TimelineView + Canvas.
/// Displays the last 5 s of ECG at 130 Hz = 650 samples.
struct ECGWaveformView: View {
    let buffer: [Float]

    var body: some View {
        ZStack {
            if buffer.isEmpty {
                // Empty state
                VStack(spacing: 8) {
                    Image(systemName: "waveform.path.ecg")
                        .font(.title)
                        .foregroundStyle(Theme.dim.opacity(0.5))
                    Text("Waiting for ECG data...")
                        .font(Theme.monoLabel)
                        .foregroundStyle(Theme.dim)
                }
            } else {
                TimelineView(.periodic(from: .now, by: 1.0 / 60.0)) { _ in
                    Canvas { ctx, size in
                        WaveformRenderer.draw(in: &ctx, size: size, samples: buffer)
                    }
                }
                .drawingGroup() // Offload rendering to Metal for better performance
            }
        }
        .frame(height: 80)
        .background(Theme.card)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
// MARK: - Preview

#Preview("ECG Waveform - With Data") {
    VStack(spacing: 16) {
        // Generate mock ECG data
        let mockECG = generateMockECGData()
        
        ECGWaveformView(buffer: mockECG)
            .padding()
        
        Text("Live ECG Stream")
            .font(Theme.monoLabel)
            .foregroundStyle(Theme.dim)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Theme.bg)
}

#Preview("ECG Waveform - Empty State") {
    VStack(spacing: 16) {
        ECGWaveformView(buffer: [])
            .padding()
        
        Text("No data connected")
            .font(Theme.monoLabel)
            .foregroundStyle(Theme.dim)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Theme.bg)
}

// MARK: - Mock Data

private func generateMockECGData() -> [Float] {
    var samples: [Float] = []
    let sampleCount = 650 // 5 seconds at 130 Hz
    
    for i in 0..<sampleCount {
        let t = Float(i) / Float(sampleCount)
        let beatPhase = (t * 5.8).truncatingRemainder(dividingBy: 1.0)
        
        var value: Float = 0
        
        if beatPhase < 0.15 {
            value = 50 * sin(beatPhase * .pi / 0.15)
        } else if beatPhase < 0.25 {
            value = 0
        } else if beatPhase < 0.35 {
            let qrsPhase = (beatPhase - 0.25) / 0.1
            if qrsPhase < 0.3 {
                value = -100 * sin(qrsPhase * .pi / 0.3)
            } else if qrsPhase < 0.7 {
                value = 800 * sin((qrsPhase - 0.3) * .pi / 0.4)
            } else {
                value = -200 * sin((qrsPhase - 0.7) * .pi / 0.3)
            }
        } else if beatPhase < 0.5 {
            value = 0
        } else if beatPhase < 0.7 {
            value = 150 * sin((beatPhase - 0.5) * .pi / 0.2)
        }
        
        value += Float.random(in: -20...20)
        samples.append(value)
    }
    
    return samples
}


