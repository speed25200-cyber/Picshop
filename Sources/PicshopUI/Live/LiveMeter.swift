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

    /// The smoothed levels; `input` and `output` follow them when the change is visible.
    @ObservationIgnored private var smoothedInput: Double = 0
    @ObservationIgnored private var smoothedOutput: Double = 0

    /// One 30 Hz publish: two 1/60 s smoothing steps toward the targets, assigned only on a visible change.
    func publish(inputTarget: Double, outputTarget: Double) {
        smoothedInput = Self.smooth(smoothedInput, toward: inputTarget)
        smoothedOutput = Self.smooth(smoothedOutput, toward: outputTarget)
        if abs(smoothedInput - input) > 0.002 || (smoothedInput == 0 && input != 0) { input = smoothedInput }
        if abs(smoothedOutput - output) > 0.002 || (smoothedOutput == 0 && output != 0) { output = smoothedOutput }
    }

    /// Both levels at rest.
    func reset() {
        smoothedInput = 0
        smoothedOutput = 0
        if input != 0 { input = 0 }
        if output != 0 { output = 0 }
    }

    private static func smooth(_ value: Double, toward target: Double) -> Double {
        let clamped = min(max(target.isFinite ? target : 0, 0), 1)
        var current = value
        for _ in 0..<2 {
            let coefficient = clamped > current ? 0.55 : 0.12
            current += (clamped - current) * coefficient
        }
        return current < 0.004 ? 0 : current
    }
}
#endif
