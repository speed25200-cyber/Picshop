#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import PhotosUI
import PicshopCore
import PicshopIntent
import PicshopImaging

/// The photo editing screen: the picture edge to edge in the studio shell,
/// Live at the bottom, every manual tool behind Outils.
///
/// W1 (studioWorkspace): the top bar names the photo and its zoom (with
/// Ajuster, 200 %, 400 %), the compare button sits with Undo and Redo, the tool
/// rail above the dock opens any panel in one tap, panels are three-height
/// inspectors, and the histogram card sits at the top left when Curves or
/// Levels turned it on.
///
/// The body reads only coarse mirrors (canUndo, canRedo, undoLabels, the open
/// tool, the split, whether work runs); the picture, the dial, the zoom and
/// Live's levels are read by leaves.
public struct PhotoEditorView: View {
    @State var session: PhotoEditorSession
    @Environment(\.dismiss) private var dismiss
    @Environment(\.picshop) private var app
    /// The picture whose colours this photo should take (Magie › Assortir les couleurs).
    @State private var referenceItem: PhotosPickerItem?
    /// studioWorkspace, read once for the editor's life.
    @State private var isStudio = FeatureFlags.isOn(.studioWorkspace)
    /// The canvas's zoom, written by ZoomBadge and read by the title only.
    @State private var zoomMirror = StudioZoomMirror()
    /// The document's name, fixed for the editor's life (the title does not observe the document).
    @State private var title: String

    public init(session: PhotoEditorSession, title: String? = nil) {
        _session = State(initialValue: session)
        _title = State(initialValue: title ?? session.document.title)
    }

    public var body: some View {
        #if DEBUG
        let _ = ViewTrace.changes(Self.self)
        #endif
        StudioChrome(bar: bar, actions: actions, live: session.live,
                     catalog: { PhotoToolCatalog.make(session: session) },
                     rail: { PhotoToolCatalog.make(session: session, railOnly: true) },
                     isToolOpen: session.activeTool != nil,
                     candidateThumbnail: { index in await candidateThumbnail(index) },
                     context: isStudio ? StudioContext(title: title, zoomPercent: 100) : nil,
                     compare: isStudio ? compare : nil,
                     openToolID: session.activeTool?.rawValue,
                     showsRail: isStudio) {
            PhotoCanvasView(session: session)
                // No blocking HUD while work runs: the picture itself is held still.
                .allowsHitTesting(!session.isProcessing)
                .overlay(alignment: .topLeading) {
                    if isStudio { PhotoHistogramCorner(tone: session.tone) }
                }
        } panel: {
            if let tool = session.activeTool {
                PhotoToolPanel(session: session, tool: tool)
            }
        }
        // Progress and toasts live in their own view, so a progress tick never
        // re-evaluates the canvas and the dock.
        .overlay { EditorStatusOverlay(session: session) }
        .task { await open() }
        .onDisappear { session.teardown() }
        .sheet(isPresented: $session.showsExport) { ExportSheet(session: session) }
        .sheet(isPresented: $session.showsHelp) {
            HelpSheet(mode: .photo) { text in session.live.send(text: text) }
        }
        .photosPicker(isPresented: $session.showsColorReferencePicker, selection: $referenceItem, matching: .images)
        .onChange(of: referenceItem) { _, item in
            guard let item else { return }
            Task {
                let data = try? await item.loadTransferable(type: Data.self)
                if let data { await session.matchColors(to: data) }
                referenceItem = nil
            }
        }
        .environment(isStudio ? zoomMirror : nil)
        .preferredColorScheme(.dark)
        .persistentSystemOverlays(.hidden)
    }

    /// Before/after in the top bar: the split where the frame allows it, the original on a hold.
    private var compare: CompareControl {
        let session = session
        return CompareControl(isSplit: session.isSplitComparing,
                              canSplit: PhotoCanvasView.canSplitCompare(session),
                              toggleSplit: { session.compareSplit = session.isSplitComparing ? nil : 0.5 },
                              showOriginal: { session.showsOriginal = $0 },
                              isEnabled: session.canUndo || session.canRevertToImport)
    }

    private var bar: StudioBar {
        StudioBar(canUndo: session.canUndo, canRedo: session.canRedo, undoLabels: session.undoLabels, isBusy: session.isProcessing,
                  canRevert: session.canRevertToImport)
    }

