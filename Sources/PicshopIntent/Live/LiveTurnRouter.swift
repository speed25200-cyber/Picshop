import Foundation
import PicshopCore

public enum LiveControlCommand: Sendable, Equatable { case stopTalking, endLive, repeatLast, startOver, cancelJob, chooseIdea(Int) }

public enum LiveLane: Sendable, Equatable { case control(LiveControlCommand), local(EditPlan), brain(isQuestion: Bool) }

/// Decides where a committed turn goes: a control phrase, the local fast lane or the brain.
public enum LiveTurnRouter {
    public static func route(_ text: String, grammar: EditPlan, brain: LiveBrainKind, ideasOnScreen: Int, jobRunning: Bool, fastLane: Bool) -> LiveLane {
        // Phase 0 stub.
        brain == .local ? .local(grammar) : .brain(isQuestion: false)
    }
}
