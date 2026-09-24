import Foundation
import PicshopCore

/// The words Live's brains are given: Claude's frozen system prompt and the
/// on-device model's instructions and per-turn prompt.
public enum LivePrompt {
    public static func system(mode: EditorMode) -> String {
        // Phase 0 stub.
        "You are Picshop Live, a creative director who edits the user's \(mode.rawValue) by voice."
    }

    public static func onDeviceInstructions(mode: EditorMode) -> String {
        // Phase 0 stub.
        system(mode: mode)
    }

    public static func onDevicePrompt(_ turn: LiveUserTurn) -> String {
        // Phase 0 stub.
        "User: \(turn.text)"
    }
}
