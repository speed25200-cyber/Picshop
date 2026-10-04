import Foundation
import PicshopCore

/// D21: the executor helper shared by photo and video for the `recipe` operation. `RecipeBook.expand` gives the
/// steps; each runs through the same executor on the evolving document (re-grounded after a step that changed the
/// photo's geometry, D19), its structural postconditions checked; the first step that fails stops the recipe with
/// « J'ai fait N étapes sur M : … ». The whole recipe is one `ExecutionResult.applied("Recipe: <title>")`, one
/// history step « Recette : <titre> »; the export step's sheet effect is passed through.
public enum RecipeExecution {
    public static let recipeID: OpID = "recipe"

    /// A photo recipe; `step` runs one intent (the photo executor's `execute`).
    public static func run(_ call: OperationCall, on document: PhotoDocument, context: IntentContext, language: NormalizedUtterance.Language,
                           step: (EditIntent, PhotoDocument, IntentContext) async -> (PhotoDocument, ExecutionResult)) async -> (PhotoDocument, ExecutionResult) {
        await run(call, on: document, domain: .photo, recipeContext: RecipeContext(domain: .photo), context: context, language: language,
                  regrounding: { RefRegrounder.geometryMap(from: $0, to: $1) },
                  check: { intent, before, after in OperationPostconditions.check(intent, before: before, after: after).failed },
                  step: step)
    }

    /// A video recipe; `step` runs one intent (the video executor's `execute`).
    public static func run(_ call: OperationCall, on timeline: VideoTimeline, context: IntentContext, language: NormalizedUtterance.Language,
                           step: (EditIntent, VideoTimeline, IntentContext) async -> (VideoTimeline, ExecutionResult)) async -> (VideoTimeline, ExecutionResult) {
        let recipeContext = RecipeContext(domain: .video, hasMusic: !timeline.audioTracks.isEmpty, hasCaptions: !(timeline.captions?.cues.isEmpty ?? true))
        return await run(call, on: timeline, domain: .video, recipeContext: recipeContext, context: context, language: language,
                         regrounding: { _, _ in nil },
                         check: { intent, before, after in OperationPostconditions.check(intent, before: before, after: after).failed },
                         step: step)
    }

    /// The recipe's history label: "Recipe: Instagram post" (English, the other labels' rule; the catalog shows
    /// « Recette : Post Instagram »).
    public static func label(_ name: RecipeName) -> String {
        "Recipe: " + RecipeBook.title(of: name).en
    }

    /// The effects a step hands on to the editor: the export sheet, the selection used up, the layer to select.
    static func passesThrough(_ effect: EditorEffect) -> Bool {
        switch effect {
        case .message(let message): return message.hasPrefix(PhotoOperationHandlers.exportPrefix) || message == "selectionUsed" || message.hasPrefix("pickImageLayer")
        case .selectLayer, .selectClip: return true
        case .undo, .redo, .revert, .compare, .zoom, .export, .share, .play, .pause, .seek, .help, .pickMusic, .pickBackground, .pickColorReference,
             .clarify, .confirm, .cancel:
            return false
        }
    }

    static func run<Document>(_ call: OperationCall, on document: Document, domain: OpDomain, recipeContext: RecipeContext, context: IntentContext,
                              language: NormalizedUtterance.Language, regrounding: (Document, Document) -> PSHomography?,
                              check: (EditIntent, Document, Document) -> [String],
                              step: (EditIntent, Document, IntentContext) async -> (Document, ExecutionResult)) async -> (Document, ExecutionResult) {
        let fr = language == .french
        guard FeatureFlags.isOn(.recipes) else {
            return (document, ExecutionResult(outcome: .failed(message: fr ? "Pas encore activé sur cet iPhone." : "That isn't turned on on this iPhone yet."),
                                              effects: [ExecutionReason.unsupported.effect]))
        }
        guard let raw = call.args["name"]?.string, let name = RecipeName(rawValue: raw) else {
            return (document, ExecutionResult(outcome: .failed(message: fr ? "Quelle recette ? Post Instagram, photo produit, retouche portrait ou nettoyage vlog."
                                                                          : "Which recipe? Instagram post, product photo, portrait retouch or vlog cleanup."),
                                              effects: [ExecutionReason.nothingToDo.effect]))
        }
        let home = RecipeBook.domain(of: name)
        guard home == domain else {
            let message = home == .video ? (fr ? "Ça se fait dans une vidéo." : "That one is for a video.") : (fr ? "Ça se fait sur une photo." : "That one is for a photo.")
            return (document, ExecutionResult(outcome: .failed(message: message), effects: [ExecutionReason.nothingToDo.effect]))
        }
        let steps = RecipeBook.expand(name, args: call.args, context: recipeContext)
        let label = Self.label(name)
        guard !steps.isEmpty else {
            return (document, ExecutionResult(outcome: .info(message: fr ? "Il n'y a rien à faire ici." : "There is nothing to do here.")))
        }
        var current = document
        var stepContext = context
        var carried: [EditorEffect] = []
        var done = 0
        func stop(_ why: String, reason: ExecutionReason?) -> (Document, ExecutionResult) {
            let text = why.trimmingCharacters(in: .whitespacesAndNewlines)
            let message = fr ? "J'ai fait \(done) étape\(done > 1 ? "s" : "") sur \(steps.count) : \(text)" : "I did \(done) of \(steps.count) steps: \(text)"
            // Never `unsupported` for a recipe: the step said why, the recipe exists.
            let code = (reason == nil || reason == .unsupported) ? ExecutionReason.nothingToDo : reason!
            guard done > 0 else { return (document, ExecutionResult(outcome: .failed(message: message), effects: [code.effect])) }
            return (current, ExecutionResult(outcome: .applied(label: label), effects: carried + [.message("speak:" + message), code.effect], label: label))
        }
        for original in steps {
            var intent = original
            if let map = regrounding(document, current) {
                guard let moved = RefRegrounder.regrounded(intent, by: map) else { return stop(RefRegrounder.leftTheCanvas(french: fr), reason: .badRegion) }
                intent = moved
            }
            let (next, result) = await step(intent, current, stepContext)
            switch result.outcome {
            case .applied:
                let failed = check(intent, current, next)
                if !failed.isEmpty {
                    return stop(fr ? "une étape n'a pas donné le résultat attendu (\(failed.joined(separator: ", ")))." : "a step did not come out as expected (\(failed.joined(separator: ", "))).",
                                reason: .verifyFailed)
                }
                current = next
                done += 1
            case .info:
                current = next
                done += 1
            case .failed(let message):
                return stop(message, reason: result.reason)
            case .needsClarification(let request):
                return stop(request.question, reason: .ambiguous)
            case .ignored:
                continue
            }
            carried += result.effects.filter(passesThrough)
            stepContext.lastIntent = intent
        }
        let said = fr ? "C'est prêt : \(RecipeBook.title(of: name).fr.lowercased())." : "Done: \(RecipeBook.title(of: name).en)."
        return (current, ExecutionResult(outcome: .applied(label: label), effects: carried + [.message("speak:" + said)], label: label))
    }
}