    private var actions: StudioActions {
        let session = session
        let dismiss = dismiss
        // A step undone under a running erase would only make it drop its result.
        let mirror = zoomMirror
        return StudioActions(close: { dismiss() },
                             undo: { guard !session.isProcessing else { return }; session.undo() },
                             redo: { guard !session.isProcessing else { return }; session.redo() },
                             undoSteps: { steps in guard !session.isProcessing else { return }; session.undo(steps: steps) },
                             revert: { guard !session.isProcessing else { return }; _ = session.revert() },
                             export: { session.showsExport = true },
                             zoom: { choice in
                                 // The canvas zooms relative to fit; a level is reached from the zoom shown now.
                                 switch choice {
                                 case .fit:
                                     session.zoomRequest = PhotoEditorSession.ZoomRequest(amount: .absolute(1), target: nil)
                                 case .percent(let level):
                                     let current = Double(mirror.percent ?? 100) / 100
                                     session.zoomRequest = PhotoEditorSession.ZoomRequest(amount: .multiplier(Double(level) / 100 / max(0.01, current)), target: nil)
                                 }
                             })
    }

    /// Configures the session, then starts Live on its own when Settings asks for it.
    private func open() async {
        await session.configure()
        guard app?.settings.liveAutoStart == true else { return }
        try? await Task.sleep(for: .milliseconds(600))
        guard !Task.isCancelled else { return }
        session.live.start()
    }

    /// The picture of choice `index` (1-based, as spoken) for the choice chips.
    private func candidateThumbnail(_ index: Int) async -> UIImage? {
        guard let candidates = session.pendingClarification?.candidates, candidates.indices.contains(index - 1) else { return nil }
        return await session.candidateThumbnail(candidates[index - 1])
    }
}

/// Live zoom factor in the corner of the canvas; tapping it snaps back to fit.
/// In W1 the zoom shows in the top bar's title instead: the badge then draws
/// nothing and only reports the zoom to the title's StudioZoomMirror (back to
/// 100 % when it leaves, as the canvas is fitted again), which leaves the
/// corner to the histogram card.
struct ZoomBadge: View {
    let zoom: CGFloat
    let onReset: () -> Void
    @Environment(StudioZoomMirror.self) private var mirror: StudioZoomMirror?

    var body: some View {
        Group {
            if mirror != nil {
                Color.clear
                    .frame(width: 1, height: 1)
                    .accessibilityHidden(true)
            } else {
                badge
            }
        }
        .onAppear { mirror?.report(zoom) }
        .onChange(of: zoom) { _, value in mirror?.report(value) }
        .onDisappear { mirror?.report(1) }
    }

    private var badge: some View {
        Button {
            Haptics.tick()
            onReset()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "arrow.down.right.and.arrow.up.left").font(.caption.weight(.medium))
                Text(StudioContextMenu.format(Int((zoom * 100).rounded())))
                    .font(.footnote.monospacedDigit().weight(.medium))
                    .contentTransition(.numericText())
            }
            .foregroundStyle(Color.psTextPrimary)
            .padding(.horizontal, 12)
            .frame(minHeight: 32)
            .psGlass(interactive: true, variant: .clear)
            .frame(minHeight: PSMetrics.control)
            .contentShape(Rectangle())
        }
        .buttonStyle(PSPressStyle(scale: 0.94))
        .accessibilityLabel(L("Reset zoom"))
    }
}

/// The histogram card at the top left of the canvas, under the top bar, when
/// Curves or Levels turned it on (E3's HistogramCard; it reads the tone state).
/// Reads the bars' edges, not the session: a leaf.
private struct PhotoHistogramCorner: View {
    let tone: PhotoToneState
    @Environment(\.studioEdges) private var edges

    var body: some View {
        ZStack(alignment: .topLeading) {
            if tone.showsHistogramCard {
                HistogramCard(state: tone)
                    .padding(.top, edges.top + PSSpacing.medium)
                    .padding(.leading, PSSpacing.medium)
                    .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .topLeading)))
            }
        }
        .animation(PSSpring.quick, value: tone.showsHistogramCard)
    }
}
#endif
