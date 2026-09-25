import Foundation
import PicshopCore

/// One action run on the editor, by any lane, kept with its arguments in the model's own vocabulary
/// (`RawIntentStep(intent:)`) and what came of it. Follow-ups resolve against these: "les autres
/// aussi" widens the last fill, "pareil pour le sous-titre" moves it to a new ref, "encore" repeats
/// it, "plus gros" rescales what it wrote. The model reads the last one as the `last:` line.
public struct LiveActionRecord: Sendable, Equatable {
    /// model: an apply_edits call; grammar: the local fast lane; idea: a tapped chip.
    public enum Source: String, Sendable { case model, grammar, idea }

    public var source: Source
    /// The steps as run, via `RawIntentStep(intent:)`.
    public var steps: [RawIntentStep]
    public var results: [LiveStepResult]
    /// The document version after the run.
    public var version: Int

    public init(source: Source, steps: [RawIntentStep], results: [LiveStepResult], version: Int) {
        self.source = source
        self.steps = steps
        self.results = results
        self.version = version
    }

    /// At least one step applied.
    public var applied: Bool { results.contains { $0.status == .applied } }

    /// The `last:` line: "fillCells text=1 cells=empty → applied, filled 44, empty left 0 (grammar)",
    /// at most `budget` characters. Rendered by `LiveSceneLines.last`.
    public func line(budget: Int = LiveSceneLines.lastBudget, scene: SceneMap? = nil) -> String {
        LiveSceneLines.last(self, budget: budget, scene: scene)
    }
}
