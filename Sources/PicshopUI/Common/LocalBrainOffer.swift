#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import PicshopIntent

/// The brain pill in the studio's top bar, between Close and Undo (where the
/// old cloud badge sat, so the dock and the picture never move for it).
///
/// While Live runs it names the brain answering this conversation: the local
/// model by name, Apple Intelligence or the commands, with "Chargement du
/// cerveau…" while the weights load and a ring while they download. At rest it
/// offers the local brain when this iPhone can run it and it is not downloaded
/// yet, shows the download's progress, and "Chargement du cerveau…" while the
/// weights load. A tap opens `LocalBrainOfferSheet` whenever there is something
/// to decide. A leaf: only this view reads the route and the hub's status.
struct LocalBrainPill: View {
    let live: LiveSession
    /// The top bar's glass namespace, so the pill melts into its neighbours.
    var glass: Namespace.ID?

    @State private var showsSheet = false
    @AppStorage(LocalBrainPillLook.snoozeKey) private var snoozedUntil: Double = 0
    private let hub = LocalBrainHub.shared

    init(live: LiveSession, glass: Namespace.ID? = nil) {
        self.live = live
        self.glass = glass
    }

    var body: some View {
        let isLive = live.isLive
        let offersAtRest = live.canGoLive && Date().timeIntervalSince1970 >= snoozedUntil
        let look = LocalBrainPillLook.make(status: hub.status, route: isLive ? live.route : nil, offersAtRest: offersAtRest)
        ZStack {
            if let look {
                pill(look)
                    .transition(AnyTransition.opacity.combined(with: .scale(scale: 0.85)))
            }
        }
        .animation(PSMotion.morph, value: look?.identity)
        .sheet(isPresented: $showsSheet) {
            LocalBrainOfferSheet(onClose: { showsSheet = false }, onLater: { LocalBrainPillLook.snoozeOffer() })
        }
    }

    @ViewBuilder
    private func pill(_ look: LocalBrainPillLook) -> some View {
        let label = ViewThatFits(in: .horizontal) {
            LocalBrainPillLabel(look: look, showsTitle: true)
            LocalBrainPillLabel(look: look, showsTitle: false)
        }
        .padding(.horizontal, 11)
        .frame(height: PSMetrics.badge)
        .psGlass(interactive: look.opensSheet, variant: .clear)
        .modifier(OptionalGlassID(id: "brain", namespace: glass))
        .frame(minHeight: PSMetrics.barButton)
        .contentShape(Capsule())
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
        if look.opensSheet {
            Button {
                Haptics.tap()
                showsSheet = true
            } label: {
                label
            }
            .buttonStyle(PSPressStyle(scale: 0.95))
            .accessibilityLabel(look.accessibility)
            .accessibilityHint(L("Shows the local brain and its download."))
        } else {
            label
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(look.accessibility)
        }
    }

    /// The pill's words for a Live route.
    static func title(_ route: LiveRoute) -> String {
        switch route.brain {
        case .model: return route.modelName ?? L("Local brain")
        case .onDevice: return "Apple Intelligence"
        case .commands: return L("Commands")
        }
    }

    static func symbol(_ brain: LiveRoute.Brain) -> String {
        switch brain {
        case .model: return "brain"
        case .onDevice: return "apple.intelligence"
        case .commands: return "text.bubble"
        }
    }
}

/// What the pill shows for a status and, while Live runs, a route. Pure, so the
/// rules read in one place.
struct LocalBrainPillLook: Equatable {
    enum Accessory: Equatable {
        case symbol(String)
        /// Download progress, 0…1.
        case ring(Double)
        case spinner
    }

    var title: String
    var accessory: Accessory
    var isWarning = false
    /// A tap opens the offer sheet (there is something to decide or to watch).
    var opensSheet: Bool
    var accessibility: String
    /// Changes when the pill changes kind, not with every progress step.
    var identity: String

    /// "Plus tard" in the sheet hides the offer at rest for a week.
    static let snoozeKey = "localBrainOfferSnoozedUntil.v1"
    static let snoozeInterval: TimeInterval = 7 * 24 * 3600

    /// The person said no for now (Plus tard, deleted it, or declined at first
    /// run): the offer at rest waits a week. Progress and loading still show.
    static func snoozeOffer() {
        UserDefaults.standard.set(Date().addingTimeInterval(snoozeInterval).timeIntervalSince1970, forKey: snoozeKey)
    }

