import SwiftUI

// MARK: - OnboardingFlow
//
// First-launch, reels-style onboarding. Drives an ordered sequence of full-screen
// steps, persisting answers to the ClientProfileStore as it goes, and calls
// `onComplete` when the user finishes (connect or skip).

struct OnboardingFlow: View {
    @Environment(AppEnvironment.self) private var env
    let onComplete: () -> Void

    private let store = ClientProfileStore()
    @State private var profile = ClientProfileStore().load()
    @State private var step: Step = .welcome
    @State private var showBLE = false

    enum Step: Int, CaseIterable {
        case welcome, phone, email, goals, practices, devices, aboutYou, connect

        /// Interactive steps after welcome, for the progress bar.
        static var progressTotal: Double { Double(Step.allCases.count - 1) } // 7
        var progress: Double {
            guard rawValue >= Step.phone.rawValue else { return 0 }
            return Double(rawValue) / Step.progressTotal
        }
    }

    // MARK: Option catalogs

    private let goalOptions: [OnboardingOption] = [
        .init("Improve sleep",            icon: "moon.stars"),
        .init("Be more present",          icon: "leaf"),
        .init("More resilient to stress", icon: "shield"),
        .init("Reduce anxiety",           icon: "heart"),
        .init("Sharpen focus",            icon: "scope"),
        .init("Boost energy",             icon: "bolt"),
    ]
    private let practiceOptions: [OnboardingOption] = [
        .init("Meditation",    icon: "brain.head.profile"),
        .init("Breathwork",    icon: "wind"),
        .init("Yoga",          icon: "figure.yoga"),
        .init("Gym",           icon: "dumbbell"),
        .init("Running",       icon: "figure.run"),
        .init("Cold exposure", icon: "snowflake"),
        .init("Walking",       icon: "figure.walk"),
    ]
    private let deviceOptions: [OnboardingOption] = [
        .init("Oura Ring",      icon: "circle.circle"),
        .init("Whoop",          icon: "applewatch.side.right"),
        .init("Apple Watch",    icon: "applewatch"),
        .init("Garmin",         icon: "location.circle"),
        .init("Fitbit",         icon: "square.circle"),
        .init("Just this app",  icon: "iphone"),
    ]

    var body: some View {
        ZStack {
            content
                .transition(.asymmetric(
                    insertion: .move(edge: .trailing).combined(with: .opacity),
                    removal:   .move(edge: .leading).combined(with: .opacity)
                ))
                .id(step)   // drive the transition on step change
        }
        .animation(.easeInOut(duration: 0.28), value: step)
        .sheet(isPresented: $showBLE) {
            BLEConnectionSheet(ble: env.ble)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch step {
        case .welcome:
            OnboardingWelcomeScreen(onStart: { go(.phone) })

        case .phone:
            OnboardingFieldScreen(
                progress: step.progress,
                question: "What's your phone number?",
                subtitle: "So your coach can reach you.",
                placeholder: "(555) 123-4567",
                keyboard: .phonePad,
                contentType: .telephoneNumber,
                text: $profile.phone,
                isValid: OnboardingValidation.isValidPhone(profile.phone),
                onBack: { go(.welcome) },
                onContinue: { persist(); go(.email) }
            )

        case .email:
            OnboardingFieldScreen(
                progress: step.progress,
                question: "And your email?",
                subtitle: "For your results and updates.",
                placeholder: "you@example.com",
                keyboard: .emailAddress,
                contentType: .emailAddress,
                text: $profile.email,
                isValid: OnboardingValidation.isValidEmail(profile.email),
                onBack: { go(.phone) },
                onContinue: { persist(); go(.goals) }
            )

        case .goals:
            OnboardingMultiSelectScreen(
                progress: step.progress,
                question: "What do you want to work on?",
                subtitle: "Pick all that apply.",
                options: goalOptions,
                selection: $profile.goals,
                onBack: { go(.email) },
                onContinue: { persist(); go(.practices) }
            )

        case .practices:
            OnboardingMultiSelectScreen(
                progress: step.progress,
                question: "What practices do you do regularly?",
                subtitle: "Pick all that apply.",
                options: practiceOptions,
                selection: $profile.practices,
                onBack: { go(.goals) },
                onContinue: { persist(); go(.devices) }
            )

        case .devices:
            OnboardingMultiSelectScreen(
                progress: step.progress,
                question: "What do you track with?",
                subtitle: "Pick all that apply.",
                options: deviceOptions,
                selection: $profile.devices,
                onBack: { go(.practices) },
                onContinue: { persist(); go(.aboutYou) }
            )

        case .aboutYou:
            OnboardingAboutYouScreen(
                progress: step.progress,
                ageRange: $profile.ageRange,
                gender: $profile.gender,
                onBack: { go(.devices) },
                onContinue: { persist(); go(.connect) }
            )

        case .connect:
            OnboardingConnectScreen(
                progress: step.progress,
                onOpenBLE: { showBLE = true },
                onBack: { go(.aboutYou) },
                onFinish: { persist(); onComplete() }
            )
        }
    }

    // MARK: Navigation & persistence

    private func go(_ next: Step) {
        withAnimation { step = next }
    }

    private func persist() {
        store.save(profile)
    }
}
