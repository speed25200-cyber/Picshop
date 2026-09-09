import Foundation
import PicshopCore

#if canImport(FoundationModels)
import FoundationModels

/// Planner backed by Apple's on-device foundation model (Apple Intelligence).
///
/// Uses guided generation so the model can only produce values from our
/// schema; the result is still validated by `IntentNormalizer` before it
/// reaches the executor. All inference runs on device.
@available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
public final class FoundationModelsIntentEngine: IntentEngine, @unchecked Sendable {
    public let kind: IntentEngineKind = .appleIntelligence

    private let model = SystemLanguageModel.default
    private let lock = NSLock()
    private var sessions: [EditorMode: (session: LanguageModelSession, requests: Int)] = [:]
    /// A session keeps every exchange in its transcript, which grows the prompt
    /// and eventually overflows the context window. Recycled after this many
    /// requests: often enough to stay bounded, rarely enough that consecutive
    /// commands still reuse the instructions the model has already read.
    private static let requestsPerSession = 8

    public init() {}

    public func isAvailable() async -> Bool {
        if case .available = model.availability { return true }
        return false
    }

    /// Human readable reason when the model can't be used.
    public var unavailabilityReason: String? {
        switch model.availability {
        case .available:
            return nil
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible: return "This device doesn't support Apple Intelligence."
            case .appleIntelligenceNotEnabled: return "Enable Apple Intelligence in Settings to use this brain."
            case .modelNotReady: return "The Apple Intelligence model is still downloading."
            @unknown default: return "Apple Intelligence is unavailable."
            }
        }
    }

    /// Warms the model so the first voice command answers quickly.
    public func prewarm(context: IntentContext) {
        session(for: context.mode).prewarm()
    }

    public func plan(_ utterance: String, context: IntentContext, hint: EditPlan?) async throws -> EditPlan {
        guard await isAvailable() else { throw PicshopError.modelUnavailable("Apple Intelligence") }
        let session = session(for: context.mode)
        let prompt = IntentPrompt.userPrompt(for: utterance, context: context, hint: hint)
        let options = GenerationOptions(temperature: 0.1)
        do {
            let response = try await session.respond(to: prompt, generating: GeneratedPlan.self, options: options)
            return IntentNormalizer.plan(from: response.content.rawPlan, utterance: utterance, context: context, engine: .appleIntelligence)
        } catch {
            // A full context window or a wedged session must not poison the next
            // command: drop it so the following request starts clean.
            discardSession(for: context.mode)
            throw error
        }
    }

    /// One session per editor, so the instructions the model has already read
    /// are reused across consecutive commands. Everything that changes between
    /// two requests is in the request itself, not in the instructions.
    private func session(for mode: EditorMode) -> LanguageModelSession {
        lock.lock()
        defer { lock.unlock() }
        if let existing = sessions[mode], existing.requests < Self.requestsPerSession {
            sessions[mode] = (existing.session, existing.requests + 1)
            return existing.session
        }
        let instructions = IntentPrompt.systemInstructions(mode: mode)
            + "\n\nExamples:\n" + IntentPrompt.fewShotExamples.map { "Request: \"\($0.0)\" → \($0.1)" }.joined(separator: "\n")
        let session = LanguageModelSession(instructions: instructions)
        sessions[mode] = (session, 1)
        return session
    }

    private func discardSession(for mode: EditorMode) {
        lock.lock()
        sessions[mode] = nil
        lock.unlock()
    }
}

@available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
@Generable(description: "One editing step for the PicShop photo/video editor.")
struct GeneratedStep {
    @Guide(description: "The action to perform, exactly one of the action names listed in the instructions (e.g. removeObject, adjust, applyLook, crop, split, deletePage).")
    var action: String

    @Guide(description: "For removeObject: canonical English noun of the thing to remove (dog, person, car, sign, wire, text, blemish, object).")
    var target: String?

    @Guide(description: "Where the target is: left, right, top, bottom, center, foreground, background, largest, smallest.")
    var spatialHint: String?

    @Guide(description: "true when the user wants every matching object removed.")
    var all: Bool?

