#if canImport(SwiftUI) && canImport(UIKit) && canImport(FoundationModels)
import Foundation
import FoundationModels
import PicshopCore
import PicshopIntent

/// Live's middle brain: Apple's on-device foundation model with tool calling,
/// streamed, used when the local model is not ready. It cannot see pixels, so
/// each turn carries the compact editor state and the scene facts. Tool calls go
/// through the same validator and handler as the local model's.
@available(iOS 26.0, *)
final class FoundationModelsLiveBrain: LiveBrain, @unchecked Sendable {
    let kind: LiveBrainKind = .onDevice

    private let mode: EditorMode
    private let bridge: FoundationModelsToolBridge
    private let lock = NSLock()
    private var session: LanguageModelSession?
    private var turnsInSession = 0
    /// The last exchanges, for the 300-character recap a fresh session starts with.
    private var recap: [String] = []
    private static let turnsPerSession = 6

    init(mode: EditorMode) {
        self.mode = mode
        bridge = FoundationModelsToolBridge(mode: mode)
    }

    func isAvailable() async -> Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    func warmUp() async {
        guard await isAvailable() else { return }
        currentSession().prewarm()
    }

    func respond(to turn: LiveUserTurn, tools: any LiveToolHandler) -> AsyncThrowingStream<LiveBrainEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { await self.run(turn, tools: tools, continuation: continuation) }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func interrupt(turn: Int, spokenText: String) async {
        // The session keeps its own transcript; the next prompt carries what changed.
        lock.withLock { recap.append("(interrupted)") }
    }

    func reset() async {
        lock.withLock {
            session = nil
            turnsInSession = 0
            recap = []
        }
    }

    // MARK: Turn

    private func run(_ turn: LiveUserTurn, tools: any LiveToolHandler, continuation: AsyncThrowingStream<LiveBrainEvent, Error>.Continuation) async {
        guard turn.kind != .sessionStart else {
            continuation.yield(.completed(.answered))
            continuation.finish()
            return
        }
        bridge.begin(turn: turn.id, handler: tools, continuation: continuation)
        defer { bridge.end(turn: turn.id) }
        continuation.yield(.started(model: "apple-on-device"))
        let prompt = LivePrompt.onDevicePrompt(turn)
        var retried = false
        while true {
            let session = currentSession()
            var emitted = false
            do {
                let reply = try await stream(session, prompt: prompt, continuation: continuation, emitted: &emitted)
                remember(user: turn.text, reply: reply)
                continuation.yield(.completed(bridge.appliedEdit(turn: turn.id) ? .editApplied : .answered))
                continuation.finish()
                return
            } catch let error as LanguageModelSession.GenerationError {
                if case .exceededContextWindowSize = error, !retried, !emitted {
                    // A fresh session with a short recap, once.
                    retried = true
                    dropSession()
                    continue
                }
                if case .guardrailViolation = error {
                    continuation.yield(.completed(.refused(category: nil)))
                    continuation.finish()
                    return
                }
                dropSession()
                continuation.finish(throwing: LiveBrainError.unavailable("on-device model: \(String(describing: error).prefix(60))"))
                return
            } catch is CancellationError {
                continuation.finish(throwing: CancellationError())
                return
            } catch {
                dropSession()
                if Task.isCancelled {
                    continuation.finish(throwing: CancellationError())
                } else {
                    continuation.finish(throwing: LiveBrainError.unavailable("on-device model"))
                }
                return
            }
        }
    }

    /// Snapshots are cumulative: each delta is what extends the text already emitted.
    /// A snapshot that rewrites earlier text stops the deltas; the final text then adds
    /// only what follows the emitted prefix.
    private func stream(_ session: LanguageModelSession, prompt: String, continuation: AsyncThrowingStream<LiveBrainEvent, Error>.Continuation,
                        emitted: inout Bool) async throws -> String {
        let options = GenerationOptions(temperature: 0.5, maximumResponseTokens: 180)
        var spoken = ""
        var latest = ""
        var diverged = false
        for try await snapshot in session.streamResponse(to: prompt, options: options) {
            try Task.checkCancellation()
            latest = snapshot.content
            guard !diverged else { continue }
            if latest.hasPrefix(spoken) {
                let delta = String(latest.dropFirst(spoken.count))
                if !delta.isEmpty {
                    continuation.yield(.text(delta))
                    emitted = true
                    spoken = latest
                }
            } else {
                diverged = true
            }
        }
        if diverged, latest.hasPrefix(spoken), latest.count > spoken.count {
            continuation.yield(.text(String(latest.dropFirst(spoken.count))))
            emitted = true
        }
        return latest
    }

