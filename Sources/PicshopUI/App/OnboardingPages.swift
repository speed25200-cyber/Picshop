#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import PicshopIntent

/// One onboarding page: the hero over the top half, then a title and a short
/// text. Scrolls only when the text is too large to fit.
private struct OnboardingPage<Hero: View>: View {
    let title: String
    let text: String
    var footnote: String?
    @ViewBuilder var hero: () -> Hero

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    hero()
                        .frame(maxWidth: .infinity)
                        .frame(height: max(260, proxy.size.height * 0.52))
                    Text(title)
                        .font(.title.bold())
                        .foregroundStyle(PSTheme.textPrimary)
                        .multilineTextAlignment(.center)
                        .accessibilityAddTraits(.isHeader)
                        .padding(.bottom, PSSpacing.medium)
                    Text(text)
                        .font(.body)
                        .foregroundStyle(PSTheme.textSecondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 330)
                    if let footnote {
                        Text(footnote)
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(PSTheme.textPrimary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: 330)
                            .padding(.top, PSSpacing.medium)
                    }
                }
                .padding(.horizontal, PSSpacing.xLarge)
                .frame(maxWidth: .infinity, minHeight: proxy.size.height, alignment: .top)
            }
            .scrollBounceBehavior(.basedOnSize)
            .scrollIndicators(.hidden)
        }
    }
}

// MARK: - Page 1

/// 'Talk to your photos.': the orb speaking a demo line.
struct OnboardingTalkPage: View {
    let isActive: Bool

    var body: some View {
        OnboardingPage(title: L("Talk to your photos."),
                       text: L("Say what you want and PicShop does it — and suggests ideas as you talk, like a real conversation.")) {
            OnboardingSpeakingOrb(isActive: isActive)
        }
    }
}

/// LiveOrb at 160 pt on a scripted voice, and the line it "says", word by word.
private struct OnboardingSpeakingOrb: View {
    let isActive: Bool
    @State private var meter = LiveMeter()
    @State private var shownWords = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.psReducedMotion) private var reducedMotion

    private var words: [String] {
        L("Lovely light! Shall we brighten the sky?").split(separator: " ").map(String.init)
    }

    var body: some View {
        let still = reduceMotion || reducedMotion
        VStack(spacing: PSSpacing.xLarge) {
            LiveOrb(size: PSMetrics.orbOnboarding, state: .speaking, meter: meter)
            Text(words.prefix(still ? words.count : shownWords).joined(separator: " "))
                .font(.title3.weight(.medium))
                .foregroundStyle(PSTheme.captionPrimary)
                .multilineTextAlignment(.center)
                .frame(minHeight: 56, alignment: .top)
                .padding(.horizontal, PSSpacing.xLarge)
                .animation(PSMotion.captionWord, value: shownWords)
                .accessibilityLabel(L("Lovely light! Shall we brighten the sky?"))
        }
        .task(id: isActive && !still) {
            guard isActive, !still else {
                meter.output = 0
                return
            }
            await speak()
        }
    }

    /// A voice-like envelope at 30 Hz, a word every 180 ms, then a pause; again.
    private func speak() async {
        let count = words.count
        while !Task.isCancelled {
            shownWords = 0
            let start = Date()
            let speaking = Double(count) * 0.18 + 0.4
            while !Task.isCancelled {
                let t = Date().timeIntervalSince(start)
                if t > speaking + 1.8 { break }
                let talking = t < speaking
                let syllables = abs(sin(t * 11)) * 0.55 + abs(sin(t * 4.3)) * 0.35
                meter.output = talking ? min(1, 0.15 + syllables) : 0
                let revealed = min(count, Int(t / 0.18) + 1)
                if revealed != shownWords { shownWords = revealed }
                try? await Task.sleep(for: .milliseconds(33))
            }
        }
        meter.output = 0
    }
}

// MARK: - Page 2

/// 'A conversation, not menus.': a sample picture whose ideas change as you watch.
struct OnboardingConversationPage: View {
    let isActive: Bool

    var body: some View {
        OnboardingPage(title: L("A conversation, not menus."),
                       text: L("Interrupt any time, it's listening. Manual tools stay one tap away in Tools.")) {
            OnboardingIdeasDemo(isActive: isActive)
        }
    }
}

private struct OnboardingIdeasDemo: View {
    let isActive: Bool
    @State private var round = 0
    @Environment(\.psReducedMotion) private var reducedMotion

