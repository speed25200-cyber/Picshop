import Foundation

/// When the photo canvas renders, decided once per display refresh.
///
/// A pure state machine (idle → interactive → settling → settled → idle) that
/// the display-link pump asks on every vsync. A drag marks the document dirty;
/// the next tick with no render in flight starts an interactive render, so
/// however many changes arrive between two frames, exactly one render follows
/// them. Once the finger has been still for `settleDelay`, one settled render
/// draws the sharp frame, and the pacer goes idle: `wantsFrames` turns false and
/// the display link pauses, so an untouched editor draws nothing.
public struct FramePacer: Sendable, Equatable {
    public enum Action: Sendable, Equatable { case none, renderInteractive, renderSettled }

    public enum Phase: Sendable, Equatable {
        /// Nothing to draw: the display link sleeps.
        case idle
        /// The finger is moving: interactive renders as fast as frames allow.
        case interactive
        /// The finger stopped (or a change landed outside a drag): the sharp frame is due at `deadline`.
        case settling(deadline: Double)
        /// The sharp frame is rendering; when it lands the pacer is idle.
        case settled
    }

    public private(set) var phase: Phase = .idle
    /// Seconds of stillness before the sharp frame.
    public var settleDelay: Double
    /// A change is waiting for an interactive render.
    public private(set) var interactivePending = false
    /// A render this pacer started has not finished.
    public private(set) var inFlight = false
    /// When the latest interactive change arrived.
    public private(set) var lastChange: Double = 0

    public init(settleDelay: Double = 0.12) {
        self.settleDelay = max(0, settleDelay)
    }

    /// The document changed. `interactive`: under a moving finger (a dial, a pinch of
    /// the crop); otherwise a finished change, drawn sharp at the next frame.
    public mutating func markDirty(interactive: Bool, now: Double) {
        if interactive {
            interactivePending = true
            lastChange = now
            phase = .interactive
        } else {
            // The sharp frame shows this change too: no interactive frame is needed for it.
            interactivePending = false
            phase = .settling(deadline: now)
        }
    }

    /// The render started by the last `.render…` action finished (or failed).
    public mutating func renderFinished(now: Double) {
        inFlight = false
        if phase == .settled, !interactivePending { phase = .idle }
    }

    /// What to do on this vsync. At most one render is ever in flight.
    public mutating func tick(now: Double, renderInFlight: Bool) -> Action {
        guard !renderInFlight, !inFlight else { return .none }
        if interactivePending {
            interactivePending = false
            inFlight = true
            if phase != .interactive { phase = .interactive }
            return .renderInteractive
        }
        if phase == .interactive { phase = .settling(deadline: lastChange + settleDelay) }
        if case .settling(let deadline) = phase, now >= deadline - 1e-9 {
            phase = .settled
            inFlight = true
            return .renderSettled
        }
        return .none
    }

    /// Whether the display link should run. False at idle, and while a render is in
    /// flight: its completion (`renderFinished`) wakes the pump again.
    public var wantsFrames: Bool {
        if inFlight { return false }
        if interactivePending { return true }
        switch phase {
        case .interactive, .settling: return true
        case .idle, .settled: return false
        }
    }
}