    // MARK: Sessions

    private func currentSession() -> LanguageModelSession {
        lock.withLock {
            if let session, turnsInSession < Self.turnsPerSession {
                turnsInSession += 1
                return session
            }
            var instructions = LivePrompt.onDeviceInstructions(mode: mode)
            let summary = recap.suffix(4).joined(separator: " / ")
            if !summary.isEmpty { instructions += "\nRecap: " + String(summary.suffix(300)) }
            let tools: [any Tool] = [
                LiveApplyEditsTool(bridge: bridge),
                LiveUndoTool(bridge: bridge),
                LiveCompareTool(bridge: bridge),
            ]
            let fresh = LanguageModelSession(tools: tools, instructions: instructions)
            session = fresh
            turnsInSession = 1
            return fresh
        }
    }

    private func dropSession() {
        lock.withLock {
            session = nil
            turnsInSession = 0
        }
    }

    private func remember(user: String, reply: String) {
        lock.withLock {
            recap.append("U: \(user.prefix(80)) A: \(reply.prefix(80))")
            if recap.count > 6 { recap.removeFirst(recap.count - 6) }
        }
    }
}

/// Connects the model's tool calls to the turn being answered: its handler and
/// its event stream change every turn, the tools do not.
@available(iOS 26.0, *)
final class FoundationModelsToolBridge: @unchecked Sendable {
    private let mode: EditorMode
    private let lock = NSLock()
    private var turn: Int?
    private var handler: (any LiveToolHandler)?
    private var continuation: AsyncThrowingStream<LiveBrainEvent, Error>.Continuation?
    private var applied: Set<Int> = []
    private var counter = 0

    init(mode: EditorMode) {
        self.mode = mode
    }

    func begin(turn: Int, handler: any LiveToolHandler, continuation: AsyncThrowingStream<LiveBrainEvent, Error>.Continuation) {
        lock.withLock {
            self.turn = turn
            self.handler = handler
            self.continuation = continuation
            applied.remove(turn)
        }
    }

    func end(turn: Int) {
        lock.withLock {
            guard self.turn == turn else { return }
            self.turn = nil
            handler = nil
            continuation = nil
        }
    }

    func appliedEdit(turn: Int) -> Bool {
        lock.withLock { applied.contains(turn) }
    }

    private func claim() -> (handler: any LiveToolHandler, continuation: AsyncThrowingStream<LiveBrainEvent, Error>.Continuation, id: String, turn: Int)? {
        lock.withLock {
            guard let turn, let handler, let continuation else { return nil }
            counter += 1
            return (handler, continuation, "fm_\(counter)", turn)
        }
    }

    private func markApplied(_ turn: Int) {
        lock.withLock { _ = applied.insert(turn) }
    }

    func applyEdits(_ steps: [RawIntentStep]) async -> String {
        guard let call = claim() else { return "{\"ok\":false,\"error\":\"no active turn\"}" }
        let context = await call.handler.context()
        switch ToolInputValidator(mode: mode).steps(raw: Array(steps.prefix(4)), context: context) {
        case .failure(let error):
            let problems: [JSONValue]
            switch error {
            case .problems(let list): problems = list.prefix(8).map { JSONValue.string($0) }
            case .invalidJSON: problems = ["invalid input"]
            case .notAnObject: problems = ["not an object"]
            case .unknownTool(let name): problems = [JSONValue.string("unknown tool \(name)")]
            }
            let payload: JSONValue = ["error": "invalid_input", "problems": JSONValue.array(problems), "hint": "Fix these fields and call the tool again."]
            return ToolResultEncoder.compactText(LiveToolResult(isError: true, payload: payload, changedDocument: false))
        case .success(let intents):
            return await perform(call, tool: .applyEdits(intents), name: .applyEdits)
        }
    }

    func undo(count: Int) async -> String {
        guard let call = claim() else { return "{\"ok\":false}" }
        return await perform(call, tool: .undo(count: min(max(count, 1), 10), redo: false, toOriginal: false), name: .undo)
    }

    func compare(seconds: Int) async -> String {
        guard let call = claim() else { return "{\"ok\":false}" }
        return await perform(call, tool: .compare(seconds: Double(min(max(seconds, 1), 5))), name: .compareBeforeAfter)
    }

