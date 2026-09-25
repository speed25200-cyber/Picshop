import Foundation
@testable import PicshopIntent

/// The executor-backed editor the model lane (A3, A4) and the dialogue eval run on; it lives in PicshopIntent
/// (`LiveEvalEditor`) so the Diagnostic Live runner replays the same corpus on the iPhone.
typealias TableEditorHost = LiveEvalEditor
