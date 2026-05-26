import SwiftUI

// MARK: - SplashView

/// Full-screen splash shown on launch.
/// Displays a random quote about the power of breath, with attribution.
/// The user can tap the arrow to proceed immediately, or wait 15 s for auto-dismiss.
struct SplashView: View {

    let onFinished: () -> Void

    @State private var opacity:      Double = 0
    @State private var arrowOpacity: Double = 0
    @State private var quote = quotes.randomElement()!

    private func dismiss() {
        withAnimation(.easeOut(duration: 0.8)) { opacity = 0 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { onFinished() }
    }

    var body: some View {
        ZStack {
            Color(hex: "#070B11").ignoresSafeArea()

            VStack(spacing: 0) {

                // ── Logo ───────────────────────────────────────────────
                VStack(spacing: 10) {
                    HStack(spacing: 10) {
                        Text("Just")
                            .font(.custom("JetBrainsMono-Regular", size: 28))
                            .foregroundStyle(Color(hex: "#EDE8DF"))
                        Text("Breathe")
                            .font(.custom("JetBrainsMono-Regular", size: 28))
                            .italic()
                            .foregroundStyle(Color.white)
                    }

                    Text("breathe · measure · grow")
                        .font(.custom("JetBrainsMono-Regular", size: 9))
                        .foregroundStyle(Color(hex: "#3A4758"))
                        .tracking(3.5)
                }
                .padding(.top, 64)

                Spacer()

                // ── Quote ──────────────────────────────────────────────
                VStack(spacing: 0) {
                    Text(quote.text)
                        .font(.custom("JetBrainsMono-Regular", size: 19))
                        .foregroundStyle(Color(hex: "#8FA8BF"))
                        .multilineTextAlignment(.center)
                        .lineSpacing(8)
                        .padding(.horizontal, 40)

                    Spacer().frame(height: 32)

                    Rectangle()
                        .fill(Color(hex: "#242E3D"))
                        .frame(width: 20, height: 1)

                    Spacer().frame(height: 24)

                    Text(quote.author.uppercased())
                        .font(.custom("JetBrainsMono-Regular", size: 8))
                        .foregroundStyle(Color(hex: "#3A4758"))
                        .tracking(4.5)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 48)
                }

                Spacer()

                // ── Arrow dismiss ──────────────────────────────────────
                Button(action: dismiss) {
                    HStack(spacing: 0) {
                        Rectangle()
                            .frame(width: 32, height: 1)
                        Image(systemName: "arrowtriangle.right.fill")
                            .font(.system(size: 7))
                    }
                    .foregroundStyle(Color(hex: "#00E5A0"))
                }
                .opacity(arrowOpacity)
                .padding(.bottom, 52)
            }
            .opacity(opacity)
        }
        .onAppear {
            withAnimation(.easeIn(duration: 2.0)) { opacity = 1 }
            withAnimation(.easeIn(duration: 1.0).delay(2.5)) { arrowOpacity = 1 }
            // Auto-dismiss after 15 s if user doesn't tap the arrow
            DispatchQueue.main.asyncAfter(deadline: .now() + 15.0) { dismiss() }
        }
    }

    // MARK: - Quote Library

    private struct Quote {
        let text:   String
        let author: String
    }

