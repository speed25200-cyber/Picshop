#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import UIKit
import Combine
import PicshopIntent

/// Where the studio's bars sit, in global coordinates: the canvas fits its
/// picture between them.
struct StudioEdges: Equatable {
    /// Bottom of the top bar.
    var top: CGFloat = 0
    /// Top of the bottom stack (the dock, or the open ToolPanel).
    var bottom: CGFloat = .greatestFiniteMagnitude

    /// How far the bars reach into a view occupying `frame` (global coordinates).
    func insets(over frame: CGRect) -> EdgeInsets {
        EdgeInsets(top: max(0, min(frame.height / 2, top - frame.minY)), leading: 0,
                   bottom: max(0, min(frame.height / 2, frame.maxY - bottom)), trailing: 0)
    }
}

private struct StudioEdgesKey: EnvironmentKey {
    static let defaultValue = StudioEdges()
}

private struct StudioCompactKey: EnvironmentKey {
    static let defaultValue = false
}

private struct StudioPanelMaxHeightKey: EnvironmentKey {
    static let defaultValue: CGFloat = 400
}

private struct StudioToolsNamespaceKey: EnvironmentKey {
    static let defaultValue: Namespace.ID? = nil
}

extension EnvironmentValues {
    /// Set by StudioChrome for its canvas.
    var studioEdges: StudioEdges {
        get { self[StudioEdgesKey.self] }
        set { self[StudioEdgesKey.self] = newValue }
    }

    /// A screen 667 points tall or less: composer 48, console 64, captions 2 lines.
    var studioCompact: Bool {
        get { self[StudioCompactKey.self] }
        set { self[StudioCompactKey.self] = newValue }
    }

    /// 46 % of the screen: the tallest a ToolPanel gets.
    var studioPanelMaxHeight: CGFloat {
        get { self[StudioPanelMaxHeightKey.self] }
        set { self[StudioPanelMaxHeightKey.self] = newValue }
    }

    /// The namespace the Outils sheet zooms out of the Outils button in.
    var studioToolsNamespace: Namespace.ID? {
        get { self[StudioToolsNamespaceKey.self] }
        set { self[StudioToolsNamespaceKey.self] = newValue }
    }
}

/// Identifiers shared by the studio's pieces.
enum StudioChromeIDs {
    /// The Outils button and the sheet that grows out of it.
    static let toolsTransition = "tools"
    /// Whether the sheet zooms out of the button (a plain sheet otherwise).
    static let zoomsToolsSheet = true
}

/// Safe-area insets of the key window (status bar, Dynamic Island, home indicator).
enum WindowInsets {
    @MainActor static var current: UIEdgeInsets {
        keyWindow?.safeAreaInsets ?? .zero
    }

    /// The key window's height: the screen, whatever the keyboard does.
    @MainActor static var windowHeight: CGFloat? {
        keyWindow.map { $0.bounds.height }
    }

    @MainActor private static var keyWindow: UIWindow? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.flatMap(\.windows).first { $0.isKeyWindow } ?? scenes.first?.windows.first
    }
}

/// What the top bar shows. Coarse values from the session's stored mirrors.
struct StudioBar: Equatable {
    var canUndo: Bool
    var canRedo: Bool
    /// Past history labels, oldest first.
    var undoLabels: [String]
    /// A heavy step runs: Undo is dimmed.
    var isBusy: Bool
}

/// What the top bar does.
struct StudioActions {
    var close: () -> Void
    var undo: () -> Void
    var redo: () -> Void
    /// Undoes this many steps at once (the history menu).
    var undoSteps: (Int) -> Void
    /// Back to the document as imported; nil hides the menu item.
    var revert: (() -> Void)?
    var export: () -> Void
}

/// The one editor shell for photo, video and PDF: a full-bleed black canvas,
/// the top bar over it, and at the bottom the LiveDock, or the tool panel
/// while a tool is open. It presents the Outils sheet (adding 'Historique'
/// to its footer while there is something to undo), the history list and
/// LiveConsentSheet, and toggles Live on the Magic Tap.
///
/// The canvas reads `studioEdges` to fit its picture between the bars; it
/// ignores the keyboard, and the edges come from the bars' sizes, not from
/// where the keyboard pushes them, so typing never moves the picture.
struct StudioChrome<Canvas: View, Panel: View>: View {
    let bar: StudioBar
    let actions: StudioActions
    let live: LiveSession
    let catalog: () -> ToolCatalog
    let isToolOpen: Bool
    var candidateThumbnail: ((Int) async -> UIImage?)?
    let canvas: Canvas
    let panel: Panel

