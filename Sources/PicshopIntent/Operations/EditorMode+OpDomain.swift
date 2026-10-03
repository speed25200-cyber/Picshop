import Foundation
import PicshopCore

public extension EditorMode {
    /// The catalog domain of the editor.
    var opDomain: OpDomain {
        switch self {
        case .photo: return .photo
        case .video: return .video
        case .pdf: return .pdf
        }
    }
}
