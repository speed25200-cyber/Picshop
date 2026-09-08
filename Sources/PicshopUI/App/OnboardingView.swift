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
            PSTheme.canvas.ignoresSafeArea()
            VStack(spacing: 28) {
                TabView(selection: $page) {
                    ForEach(Array(pages.enumerated()), id: \.offset) { index, item in
                        VStack(spacing: 18) {
                            Image(systemName: item.0)
                                .font(.system(size: 64, weight: .light))
                                .foregroundStyle(PSTheme.voiceGradient)
                                .padding(.bottom, 8)
                            Text(item.1).font(PSFont.title(30)).foregroundStyle(PSTheme.textPrimary).multilineTextAlignment(.center)
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
            HStack {
                Image(systemName: symbol).frame(width: 26)
                Text(title).font(PSFont.headline(15))
                Spacer()
                Image(systemName: granted ? "checkmark.circle.fill" : "circle").foregroundStyle(granted ? PSTheme.success : PSTheme.textSecondary)
            }
            .foregroundStyle(PSTheme.textPrimary)
            .padding(.horizontal, 16).padding(.vertical, 12)
        }
        .buttonStyle(.plain)
        .psGlass(interactive: true, shape: AnyShape(RoundedRectangle(cornerRadius: 18, style: .continuous)))
    }
}

/// Chooses between onboarding and the library.
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
        .animation(.easeInOut, value: environment.settings.hasCompletedOnboarding)
    }
}
#endif
