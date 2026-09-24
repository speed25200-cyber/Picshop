import Foundation
import PicshopCore

/// Idea chips built on the device from what the editor knows, and the merge
/// with the ideas a brain proposes.
public enum IdeaEngine {
    public static func heuristic(_ state: LiveEditorState, dismissed: Set<String>, language: NormalizedUtterance.Language) -> [LiveIdea] {
        // Phase 0 stub.
        []
    }

    public static func merge(current: [LiveIdea], incoming: [LiveIdea], dismissed: Set<String>, fill: [LiveIdea]) -> [LiveIdea] {
        // Phase 0 stub.
        current
    }
}
