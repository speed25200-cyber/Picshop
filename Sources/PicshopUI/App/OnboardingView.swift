#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import TipKit
import PicshopSpeech
import PicshopImaging

/// First launch, three pages: talk to your photos, a conversation rather than
/// menus (and the microphone), private by default. A slow spectrum at the
/// top, custom dots, one white button.
public struct OnboardingView: View {
    @Environment(\.picshop) private var app
    @State private var page = 0
    @State private var micGranted = VoiceController.permissionsGranted
    @State private var permissionsAsked = false
    @State private var isAsking = false

    static let pageCount = 3

    public init() {}

    public var body: some View {
        ZStack {
            PSTheme.ink.ignoresSafeArea()
            // The spectrum over the top 55 %, animated and never blurred.
            GeometryReader { proxy in
                IntelligenceField(animated: true)
                    .frame(height: proxy.size.height * 0.55)
                    .overlay {
                        LinearGradient(stops: [
                            .init(color: PSTheme.ink.opacity(0), location: 0.35),
                            .init(color: PSTheme.ink, location: 1),
                        ], startPoint: .top, endPoint: .bottom)
                    }
                    .opacity(0.45)
            }
            .ignoresSafeArea()
            .accessibilityHidden(true)
            VStack(spacing: 0) {
                TabView(selection: $page) {
                    OnboardingTalkPage(isActive: page == 0).tag(0)
                    OnboardingConversationPage(isActive: page == 1).tag(1)
                    OnboardingPrivacyPage().tag(2)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                OnboardingDots(count: Self.pageCount, current: page)
                    .padding(.vertical, PSSpacing.large)
                buttons
                    .padding(.horizontal, PSSpacing.xLarge)
                    .padding(.bottom, PSSpacing.mediumLarge)
            }
        }
        .preferredColorScheme(.dark)
    }

    /// Pinned at the bottom: the page's primary action, then its secondary one
    /// (a fixed 44 pt slot, so the primary never moves between pages).
    @ViewBuilder
    private var buttons: some View {
        VStack(spacing: 0) {
            switch page {
            case 0:
                OnboardingPrimaryButton(title: L("Continue")) { advance() }
                secondarySlot(nil)
            case 1:
                if permissionsAsked {
                    OnboardingPrimaryButton(title: L("Continue"), systemImage: micGranted ? "checkmark.circle.fill" : nil) { advance() }
                    secondarySlot(nil)
                } else {
                    OnboardingPrimaryButton(title: L("Allow microphone"), isBusy: isAsking) { askPermissions() }
                    secondarySlot(L("Later")) { advance() }
                }
            default:
                OnboardingPrimaryButton(title: L("Get started")) {
                    Haptics.magic()
                    app?.settings.hasCompletedOnboarding = true
                }
                secondarySlot(nil)
            }
        }
        .animation(PSMotion.standard, value: page)
        .animation(PSMotion.standard, value: permissionsAsked)
    }

    @ViewBuilder
    private func secondarySlot(_ title: String?, action: @escaping () -> Void = {}) -> some View {
        if let title {
            Button(action: action) {
                Text(title)
                    .font(.subheadline)
                    .foregroundStyle(PSTheme.textSecondary)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.top, PSSpacing.small)
        } else {
            Color.clear.frame(height: 44 + PSSpacing.small).accessibilityHidden(true)
        }
    }

    private func advance() {
        Haptics.tap()
        withAnimation(PSMotion.standard) { page = min(page + 1, Self.pageCount - 1) }
    }

    /// The microphone and speech recognition, then adding to Photos; the
    /// button then reads Continue, with a check when the microphone is allowed.
    private func askPermissions() {
        guard !isAsking else { return }
        Haptics.tap()
        isAsking = true
        Task {
            let granted = await VoiceController.requestPermissions()
            _ = await PhotoLibrary.requestAddAccess()
            micGranted = granted
            isAsking = false
            permissionsAsked = true
            if granted { Haptics.success() }
        }
    }
}

/// The white 52 pt primary button of onboarding.
struct OnboardingPrimaryButton: View {
    let title: String
    var systemImage: String?
    var isBusy = false
    let action: () -> Void

    init(title: String, systemImage: String? = nil, isBusy: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.isBusy = isBusy
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: PSSpacing.small) {
                if isBusy {
                    ProgressView().tint(PSTheme.onPrimary)
                } else if let systemImage {
                    Image(systemName: systemImage)
                        .foregroundStyle(PSTheme.success)
                        .transition(.scale.combined(with: .opacity))
                }
                Text(title)
            }
            .font(.headline)
            .foregroundStyle(PSTheme.onPrimary)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Capsule())
        }
        .buttonStyle(.glassProminent)
        .buttonBorderShape(.capsule)
        .tint(PSTheme.primary)
        .frame(height: PSMetrics.largeButton)
        .disabled(isBusy)
    }
}

/// Three 6 pt dots, the current one a 16 × 6 white capsule.
struct OnboardingDots: View {
    let count: Int
    let current: Int

    var body: some View {
        HStack(spacing: 8) {
            ForEach(0..<count, id: \.self) { index in
                Capsule()
                    .fill(index == current ? Color.white : Color.white.opacity(0.3))
                    .frame(width: index == current ? 16 : 6, height: 6)
            }
        }
        .animation(PSMotion.quick, value: current)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(format: L("Page %d of %d"), current + 1, count))
    }
}

/// Chooses between onboarding and the library, and feeds the performance
/// budget into the environment so every surface can adapt to heat.
public struct RootView: View {
    let environment: AppEnvironment

    public init(environment: AppEnvironment) {
        self.environment = environment
    }

    public var body: some View {
        Group {
            if environment.settings.hasCompletedOnboarding {
                HomeView()
            } else {
                OnboardingView()
            }
        }
        .environment(\.picshop, environment)
        .environment(\.psEffects, environment.performance.effectsLevel)
        .environment(\.psReducedMotion, environment.performance.reduceMotion)
        .animation(.easeInOut, value: environment.settings.hasCompletedOnboarding)
        .task {
            // The Live orb's tip; configuring twice throws, which is harmless.
            try? Tips.configure()
        }
    }
}
#endif