    static func make(status: LocalBrainStatus, route: LiveRoute?, offersAtRest: Bool) -> LocalBrainPillLook? {
        let canOffer = status.model != nil
        if let route {
            // Live: which brain answers, and what the local brain is doing meanwhile.
            let name = LocalBrainPill.title(route)
            let spoken = String(format: L("Live answers with %@, on the iPhone."), name)
            let offers = canOffer && route.brain != .model && LocalBrainText.isOffered(status.phase)
            switch status.phase {
            case .loading where route.brain != .model:
                return LocalBrainPillLook(title: L("Loading the brain…"), accessory: .spinner, opensSheet: false,
                                          accessibility: L("Loading the brain…") + " " + spoken, identity: "live-loading")
            case .downloading(let progress) where route.brain != .model:
                return LocalBrainPillLook(title: name, accessory: .ring(progress), opensSheet: true,
                                          accessibility: spoken + " " + LocalBrainText.phase(status.phase), identity: "live-downloading-\(route.brain.rawValue)")
            default:
                return LocalBrainPillLook(title: name, accessory: .symbol(LocalBrainPill.symbol(route.brain)), opensSheet: offers,
                                          accessibility: spoken, identity: "live-\(route.brain.rawValue)-\(name)")
            }
        }
        switch status.phase {
        case .notInstalled where canOffer && offersAtRest:
            return LocalBrainPillLook(title: L("Local brain"), accessory: .symbol("arrow.down.circle"), opensSheet: true,
                                      accessibility: L("Download the local brain"), identity: "offer")
        case .failed where canOffer && offersAtRest:
            return LocalBrainPillLook(title: L("Local brain"), accessory: .symbol("exclamationmark.triangle.fill"), isWarning: true, opensSheet: true,
                                      accessibility: LocalBrainText.phase(status.phase), identity: "failed")
        case .waitingForWiFi where canOffer && offersAtRest:
            return LocalBrainPillLook(title: L("Waiting for Wi‑Fi"), accessory: .symbol("wifi"), opensSheet: true,
                                      accessibility: L("Local brain") + ", " + L("Waiting for Wi‑Fi"), identity: "wifi")
        case .downloading(let progress) where canOffer:
            let percent = LocalBrainText.percent(progress)
            return LocalBrainPillLook(title: String(format: L("Local brain · %@"), percent), accessory: .ring(progress), opensSheet: true,
                                      accessibility: L("Local brain") + ", " + LocalBrainText.phase(status.phase), identity: "downloading")
        case .verifying where canOffer:
            return LocalBrainPillLook(title: L("Verifying…"), accessory: .spinner, opensSheet: true,
                                      accessibility: L("Local brain") + ", " + L("Verifying…"), identity: "verifying")
        case .loading:
            return LocalBrainPillLook(title: L("Loading the brain…"), accessory: .spinner, opensSheet: false,
                                      accessibility: L("Loading the brain…"), identity: "loading")
        default:
            return nil
        }
    }
}

/// The pill's content: the accessory, then the title when it fits.
private struct LocalBrainPillLabel: View {
    let look: LocalBrainPillLook
    let showsTitle: Bool

