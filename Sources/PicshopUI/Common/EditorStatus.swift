#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import Observation

/// What the shared editor overlays need from a session.
@MainActor
protocol EditorStatus: AnyObject, Observable {
    var isProcessing: Bool { get }
    var processingTitle: String { get }
    /// Fraction of the running task, when it reports one.
    var processingProgress: Double? { get }
    /// Fraction of a running export, when one is running.
    var exportProgress: Double? { get }
    var toast: PhotoEditorSession.Toast? { get }
    func undo()
    func performToastAction(_ action: PhotoEditorSession.Toast.Action)
}

extension EditorStatus {
    func performToastAction(_ action: PhotoEditorSession.Toast.Action) {}
}

/// Processing HUD, export HUD and toast for an editor.
///
/// This lives in its own view on purpose. Progress arrives many times a
/// second, and reading it in the editor's own body would re-evaluate the
/// canvas, the timeline and the dock on every tick.
struct EditorStatusOverlay<Session: EditorStatus>: View {
    var session: Session
    var toastTopInset: CGFloat = 60
    var toastHorizontalInset: CGFloat = 20

    private var blocksTouches: Bool { session.isProcessing || session.exportProgress != nil }

    var body: some View {
        ZStack {
            ZStack {
                if session.isProcessing {
                    ProgressHUD(title: session.processingTitle, progress: session.processingProgress)
                }
                if let progress = session.exportProgress {
                    ProgressHUD(title: L("Exporting…"), progress: progress)
                }
            }
            .allowsHitTesting(blocksTouches)
            // The toast's button must stay tappable while the editor below keeps its touches.
            if let toast = session.toast {
                ToastView(text: toast.text,
                          systemImage: toast.isError ? "exclamationmark.triangle.fill" : toast.action != nil ? "arrow.uturn.up.circle.fill" : "checkmark.circle.fill",
                          tint: toast.isError ? PSTheme.danger : toast.action != nil ? PSTheme.accent : PSTheme.success,
                          action: button(for: toast))
                    .padding(.top, toastTopInset)
                    .padding(.horizontal, toastHorizontalInset)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .id(toast.id)
            }
        }
        .animation(PSMotion.standard, value: session.isProcessing)
    }

    private func button(for toast: PhotoEditorSession.Toast) -> ToastView.Action? {
        if let action = toast.action {
            switch action {
            case .rightWayUp:
                return ToastView.Action(title: L("Right way up"), symbol: "arrow.uturn.up") { session.performToastAction(action) }
            }
        }
        return toast.undoable ? ToastView.Action(title: L("Undo"), symbol: "arrow.uturn.backward") { session.undo() } : nil
    }
}
#endif
