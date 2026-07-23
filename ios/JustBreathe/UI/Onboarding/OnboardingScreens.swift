import SwiftUI

// MARK: - Shared chrome
//
// Every non-welcome step renders inside `OnboardingScaffold`: progress bar on
// top, a big bold question, optional subtitle, the step's content, and a
// Back / Continue footer. Keeps the whole flow feeling like one system.

struct OnboardingScaffold<Content: View>: View {
    let progress:      Double          // 0…1
    let question:      String
    let subtitle:      String?
    let canContinue:   Bool
    let continueTitle: String
    let onBack:        (() -> Void)?
    let onContinue:    () -> Void
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            OnboardingProgressBar(progress: progress)
                .padding(.top, 8)
                .padding(.horizontal, 24)

            VStack(alignment: .leading, spacing: 8) {
                Text(question)
                    .font(.system(size: 30, weight: .bold))
                    .foregroundStyle(Theme.text)
                    .fixedSize(horizontal: false, vertical: true)
                if let subtitle {
                    Text(subtitle)
                        .font(Theme.monoBody)
                        .foregroundStyle(Theme.dim)
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 28)
            .padding(.bottom, 20)

            ScrollView { content.padding(.horizontal, 24) }

            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.bg.ignoresSafeArea())
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if let onBack {
                Button(action: onBack) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Theme.dim)
                        .frame(width: 52, height: 52)
                        .background(Theme.surface)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
            }
            Button(action: onContinue) {
                Text(continueTitle)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(canContinue ? Theme.bg : Theme.dim)
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .background(canContinue ? Theme.accent : Theme.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .disabled(!canContinue)
        }
        .padding(.horizontal, 24)
        .padding(.top, 12)
        .padding(.bottom, 20)
    }
}

struct OnboardingProgressBar: View {
    let progress: Double
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.surface)
                Capsule()
                    .fill(Theme.accent)
                    .frame(width: max(6, geo.size.width * min(max(progress, 0), 1)))
                    .animation(.easeInOut(duration: 0.3), value: progress)
            }
        }
        .frame(height: 6)
    }
}

// MARK: - Option card (reels question choices)

struct OnboardingOption: Identifiable, Equatable {
    let id:    String    // stored value + identity
    let icon:  String    // SF Symbol
    var label: String { id }
    init(_ id: String, icon: String) { self.id = id; self.icon = icon }
}

struct OptionCard: View {
    let option:   OnboardingOption
    let selected: Bool
    let action:   () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: option.icon)
                    .font(.system(size: 18))
                    .foregroundStyle(selected ? Theme.bg : Theme.text)
                    .frame(width: 26)
                Text(option.label)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(selected ? Theme.bg : Theme.text)
                Spacer()
                if selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(Theme.bg)
                }
            }
            .padding(.horizontal, 16)
            .frame(height: 56)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? Theme.accent : Theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(selected ? Color.clear : Theme.border, lineWidth: 0.5)
            )
            .scaleEffect(selected ? 1.0 : 0.99)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: selected)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Welcome

struct OnboardingWelcomeScreen: View {
    let onStart: () -> Void
    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            Image(systemName: "wind")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(Theme.accent)
            Text("JUST BREATHE")
                .font(.system(size: 30, weight: .bold))
                .foregroundStyle(Theme.text)
                .padding(.top, 20)
            Text("Understand your nervous system,\none breath at a time.")
                .font(Theme.monoBody)
                .foregroundStyle(Theme.dim)
                .multilineTextAlignment(.center)
                .padding(.top, 10)
            Spacer()
            Button(action: onStart) {
                Text("Get Started")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.bg)
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .background(Theme.accent)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bg.ignoresSafeArea())
    }
}

// MARK: - Contact field step (phone / email)

struct OnboardingFieldScreen: View {
    let progress:     Double
    let question:     String
    let subtitle:     String?
    let placeholder:  String
    let keyboard:     UIKeyboardType
    let contentType:  UITextContentType?
    @Binding var text: String
    let isValid:      Bool
    let onBack:       (() -> Void)?
    let onContinue:   () -> Void

    var body: some View {
        OnboardingScaffold(
            progress: progress,
            question: question,
            subtitle: subtitle,
            canContinue: isValid,
            continueTitle: "Continue",
            onBack: onBack,
            onContinue: onContinue
        ) {
            TextField("", text: $text, prompt: Text(placeholder).foregroundColor(Theme.dim))
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(Theme.text)
                .keyboardType(keyboard)
                .textContentType(contentType)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .padding(.horizontal, 16)
                .frame(height: 56)
                .background(Theme.surface)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.border, lineWidth: 0.5))
                .padding(.top, 4)
        }
    }
}

// MARK: - Reels multi-select question

struct OnboardingMultiSelectScreen: View {
    let progress:  Double
    let question:  String
    let subtitle:  String?
    let options:   [OnboardingOption]
    @Binding var selection: [String]
    let onBack:     () -> Void
    let onContinue: () -> Void