    /// Bottom of the top bar, and the height of the bottom stack, in global coordinates.
    @State private var topEdge: CGFloat = 0
    @State private var bottomHeight: CGFloat = 0
    @State private var showsTools = false
    @State private var showsHistory = false
    @State private var pendingAction: (() -> Void)?
    @State private var keyboardVisible = false
    @Namespace private var toolsNamespace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(bar: StudioBar, actions: StudioActions, live: LiveSession, catalog: @escaping () -> ToolCatalog, isToolOpen: Bool,
         candidateThumbnail: ((Int) async -> UIImage?)? = nil,
         @ViewBuilder canvas: () -> Canvas, @ViewBuilder panel: () -> Panel) {
        self.bar = bar
        self.actions = actions
        self.live = live
        self.catalog = catalog
        self.isToolOpen = isToolOpen
        self.candidateThumbnail = candidateThumbnail
        self.canvas = canvas()
        self.panel = panel()
    }

    var body: some View {
        GeometryReader { proxy in
            // Presented editors occasionally receive zero safe-area insets from SwiftUI; the
            // window always knows the real status bar / home indicator geometry.
            let window = WindowInsets.current
            let extraTop = max(0, window.top - proxy.safeAreaInsets.top)
            let safeBottom = max(proxy.safeAreaInsets.bottom, window.bottom)
            // The keyboard shrinks the proxy, never the window.
            let screenHeight = WindowInsets.windowHeight ?? (proxy.size.height + proxy.safeAreaInsets.top + proxy.safeAreaInsets.bottom)
            let restingBottom = max(safeBottom - 8, 12)
            // The bottom edge comes from the stack's height at its resting place, so the
            // keyboard, which only lifts the stack, never re-lays the picture out.
            let edges = StudioEdges(top: topEdge, bottom: bottomHeight > 0 ? screenHeight - restingBottom - bottomHeight : .greatestFiniteMagnitude)
            ZStack {
                canvas
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .environment(\.studioEdges, edges)
                    .ignoresSafeArea()
                // Empty space in the stack is not hit-testable: the canvas
                // keeps every touch between the bars.
                VStack(spacing: 0) {
                    StudioTopBar(bar: bar, actions: actions, live: live)
                        .padding(.top, extraTop)
                        .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).maxY } action: { topEdge = $0 }
                    Spacer(minLength: 0)
                    // Dock and panel overlap while one replaces the other.
                    ZStack(alignment: .bottom) { bottom }
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { bottomHeight = $0 }
                        .padding(.bottom, keyboardVisible ? 8 : restingBottom)
                }
                .ignoresSafeArea(.container, edges: .bottom)
            }
            .environment(\.studioCompact, screenHeight <= 700)
            .environment(\.studioPanelMaxHeight, screenHeight * 0.46)
        }
        .background(PSTheme.canvas.ignoresSafeArea())
        .environment(\.studioToolsNamespace, StudioChromeIDs.zoomsToolsSheet ? toolsNamespace : nil)
        .animation(reduceMotion ? .easeInOut(duration: 0.25) : PSMotion.standard, value: isToolOpen)
        .sheet(isPresented: $showsTools, onDismiss: runPendingAction) {
            ToolsSheet(catalog: sheetCatalog(), onPick: pick)
                .modifier(ToolsZoomTransition(namespace: StudioChromeIDs.zoomsToolsSheet ? toolsNamespace : nil))
        }
        .background {
            StudioHistoryPresenter(isPresented: $showsHistory, bar: bar, actions: actions)
        }
        .background {
            LiveConsentPresenter(live: live)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in keyboardVisible = true }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in keyboardVisible = false }
        .task { LiveTips.configure() }
        .accessibilityAction(.magicTap) {
            if live.isLive { live.end() } else { live.start() }
        }
    }

    @ViewBuilder
    private var bottom: some View {
        if isToolOpen {
            panel
                .overlay(alignment: .top) {
                    LiveReplyCapsule(live: live, placement: .overPanel)
                        .padding(.horizontal, PSSpacing.editorSide)
                        .alignmentGuide(.top) { $0[.bottom] + 8 }
                }
                .transition(reduceMotion ? AnyTransition.opacity : AnyTransition.move(edge: .bottom).combined(with: .opacity))
        } else {
            LiveDock(live: live, onTools: openTools, candidateThumbnail: candidateThumbnail)
                .transition(.opacity)
        }
    }

    private func openTools() {
        pendingAction = nil
        showsTools = true
    }

    /// The editor's catalog, with 'Historique' in the footer while there is something to undo.
    private func sheetCatalog() -> ToolCatalog {
        var built = catalog()
        built.footer.removeAll { $0.id == Self.historyID }
        if bar.canUndo {
            built.footer.append(.button(id: Self.historyID, title: L("History"), systemImage: "clock.arrow.circlepath",
                                        action: { showsHistory = true }))
        }
        return built
    }

    private static var historyID: String { "history" }

    private func pick(_ choice: ToolsSheetPick) {
        switch choice {
        case .panel(let open):
            pendingAction = nil
            showsTools = false
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(150))
                open()
            }
        case .action(let run):
            pendingAction = run
            showsTools = false
        }
    }

    private func runPendingAction() {
        guard let run = pendingAction else { return }
        pendingAction = nil
        run()
    }
}