    private func perform(_ call: (handler: any LiveToolHandler, continuation: AsyncThrowingStream<LiveBrainEvent, Error>.Continuation, id: String, turn: Int),
                         tool: LiveTool, name: LiveToolName) async -> String {
        call.continuation.yield(.toolStarted(id: call.id, name: name, activity: nil))
        let result = await call.handler.perform(LiveToolCall(id: call.id, tool: tool))
        call.continuation.yield(.toolFinished(id: call.id, name: name, result: result))
        if result.changedDocument { markApplied(call.turn) }
        return ToolResultEncoder.compactText(result)
    }
}

@available(iOS 26.0, *)
@Generable(description: "One editing step.")
struct LiveStepArguments {
    @Guide(description: "The action name, exactly as listed in the instructions.")
    var action: String
    @Guide(description: "The object: a canonical English noun (dog, person, sky, face).")
    var target: String?
    @Guide(description: "left, right, top, bottom, center, foreground, background, largest or smallest.")
    var spatialHint: String?
    @Guide(description: "true for every matching object.")
    var all: Bool?
    @Guide(description: "For adjust: the parameter name (exposure, contrast, saturation, warmth...).")
    var parameter: String?
    @Guide(description: "relative for more or less, absolute for set to.", .anyOf(["relative", "absolute"]))
    var amountMode: String?
    @Guide(description: "Percent from -100 to 100 for adjustments; seconds or a multiplier where the instructions say so.")
    var amount: Double?
    @Guide(description: "For applyLook: the look name.")
    var look: String?
    @Guide(description: "For crop and setAspect: square, ratio4x5, ratio9x16, ratio16x9...")
    var aspect: String?
    @Guide(description: "For rotate and straighten: degrees.")
    var degrees: Double?
    @Guide(description: "For flip.", .anyOf(["horizontal", "vertical"]))
    var flipAxis: String?
    @Guide(description: "Text to show, or the music genre.")
    var text: String?
    @Guide(description: "Colour name in English.")
    var color: String?
    @Guide(description: "Video: start of the range in seconds.")
    var startSeconds: Double?
    @Guide(description: "Video: end of the range in seconds.")
    var endSeconds: Double?
    @Guide(description: "Video: one time in seconds.")
    var seconds: Double?
    @Guide(description: "Video: 1-based clip number.")
    var clipNumber: Int?
    @Guide(description: "Video: speed multiplier.")
    var speed: Double?
}

@available(iOS 26.0, *)
extension LiveStepArguments {
    var raw: RawIntentStep {
        RawIntentStep(action: action, target: target, spatialHint: spatialHint, all: all, parameter: parameter, amountMode: amountMode, amount: amount,
                      look: look, aspect: aspect, degrees: degrees, flipAxis: flipAxis, text: text, color: color, startSeconds: startSeconds,
                      endSeconds: endSeconds, seconds: seconds, clipNumber: clipNumber, speed: speed)
    }
}

@available(iOS 26.0, *)
struct LiveApplyEditsTool: Tool {
    let bridge: FoundationModelsToolBridge
    let name = "apply_edits"
    let description = "Apply edits to the open photo or video, in order. Call it when the user asks for a change or accepts an idea. Never for questions."

    @Generable
    struct Arguments {
        @Guide(description: "The steps, in order.", .maximumCount(4))
        var steps: [LiveStepArguments]
    }

    func call(arguments: Arguments) async throws -> String {
        await bridge.applyEdits(arguments.steps.map(\.raw))
    }
}

@available(iOS 26.0, *)
struct LiveUndoTool: Tool {
    let bridge: FoundationModelsToolBridge
    let name = "undo"
    let description = "Undo the last edits, when the user says it is too much or wants it back as before."

    @Generable
    struct Arguments {
        @Guide(description: "How many edits to undo.", .range(1...10))
        var count: Int
    }

    func call(arguments: Arguments) async throws -> String {
        await bridge.undo(count: arguments.count)
    }
}

@available(iOS 26.0, *)
struct LiveCompareTool: Tool {
    let bridge: FoundationModelsToolBridge
    let name = "compare_before_after"
    let description = "Show the original for a few seconds, when the user wants to see the before."

    @Generable
    struct Arguments {
        @Guide(description: "Seconds to show the original.", .range(1...5))
        var seconds: Int
    }

    func call(arguments: Arguments) async throws -> String {
        await bridge.compare(seconds: arguments.seconds)
    }
}
#endif
