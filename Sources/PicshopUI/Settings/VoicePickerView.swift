#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI

/// Where to download a better system voice. One pair of strings, so the path
/// can be corrected in one place once checked against iOS 26's Settings.
enum VoiceDownloadHint {
    static var title: String { L("A more natural voice") }
    static var path: String { L("Download a Premium voice: Settings › Accessibility › Spoken Content › Voices › French.") }
}
#endif