    private static let quotes: [Quote] = [

        // Ancient wisdom
        Quote(
            text:   "When the breath wanders, the mind also is unsteady. But when the breath is calmed, the mind too will be still.",
            author: "Hatha Yoga Pradipika"
        ),
        Quote(
            text:   "Breath is the king of mind.",
            author: "B.K.S. Iyengar"
        ),
        Quote(
            text:   "For breath is life, and if you breathe well you will live long on earth.",
            author: "Sanskrit proverb"
        ),
        Quote(
            text:   "Control of the breath is the supreme form of self-discipline.",
            author: "Patanjali, Yoga Sutras"
        ),
        Quote(
            text:   "There is one way of breathing that is shameful and constricted. Then there is another way — a breath of love that takes you all the way to infinity.",
            author: "Rumi"
        ),
        Quote(
            text:   "Breathing correctly is the foundation of any practice of self-cultivation.",
            author: "Zhuangzi"
        ),

        // Gorakh Bodh
        Quote(
            text:   "Inhalation brings the sound 'Sah', exhalation carries the sound 'Ham'. So-Ham is the breath's own mantra.",
            author: "Gorakh Bodh"
        ),
        Quote(
            text:   "They who reverse the breath, tame the vital air, and still the mind — they alone know the Self.",
            author: "Gorakh Bodh"
        ),
        Quote(
            text:   "Prana flows through the median channel when the breath is refined and the mind made quiet.",
            author: "Gorakh Bodh"
        ),
        Quote(
            text:   "Listen to the inner sound that arises beyond all breath — the unstruck note that echoes in silence.",
            author: "Gorakh Bodh"
        ),

        // Modern teachers
        Quote(
            text:   "Breath is the bridge which connects life to consciousness, which unites your body to your thoughts.",
            author: "Thích Nhất Hạnh"
        ),
        Quote(
            text:   "Feelings come and go like clouds in a windy sky. Conscious breathing is my anchor.",
            author: "Thích Nhất Hạnh"
        ),
        Quote(
            text:   "The quality of our breath expresses our inner feelings.",
            author: "T.K.V. Desikachar"
        ),
        Quote(
            text:   "Breathe in deeply to bring your mind home to your body.",
            author: "Thích Nhất Hạnh"
        ),
        Quote(
            text:   "In the practice of meditation, the breath is your anchor, your home, the place you can always return to.",
            author: "Jon Kabat-Zinn"
        ),
        Quote(
            text:   "The present moment always will have been. Come back to the breath and it is always here.",
            author: "Jon Kabat-Zinn"
        ),

        // Science & medicine
        Quote(
            text:   "No matter what you eat, how much you exercise, or how resilient your genes are, none of it matters unless you're breathing correctly.",
            author: "James Nestor, Breath"
        ),
        Quote(
            text:   "Breath is the most powerful drug we have. Learning to use it is one of the greatest gifts you can give yourself.",
            author: "Andrew Weil"
        ),
        Quote(
            text:   "If I had to limit my advice on healthier living to just one tip, it would be simply to breathe properly.",
            author: "Andrew Weil"
        ),
        Quote(
            text:   "The breath is always here. It never leaves you. And you can always come back to it.",
            author: "Wim Hof"
        ),
        Quote(
            text:   "Breathing is the first act of life and the last. Our very life depends on it.",
            author: "Joseph Pilates"
        ),

        // Philosophy & poetry
        Quote(
            text:   "When you own your breath, nobody can steal your peace.",
            author: "Unknown"
        ),
        Quote(
            text:   "Inhale the future, exhale the past.",
            author: "Unknown"
        ),
        Quote(
            text:   "Breathe deeply, until sweet air extinguishes the burn of fear in your lungs and every breath is a beautiful refusal to become anything less than infinite.",
            author: "D. Antoinette Foy"
        ),
        Quote(
            text:   "With every breath, I plant the seeds of devotion. I am a farmer of the heart.",
            author: "Rumi"
        ),
        Quote(
            text:   "Breathing in, I calm my body and mind. Breathing out, I smile. Dwelling in the present moment, I know this is the only moment.",
            author: "Thích Nhất Hạnh"
        ),
        Quote(
            text:   "The rhythm of the body, the melody of the mind, and the harmony of the soul create the symphony of life.",
            author: "B.K.S. Iyengar"
        ),
        Quote(
            text:   "Perhaps the most important thing we bring to another person is the silence in us. Not the sort of silence that is empty, but the kind that is a willingness to witness.",
            author: "Rachel Naomi Remen"
        ),
        Quote(
            text:   "Life is not measured by the number of breaths we take, but by the moments that take our breath away.",
            author: "Maya Angelou"
        ),
        Quote(
            text:   "In the middle of difficulty lies opportunity — find it in the breath.",
            author: "Albert Einstein"
        ),
        Quote(
            text:   "Smile, breathe, and go slowly.",
            author: "Thích Nhất Hạnh"
        ),
    ]
}
