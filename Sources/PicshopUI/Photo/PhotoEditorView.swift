#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import PicshopCore
import PicshopIntent
import PicshopImaging

/// The photo editing screen.
public struct PhotoEditorView: View {
    @State var session: PhotoEditorSession
    @Environment(\.dismiss) private var dismiss
    @Environment(\.picshop) private var app

    public init(session: PhotoEditorSession) {
        _session = State(initialValue: session)
    }

    public var body: some View {
        EditorChrome {
            PhotoCanvasView(session: session)
        } top: {
            EditorTopBar(
                title: L("Photo"),
                subtitle: "\(Int(session.document.canvasSize.width)) × \(Int(session.document.canvasSize.height))",
                canUndo: session.history.canUndo, canRedo: session.history.canRedo,
                onClose: { session.teardown(); dismiss() },
                onUndo: { session.undo() }, onRedo: { session.redo() },
                onHelp: { session.showsHelp = true }, onExport: { session.showsExport = true })
        } bottom: {
            bottomArea
        }
        // Progress and toasts live in their own view, so a progress tick never
        // re-evaluates the canvas and the dock.
        .overlay { EditorStatusOverlay(session: session) }

        .task { await session.configure() }
        .onDisappear { session.teardown() }
        .sheet(isPresented: $session.showsExport) { ExportSheet(session: session) }
        .sheet(isPresented: $session.showsHelp) { HelpSheet(mode: .photo) { text in Task { await session.handleTranscript(text) } } }
        .preferredColorScheme(.dark)
        .persistentSystemOverlays(.hidden)
    }

    // MARK: Bottom

    private var bottomArea: some View {
        VStack(spacing: 8) {
            if let tool = session.activeTool {
                PhotoToolPanel(session: session, tool: tool)
                    .transition(.move(edge: .bottom).combined(with: .opacity).combined(with: .scale(scale: 0.98, anchor: .bottom)))
            }
            if let app {
                VoiceStrip(voice: app.voice, isBusy: session.isProcessing, busyTitle: session.processingTitle,
                           transcript: session.transcript, plan: session.lastPlan, clarification: session.pendingClarification,
                           showsHint: session.activeTool == nil,
                           candidateThumbnail: { await session.candidateThumbnail($0) },
                           onChoose: { session.choose(candidateIndex: $0) }, onChooseAll: { session.chooseAllCandidates() }, onCancel: { session.cancelClarification() })
            }
            HStack(spacing: 8) {
                GroupedToolDock(groups: PhotoEditorSession.Tool.groups, selection: $session.activeTool)
                if let app { MicButton(voice: app.voice, isBusy: session.isProcessing) }
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .padding(.bottom, 4)
        .psDockBackground()
        .animation(PSMotion.standard, value: session.activeTool)
    }
}

/// Press-and-hold "before" button floating over the canvas, like Photos.
/// Live zoom factor in the corner of the canvas; tapping it snaps back to fit.
struct ZoomBadge: View {
    let zoom: CGFloat
    let onReset: () -> Void

    var body: some View {
        Button {
            Haptics.tick()
            onReset()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "arrow.down.right.and.arrow.up.left").font(.system(size: 10, weight: .bold))
                Text("\(Int((zoom * 100).rounded())) %").font(PSFont.mono(11)).contentTransition(.numericText())
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(.black.opacity(0.55), in: Capsule())
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.18), lineWidth: 1))
            .animation(PSMotion.numeric, value: zoom)
        }
        .buttonStyle(PSPressStyle(scale: 0.94))
        .accessibilityLabel(L("Reset zoom"))
    }
}

struct CompareButton: View {
    var isShowingOriginal: Bool
    var onChange: (Bool) -> Void
    @State private var holding = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: isShowingOriginal ? "eye.fill" : "eye").font(.system(size: 13, weight: .semibold))
            Text(isShowingOriginal ? L("Original") : L("Before")).font(PSFont.caption(12))
        }
        .foregroundStyle(isShowingOriginal ? Color.white : PSTheme.textPrimary)
        .padding(.horizontal, 12).padding(.vertical, 9)
        .psGlass(interactive: true)
        .psActivePill(Capsule(), isActive: isShowingOriginal, glow: false)
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
