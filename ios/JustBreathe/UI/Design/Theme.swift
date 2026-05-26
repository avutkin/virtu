import SwiftUI

// MARK: - Colour Palette

enum Theme {
    // Backgrounds
    static let bg      = Color(hex: "#070B11")   // deep navy-black
    static let card    = Color(hex: "#0D1420")   // slightly lighter panel
    static let border  = Color(hex: "#1A2535")   // subtle border

    // Accents
    static let accent  = Color(hex: "#00E5A0")   // ECG green
    static let hrv     = Color(hex: "#818CF8")   // indigo — HRV metrics
    static let rsa     = Color(hex: "#FB923C")   // amber — RSA
    static let warn    = Color(hex: "#FF6B6B")   // soft red
    static let coh     = Color(hex: "#39D353")   // coherence green
    static let breathe = Color(hex: "#58A6FF")   // blue — breathing
    static let ulf     = Color(hex: "#A78BFA")   // muted violet — ULF power ring

    // Text
    static let text    = Color(hex: "#E2E8F0")   // cool white
    static let dim     = Color(hex: "#4A5568")   // muted

    // MARK: Typography

    static func mono(_ size: CGFloat) -> Font {
        .custom("JetBrainsMono-Regular", size: size)
    }

    static func display(_ size: CGFloat) -> Font {
        .custom("CormorantGaramond-Light", size: size)
    }

    // Fallback system fonts if custom fonts aren't loaded
    static let monoSmall:   Font = .custom("JetBrainsMono-Regular", size: 11, relativeTo: .caption)
    static let monoBody:    Font = .custom("JetBrainsMono-Regular", size: 13, relativeTo: .body)
    static let monoLabel:   Font = .custom("JetBrainsMono-Regular", size: 11, relativeTo: .caption2)
    static let displayLarge: Font = .custom("CormorantGaramond-Light", size: 36, relativeTo: .title)

    // MARK: Spacing

    static let cardPad:   CGFloat = 16
    static let cardRadius: CGFloat = 12
    static let ringSize:   CGFloat = 72
}

// MARK: - Color hex initialiser

extension Color {
    init(hex: String) {
        let h = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        let scanner = Scanner(string: h)
        var rgb: UInt64 = 0
        scanner.scanHexInt64(&rgb)
        let r = Double((rgb >> 16) & 0xFF) / 255
        let g = Double((rgb >>  8) & 0xFF) / 255
        let b = Double( rgb        & 0xFF) / 255
        self.init(red: r, green: g, blue: b)
    }
}

// MARK: - View Modifiers

extension View {
    func cardStyle() -> some View {
        self
            .padding(Theme.cardPad)
            .background(Theme.card)
            .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cardRadius)
                    .strokeBorder(Theme.border, lineWidth: 0.5)
            )
    }

    func monoLabel(_ text: String, color: Color = Theme.dim) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(text)
                .font(Theme.monoLabel)
                .foregroundStyle(color)
            self
        }
    }
}

// MARK: - Metric Value Formatter

enum MetricFormat {
    static func bpm(_ v: Float?)      -> String { v.map { String(format: "%.0f", $0) } ?? "—" }
    static func ms(_ v: Float?)       -> String { v.map { String(format: "%.1f", $0) } ?? "—" }
    static func ratio(_ v: Float?)    -> String { v.map { String(format: "%.2f", $0) } ?? "—" }
    static func percent(_ v: Float?)  -> String { v.map { String(format: "%.1f%%", $0) } ?? "—" }
    static func score(_ v: Float?)    -> String { v.map { String(format: "%.2f", $0) } ?? "—" }
    static func hz(_ v: Float?)       -> String { v.map { String(format: "%.3f", $0) } ?? "—" }
}