    var body: some View {
        HStack(spacing: 6) {
            accessory
            if showsTitle {
                Text(look.title)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(look.isWarning ? PSTheme.warning : PSTheme.textPrimary)
    }

    @ViewBuilder
    private var accessory: some View {
        switch look.accessory {
        case .symbol(let name):
            Image(systemName: name)
                .font(.system(size: 11, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .contentTransition(.symbolEffect(.replace))
        case .ring(let progress):
            LocalBrainRing(progress: progress, lineWidth: 2)
                .frame(width: 12, height: 12)
        case .spinner:
            ProgressView()
                .controlSize(.mini)
                .tint(PSTheme.textPrimary)
                .frame(width: 12, height: 12)
        }
    }
}

/// A thin download ring.
struct LocalBrainRing: View {
    let progress: Double
    var lineWidth: CGFloat = 2

    var body: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.18), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: CGFloat(max(0.03, min(1, progress))))
                .stroke(PSTheme.textPrimary, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .animation(PSMotion.standard, value: progress)
        .accessibilityHidden(true)
    }
}

/// `glassEffectID` when the owner gives a namespace.
private struct OptionalGlassID: ViewModifier {
    let id: String
    let namespace: Namespace.ID?

    func body(content: Content) -> some View {
        if let namespace {
            content.glassEffectID(id, in: namespace)
        } else {
            content
        }
    }
}

#if DEBUG
#Preview("Brain pill") {
    let info = LocalModelInfo(id: LocalModelTiering.maxModelID, displayName: "Qwen3.5 4B", revision: "preview", contextTokens: 8_192,
                              supportsVision: true, promptSize: .full)
    let decision = LocalTierDecision(tier: .max, reason: .recommended)
    let phases: [LocalBrainStatus.Phase] = [.notInstalled, .waitingForWiFi, .downloading(progress: 0.42), .verifying, .loading, .failed("Réseau")]
    let resting: [LocalBrainPillLook] = phases.compactMap { phase in
        LocalBrainPillLook.make(status: LocalBrainStatus(phase: phase, decision: decision, model: info, downloadBytes: 3_060_000_000),
                                route: nil, offersAtRest: true)
    }
    let live: [(LocalBrainStatus.Phase, LiveRoute)] = [
        (.ready, LiveRoute(brain: .model, modelName: "Qwen3.5 4B")),
        (.loading, LiveRoute(brain: .onDevice)),
        (.downloading(progress: 0.7), LiveRoute(brain: .commands)),
    ]
    let talking: [LocalBrainPillLook] = live.compactMap { phase, route in
        LocalBrainPillLook.make(status: LocalBrainStatus(phase: phase, decision: decision, model: info), route: route, offersAtRest: true)
    }
    let looks = resting + talking
    VStack(spacing: 12) {
        ForEach(Array(looks.enumerated()), id: \.offset) { _, look in
            LocalBrainPillLabel(look: look, showsTitle: true)
                .padding(.horizontal, 11)
                .frame(height: PSMetrics.badge)
                .psGlass(variant: .clear)
        }
    }
    .padding()
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(LinearGradient(colors: [.blue, .orange], startPoint: .top, endPoint: .bottom))
}
#endif

// MARK: - Offer sheet

/// The local brain, offered: what it is, its size, and how to get it. Wi‑Fi by
/// default (the download waits for Wi‑Fi and never touches cellular data);
/// cellular only after a confirmation that shows the size. While it downloads,
/// the progress and Annuler; once it is here, where it stands.
struct LocalBrainOfferSheet: View {
    let onClose: () -> Void
    /// "Plus tard": the owner decides what later means (the pill hides the offer for a week).
    var onLater: (() -> Void)?

    init(onClose: @escaping () -> Void, onLater: (() -> Void)? = nil) {
        self.onClose = onClose
        self.onLater = onLater
    }

    var body: some View {
        LocalBrainOfferContent(onClose: onClose, onLater: onLater)
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
            .preferredColorScheme(.dark)
    }
}

/// The sheet's content: a leaf, the only part that reads the hub's status (and
/// so redraws with the download's progress).
private struct LocalBrainOfferContent: View {
    let onClose: () -> Void
    let onLater: (() -> Void)?

    @Environment(\.picshop) private var app
    @State private var confirmsCellular = false
    private let hub = LocalBrainHub.shared

