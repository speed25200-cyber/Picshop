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
        ZStack {
            PSTheme.canvas.ignoresSafeArea()
            VStack(spacing: 0) {
                topBar
                PhotoCanvasView(session: session)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                bottomArea
            }
            if session.isProcessing {
                ProgressHUD(title: session.processingTitle)
            }
            if let progress = session.exportProgress {
                ProgressHUD(title: L("Exporting…"), progress: progress)
            }
        }
        .overlay(alignment: .top) {
            if let toast = session.toast {
                ToastView(text: toast.text, systemImage: toast.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill", tint: toast.isError ? PSTheme.danger : PSTheme.success)
                    .padding(.top, 64)
                    .id(toast.id)
            }
        }
        .task { await session.configure() }
        .onDisappear { session.teardown() }
        .sheet(isPresented: $session.showsExport) { ExportSheet(session: session) }
        .sheet(isPresented: $session.showsHelp) { HelpSheet(mode: .photo) }
        .preferredColorScheme(.dark)
        .statusBarHidden(false)
        .persistentSystemOverlays(.hidden)
    }

    // MARK: Top bar

    private var topBar: some View {
        HStack(spacing: 10) {
            GlassIconButton("chevron.left", label: L("Close")) {
                session.teardown()
                dismiss()
            }
            Spacer()
            PSGlassContainer(spacing: 8) {
                HStack(spacing: 8) {
                    GlassIconButton("arrow.uturn.backward", label: L("Undo")) { session.undo() }
                        .disabled(!session.history.canUndo)
                        .opacity(session.history.canUndo ? 1 : 0.4)
                    GlassIconButton("arrow.uturn.forward", label: L("Redo")) { session.redo() }
                        .disabled(!session.history.canRedo)
                        .opacity(session.history.canRedo ? 1 : 0.4)
                }
            }
            Spacer()
            HStack(spacing: 8) {
                GlassIconButton("questionmark", label: L("Help")) { session.showsHelp = true }
                GlassIconButton("square.and.arrow.up", label: L("Export"), tint: PSTheme.accent, isActive: true) { session.showsExport = true }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 6)
    }

    // MARK: Bottom

    private var bottomArea: some View {
        VStack(spacing: 10) {
            if let app {
                CommandFeedbackView(voice: app.voice, transcript: session.transcript, plan: session.lastPlan, clarification: session.pendingClarification,
                                    showsTranscript: app.settings.showsVoiceTranscript,
                                    onChoose: { session.choose(candidateIndex: $0) }, onChooseAll: { session.chooseAllCandidates() }, onCancel: { session.cancelClarification() })
                    .padding(.horizontal, 16)
            }
            if let tool = session.activeTool {
                PhotoToolPanel(session: session, tool: tool)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            dock
        }
        .padding(.bottom, 6)
        .animation(.spring(duration: 0.35), value: session.activeTool)
    }

    private var dock: some View {
        ZStack(alignment: .bottom) {
            PSGlassContainer(spacing: 6) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(PhotoEditorSession.Tool.allCases) { tool in
                            let isActive = session.activeTool == tool
                            Button {
                                Haptics.tap()
                                withAnimation(.spring(duration: 0.3)) {
                                    if session.activeTool == .erase, tool != .erase { session.commitBrushErase() }
                                    if session.activeTool == .precise, tool != .precise { session.brushStrokes = []; session.lassoPoints = [] }
                                    session.activeTool = isActive ? nil : tool
                                }
                            } label: {
                                VStack(spacing: 4) {
                                    Image(systemName: tool.symbol).font(.system(size: 18, weight: .semibold))
                                    Text(tool.title).font(PSFont.caption(10))
                                }
                                .foregroundStyle(isActive ? Color.black : PSTheme.textPrimary)
                                .frame(width: 60, height: 54)
                                .background(isActive ? PSTheme.accent : Color.clear, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(tool.title)
                            .accessibilityAddTraits(isActive ? [.isSelected] : [])
                            if tool == .looks { Spacer(minLength: 80) }
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                }
                .psGlass(shape: AnyShape(RoundedRectangle(cornerRadius: 30, style: .continuous)))
                .padding(.horizontal, 16)
            }
            if let app {
                VoiceOrb(voice: app.voice, isBusy: session.isProcessing)
                    .offset(y: -22)
            }
        }
    }
}
#endif