/// The Outils sheet grows out of the Outils button when a namespace is given.
private struct ToolsZoomTransition: ViewModifier {
    let namespace: Namespace.ID?

    func body(content: Content) -> some View {
        if let namespace {
            content.navigationTransition(.zoom(sourceID: StudioChromeIDs.toolsTransition, in: namespace))
        } else {
            content
        }
    }
}

/// Presents LiveConsentSheet while Live asks for it. A leaf, so the flag
/// never re-evaluates the shell.
private struct LiveConsentPresenter: View {
    let live: LiveSession

    var body: some View {
        Color.clear
            .sheet(isPresented: Binding(get: { live.needsConsent }, set: { _ in })) {
                LiveConsentSheet { granted, sendImages in
                    live.resolveConsent(granted: granted, sendImages: sendImages)
                }
            }
            .accessibilityHidden(true)
    }
}

/// Presents the history list from the Outils footer.
private struct StudioHistoryPresenter: View {
    @Binding var isPresented: Bool
    let bar: StudioBar
    let actions: StudioActions

    var body: some View {
        Color.clear
            .sheet(isPresented: $isPresented) {
                StudioHistorySheet(labels: bar.undoLabels, onUndoSteps: actions.undoSteps, onRevert: actions.revert)
            }
            .accessibilityHidden(true)
    }
}

// MARK: - Top bar

/// Close, the cloud badge while Live runs on Claude, then Undo (with Redo
/// after an undo) and Export. 44 points tall, 4 below the safe area.
struct StudioTopBar: View {
    let bar: StudioBar
    let actions: StudioActions
    let live: LiveSession
    @Namespace private var glass

    var body: some View {
        PSGlassContainer(spacing: 8) {
            HStack(spacing: 8) {
                PSCircleButton(systemImage: "xmark", accessibilityLabel: L("Close"), action: actions.close)
                    .glassEffectID("close", in: glass)
                Spacer(minLength: 4)
                StudioBadgeSlot(live: live, glass: glass)
                Spacer(minLength: 4)
                UndoRedoCluster(bar: bar, actions: actions, glass: glass)
                PSCapsuleButton(L("Export"), action: actions.export)
            }
        }
        .padding(.horizontal, PSSpacing.editorSide)
        .padding(.top, 4)
        .frame(height: PSMetrics.barButton + 4, alignment: .bottom)
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
    }
}

/// The cloud badge, read in a leaf so Live's route never re-evaluates the bar.
/// It shows while Live runs on Claude, and stays to say 'Sur l'iPhone' if
/// Live falls back to the device in the same conversation.
private struct StudioBadgeSlot: View {
    let live: LiveSession
    let glass: Namespace.ID
    @State private var usedClaude = false

    var body: some View {
        let isLive = live.isLive
        let onClaude = isLive && live.route.brain == .claude
        let shows = isLive && (onClaude || usedClaude)
        ZStack {
            if shows {
                LiveCloudBadge(live: live)
                    .glassEffectID("badge", in: glass)
                    .transition(AnyTransition.opacity.combined(with: .scale(scale: 0.8)))
            }
        }
        .animation(PSMotion.morph, value: shows)
        .onChange(of: onClaude) { _, now in if now { usedClaude = true } }
        .onChange(of: isLive) { _, now in if !now { usedClaude = false } }
    }
}

/// Undo, a tap away at all times. After an undo, Redo morphs out beside it
/// for 8 s or until the next edit. A long press opens Rétablir, the history
/// ('Avant « … »') and 'Revenir à l'original'.
private struct UndoRedoCluster: View {
    let bar: StudioBar
    let actions: StudioActions
    let glass: Namespace.ID

    @State private var showsRedo = false
    @State private var redoToken = 0
    @Environment(\.colorSchemeContrast) private var contrast

    /// The history menu lists this many steps; older ones are reached through the original.
    private static var menuDepth: Int { 30 }

    var body: some View {
        HStack(spacing: 8) {
            undoMenu
                .glassEffectID("undo", in: glass)
            if showsRedo, bar.canRedo {
                PSCircleButton(systemImage: "arrow.uturn.forward", accessibilityLabel: L("Redo")) {
                    actions.redo()
                    reveal()
                }
                .disabled(bar.isBusy)
                .glassEffectID("redo", in: glass)
                .transition(AnyTransition.opacity.combined(with: .scale(scale: 0.8)))
            }
        }
        .animation(PSMotion.morph, value: showsRedo && bar.canRedo)
        .onChange(of: bar.canRedo) { old, new in
            if new, !old { reveal() } else if !new { showsRedo = false }
        }
        .task(id: redoToken) {
            guard showsRedo else { return }
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled else { return }
            showsRedo = false
        }
    }

