import SwiftUI

// MARK: - ECG Glow Waveform Renderer
//
// Three-pass glow technique:
//   Pass 1: width 8, opacity 0.06  (wide outer glow)
//   Pass 2: width 4, opacity 0.20  (mid halo)
//   Pass 3: width 1.5, opacity 1.0 (crisp centre line)
//
// On QRS peak (largest positive excursion), adds a radial bloom.

struct WaveformRenderer {

    struct Config {
        var color:      Color   = Theme.accent
        var lineWidth:  CGFloat = 1.5
        var glowPasses: [(width: CGFloat, opacity: Double)] = [
            (8, 0.06),
            (4, 0.20),
            (1.5, 1.0),
        ]
        var bloomRadius: CGFloat = 20
        var bloomOpacity: Double = 0.15
    }

    static let defaultConfig = Config()

    /// Draw the waveform into a Canvas context.
    /// - Parameters:
    ///   - ctx:     SwiftUI Canvas context
    ///   - size:    Canvas size
    ///   - samples: ECG / ACC samples (raw units)
    ///   - config:  Visual configuration
    static func draw(
        in ctx: inout GraphicsContext,
        size: CGSize,
        samples: [Float],
        config: Config = defaultConfig
    ) {
        guard samples.count > 1 else { return }

        let path = buildPath(samples: samples, size: size)

        // QRS bloom: find index of max value (largest R-peak)
        if let maxIdx = samples.indices.max(by: { samples[$0] < samples[$1] }) {
            let xPeak = CGFloat(maxIdx) / CGFloat(samples.count - 1) * size.width
            let norm  = normalise(samples)
            let yPeak = (1 - CGFloat(norm[maxIdx])) * size.height * 0.9 + size.height * 0.05
            let bloomRect = CGRect(
                x: xPeak - config.bloomRadius,
                y: yPeak - config.bloomRadius,
                width: config.bloomRadius * 2,
                height: config.bloomRadius * 2
            )
            ctx.fill(
                Path(ellipseIn: bloomRect),
                with: .color(config.color.opacity(config.bloomOpacity))
            )
        }

        // Glow passes
        for pass in config.glowPasses {
            ctx.stroke(
                path,
                with: .color(config.color.opacity(pass.opacity)),
                lineWidth: pass.width
            )
        }
    }

    // MARK: - Private

    static func buildPath(samples: [Float], size: CGSize) -> Path {
        let norm = normalise(samples)
        let n    = norm.count
        var path = Path()
        for (i, v) in norm.enumerated() {
            let x = CGFloat(i) / CGFloat(n - 1) * size.width
            // Map 0→1 to height with 5% margins
            let y = (1 - CGFloat(v)) * size.height * 0.90 + size.height * 0.05
            if i == 0 { path.move(to: CGPoint(x: x, y: y)) }
            else       { path.addLine(to: CGPoint(x: x, y: y)) }
        }
        return path
    }

    static func normalise(_ s: [Float]) -> [Float] {
        guard !s.isEmpty else { return [] }
        guard let mn = s.min(), let mx = s.max(), mx > mn else {
            return s.map { _ in 0.5 }
        }
        let range = mx - mn
        // Guard against invalid values
        guard range.isFinite && range > 0 else {
            return s.map { _ in 0.5 }
        }
        return s.map { value in
            guard value.isFinite else { return 0.5 }
            return Float((value - mn) / range)
        }
    }
}
// MARK: - Preview

#Preview("ECG Waveform with Glow") {
    VStack(spacing: 20) {
        // Simulated ECG waveform data (typical ECG pattern with QRS complex)
        let ecgSamples = generateMockECG()
        
        Canvas { ctx, size in
            WaveformRenderer.draw(in: &ctx, size: size, samples: ecgSamples)
        }
        .frame(height: 100)
        .background(Theme.card)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .padding()
        
        Text("ECG Waveform Preview")
            .font(Theme.monoBody)
            .foregroundStyle(Theme.text)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Theme.bg)
}

#Preview("Different Waveform Styles") {
    ScrollView {
        VStack(spacing: 20) {
            // Default style
            Canvas { ctx, size in
                WaveformRenderer.draw(in: &ctx, size: size, samples: generateMockECG())
            }
            .frame(height: 80)
            .background(Theme.card)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(alignment: .topLeading) {
                Text("Default Glow")
                    .font(Theme.monoLabel)
                    .foregroundStyle(Theme.dim)
                    .padding(8)
            }
            
            // Custom color
            Canvas { ctx, size in
                var config = WaveformRenderer.Config()
                config.color = Theme.hrv
                WaveformRenderer.draw(in: &ctx, size: size, samples: generateMockECG(), config: config)
            }
            .frame(height: 80)
            .background(Theme.card)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(alignment: .topLeading) {
                Text("Custom Color (HRV)")
                    .font(Theme.monoLabel)
                    .foregroundStyle(Theme.dim)
                    .padding(8)
            }
            
            // Enhanced bloom
            Canvas { ctx, size in
                var config = WaveformRenderer.Config()
                config.bloomRadius = 30
                config.bloomOpacity = 0.3
                WaveformRenderer.draw(in: &ctx, size: size, samples: generateMockECG(), config: config)
            }
            .frame(height: 80)
            .background(Theme.card)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(alignment: .topLeading) {
                Text("Enhanced Bloom")
                    .font(Theme.monoLabel)
                    .foregroundStyle(Theme.dim)
                    .padding(8)
            }
        }
        .padding()
    }
    .background(Theme.bg)
}

// MARK: - Mock Data Generator

/// Generates a realistic ECG waveform pattern for previews
private func generateMockECG() -> [Float] {
    var samples: [Float] = []
    let sampleCount = 650 // 5 seconds at 130 Hz
    
    for i in 0..<sampleCount {
        let t = Float(i) / Float(sampleCount)
        
        // Create a repeating ECG pattern (approximately 70 BPM = ~0.86 seconds per beat)
        let beatPhase = (t * 5.8).truncatingRemainder(dividingBy: 1.0)
        
        var value: Float = 0
        
        // P wave (atrial depolarization)
        if beatPhase < 0.15 {
            value = 50 * sin(beatPhase * .pi / 0.15)
        }
        // PR segment (isoelectric)
        else if beatPhase < 0.25 {
            value = 0
        }
        // QRS complex (ventricular depolarization)
        else if beatPhase < 0.35 {
            let qrsPhase = (beatPhase - 0.25) / 0.1
            if qrsPhase < 0.3 {
                // Q wave (small negative)
                value = -100 * sin(qrsPhase * .pi / 0.3)
            } else if qrsPhase < 0.7 {
                // R wave (large positive - QRS peak)
                value = 800 * sin((qrsPhase - 0.3) * .pi / 0.4)
            } else {
                // S wave (negative)
                value = -200 * sin((qrsPhase - 0.7) * .pi / 0.3)
            }
        }
        // ST segment
        else if beatPhase < 0.5 {
            value = 0
        }
        // T wave (ventricular repolarization)
        else if beatPhase < 0.7 {
            value = 150 * sin((beatPhase - 0.5) * .pi / 0.2)
        }
        // Baseline
        else {
            value = 0
        }
        
        // Add slight noise for realism
        value += Float.random(in: -20...20)
        
        samples.append(value)
    }
    
    return samples
}


