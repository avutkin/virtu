import SwiftUI

// MARK: - Colour Palette

enum Theme {
    // Backgrounds
    static let bg      = Color(hex: "#0C0C0C")   // pure near-black
    static let card    = Color(hex: "#171717")   // dark surface
    static let surface = Color(hex: "#222222")   // elevated surface (nested cards, icon containers)
    static let border  = Color(hex: "#2A2A2A")   // neutral subtle border

    // Accents (used in charts and metric colors)
    static let accent  = Color(hex: "#00E5A0")   // ECG green
    static let hrv     = Color(hex: "#818CF8")   // indigo — HRV metrics
    static let rsa     = Color(hex: "#FB923C")   // amber — RSA
    static let warn    = Color(hex: "#FF6B6B")   // soft red
    static let coh     = Color(hex: "#39D353")   // coherence green
    static let breathe = Color(hex: "#58A6FF")   // blue — breathing
    static let ulf     = Color(hex: "#A78BFA")   // muted violet — ULF

    // Text
    static let text    = Color(hex: "#FFFFFF")   // pure white
    static let dim     = Color(hex: "#787878")   // medium gray

    // MARK: Typography

    static func mono(_ size: CGFloat) -> Font {
        .system(size: size, design: .monospaced)
    }

    static func display(_ size: CGFloat) -> Font {
        .system(size: size, weight: .bold, design: .default)
    }

    static let monoSmall:    Font = .system(size: 11, design: .monospaced)
    static let monoBody:     Font = .system(size: 13, design: .monospaced)
    static let monoLabel:    Font = .system(size: 11, design: .monospaced)
    static let displayLarge: Font = .system(size: 42, weight: .bold, design: .default)

    // MARK: Spacing

    static let cardPad:    CGFloat = 16
    static let cardRadius: CGFloat = 16
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