    private var isEnabled: Bool { bar.canUndo && !bar.isBusy }

    private var undoMenu: some View {
        Menu {
            if bar.canRedo {
                Button {
                    actions.redo()
                } label: {
                    Label(L("Redo"), systemImage: "arrow.uturn.forward")
                }
            }
            if !bar.undoLabels.isEmpty {
                Section(L("History")) {
                    let count = bar.undoLabels.count
                    let shown = Array(bar.undoLabels.enumerated().suffix(Self.menuDepth).reversed())
                    ForEach(shown, id: \.offset) { index, label in
                        // Going back to before this step undoes it and everything after it.
                        Button(String(format: L("Before “%@”"), LD(label))) {
                            Haptics.tick()
                            actions.undoSteps(count - index)
                        }
                    }
                }
            }
            if let revert = actions.revert, bar.canUndo || bar.canRedo {
                Divider()
                Button(role: .destructive) {
                    Haptics.confirm()
                    revert()
                } label: {
                    Label(L("Back to the original"), systemImage: "arrow.counterclockwise")
                }
            }
        } label: {
            Image(systemName: "arrow.uturn.backward")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(PSTheme.textPrimary)
                .frame(width: PSMetrics.barButton, height: PSMetrics.barButton)
                .contentShape(Circle())
                .psGlass(interactive: true, shape: AnyShape(Circle()))
                .opacity(isEnabled ? 1 : (contrast == .increased ? 0.5 : 0.35))
        } primaryAction: {
            guard isEnabled else { return }
            Haptics.tap()
            actions.undo()
            reveal()
        }
        .accessibilityLabel(L("Undo"))
        .accessibilityValue(bar.undoLabels.last.map { LD($0) } ?? "")
        .accessibilityHint(L("Hold for the history"))
    }

    private func reveal() {
        showsRedo = true
        redoToken += 1
    }
}

/// The history as a list: tap a step to go back to before it.
struct StudioHistorySheet: View {
    let labels: [String]
    let onUndoSteps: (Int) -> Void
    let onRevert: (() -> Void)?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(Array(labels.enumerated().reversed()), id: \.offset) { index, label in
                        Button {
                            Haptics.tick()
                            onUndoSteps(labels.count - index)
                            dismiss()
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: index == labels.count - 1 ? "circle.inset.filled" : "circle")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(PSTheme.textTertiary)
                                Text(String(format: L("Before “%@”"), LD(label)))
                                    .foregroundStyle(PSTheme.textPrimary)
                            }
                        }
                    }
                }
                if let onRevert {
                    Section {
                        Button(role: .destructive) {
                            Haptics.confirm()
                            onRevert()
                            dismiss()
                        } label: {
                            Label(L("Back to the original"), systemImage: "arrow.counterclockwise")
                        }
                    }
                }
            }
            .navigationTitle(L("History"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("Done")) { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .preferredColorScheme(.dark)
    }
}

#if DEBUG
private struct StudioChromePreview: View {
    let scenario: LiveSession.PreviewScenario
    @State private var live: LiveSession?
    @State private var toolOpen = false
    @State private var labels = ["Exposition", "Supprimer le chien"]

    var body: some View {
        Group {
            if let live {
                StudioChrome(bar: StudioBar(canUndo: !labels.isEmpty, canRedo: labels.count < 2, undoLabels: labels, isBusy: false),
                             actions: StudioActions(close: {}, undo: { _ = labels.popLast() }, redo: { labels.append("Exposition") },
                                                    undoSteps: { labels.removeLast(min($0, labels.count)) }, revert: { labels = [] }, export: {}),
                             live: live,
                             catalog: { ToolCatalog.preview(open: { toolOpen = true }) },
                             isToolOpen: toolOpen) {
                    LinearGradient(colors: [Color(red: 0.2, green: 0.3, blue: 0.5), Color(red: 0.8, green: 0.5, blue: 0.3)], startPoint: .top, endPoint: .bottom)
                        .aspectRatio(3 / 4, contentMode: .fit)
                } panel: {
                    ToolPanel(title: "Réglages", live: live, onDone: { toolOpen = false }) {
                        Text(verbatim: "Contenu du panneau").foregroundStyle(PSTheme.textSecondary).frame(height: 120)
                    }
                }
            } else {
                PSTheme.canvas
            }
        }
        .onAppear { if live == nil { live = LiveSession.preview(scenario) } }
        .onDisappear { live?.teardown() }
    }
}

#Preview("StudioChrome") {
    StudioChromePreview(scenario: .cycle)
}

#Preview("StudioChrome resting") {
    StudioChromePreview(scenario: .resting)
}
#endif
#endif