    var body: some View {
        let status = hub.status
        ScrollView {
            VStack(spacing: 16) {
                Image(systemName: "brain")
                    .font(.system(size: 40, weight: .regular))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(PSTheme.textPrimary)
                    .accessibilityHidden(true)
                Text(title(status))
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(PSTheme.textPrimary)
                    .multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)
                Text(explanation(status))
                    .font(.subheadline)
                    .foregroundStyle(PSTheme.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                if let model = status.model, status.downloadBytes > 0 {
                    Text(verbatim: "\(model.displayName) · \(LocalBrainText.size(status.downloadBytes))")
                        .font(PSFont.mono(12))
                        .foregroundStyle(PSTheme.textTertiary)
                }
                progress(status)
                actions(status)
            }
            .padding(24)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        .localBrainCellularConfirmation(isPresented: $confirmsCellular, status: status) {
            app?.settings.localModelAllowsCellular = true
            hub.download(allowCellular: true)
            onClose()
        }
    }

    private func title(_ status: LocalBrainStatus) -> String {
        switch status.phase {
        case .notInstalled, .failed: return L("Download the local brain?")
        case .waitingForWiFi, .downloading, .verifying: return L("The local brain is on its way")
        case .installed, .loading, .ready: return L("The local brain is on this iPhone")
        case .unsupported, .notInThisBuild: return L("No local brain on this iPhone")
        }
    }

    private func explanation(_ status: LocalBrainStatus) -> String {
        switch status.phase {
        case .unsupported, .notInThisBuild:
            return LocalBrainText.reason(status.decision.reason)
        case .waitingForWiFi:
            return L("The download starts by itself on Wi‑Fi. Live keeps working with Apple Intelligence or the commands meanwhile.")
        case .downloading, .verifying:
            return L("Live keeps working with Apple Intelligence or the commands meanwhile. Keep PicShop open: the download pauses in the background.")
        case .installed, .loading, .ready:
            return L("Live listens, looks at the picture and answers with it, entirely on the iPhone.")
        case .notInstalled, .failed:
            return L("PicShop Live works entirely on your iPhone. The local brain lets it look at the picture and talk more naturally.")
        }
    }

    @ViewBuilder
    private func progress(_ status: LocalBrainStatus) -> some View {
        switch status.phase {
        case .downloading(let progress):
            VStack(spacing: 6) {
                ProgressView(value: min(max(progress, 0), 1))
                    .tint(PSTheme.textPrimary)
                Text(LocalBrainText.phase(status.phase))
                    .font(PSFont.caption(12).monospacedDigit())
                    .foregroundStyle(PSTheme.textSecondary)
                    .contentTransition(.numericText())
            }
            .frame(maxWidth: 280)
        case .verifying, .loading:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small).tint(PSTheme.textPrimary)
                Text(LocalBrainText.phase(status.phase)).font(PSFont.caption(12)).foregroundStyle(PSTheme.textSecondary)
            }
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.footnote)
                .foregroundStyle(PSTheme.warning)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private func actions(_ status: LocalBrainStatus) -> some View {
        VStack(spacing: 10) {
            switch status.phase {
            case .notInstalled, .failed:
                PSPanelPrimaryButton(status.phase == .notInstalled ? L("Download over Wi‑Fi") : L("Try again over Wi‑Fi"), systemImage: "wifi", height: 50) {
                    hub.download(allowCellular: false)
                    onClose()
                }
                .frame(maxWidth: .infinity)
                cellularButton
                secondaryButton(L("Later")) {
                    onLater?()
                    onClose()
                }
            case .waitingForWiFi:
                cellularButton
                secondaryButton(L("Cancel the download")) {
                    hub.cancelDownload()
                    app?.settings.localModelAllowsCellular = false
                    onClose()
                }
                secondaryButton(L("Done"), action: onClose)
            case .downloading, .verifying:
                secondaryButton(L("Cancel the download")) {
                    hub.cancelDownload()
                    app?.settings.localModelAllowsCellular = false
                    onClose()
                }
                secondaryButton(L("Done"), action: onClose)
            case .installed, .loading, .ready, .unsupported, .notInThisBuild:
                PSPanelPrimaryButton(L("Done"), height: 50, action: onClose)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.top, 4)
    }

    private var cellularButton: some View {
        secondaryButton(L("Use cellular data…")) { confirmsCellular = true }
    }

    private func secondaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(PSTheme.textSecondary)
                .frame(maxWidth: .infinity, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

extension View {
    /// Asks before the local brain downloads over cellular, with its size (D12).
    func localBrainCellularConfirmation(isPresented: Binding<Bool>, status: LocalBrainStatus, onConfirm: @escaping () -> Void) -> some View {
        let size = LocalBrainText.size(status.downloadBytes)
        let name = status.model?.displayName ?? L("Local brain")
        return confirmationDialog(String(format: L("Download %@ over cellular?"), size), isPresented: isPresented, titleVisibility: .visible) {
            Button(String(format: L("Download %@ over cellular"), size)) {
                Haptics.confirm()
                onConfirm()
            }
            Button(L("Cancel"), role: .cancel) {}
        } message: {
            Text(String(format: L("%@ weighs %@. Your carrier may charge for this data. Nothing else is sent."), name, size))
        }
    }
}
// MARK: - First run

/// The first-run offer of the local brain: on onboarding's last page for new
/// installs, and once on Home for people who were onboarded before the local
/// brain existed. The choice is remembered; the pill and Settings › Intelligence
/// keep offering it afterwards.
@MainActor
enum LocalBrainFirstRun {
    static let promptedKey = "localBrainFirstRunPrompted.v1"

    static var hasPrompted: Bool {
        get { UserDefaults.standard.bool(forKey: promptedKey) }
        set { UserDefaults.standard.set(newValue, forKey: promptedKey) }
    }

    /// This iPhone can run the local brain and it isn't here (nor on its way).
    static func offers(_ status: LocalBrainStatus) -> Bool {
        guard status.model != nil else { return false }
        switch status.phase {
        case .notInstalled, .waitingForWiFi, .failed: return true
        default: return false
        }
    }

    /// Onboarding's answer: download over Wi‑Fi now (it waits for Wi‑Fi, never
    /// cellular), or not, in which case it isn't fetched by itself either.
    static func resolve(app: AppEnvironment, download: Bool) {
        hasPrompted = true
        let hub = LocalBrainHub.shared
        guard let model = hub.status.model, offers(hub.status) else { return }
        if download {
            hub.download(allowCellular: false)
        } else {
            app.settings.setAutoInstallSkipped(true, for: model.id)
            LocalBrainPillLook.snoozeOffer()
        }
    }

    /// Home: whether to offer it now. Asks ModelManager itself, because the hub
    /// learns the install states a moment after launch.
    static func shouldOfferOnHome(app: AppEnvironment) async -> Bool {
        guard !hasPrompted, app.settings.hasCompletedOnboarding else { return false }
        let hub = LocalBrainHub.shared
        guard hub.runtime != nil, let model = hub.status.model, hub.status.phase == .notInstalled,
              !app.settings.isAutoInstallSkipped(model.id) else { return false }
        guard await app.models.state(of: model.id) == .notInstalled else { return false }
        return hub.status.phase == .notInstalled && hub.status.model?.id == model.id
    }
}

/// Home's one-time offer (see LocalBrainFirstRun), two seconds after Home
/// appears and only while nothing else is on screen. "Plus tard" means the
/// model is not downloaded by itself; the pill and Settings still offer it.
struct LocalBrainFirstRunPrompt: ViewModifier {
    /// Another sheet, picker or editor is up: wait for the next appearance.
    let isBusy: Bool

    @Environment(\.picshop) private var app
    @State private var shows = false

    func body(content: Content) -> some View {
        content
            .task(id: isBusy) {
                guard !isBusy, let app, !LocalBrainFirstRun.hasPrompted else { return }
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled, !isBusy, !app.isEditorOpen, await LocalBrainFirstRun.shouldOfferOnHome(app: app) else { return }
                LocalBrainFirstRun.hasPrompted = true
                shows = true
            }
            .sheet(isPresented: $shows) {
                LocalBrainOfferSheet(onClose: { shows = false }, onLater: {
                    if let app, let model = LocalBrainHub.shared.status.model {
                        app.settings.setAutoInstallSkipped(true, for: model.id)
                    }
                    LocalBrainPillLook.snoozeOffer()
                })
            }
    }
}

/// Onboarding's last page: the local brain for this iPhone, with a switch to
/// download it over Wi‑Fi (on by default). On an iPhone without enough memory,
/// the honest line instead. A leaf: it reads the hub's status.
struct OnboardingBrainChoice: View {
    @Binding var downloads: Bool
    private let hub = LocalBrainHub.shared

    var body: some View {
        let status = hub.status
        if let model = status.model, LocalBrainFirstRun.offers(status) {
            Toggle(isOn: $downloads) {
                HStack(spacing: 12) {
                    Image(systemName: "brain")
                        .font(.system(size: 20, weight: .regular))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(PSTheme.textPrimary)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L("Download the local brain over Wi‑Fi"))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(PSTheme.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(verbatim: "\(model.displayName) · \(LocalBrainText.size(status.downloadBytes))")
                            .font(PSFont.caption(12))
                            .foregroundStyle(PSTheme.textSecondary)
                    }
                }
            }
            .tint(PSTheme.success)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .psCard(cornerRadius: PSRadius.onboardingCard, shadow: false)
            .frame(maxWidth: 360)
            .padding(.top, PSSpacing.large)
        } else if case .unsupported = status.phase, status.decision.reason == .notEnoughMemory {
            Text(LocalBrainText.reason(.notEnoughMemory))
                .font(.footnote)
                .foregroundStyle(PSTheme.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 330)
                .padding(.top, PSSpacing.large)
        }
    }
}
#endif
