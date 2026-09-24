#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import PhotosUI
import PicshopCore
import PicshopIntent
import PicshopImaging

/// The photo editing screen: the picture edge to edge in the studio shell,
/// Live at the bottom, every manual tool behind Outils.
///
/// The body reads only coarse mirrors (canUndo, canRedo, undoLabels, the open
/// tool, whether work runs); the picture, the dial and Live's levels are read
/// by leaves.
public struct PhotoEditorView: View {
    @State var session: PhotoEditorSession
    @Environment(\.dismiss) private var dismiss
    @Environment(\.picshop) private var app
    /// The picture whose colours this photo should take (Magie › Assortir les couleurs).
    @State private var referenceItem: PhotosPickerItem?

    public init(session: PhotoEditorSession) {
        _session = State(initialValue: session)
    }

    public var body: some View {
        #if DEBUG
        let _ = ViewTrace.changes(Self.self)
        #endif
        StudioChrome(bar: bar, actions: actions, live: session.live,
                     catalog: { PhotoToolCatalog.make(session: session) },
                     isToolOpen: session.activeTool != nil,
                     candidateThumbnail: { index in await candidateThumbnail(index) }) {
            PhotoCanvasView(session: session)
                // No blocking HUD while work runs: the picture itself is held still.
                .allowsHitTesting(!session.isProcessing)
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
        .preferredColorScheme(.dark)
        .persistentSystemOverlays(.hidden)
    }

    private var bar: StudioBar {
        StudioBar(canUndo: session.canUndo, canRedo: session.canRedo, undoLabels: session.undoLabels, isBusy: session.isProcessing)
    }

    private var actions: StudioActions {
        let session = session
        let dismiss = dismiss
        // A step undone under a running erase would only make it drop its result.
        return StudioActions(close: { dismiss() },
                             undo: { guard !session.isProcessing else { return }; session.undo() },
                             redo: { guard !session.isProcessing else { return }; session.redo() },
                             undoSteps: { steps in guard !session.isProcessing else { return }; session.undo(steps: steps) },
                             revert: { guard !session.isProcessing else { return }; _ = session.revert() },
                             export: { session.showsExport = true })
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
struct ZoomBadge: View {
    let zoom: CGFloat
    let onReset: () -> Void

    var body: some View {
        Button {
            Haptics.tick()
            onReset()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "arrow.down.right.and.arrow.up.left").font(.system(size: 12, weight: .medium))
                Text("\(Int((zoom * 100).rounded())) %").font(.footnote.monospacedDigit().weight(.medium)).contentTransition(.numericText())
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .frame(minHeight: 32)
            .psGlass(interactive: true, variant: .clear)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(PSPressStyle(scale: 0.94))
        .accessibilityLabel(L("Reset zoom"))
    }
}

/// Press-and-hold "before" button. The canvas compares on a hold of the
/// picture itself now; this type goes when the old chrome does (phase 2).
struct CompareButton: View {
    var isShowingOriginal: Bool
    var onChange: (Bool) -> Void
    @State private var holding = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: isShowingOriginal ? "eye.fill" : "eye").font(.system(size: 15, weight: .medium))
            Text(isShowingOriginal ? L("Original") : L("Before")).font(.footnote.weight(.medium))
        }
        .foregroundStyle(isShowingOriginal ? Color.black : PSTheme.textPrimary)
        .padding(.horizontal, 14)
        .frame(minHeight: 38)
        .background(Capsule().fill(Color.white).opacity(isShowingOriginal ? 1 : 0))
        .psGlass(interactive: true, variant: .clear)
        .scaleEffect(holding ? 0.95 : 1)
        .animation(PSMotion.quick, value: holding)
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard !holding else { return }
                    holding = true
                    Haptics.soft()
                    onChange(true)
                }
                .onEnded { _ in
                    holding = false
                    onChange(false)
                }
        )
        .accessibilityLabel(L("Compare with original"))
        .accessibilityHint(L("Hold to see the original photo."))
    }
}
#endif
