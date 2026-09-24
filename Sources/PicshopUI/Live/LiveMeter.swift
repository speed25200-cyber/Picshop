#if canImport(SwiftUI) && canImport(UIKit)
import Foundation
import Observation

/// Audio levels for the Live orb and its halo, and nothing else: only LiveOrb
/// reads them, so the 30 Hz updates never re-evaluate a screen.
@MainActor
@Observable
public final class LiveMeter {
    /// Microphone, 0...1, smoothed (attack 0.55, release 0.12 per 1/60 s), published at 30 Hz.
    public var input: Double
    /// The assistant's voice, 0...1, smoothed and published the same way.
    public var output: Double

    public init(input: Double = 0, output: Double = 0) {
        self.input = input
        self.output = output
    }
}
#endif
