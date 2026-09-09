#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import PicshopSpeech
import PicshopImaging

/// Three-screen introduction plus permissions.
public struct OnboardingView: View {
    @Environment(\.picshop) private var app
    @State private var page = 0
    @State private var micGranted = VoiceController.permissionsGranted
    @State private var photosGranted = false

    public init() {}

    private let pages: [(String, String, String)] = [
        ("waveform.and.mic", L("Just say it"), L("“Efface le chien”, “make it warmer”, “coupe les 3 premières secondes”. PicShop understands French and English and edits instantly.")),
        ("sparkles.rectangle.stack", L("Pro tools, zero friction"), L("Non-destructive layers, looks, cutouts, object removal, and a full video timeline — all on your iPhone.")),
        ("lock.shield", L("Private by design"), L("Recognition, language models and every pixel stay on device. Nothing is uploaded, ever.")),
    ]

    public var body: some View {
        ZStack {
            AmbientBackground().ignoresSafeArea()
            VStack(spacing: 28) {
                TabView(selection: $page) {
                    ForEach(Array(pages.enumerated()), id: \.offset) { index, item in
                        VStack(spacing: 18) {
                            Image(systemName: item.0)
                                .font(.system(size: 44, weight: .medium))
                                .symbolRenderingMode(.hierarchical)
                                .foregroundStyle(.white)
                                .frame(width: 112, height: 112)
                                .background {
                                    let shape = RoundedRectangle(cornerRadius: 30, style: .continuous)
                                    HeroMesh().clipShape(shape)
                                        .overlay(shape.fill(LinearGradient(colors: [Color.white.opacity(0.2), .clear], startPoint: .top, endPoint: .center)))
                                }
                                .overlay(RoundedRectangle(cornerRadius: 30, style: .continuous).strokeBorder(Color.white.opacity(0.35), lineWidth: 1))
                                .shadow(color: PSTheme.voice.opacity(0.45), radius: 30, y: 14)
                                .padding(.bottom, 12)
                                .symbolEffect(.bounce, value: page == index)
                            Text(item.1).font(PSFont.display(32)).foregroundStyle(PSTheme.textPrimary).multilineTextAlignment(.center).tracking(-0.8)
                            Text(item.2).font(PSFont.body(16)).foregroundStyle(PSTheme.textSecondary).multilineTextAlignment(.center).padding(.horizontal, 28)
                        }
                        .tag(index)
                    }
                }
                .tabViewStyle(.page)
                .indexViewStyle(.page(backgroundDisplayMode: .always))

                VStack(spacing: 12) {
                    permissionRow(title: L("Microphone & speech"), granted: micGranted, symbol: "mic.fill") {
                        micGranted = await VoiceController.requestPermissions()
                    }
                    permissionRow(title: L("Save to Photos"), granted: photosGranted, symbol: "photo.on.rectangle") {
                        photosGranted = await PhotoLibrary.requestAddAccess()
                    }
                    Button {
                        Haptics.confirm()
                        app?.settings.hasCompletedOnboarding = true
                    } label: { Text(L("Start editing")) }
                        .buttonStyle(PrimaryButtonStyle())
                        .padding(.top, 6)
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 24)
            }
        }
        .preferredColorScheme(.dark)
    }

    private func permissionRow(title: String, granted: Bool, symbol: String, request: @escaping () async -> Void) -> some View {
        Button {
            Haptics.tap()
            Task { await request() }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 14, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill((granted ? PSTheme.success : PSTheme.accent).gradient))
                Text(title).font(PSFont.headline(15))
                Spacer()
                Image(systemName: granted ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(granted ? PSTheme.success : PSTheme.textTertiary)
                    .contentTransition(.symbolEffect(.replace))
                    .symbolEffect(.bounce, value: granted)
            }
            .foregroundStyle(PSTheme.textPrimary)
            .padding(.horizontal, 14).padding(.vertical, 11)
            .psCard(cornerRadius: 18, shadow: false)
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(PSTheme.success.opacity(granted ? 0.5 : 0), lineWidth: 1))
        }
        .buttonStyle(PSPressStyle(scale: 0.98))
        .animation(PSMotion.quick, value: granted)
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
    }
}
#endif
