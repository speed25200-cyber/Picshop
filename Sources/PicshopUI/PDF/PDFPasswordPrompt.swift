#if canImport(SwiftUI) && canImport(PDFKit) && canImport(UIKit)
import UIKit
import PicshopCore

/// The password of a protected PDF, asked in a system alert over whatever is on screen
/// (the editor opens first, then asks). `completion` gets the password, or nil on Cancel.
@MainActor
enum PDFPasswordPrompt {
    static func present(title: String, retry: Bool, completion: @escaping @MainActor (String?) -> Void) {
        guard let presenter = topViewController() else {
            completion(nil)
            return
        }
        let message = retry
            ? L("Wrong password. Try again.")
            : String(format: L("“%@” is protected. Enter its password to open it."), title)
        let alert = UIAlertController(title: L("Protected PDF"), message: message, preferredStyle: .alert)
        alert.addTextField { field in
            field.isSecureTextEntry = true
            field.textContentType = .password
            field.placeholder = L("Password")
            field.returnKeyType = .done
        }
        alert.addAction(UIAlertAction(title: L("Cancel"), style: .cancel) { _ in
            MainActor.assumeIsolated { completion(nil) }
        })
        alert.addAction(UIAlertAction(title: L("Open"), style: .default) { [weak alert] _ in
            let password = alert?.textFields?.first?.text ?? ""
            MainActor.assumeIsolated { completion(password) }
        })
        presenter.present(alert, animated: true)
    }

    /// The view controller at the top of the active window's presentation stack.
    static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        var top = scene?.keyWindow?.rootViewController
        while let presented = top?.presentedViewController, !presented.isBeingDismissed { top = presented }
        return top
    }
}
#endif
