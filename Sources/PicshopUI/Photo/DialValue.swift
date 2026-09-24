#if canImport(SwiftUI) && canImport(UIKit)
import Foundation
import Observation
import PicshopCore

/// The value of the dial being dragged, and nothing else: only the dial and its
/// readout read it, so a drag never re-evaluates the editor screen. The session
/// commits the document once, when the drag ends.
@MainActor
@Observable
public final class DialValue {
    /// Non-nil only while an adjust dial is dragged.
    public internal(set) var parameter: AdjustmentParameter?
    /// aperture | look | colorMixer | colorGrade while those dials drag.
    public internal(set) var group: String?
    public internal(set) var value: Double

    init(parameter: AdjustmentParameter? = nil, group: String? = nil, value: Double = 0) {
        self.parameter = parameter
        self.group = group
        self.value = value
    }
}
#endif