    private var sets: [[IdeaChipModel]] {
        [
            [IdeaChipModel(id: "sky", title: L("Brighten the sky"), symbol: "sun.max"),
             IdeaChipModel(id: "blur", title: L("Blur the background"), symbol: "camera.aperture"),
             IdeaChipModel(id: "clean", title: L("Remove passers-by"), symbol: "eraser")],
            [IdeaChipModel(id: "golden", title: L("Golden hour"), symbol: "cloud.sun", fromClaude: true),
             IdeaChipModel(id: "portrait", title: L("Soft portrait"), symbol: "person.crop.circle", fromClaude: true),
             IdeaChipModel(id: "crop", title: L("Crop"), symbol: "crop", fromClaude: true)],
            [IdeaChipModel(id: "mono", title: L("Black & white"), symbol: "circle.lefthalf.filled"),
             IdeaChipModel(id: "expand", title: L("Expand the image"), symbol: "arrow.up.left.and.arrow.down.right"),
             IdeaChipModel(id: "text", title: L("Text behind"), symbol: "textformat")],
        ]
    }

    var body: some View {
        VStack(spacing: PSSpacing.large) {
            OnboardingSamplePicture()
                .frame(width: 240, height: 300)
                .clipShape(RoundedRectangle(cornerRadius: PSRadius.hero, style: .continuous))
                .accessibilityHidden(true)
            IdeaChipsRow(items: sets[round % sets.count]) { _ in Haptics.tap() }
                .accessibilityHidden(true)
        }
        .task(id: isActive) {
            guard isActive else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                withAnimation(reducedMotion ? .easeInOut(duration: 0.2) : PSMotion.ideas) { round += 1 }
            }
        }
    }
}

/// A drawn landscape standing in for a photo: no asset to ship, sharp at any size.
private struct OnboardingSamplePicture: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.16, green: 0.26, blue: 0.52), Color(red: 0.96, green: 0.62, blue: 0.46), Color(red: 1.0, green: 0.82, blue: 0.62)],
                           startPoint: .top, endPoint: .bottom)
            RadialGradient(colors: [Color(red: 1, green: 0.93, blue: 0.75), Color(red: 1, green: 0.8, blue: 0.5).opacity(0)], center: UnitPoint(x: 0.68, y: 0.56), startRadius: 6, endRadius: 90)
            GeometryReader { proxy in
                let size = proxy.size
                Path { path in
                    path.move(to: CGPoint(x: 0, y: size.height * 0.66))
                    path.addLine(to: CGPoint(x: size.width * 0.28, y: size.height * 0.5))
                    path.addLine(to: CGPoint(x: size.width * 0.5, y: size.height * 0.62))
                    path.addLine(to: CGPoint(x: size.width * 0.76, y: size.height * 0.46))
                    path.addLine(to: CGPoint(x: size.width, y: size.height * 0.6))
                    path.addLine(to: CGPoint(x: size.width, y: size.height))
                    path.addLine(to: CGPoint(x: 0, y: size.height))
                    path.closeSubpath()
                }
                .fill(Color(red: 0.23, green: 0.2, blue: 0.3))
                Path { path in
                    path.move(to: CGPoint(x: 0, y: size.height * 0.8))
                    path.addQuadCurve(to: CGPoint(x: size.width, y: size.height * 0.74), control: CGPoint(x: size.width * 0.45, y: size.height * 0.66))
                    path.addLine(to: CGPoint(x: size.width, y: size.height))
                    path.addLine(to: CGPoint(x: 0, y: size.height))
                    path.closeSubpath()
                }
                .fill(Color(red: 0.1, green: 0.1, blue: 0.14))
            }
        }
    }
}

// MARK: - Page 3

/// 'Private by default.': what stays on the iPhone, what Live with Claude sends.
struct OnboardingPrivacyPage: View {
    var body: some View {
        OnboardingPage(title: L("Private by default."),
                       text: L("PicShop works entirely on your iPhone. If you add a Claude key in Settings › Live, Live mode sends Anthropic the text of what you say and, if you allow it, a reduced copy of the picture — never the audio. Outside Live mode, nothing is sent."),
                       footnote: L("To talk with Claude, add your key in Settings › Live.")) {
            Image(systemName: "lock.shield")
                .font(.system(size: 52, weight: .regular))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(PSTheme.textPrimary)
                .frame(width: 128, height: 128)
                .psGlass(shape: AnyShape(Circle()))
                .accessibilityHidden(true)
        }
    }
}
#endif
