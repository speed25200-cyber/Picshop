#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import UIKit
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

extension EnvironmentValues {
    /// Set by StudioChrome for its canvas.
    var studioEdges: StudioEdges {
        get { self[StudioEdgesKey.self] }
        set { self[StudioEdgesKey.self] = newValue }
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
/// while a tool is open. It presents the Outils sheet.
///
/// Phase 0: the layout, the top bar with plain Undo / Redo, the dock and the
/// sheet. The history menu, the Redo morph, the undo toast and the consent
/// sheet follow.
struct StudioChrome<Canvas: View, Panel: View>: View {
    let bar: StudioBar
    let actions: StudioActions
    let live: LiveSession
    let catalog: () -> ToolCatalog
    let isToolOpen: Bool
    var candidateThumbnail: ((Int) async -> UIImage?)?
    let canvas: Canvas
    let panel: Panel

    @State private var edges = StudioEdges()
    @State private var showsTools = false

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
            let extraBottom = max(0, window.bottom - proxy.safeAreaInsets.bottom)
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
                        .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).maxY } action: { edges.top = $0 }
                    Spacer(minLength: 0)
                    bottom
                        .padding(.bottom, extraBottom)
                        .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY } action: { edges.bottom = $0 }
                }
            }
        }
        .background(PSTheme.canvas.ignoresSafeArea())
        .animation(PSMotion.standard, value: isToolOpen)
        .sheet(isPresented: $showsTools) {
            ToolsSheet(catalog: catalog(), onDismiss: { showsTools = false })
        }
        .accessibilityAction(.magicTap) {
            if live.isLive { live.end() } else { live.start() }
        }
    }

    @ViewBuilder
    private var bottom: some View {
        if isToolOpen {
            panel
                .transition(.move(edge: .bottom).combined(with: .opacity))
        } else {
            LiveDock(live: live, onTools: { showsTools = true }, candidateThumbnail: candidateThumbnail)
                .padding(.bottom, 4)
                .transition(.opacity)
        }
    }
}

/// Close, the cloud badge while Live runs on Claude, then Undo / Redo and Export.
struct StudioTopBar: View {
    let bar: StudioBar
    let actions: StudioActions
    let live: LiveSession

    var body: some View {
        PSGlassContainer(spacing: 8) {
            HStack(spacing: 8) {
                PSCircleButton(systemImage: "xmark", accessibilityLabel: L("Close"), action: actions.close)
                Spacer(minLength: 4)
                if live.isLive && live.route.brain == .claude {
                    LiveCloudBadge(live: live)
                        .transition(.opacity)
                }
                Spacer(minLength: 4)
                PSCircleButton(systemImage: "arrow.uturn.backward", accessibilityLabel: L("Undo"), action: actions.undo)
                    .disabled(!bar.canUndo || bar.isBusy)
                    .opacity(bar.canUndo && !bar.isBusy ? 1 : 0.35)
                if bar.canRedo {
                    PSCircleButton(systemImage: "arrow.uturn.forward", accessibilityLabel: L("Redo"), action: actions.redo)
                        .disabled(bar.isBusy)
                        .transition(.opacity)
                }
                PSCapsuleButton(L("Export"), action: actions.export)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .padding(.bottom, 8)
        .animation(PSMotion.quick, value: bar)
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
    }
}

#if DEBUG
private struct StudioChromePreview: View {
    @State private var live: LiveSession?
    @State private var toolOpen = false

    var body: some View {
        Group {
            if let live {
                StudioChrome(bar: StudioBar(canUndo: true, canRedo: false, undoLabels: ["Exposition"], isBusy: false),
                             actions: StudioActions(close: {}, undo: {}, redo: {}, undoSteps: { _ in }, revert: nil, export: {}),
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
        .onAppear { if live == nil { live = LiveSession.preview(.cycle) } }
        .onDisappear { live?.teardown() }
    }
}

#Preview("StudioChrome") {
    StudioChromePreview()
}
#endif
#endif