    var body: some View {
        OnboardingScaffold(
            progress: progress,
            question: question,
            subtitle: subtitle,
            canContinue: !selection.isEmpty,
            continueTitle: "Continue",
            onBack: onBack,
            onContinue: onContinue
        ) {
            VStack(spacing: 10) {
                ForEach(options) { opt in
                    OptionCard(option: opt, selected: selection.contains(opt.id)) {
                        toggle(opt.id)
                    }
                }
            }
            .padding(.top, 4)
        }
    }

    private func toggle(_ id: String) {
        if let idx = selection.firstIndex(of: id) {
            selection.remove(at: idx)
        } else {
            selection.append(id)
        }
    }
}

// MARK: - About you (age + gender, one screen)

struct OnboardingAboutYouScreen: View {
    let progress: Double
    @Binding var ageRange: String?
    @Binding var gender:   String?
    let onBack:     () -> Void
    let onContinue: () -> Void

    private let ages    = ["18–24", "25–34", "35–44", "45–54", "55+"]
    private let genders = ["Female", "Male", "Non-binary", "Prefer not to say"]

    var body: some View {
        OnboardingScaffold(
            progress: progress,
            question: "A bit about you",
            subtitle: "This tailors your guidance.",
            canContinue: ageRange != nil && gender != nil,
            continueTitle: "Continue",
            onBack: onBack,
            onContinue: onContinue
        ) {
            VStack(alignment: .leading, spacing: 18) {
                pickerGroup(title: "AGE", options: ages, selection: $ageRange)
                pickerGroup(title: "GENDER", options: genders, selection: $gender)
            }
            .padding(.top, 4)
        }
    }

    private func pickerGroup(title: String, options: [String], selection: Binding<String?>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(Theme.monoLabel)
                .foregroundStyle(Theme.dim)
            FlowChips(options: options, selection: selection)
        }
    }
}

/// Simple wrapping chip row for single-select pickers.
struct FlowChips: View {
    let options: [String]
    @Binding var selection: String?

    var body: some View {
        FlexibleWrap(options, spacing: 8) { opt in
            let sel = selection == opt
            Button {
                selection = opt
            } label: {
                Text(opt)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(sel ? Theme.bg : Theme.text)
                    .padding(.horizontal, 14)
                    .frame(height: 40)
                    .background(sel ? Theme.accent : Theme.surface)
                    .clipShape(Capsule())
                    .overlay(Capsule().strokeBorder(sel ? Color.clear : Theme.border, lineWidth: 0.5))
            }
            .buttonStyle(.plain)
        }
    }
}

/// Minimal flow layout that wraps its children onto multiple lines.
struct FlexibleWrap<Data: RandomAccessCollection, Content: View>: View where Data.Element: Hashable {
    let data:    Data
    let spacing: CGFloat
    @ViewBuilder let content: (Data.Element) -> Content

    init(_ data: Data, spacing: CGFloat = 8, @ViewBuilder content: @escaping (Data.Element) -> Content) {
        self.data = data
        self.spacing = spacing
        self.content = content
    }

    var body: some View {
        WrapLayout(spacing: spacing) {
            ForEach(Array(data), id: \.self) { content($0) }
        }
    }
}

/// iOS 16+ Layout that flows subviews left-to-right, wrapping to new rows.
struct WrapLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var rowWidth: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if rowWidth + size.width > maxWidth, rowWidth > 0 {
                totalHeight += rowHeight + spacing
                rowWidth = 0
                rowHeight = 0
            }
            rowWidth += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        totalHeight += rowHeight
        return CGSize(width: maxWidth == .infinity ? rowWidth : maxWidth, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

// MARK: - Connect device step

struct OnboardingConnectScreen: View {
    let progress:    Double
    let onOpenBLE:   () -> Void
    let onBack:      () -> Void
    let onFinish:    () -> Void

    var body: some View {
        OnboardingScaffold(
            progress: progress,
            question: "Connect your Polar H10",
            subtitle: "Your chest strap streams the heart data that powers every insight.",
            canContinue: true,
            continueTitle: "Finish",
            onBack: onBack,
            onContinue: onFinish
        ) {
            VStack(spacing: 14) {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.system(size: 44, weight: .light))
                    .foregroundStyle(Theme.accent)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)

                Button(action: onOpenBLE) {
                    HStack(spacing: 8) {
                        Image(systemName: "plus.circle.fill")
                        Text("Connect device")
                    }
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.bg)
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .background(Theme.accent)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }

                Text("You can also do this later from the Live tab.")
                    .font(Theme.monoLabel)
                    .foregroundStyle(Theme.dim)
                    .multilineTextAlignment(.center)
                    .padding(.top, 4)
            }
            .padding(.top, 4)
        }
    }
}
