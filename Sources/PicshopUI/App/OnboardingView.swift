#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import PicshopSpeech
import PicshopImaging

/// First launch: a slow spectrum behind the name (the one AI moment of the
/// screen), four short pages — photo, video, voice, privacy — then the two
/// permissions and one button.
public struct OnboardingView: View {
    @Environment(\.picshop) private var app
    @State private var page = 0
    @State private var micGranted = VoiceController.permissionsGranted
    @State private var photosGranted = false

    public init() {}

    private struct Page {
        let symbols: [String]
        let title: String
        let text: String
    }

    private var pages: [Page] {
        [
            Page(symbols: ["wand.and.stars", "person.crop.rectangle", "eraser"], title: L("Photo, magically."),
                 text: L("Erase or move anything, expand the frame, refocus after the shot, put the title behind a person, grade like a colourist. One tap or one sentence.")),
            Page(symbols: ["captions.bubble", "metronome", "rectangle.portrait"], title: L("Video, like a pro."),
                 text: L("Edit by the words, captions from the voice, every “euh” cut, cuts on the beat, titles that follow a face, a recap of the best moments.")),
            Page(symbols: ["waveform"], title: L("Just say it."),
                 text: L("“Efface le chien”, “make it warmer”, “ajoute des sous-titres”. PicShop understands French and English and edits instantly.")),
            Page(symbols: ["lock.shield"], title: L("Private by design."),
                 text: L("Recognition, language models and every pixel stay on your iPhone. Nothing is uploaded, ever.")),
        ]
    }

    public var body: some View {
        ZStack {
            PSTheme.ink.ignoresSafeArea()
            IntelligenceField(animated: true)
                .frame(height: 520)
                .blur(radius: 60)
                .opacity(0.5)
                .frame(maxHeight: .infinity, alignment: .top)
                .ignoresSafeArea()
            LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: PSTheme.ink.opacity(0.4), location: 0.35), .init(color: PSTheme.ink, location: 0.62)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
            VStack(spacing: PSSpacing.xLarge) {
                VStack(spacing: PSSpacing.xSmall) {
                    Text("PicShop").font(PSFont.largeTitle()).foregroundStyle(PSTheme.textPrimary)
                    Text(L("Photo and video, magically.")).font(PSFont.callout()).foregroundStyle(PSTheme.textSecondary)
                }
                .padding(.top, PSSpacing.xLarge)
                TabView(selection: $page) {
                    ForEach(Array(pages.enumerated()), id: \.offset) { index, item in
                        VStack(spacing: PSSpacing.large) {
                            PSGlassContainer(spacing: PSSpacing.medium) {
                                HStack(spacing: -10) {
                                    ForEach(Array(item.symbols.enumerated()), id: \.offset) { position, symbol in
                                        Image(systemName: symbol)
                                            .font(.system(size: item.symbols.count == 1 ? 40 : 26, weight: .regular))
                                            .symbolRenderingMode(.hierarchical)
                                            .foregroundStyle(PSTheme.textPrimary)
                                            .frame(width: item.symbols.count == 1 ? 104 : 72, height: item.symbols.count == 1 ? 104 : 72)
                                            .psGlass(shape: AnyShape(Circle()))
                                            .offset(y: position == 1 ? -10 : 0)
                                            .zIndex(position == 1 ? 1 : 0)
                                    }
                                }
                            }
                            .symbolEffect(.bounce, value: page == index)
                            .padding(.bottom, PSSpacing.small)
                            Text(item.title).font(.title.weight(.bold)).foregroundStyle(PSTheme.textPrimary).multilineTextAlignment(.center)
                            Text(item.text).font(PSFont.callout()).foregroundStyle(PSTheme.textSecondary).multilineTextAlignment(.center).padding(.horizontal, PSSpacing.xxLarge)
                        }
                        .tag(index)
                    }
                }
                .tabViewStyle(.page)
                .indexViewStyle(.page(backgroundDisplayMode: .always))

                VStack(spacing: PSSpacing.small) {
                    permissionRow(title: L("Microphone & speech"), granted: micGranted, symbol: "mic.fill") {
                        micGranted = await VoiceController.requestPermissions()
                    }
                    permissionRow(title: L("Save to Photos"), granted: photosGranted, symbol: "photo.on.rectangle") {
                        photosGranted = await PhotoLibrary.requestAddAccess()
                    }
                    Button {
                        Haptics.magic()
                        app?.settings.hasCompletedOnboarding = true
                    } label: { Text(L("Start editing")) }
                        .buttonStyle(PrimaryButtonStyle())
                        .padding(.top, PSSpacing.small)
                }
                .padding(.horizontal, PSSpacing.xLarge)
                .padding(.bottom, PSSpacing.mediumLarge)
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
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(granted ? PSTheme.success : PSTheme.textPrimary)
                    .frame(width: 32, height: 32)
                    .background(PSTheme.fill, in: Circle())
                Text(title).font(PSFont.control(selected: true))
                Spacer()
                Image(systemName: granted ? "checkmark.circle.fill" : "chevron.right")
                    .font(.system(size: granted ? 20 : 13, weight: .medium))
                    .foregroundStyle(granted ? PSTheme.success : PSTheme.textTertiary)
                    .contentTransition(.symbolEffect(.replace))
                    .symbolEffect(.bounce, value: granted)
            }
            .foregroundStyle(PSTheme.textPrimary)
            .padding(.horizontal, PSSpacing.medium).padding(.vertical, 10)
            .psGlass(interactive: true)
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
