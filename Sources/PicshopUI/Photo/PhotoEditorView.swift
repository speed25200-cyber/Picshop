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
        .overlay {
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
                    .padding(.top, 60)
                    .id(toast.id)
            }
        }
        .task { await session.configure() }
        .onDisappear { session.teardown() }
        .sheet(isPresented: $session.showsExport) { ExportSheet(session: session) }
        .sheet(isPresented: $session.showsHelp) { HelpSheet(mode: .photo) }
        .preferredColorScheme(.dark)
        .persistentSystemOverlays(.hidden)
    }

    // MARK: Bottom

    private var bottomArea: some View {
        VStack(spacing: 8) {
            if let tool = session.activeTool {
                PhotoToolPanel(session: session, tool: tool)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            if let app {
                VoiceStrip(voice: app.voice, isBusy: session.isProcessing, busyTitle: session.processingTitle,
                           transcript: session.transcript, plan: session.lastPlan, clarification: session.pendingClarification,
                           showsHint: session.activeTool == nil,
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
        .background(
            LinearGradient(colors: [PSTheme.canvas.opacity(0), PSTheme.canvas.opacity(0.85)], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea(edges: .bottom)
        )
        .animation(.spring(duration: 0.32, bounce: 0.12), value: session.activeTool)
    }
}
#endif