    @Guide(description: "For adjust: the parameter name (exposure, brightness, contrast, highlights, shadows, whites, blacks, saturation, vibrance, temperature, tint, sharpness, clarity, noiseReduction, vignette, grain, fade, hue, skinTone).")
    var parameter: String?

    @Guide(description: "relative for more/less requests, absolute for 'set to' requests.", .anyOf(["relative", "absolute"]))
    var amountMode: String?

    @Guide(description: "Amount in percent, -100 to 100. Brighter is +20, a bit is ±10, a lot is ±40.")
    var amount: Double?

    @Guide(description: "For applyLook: the look name (original, vivid, vividWarm, vividCool, dramatic, dramaticWarm, dramaticCool, cinematic, goldenHour, tealOrange, matte, vintage, film, mono, silvertone, noir, portrait, pastel, punch, fresh).")
    var look: String?

    @Guide(description: "For crop/setAspect: original, free, square, ratio4x3, ratio3x4, ratio3x2, ratio2x3, ratio16x9, ratio9x16, ratio21x9, ratio5x4, ratio4x5.")
    var aspect: String?

    @Guide(description: "For rotate/straighten: degrees, negative for counter-clockwise.")
    var degrees: Double?

    @Guide(description: "For flip.", .anyOf(["horizontal", "vertical"]))
    var flipAxis: String?

    @Guide(description: "For addText/editText: the exact text to show, or for addMusic the genre.")
    var text: String?

    @Guide(description: "For replaceText: the new words that replace `text`.")
    var replacement: String?

    @Guide(description: "For addText: top, center, bottom, topLeading, topTrailing, bottomLeading or bottomTrailing.")
    var placement: String?

    @Guide(description: "Colour name in English (red, white, light blue...).")
    var color: String?

    @Guide(description: "For replaceBackground: colour name, or transparent.")
    var background: String?

    @Guide(description: "Video: start of the range in seconds.")
    var startSeconds: Double?

    @Guide(description: "Video: end of the range in seconds.")
    var endSeconds: Double?

    @Guide(description: "Video: a single time in seconds (split, seek, extractFrame).")
    var seconds: Double?

    @Guide(description: "Video: 1-based clip number.")
    var clipNumber: Int?

    @Guide(description: "Video transition kind: crossDissolve, fadeToBlack, fadeToWhite, slideLeft, slideRight, wipeLeft, zoom or blur.")
    var transition: String?

    @Guide(description: "Video: playback speed multiplier (0.5 = slow motion, 2 = twice as fast).")
    var speed: Double?

    @Guide(description: "For chooseCandidate/moveClip: 1-based index.")
    var choiceIndex: Int?

    @Guide(description: "current for the selected clip, all for every clip.", .anyOf(["current", "all"]))
    var scope: String?
}

@available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
@Generable(description: "The full plan for one spoken request.")
struct GeneratedPlan {
    @Guide(description: "The editing steps, in order. Empty if the request isn't an edit.", .maximumCount(6))
    var steps: [GeneratedStep]

    @Guide(description: "One short confirmation sentence in the user's language.")
    var reply: String

    @Guide(description: "A question to ask if the request is genuinely ambiguous, otherwise empty.")
    var clarification: String?

    @Guide(description: "Language of the request.", .anyOf(["fr", "en"]))
    var language: String

}

@available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
extension GeneratedPlan {
    var rawPlan: RawPlan {
        RawPlan(steps: steps.map { step in
            RawIntentStep(action: step.action, target: step.target, spatialHint: step.spatialHint, ordinal: nil, all: step.all, parameter: step.parameter,
                          amountMode: step.amountMode, amount: step.amount, look: step.look, aspect: step.aspect, degrees: step.degrees, flipAxis: step.flipAxis,
                          text: step.text, placement: step.placement, color: step.color, background: step.background, startSeconds: step.startSeconds,
                          endSeconds: step.endSeconds, seconds: step.seconds, clipNumber: step.clipNumber, transition: step.transition, speed: step.speed,
                          choiceIndex: step.choiceIndex, scope: step.scope, replacement: step.replacement)
        }, reply: reply, clarification: clarification, language: language)
    }
}
#endif
