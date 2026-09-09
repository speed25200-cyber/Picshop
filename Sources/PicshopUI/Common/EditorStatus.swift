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
            if session.isProcessing {
                ProgressHUD(title: session.processingTitle, progress: session.processingProgress)
            }
            if let progress = session.exportProgress {
                ProgressHUD(title: L("Exporting…"), progress: progress)
            }
            if let toast = session.toast {
                ToastView(text: toast.text,
                          systemImage: toast.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill",
                          tint: toast.isError ? PSTheme.danger : PSTheme.success,
                          onUndo: toast.undoable ? { session.undo() } : nil)
                    .padding(.top, toastTopInset)
                    .padding(.horizontal, toastHorizontalInset)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .id(toast.id)
            }
        }
        .allowsHitTesting(blocksTouches)
        .animation(PSMotion.standard, value: session.isProcessing)
    }
}
#endif
