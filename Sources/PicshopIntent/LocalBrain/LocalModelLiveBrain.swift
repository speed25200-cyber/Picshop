import Foundation
import PicshopCore

/// Live's model brain: Qwen3.5 on the iPhone, through a `LocalChatEngine`.
/// It talks, looks at the picture when it needs to, and acts only through the
/// four validated tools. When it cannot answer before saying anything, the turn
/// goes to `fallback`, the rules-only grammar.
///
/// One engine (one KV cache) per conversation, append-only: every user message
/// goes on top of what the model already read. How one turn runs (contract §6):
/// 1. `.started`, then the user message (the session-start message or a delta of
///    the editor state), the picture when it deserves a fresh look, and the tool
///    results owed from the last turn in front of it.
/// 2. Streamed text goes through `LocalOutputFilter`: speech becomes `.text`, a
///    call written as text or sent structured goes through the coercer and the
///    validator, then the editor.
/// 3. A clean edit ends the turn (its result is owed to the next message); a
///    failed, needs-user or invalid result goes back to the model, within
///    `maxRounds` and `maxApplyEdits`. Still invalid after one retry with nothing
///    said: the grammar answers instead.
/// 4. Past `compactAt` tokens, or when a third picture arrives, the engine is
///    replaced by one that starts from the examples and a recap written by code.
public actor LocalModelLiveBrain: LiveBrain {
    public struct Limits: Sendable, Equatable {
        /// Seconds without a token before `.timeout(stage: "first_token")`.
        public var firstTokenTimeout = 6.0
        /// Additive (phase 1): the same deadline when the cache is cold (a new
        /// conversation, a compaction, the rebuild after a cut-off turn, a previous turn
        /// that reused nothing, or a turn that attaches a picture), where the system
        /// prompt, the examples and the history are prefilled first.
        public var coldFirstTokenTimeout = 12.0
        public var turnTimeout = 25.0
        /// Generations per turn, tool round trips included.
        public var maxRounds = 3
        public var maxApplyEdits = 2
        /// Rounds after a step that failed with a reason, was blocked as a repeat, or applied but
        /// failed its check (act-then-verify): one, greedy; then the turn says so in one sentence.
        public var maxRepairRounds = 1
        /// How long the check of an applied result may hold the turn, on top of the step itself.
        public var verifyTimeout = 2.0
        /// Context tokens above which the conversation is compacted. 7,000 since the table and text
        /// examples (a prefix of about 4,000 tokens): room for five or six grounded turns, and a turn's
        /// worst case (a grounded message, a picture, three generations) still fits in 8,192.
        public var compactAt = 7_000
        public var maxImagesInContext = 2
        public var speechMaxTokens = 120
        /// Session start and opinions, when propose_ideas is expected.
        public var ideasMaxTokens = 320
        /// Thermal state serious.
        public var hotMaxTokens = 80

        public init() {}
    }

    /// .model
    public nonisolated let kind: LiveBrainKind
    public nonisolated let capabilities: LiveBrainCapabilities

    private let mode: EditorMode
    private let info: LocalModelInfo
    private let makeEngine: LocalChatEngineFactory
    private let fallback: (any LiveBrain)?
    private let limits: Limits
    private let clock: any LiveClock
    private let log: (@Sendable (LiveLogEntry) -> Void)?
    private var thermalSerious = false

    // The conversation, as the engine holds it.
    private var engine: (any LocalChatEngine)?
    /// The editor state the model read last, so the next message says only what changed.
    private var lastSentState: LiveEditorState?
    /// The picture the model saw last: its version (and video frame), its shape.
    private var lastLook: (version: Int, frame: String?)?
    private var lastImageAspect: Double?
    private var imagesInContext = 0
    /// Tool results the model has not read yet: they open the next message.
    private var owedResults: [LocalChatMessage] = []
    /// What the user heard before cutting the last reply off.
    private var heardBeforeInterruption: String?
    private var callCounter = 0
    /// The next generation starts from a cold cache (see `Limits.coldFirstTokenTimeout`):
    /// true until a turn actually reused cached tokens.
    private var cacheIsCold = true

    /// The engine answered `.modelNotReady` before any output of the turn's first
    /// generation (it was closed when the weights were unloaded): `run` opens a fresh one, once.
    private struct EngineClosedBeforeOutput: Error {}

    // What a compaction keeps (never logged).
    private var recapEdits: [String] = []
    private var recapExchanges: [String] = []
    private var openQuestion: String?
    private var lastLookNote: String?

    // One turn at a time: a new turn waits for the previous one to wind down.
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// The long side of the snapshot the session hands over for a look.
    private static let imageMaxPixel = 768

    public init(mode: EditorMode, info: LocalModelInfo, makeEngine: @escaping LocalChatEngineFactory,
                fallback: (any LiveBrain)?, limits: Limits = .init(),
                clock: any LiveClock = SystemLiveClock(), log: (@Sendable (LiveLogEntry) -> Void)? = nil) {
        kind = .model
        capabilities = LiveBrainCapabilities(opensSession: true, seesImages: info.supportsVision, imageMaxPixel: Self.imageMaxPixel, proposesIdeas: true)
        self.mode = mode
        self.info = info
        self.makeEngine = makeEngine
        self.fallback = fallback
        self.limits = limits
        self.clock = clock
        self.log = log
    }

    /// Serious: shorter answers (`hotMaxTokens`) and no ideas at session start.
    public func setThermalSerious(_ serious: Bool) {
        thermalSerious = serious
    }

    public func isAvailable() async -> Bool { true }

    /// Opens the conversation ahead of the first turn: the engine is made and
    /// prepared. Quietly does nothing while the weights are not loaded, or while
    /// a turn runs.
    public func warmUp() async {
        guard engine == nil, !busy else { return }
        await acquire()
        defer { release() }
        guard engine == nil else { return }
        do {
            _ = try await openEngine(recap: nil)
        } catch {
            note("model.warmup_failed", ["error": Self.errorName(error)])
        }
    }

    public nonisolated func respond(to turn: LiveUserTurn, tools: any LiveToolHandler) -> AsyncThrowingStream<LiveBrainEvent, Error> {
        let (stream, continuation) = AsyncThrowingStream<LiveBrainEvent, Error>.makeStream()
        let task = Task { await self.run(turn, tools: tools, output: continuation) }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    /// Records what was heard for the next message (`interruptedAfter`); there is no rewind (D6).
    public func interrupt(turn: Int, spokenText: String) async {
        let heard = spokenText.trimmingCharacters(in: .whitespacesAndNewlines)
        heardBeforeInterruption = heard.isEmpty ? nil : String(heard.suffix(200))
        // A cut-off generation is not kept: the next one rebuilds the cache from the transcript.
        cacheIsCold = true
        note("model.interrupted", ["turn": String(turn), "heard_chars": String(heard.count)])
    }

    /// A new conversation: the engine is closed and everything it knew forgotten.
    public func reset() async {
        await acquire()
        defer { release() }
        let old = engine
        engine = nil
        clearConversation()
        await old?.close()
    }

    // MARK: - One turn

    typealias Output = AsyncThrowingStream<LiveBrainEvent, Error>.Continuation

    private func run(_ turn: LiveUserTurn, tools: any LiveToolHandler, output: Output) async {
        await acquire()
        defer { release() }
        guard !Task.isCancelled else {
            output.finish()
            return
        }
        output.yield(.started(model: info.displayName))
        let heard = heardBeforeInterruption
        do {
            do {
                try await answer(turn, tools: tools, output: output)
            } catch is EngineClosedBeforeOutput {
                // The weights were unloaded under this conversation, and may be back: a fresh
                // engine (the whole editor state, the picture again), once. Still closed: the next brain.
                note("model.engine_reopened", ["turn": String(turn.id)])
                await dropEngine()
                heardBeforeInterruption = heard
                try await answer(turn, tools: tools, output: output)
            }
            output.finish()
        } catch {
            if error is CancellationError || Task.isCancelled {
                cacheIsCold = true
                output.finish()
                return
            }
            cacheIsCold = true
            let brainError = error is EngineClosedBeforeOutput ? .modelNotReady : ((error as? LiveBrainError) ?? .unavailable("model: \(Self.errorName(error))"))
            note("model.error", ["turn": String(turn.id), "error": BrainSelector.errorName(brainError)])
            if case .timeout = brainError {} else {
                // The engine may be gone (weights unloaded) or unsure of its transcript: the next turn opens a fresh one.
                await dropEngine()
            }
            output.finish(throwing: brainError)
        }
    }

    /// What one turn accumulates across its generations.
    private struct Progress {
        var rounds = 0
        var applyEdits = 0
        var invalidRetries = 0
        var spoken = ""
        var cleanEdit = false
        var lastExecution: LiveExecution?
        var loopLimited = false
        var firstTokenMs: Int?
        var promptTokens = 0
        var cachedTokens = 0
        var generatedTokens = 0
        var tokensPerSecond = 0.0
        var stop: LocalStopReason = .endOfTurn
        /// This turn attached a picture.
        var looked = false
        /// Steps that failed this turn, by what makes them the same (D12): a repeat is answered blocked.
        var failedSteps: [StepSignature: LiveStepResult] = [:]
        /// Rounds given after a reasoned failure, a blocked repeat or a failed check (at most `maxRepairRounds`).
        var repairRounds = 0
        /// The last run left something to own up to (a failure, a block, a failed check) and nothing was
        /// said since: `finish` says it.
        var owesOutcome = false
        /// Step actions and reason codes of the turn's calls, for `model.tool`.
        var loggedActions: [String] = []
        /// Some step of the turn changed the picture (the turn then ends `.editApplied`).
        var changedDocument = false
    }

    /// What makes two steps the same for the identical-failure block (D12): the action and its key
    /// arguments (target, text, table scope, scene ref, region). A step whose signature already
    /// failed this turn is not run again: it comes back `blocked[repeat]`.
    struct StepSignature: Hashable, Sendable {
        var action: IntentAction
        var target: String?
        var text: String?
        var rows: [TableEditSpec.Ref]
        var columns: [TableEditSpec.Ref]
        var onlyEmpty: Bool?
        var ref: String?
        var region: PSRect?
        /// Every other argument, in the model's vocabulary (amount, parameter, look, point, value…):
        /// "plus chaud" with 15 then with 25 are two different steps.
        var arguments: String

        init(_ intent: EditIntent) {
            action = intent.action
            target = intent.target?.label
            text = intent.text?.lowercased()
            rows = intent.table?.rows ?? []
            columns = intent.table?.columns ?? []
            onlyEmpty = intent.table?.onlyEmpty
            ref = intent.ref?.id
            region = intent.region
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            arguments = (try? encoder.encode(RawIntentStep(intent: intent))).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        }
    }

    /// The sampling style of a turn's first generation (contract §11): questions, opinions and the
    /// session start talk (0.6); everything else is edit-like (an action verb, a follow-up on the `last:`
    /// line, a table request) and wants tool JSON with little randomness (0.25). The repair round is greedy.
    static func style(for turn: LiveUserTurn) -> LocalGenerationOptions.Style {
        if turn.kind == .sessionStart || expectsIdeas(turn) { return .conversation }
        if LiveTurnRouter.isQuestion(turn.text, tokens: NormalizedUtterance(turn.text).tokens) { return .conversation }
        return .edit
    }

    /// One tool call of the current generation and what came of it.
    private struct CallRecord {
        var id: String
        var name: String
        var result: LiveToolResult
        var needsReply: Bool
        var invalid: Bool
        /// A reasoned failure, a blocked repeat or a failed check: the next round is the repair round.
        var wantsRepair = false

        var message: LocalChatMessage { .toolResult(callID: id, name: name, content: ToolResultEncoder.compactText(result)) }
    }

    private func answer(_ original: LiveUserTurn, tools: any LiveToolHandler, output: Output) async throws {
        let started = clock.now()
        var turn = original
        if turn.interruptedAfter == nil { turn.interruptedAfter = heardBeforeInterruption }
        heardBeforeInterruption = nil

        var engine = try await currentEngine()
        if await engine.contextTokens() > limits.compactAt { engine = try await compact(reason: "tokens") }

        // The picture: once per version, and only when this turn needs a fresh look (D7).
        var imageJPEG: Data?
        if capabilities.seesImages, let image = turn.image, deservesLook(turn, image: image) {
            if imagesInContext >= limits.maxImagesInContext { engine = try await compact(reason: "images") }
            imageJPEG = image.jpeg
            imagesInContext += 1
            lastLook = (image.version, image.frameKey)
            lastImageAspect = image.pixelHeight > 0 ? Double(image.pixelWidth) / Double(image.pixelHeight) : nil
            note("model.look", ["turn": String(turn.id), "version": String(image.version), "images": String(imagesInContext)])
        }

        var text: String
        if turn.kind == .sessionStart {
            text = LocalLivePrompt.sessionStartMessage(turn, imageAttached: imageJPEG != nil)
            if thermalSerious { text += "\n" + Self.hotSessionStartLine(turn.language) }
        } else {
            text = LocalLivePrompt.userMessage(turn, previous: lastSentState, imageAttached: imageJPEG != nil)
        }
        var messages = owedResults + [LocalChatMessage.user(text, imageJPEG: imageJPEG)]
        owedResults = []
        lastSentState = turn.editorState

        let maxTokens = thermalSerious ? limits.hotMaxTokens : (Self.expectsIdeas(turn) ? limits.ideasMaxTokens : limits.speechMaxTokens)
        var options = LocalGenerationOptions(style: Self.style(for: turn), maxTokens: maxTokens)

        // Re-read after every round that changed the picture: a repair names what the last round made ("l1"),
        // and a block it erased ("t1") must no longer validate.
        var context = await tools.context()
        let grounding = ToolInputValidator.Grounding(imageAspect: lastImageAspect, canvasAspect: turn.editorState.canvasPixels.flatMap(Self.aspect))
        var progress = Progress()
        progress.looked = imageJPEG != nil

        while true {
            try Task.checkCancellation()
            progress.rounds += 1
            let records = try await generate(engine: engine, messages: messages, options: options, turn: turn, tools: tools, context: context,
                                             grounding: grounding, started: started, progress: &progress, output: output)
            let replies = records.map(\.message)

            if progress.loopLimited {
                owedResults = replies
                return finish(turn, .loopLimit, progress: progress, output: output)
            }
            if records.contains(where: \.needsReply) {
                if records.contains(where: \.invalid) { progress.invalidRetries += 1 }
                let repair = records.contains(where: \.wantsRepair)
                if repair { progress.repairRounds += 1 }
                if progress.invalidRetries > 1, progress.spoken.isEmpty, let fallback {
                    // Still invalid after one retry, nothing said: the grammar answers the same words.
                    owedResults = replies
                    return try await forward(turn, to: fallback, tools: tools, progress: progress, output: output)
                }
                if progress.repairRounds > limits.maxRepairRounds {
                    // The repair round did not fix it (D12): one honest sentence, no more tries.
                    owedResults = replies
                    note("model.repair_exhausted", ["turn": String(turn.id), "rounds": String(progress.rounds)])
                    return finish(turn, progress.changedDocument ? .editApplied : .loopLimit, progress: progress, output: output)
                }
                if progress.rounds >= limits.maxRounds || progress.invalidRetries > 1 {
                    owedResults = replies
                    note("model.loop_limit", ["turn": String(turn.id), "rounds": String(progress.rounds)])
                    return finish(turn, .loopLimit, progress: progress, output: output)
                }
                messages = replies
                // The repair round is greedy: the model reads the code and the hint, and follows them.
                if repair { options = LocalGenerationOptions(style: .repair, maxTokens: options.maxTokens) }
                if progress.changedDocument { context = await tools.context() }
                continue
            }
            owedResults = replies
            if records.isEmpty, progress.spoken.isEmpty {
                // Nothing said after a step ran (a repair round left silent): the reason-aware outcome.
                if progress.lastExecution != nil { return finish(turn, progress.changedDocument ? .editApplied : .answered, progress: progress, output: output) }
                // The model said nothing at all.
                if let fallback { return try await forward(turn, to: fallback, tools: tools, progress: progress, output: output) }
                throw LiveBrainError.streamTruncated
            }
            let end: LiveTurnEnd = progress.cleanEdit ? .editApplied : (progress.stop == .maxTokens ? .maxTokens : .answered)
            return finish(turn, end, progress: progress, output: output)
        }
    }

    /// One generation: streams it, speaks it, runs its calls as they close.
    private func generate(engine: any LocalChatEngine, messages: [LocalChatMessage], options: LocalGenerationOptions, turn: LiveUserTurn,
                          tools: any LiveToolHandler, context: IntentContext, grounding: ToolInputValidator.Grounding, started: Double,
                          progress: inout Progress, output: Output) async throws -> [CallRecord] {
        let remaining = started + limits.turnTimeout - clock.now()
        guard remaining > 0 else { throw LiveBrainError.timeout(stage: "turn") }
        let sentAt = clock.now()
        // Cold: no reuse seen yet, or a picture attached (Qwen3.5 cannot split a new picture
        // off a cached prefix, so that turn prefills everything and runs the vision tower).
        let cold = cacheIsCold || progress.looked
        let firstToken = progress.rounds == 1 && cold ? max(limits.firstTokenTimeout, limits.coldFirstTokenTimeout) : limits.firstTokenTimeout
        let ticks = Self.watched(engine.send(messages, options: options), clock: clock, firstToken: firstToken, turn: remaining)
        // Several calls in one generation: each one is checked against the picture as the calls before left it.
        var context = context
        var filter = LocalOutputFilter()
        var records: [CallRecord] = []
        var gotToken = false

        func token() {
            guard !gotToken else { return }
            gotToken = true
            if progress.firstTokenMs == nil { progress.firstTokenMs = Int(((clock.now() - sentAt) * 1_000).rounded()) }
        }

        do {
            for try await tick in ticks {
                try Task.checkCancellation()
                switch tick {
                case .firstTokenMissed:
                    if !gotToken { throw LiveBrainError.timeout(stage: "first_token") }
                case .turnDeadline:
                    throw LiveBrainError.timeout(stage: "turn")
                case .event(.text(let delta)):
                    token()
                    for piece in filter.feed(delta) {
                        try await take(piece, turn: turn, tools: tools, context: context, grounding: grounding, progress: &progress, records: &records, output: output)
                        if case .toolCall = piece { if progress.changedDocument { context = await tools.context() } }
                    }
                case .event(.toolCall(let call)):
                    token()
                    let use = ToolArgumentCoercer.rawToolUse(id: call.id.isEmpty ? nextCallID(turn) : call.id, name: call.name, arguments: call.arguments)
                    let record = try await perform(use, turn: turn, tools: tools, context: context, grounding: grounding, progress: &progress, output: output)
                    records.append(record)
                    if progress.changedDocument { context = await tools.context() }
                case .event(.rejectedToolCall(let raw)):
                    token()
                    // The engine could not read it; the filter may. Anything else is an invalid call.
                    var reader = LocalOutputFilter()
                    let recovered = (reader.feed(raw) + reader.finish()).compactMap { piece -> (String, JSONValue)? in
                        if case .toolCall(let name, let arguments) = piece { return (name, arguments) }
                        return nil
                    }
                    if recovered.isEmpty {
                        records.append(invalidCall(raw, turn: turn))
                    } else {
                        for (name, arguments) in recovered {
                            let use = ToolArgumentCoercer.rawToolUse(id: nextCallID(turn), name: name, arguments: arguments)
                            let record = try await perform(use, turn: turn, tools: tools, context: context, grounding: grounding, progress: &progress, output: output)
                            records.append(record)
                            if progress.changedDocument { context = await tools.context() }
                        }
                    }
                case .event(.finished(let stats, let reason)):
                    progress.promptTokens += stats.promptTokens
                    if progress.rounds == 1 { progress.cachedTokens = stats.cachedTokens }
                    progress.generatedTokens += stats.generatedTokens
                    if stats.tokensPerSecond.isFinite, stats.tokensPerSecond > 0 { progress.tokensPerSecond = stats.tokensPerSecond }
                    if progress.rounds == 1, stats.firstTokenMs > 0 { progress.firstTokenMs = stats.firstTokenMs }
                    progress.stop = reason
                }
            }
        } catch LiveBrainError.modelNotReady where progress.rounds == 1 && !gotToken && records.isEmpty && progress.spoken.isEmpty {
            // The engine was closed before it said anything (the weights were unloaded): `run` reopens one.
            throw EngineClosedBeforeOutput()
        }
        try Task.checkCancellation()
        for piece in filter.finish() {
            try await take(piece, turn: turn, tools: tools, context: context, grounding: grounding, progress: &progress, records: &records, output: output)
        }
        return records
    }

    private func take(_ piece: LocalOutputFilter.Piece, turn: LiveUserTurn, tools: any LiveToolHandler, context: IntentContext,
                      grounding: ToolInputValidator.Grounding, progress: inout Progress, records: inout [CallRecord], output: Output) async throws {
        switch piece {
        case .speech(let text):
            guard let speakable = Self.speakable(text) else {
                if !text.isEmpty { note("model.markup_dropped", ["turn": String(turn.id), "chars": String(text.count)]) }
                return
            }
            output.yield(.text(speakable))
            progress.spoken += speakable
            progress.owesOutcome = false
        case .toolCall(let name, let arguments):
            let use = ToolArgumentCoercer.rawToolUse(id: nextCallID(turn), name: name, arguments: arguments)
            let record = try await perform(use, turn: turn, tools: tools, context: context, grounding: grounding, progress: &progress, output: output)
            records.append(record)
        case .malformed(let raw):
            records.append(invalidCall(raw, turn: turn))
        }
    }

    /// Validates a call, runs it on the editor, and says what the model must hear back. A step identical
    /// to one that failed this turn is not run again (D12): it comes back `blocked[repeat]`, and a call
    /// made only of repeats does not count toward `maxApplyEdits`.
    private func perform(_ use: RawToolUse, turn: LiveUserTurn, tools: any LiveToolHandler, context: IntentContext,
                         grounding: ToolInputValidator.Grounding, progress: inout Progress, output: Output) async throws -> CallRecord {
        try Task.checkCancellation()
        let name = LiveToolName(rawValue: use.name)
        let validation = ToolInputValidator(mode: mode).validate(use, context: context, grounding: grounding)
        if name == .applyEdits, case .success(let call) = validation, case .applyEdits(let intents) = call.tool, !intents.isEmpty,
           intents.allSatisfy({ progress.failedSteps[StepSignature($0)] != nil }) {
            // Nothing new in it: answered without the editor, and without counting.
            let execution = blockedExecution(intents, progress: progress, version: turn.editorState.version, canUndo: context.canUndo)
            let result = ToolResultEncoder.applyEdits(execution)
            progress.lastExecution = execution
            progress.owesOutcome = true
            logTool(turn, name: .applyEdits, execution: execution, needsReply: true, progress: &progress)
            return CallRecord(id: call.id, name: LiveToolName.applyEdits.rawValue, result: result, needsReply: true, invalid: false, wantsRepair: true)
        }
        if name == .applyEdits, progress.applyEdits >= limits.maxApplyEdits {
            progress.loopLimited = true
            return CallRecord(id: use.id, name: use.name, result: ToolResultEncoder.loopLimit(), needsReply: false, invalid: false)
        }
        if name == .proposeIdeas, turn.kind == .sessionStart, thermalSerious {
            // A hot phone: no ideas at session start.
            let skipped = LiveToolResult(isError: false, payload: ["ok": false, "message": "Not now."], changedDocument: false)
            return CallRecord(id: use.id, name: use.name, result: skipped, needsReply: false, invalid: false)
        }
        switch validation {
        case .failure(let error):
            if case .problems(let problems) = error,
               let refused = subjectRefusal(use, problems: problems, turn: turn, context: context, grounding: grounding, progress: &progress) {
                return refused
            }
            note("model.invalid_call", ["turn": String(turn.id), "tool": String(use.name.prefix(40))])
            return CallRecord(id: use.id, name: use.name, result: ToolResultEncoder.invalid(error), needsReply: true, invalid: true)
        case .success(let call):
            guard let name else { return CallRecord(id: use.id, name: use.name, result: ToolResultEncoder.invalid(.unknownTool(use.name)), needsReply: true, invalid: true) }
            if name == .applyEdits { progress.applyEdits += 1 }
            output.yield(.toolStarted(id: call.id, name: name, activity: LiveActivityTitles.title(for: call.tool, language: turn.language)))
            var result: LiveToolResult
            var intents: [EditIntent] = []
            if case .applyEdits(let all) = call.tool {
                intents = all
                result = await runSkippingRepeats(call, intents: all, tools: tools, progress: progress, canUndo: context.canUndo)
            } else {
                result = await tools.perform(call)
            }
            output.yield(.toolFinished(id: call.id, name: name, result: result))
            if case .proposeIdeas(let ideas) = call.tool, !ideas.isEmpty { output.yield(.ideas(ideas)) }
            let steps = result.execution?.steps ?? []
            // Remember what failed, so the same step is not run again this turn.
            for step in steps where Self.countsAsFailure(step) && step.status != .blocked && intents.indices.contains(step.index) {
                progress.failedSteps[StepSignature(intents[step.index])] = step
            }
            let verifyFailed = steps.contains { $0.status == .applied && $0.verification?.status == .failed }
            let needsReply = result.isError || verifyFailed
                || steps.contains { [.failed, .needsUser, .needsClarification, .blocked].contains($0.status) || ($0.status == .info && $0.reason != nil) }
            let wantsRepair = verifyFailed || steps.contains { $0.status == .blocked || ($0.status != .applied && $0.status != .skipped && $0.reason != nil) }
            if let execution = result.execution {
                progress.lastExecution = execution
                progress.owesOutcome = needsReply && execution.steps.contains { $0.status != .applied || $0.verification?.status == .failed }
            }
            if name == .applyEdits, result.changedDocument {
                progress.changedDocument = true
                // The recap keeps what ran with its arguments, so a follow-up after a compaction still resolves.
                remember(edits: steps.filter { $0.status == .applied }.compactMap { step in
                    guard let label = step.label else { return nil }
                    guard intents.indices.contains(step.index) else { return label }
                    return label + " [" + LiveSceneLines.step(of: RawIntentStep(intent: intents[step.index]), limit: 4) + "]"
                })
                if !needsReply { progress.cleanEdit = true }
            }
            if name == .undo, result.changedDocument, !needsReply { remember(edits: ["undo"]) }
            if let execution = result.execution {
                logTool(turn, name: name, execution: execution, needsReply: needsReply, progress: &progress)
            } else {
                note("model.tool", ["turn": String(turn.id), "tool": name.rawValue, "reply": needsReply ? "1" : "0"])
            }
            return CallRecord(id: call.id, name: name.rawValue, result: result, needsReply: needsReply, invalid: false, wantsRepair: wantsRepair)
        }
    }

    /// A subject step (textBehind, a background swap…) on a picture the validator knows has no subject (a
    /// table screenshot): answered as the failure it would be, `failed[no_subject]` with its hint, without
    /// reaching the editor. So the model gets a code and a way out rather than "invalid input", the repair
    /// round follows the hint, and a model that insists gets `blocked[repeat]` (D12, A4).
    private func subjectRefusal(_ use: RawToolUse, problems: [String], turn: LiveUserTurn, context: IntentContext,
                                grounding: ToolInputValidator.Grounding, progress: inout Progress) -> CallRecord? {
        let refusals = [ToolHints.noSubjectProblem, ToolHints.noSubjectScreenshotProblem]
        guard use.name == LiveToolName.applyEdits.rawValue, !problems.isEmpty,
              problems.allSatisfy({ problem in refusals.contains { problem.hasSuffix($0) } }) else { return nil }
        // The same call read without what the editor knows of the picture: the steps as the model meant them.
        var bare = context
        bare.table = nil
        bare.scene = nil
        guard case .success(let call) = ToolInputValidator(mode: mode).validate(use, context: bare, grounding: grounding),
              case .applyEdits(let intents) = call.tool, !intents.isEmpty else { return nil }
        let hasTable = context.table != nil
        let steps = intents.enumerated().map { index, intent -> LiveStepResult in
            if progress.failedSteps[StepSignature(intent)] != nil { return blocked(intent, index: index, progress: progress) }
            let background = intent.target.map { ["background", "arriere plan", "fond"].contains($0.label.normalizedForMatching) } ?? false
            guard ToolHints.subjectActions.contains(intent.action) || background else {
                return LiveStepResult(index: index, action: intent.action, status: .skipped)
            }
            return LiveStepResult(index: index, action: intent.action, status: .failed, message: nil, reason: .noSubject,
                                  hint: ToolHints.hint(for: .noSubject, action: intent.action, hasTable: hasTable))
        }
        for step in steps where step.status == .failed { progress.failedSteps[StepSignature(intents[step.index])] = step }
        var execution = LiveExecution(steps: steps, version: progress.lastExecution?.version ?? turn.editorState.version, canUndo: context.canUndo)
        execution.pictureIsTable = context.table?.coversPicture == true
        progress.lastExecution = execution
        progress.owesOutcome = true
        logTool(turn, name: .applyEdits, execution: execution, needsReply: true, progress: &progress)
        return CallRecord(id: call.id, name: LiveToolName.applyEdits.rawValue, result: ToolResultEncoder.applyEdits(execution), needsReply: true, invalid: false,
                          wantsRepair: true)
    }

    /// Runs the steps that did not fail yet; the repeats come back blocked, in their places.
    private func runSkippingRepeats(_ call: LiveToolCall, intents: [EditIntent], tools: any LiveToolHandler, progress: Progress, canUndo: Bool) async -> LiveToolResult {
        let repeats = Set(intents.indices.filter { progress.failedSteps[StepSignature(intents[$0])] != nil })
        guard !repeats.isEmpty else { return await tools.perform(call) }
        let fresh = intents.indices.filter { !repeats.contains($0) }
        let ran = await tools.perform(LiveToolCall(id: call.id, tool: .applyEdits(fresh.map { intents[$0] })))
        guard let execution = ran.execution else { return ran }
        var steps: [LiveStepResult] = []
        for index in intents.indices {
            if repeats.contains(index) {
                steps.append(blocked(intents[index], index: index, progress: progress))
            } else if let position = fresh.firstIndex(of: index), let step = execution.steps.first(where: { $0.index == position }) {
                var moved = step
                moved.index = index
                steps.append(moved)
            }
        }
        var merged = execution
        merged.steps = steps
        return ToolResultEncoder.applyEdits(merged)
    }

    private func blockedExecution(_ intents: [EditIntent], progress: Progress, version: Int, canUndo: Bool) -> LiveExecution {
        var execution = LiveExecution(steps: intents.indices.map { blocked(intents[$0], index: $0, progress: progress) },
                                      version: progress.lastExecution?.version ?? version, canUndo: progress.lastExecution?.canUndo ?? canUndo)
        execution.pictureIsTable = progress.lastExecution?.pictureIsTable ?? false
        return execution
    }

    /// A repeat, answered with what the first try said (its reason and words), so the spoken line stays right.
    private func blocked(_ intent: EditIntent, index: Int, progress: Progress) -> LiveStepResult {
        let first = progress.failedSteps[StepSignature(intent)]
        return LiveStepResult(index: index, action: intent.action, status: .blocked, message: first?.message, reason: first?.reason, hint: first?.hint)
    }

    /// Failed, or a needs-user / info step with a code: not worth running again this turn.
    static func countsAsFailure(_ step: LiveStepResult) -> Bool {
        switch step.status {
        case .failed, .blocked: return true
        case .needsUser, .info: return step.reason != nil
        default: return false
        }
    }

    /// `model.tool` with the step actions and reason codes (RC12), never the words.
    private func logTool(_ turn: LiveUserTurn, name: LiveToolName, execution: LiveExecution, needsReply: Bool, progress: inout Progress) {
        let actions = execution.steps.map(\.action.rawValue)
        let reasons = execution.steps.compactMap { step -> String? in
            if step.status == .blocked { return "repeat" }
            return step.status == .applied ? nil : step.reason?.rawValue
        }
        progress.loggedActions += actions
        var fields = ["turn": String(turn.id), "tool": name.rawValue, "reply": needsReply ? "1" : "0",
                      "actions": String(actions.joined(separator: ",").prefix(120))]
        if !reasons.isEmpty { fields["reasons"] = String(reasons.joined(separator: ",").prefix(80)) }
        let checks = execution.verifications
        if !checks.isEmpty { fields["verify"] = checks.map(\.status.rawValue).joined(separator: ",") }
        note("model.tool", fields)
    }

    private func invalidCall(_ raw: String, turn: LiveUserTurn) -> CallRecord {
        note("model.invalid_call", ["turn": String(turn.id), "chars": String(raw.count)])
        let result = ToolResultEncoder.invalid(.invalidJSON(raw: String(raw.prefix(300))))
        return CallRecord(id: nextCallID(turn), name: Self.functionName(in: raw) ?? "apply_edits", result: result, needsReply: true, invalid: true)
    }

    /// The same turn, answered by the rules-only grammar.
    private func forward(_ turn: LiveUserTurn, to fallback: any LiveBrain, tools: any LiveToolHandler, progress: Progress, output: Output) async throws {
        note("model.fallback", ["turn": String(turn.id), "rounds": String(progress.rounds)])
        output.yield(.stats(stats(progress)))
        var completed = false
        for try await event in fallback.respond(to: turn, tools: tools) {
            try Task.checkCancellation()
            switch event {
            case .started:
                continue
            case .completed:
                completed = true
                output.yield(event)
            default:
                output.yield(event)
            }
        }
        if !completed { output.yield(.completed(.answered)) }
    }

    private func finish(_ turn: LiveUserTurn, _ end: LiveTurnEnd, progress: Progress, output: Output) {
        var spoken = progress.spoken
        let silent = spoken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if silent || progress.owesOutcome {
            // Never a silent turn, and never a failure left unsaid: the reason-aware line (LiveLines), never
            // the executor's raw text, always through the sanitizer.
            let outcome = progress.lastExecution?.outcomeText(language: turn.language) ?? ""
            let line = LiveSpeechSanitizer.clean(outcome, language: turn.language)
            let fill = line.isEmpty && end == .loopLimit && silent ? LiveLines.line(.lostThread, turn.language) : line
            if !fill.isEmpty {
                let piece = silent || spoken.last?.isWhitespace == true ? fill : " " + fill
                output.yield(.text(piece))
                spoken += piece
            }
        }
        output.yield(.stats(stats(progress)))
        output.yield(.completed(end))
        // Warm only once reuse was seen: a turn that prefilled everything says nothing of the next one.
        cacheIsCold = progress.cachedTokens == 0
        remember(turn, said: spoken, looked: progress.looked)
    }

    private func stats(_ progress: Progress) -> LiveGenerationStats {
        LiveGenerationStats(model: info.displayName, promptTokens: progress.promptTokens, cachedTokens: progress.cachedTokens,
                            generatedTokens: progress.generatedTokens, firstTokenMs: progress.firstTokenMs ?? 0, tokensPerSecond: progress.tokensPerSecond)
    }

    // MARK: - Engine

    private func currentEngine() async throws -> any LocalChatEngine {
        if let engine { return engine }
        return try await openEngine(recap: nil)
    }

    /// A fresh conversation: the system prompt, the tool specs, the few-shot
    /// examples as real history, then the recap after a compaction.
    private func openEngine(recap: String?) async throws -> any LocalChatEngine {
        var history = Self.exampleHistory(mode: mode, size: info.promptSize)
        if let recap {
            history.append(.user(recap, imageJPEG: nil))
            history.append(.assistant(Self.recapAcknowledgement(recap), toolCalls: []))
        }
        let setup = LocalChatSetup(system: LocalLivePrompt.system(mode: mode, size: info.promptSize), tools: LocalLivePrompt.toolSpecs(mode: mode),
                                   history: history, imageMaxPixels: LocalModelCatalog.imageMaxPixels)
        let made: any LocalChatEngine
        do {
            made = try await makeEngine(setup)
            try await made.prepare()
        } catch let error as LiveBrainError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw LiveBrainError.modelUnavailable("engine: \(Self.errorName(error))")
        }
        engine = made
        cacheIsCold = true
        note("model.engine", ["history": String(history.count), "recap": recap == nil ? "0" : "1"])
        return made
    }

    /// Closes the conversation and starts one from the examples and a recap.
    private func compact(reason: String) async throws -> any LocalChatEngine {
        let old = engine
        engine = nil
        let tokens = await old?.contextTokens() ?? 0
        await old?.close()
        let recap = LocalLivePrompt.recap(LocalRecapInput(appliedEdits: Array(recapEdits.suffix(10)), lastExchanges: Array(recapExchanges.suffix(3)),
                                                          openQuestion: openQuestion, lastLook: lastLookNote))
        // Owed results belong to the closed conversation; the recap carries the edits.
        owedResults = []
        imagesInContext = 0
        lastSentState = nil
        note("model.compacted", ["reason": reason, "tokens": String(tokens)])
        return try await openEngine(recap: recap)
    }

    /// Closes the engine; the next turn starts a new conversation with the whole editor state.
    private func dropEngine() async {
        let old = engine
        engine = nil
        lastSentState = nil
        lastLook = nil
        lastImageAspect = nil
        imagesInContext = 0
        owedResults = []
        await old?.close()
    }

    private func clearConversation() {
        lastSentState = nil
        lastLook = nil
        lastImageAspect = nil
        imagesInContext = 0
        owedResults = []
        heardBeforeInterruption = nil
        recapEdits = []
        recapExchanges = []
        openQuestion = nil
        lastLookNote = nil
    }

    // MARK: - Memory for the recap

    private func remember(edits: [String]) {
        recapEdits.append(contentsOf: edits)
        if recapEdits.count > 20 { recapEdits.removeFirst(recapEdits.count - 20) }
    }

    private func remember(_ turn: LiveUserTurn, said: String, looked: Bool) {
        let reply = said.trimmingCharacters(in: .whitespacesAndNewlines)
        let words = turn.kind == .sessionStart ? "(session start)" : String(turn.text.prefix(100))
        recapExchanges.append("\(words) → \(reply.prefix(120))")
        if recapExchanges.count > 6 { recapExchanges.removeFirst(recapExchanges.count - 6) }
        openQuestion = turn.editorState.pendingQuestion ?? (reply.hasSuffix("?") ? String(reply.suffix(160)) : nil)
        if looked, !reply.isEmpty {
            lastLookNote = String(reply.prefix(200))
        }
    }

    // MARK: - Turn gate

    private func acquire() async {
        guard busy else {
            busy = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        if waiters.isEmpty {
            busy = false
        } else {
            waiters.removeFirst().resume()
        }
    }

    // MARK: - Helpers

    private func deservesLook(_ turn: LiveUserTurn, image: LiveImage) -> Bool {
        if let lastLook, lastLook.version == image.version, lastLook.frame == image.frameKey { return false }
        let since = lastLook.map { max(0, image.version - $0.version) } ?? Int.max / 2
        return LocalLivePrompt.needsFreshLook(turn, versionsSinceLastLook: since)
    }

    private func nextCallID(_ turn: LiveUserTurn) -> String {
        callCounter += 1
        return "call_\(turn.id)_\(callCounter)"
    }

    private func note(_ event: String, _ fields: [String: String] = [:]) {
        guard let log else { return }
        var fields = fields
        fields["model"] = info.id
        log(LiveLogEntry(time: clock.now(), event: event, fields: fields))
    }

    /// The few-shot examples as the conversation's first exchanges (also the
    /// self-test's probe history). Additive to the contract (phase 1).
    public static func exampleHistory(mode: EditorMode, size: LocalPromptSize) -> [LocalChatMessage] {
        var history: [LocalChatMessage] = []
        for (index, example) in LocalLivePrompt.examples(mode: mode, size: size).enumerated() {
            history.append(.user(example.user, imageJPEG: nil))
            guard let tool = example.toolName else {
                history.append(.assistant(example.assistant, toolCalls: []))
                continue
            }
            let id = "example_\(index + 1)"
            history.append(.assistant(example.assistant, toolCalls: [LocalToolCall(id: id, name: tool.rawValue, arguments: example.arguments ?? [:])]))
            if let result = example.toolResult {
                history.append(.toolResult(callID: id, name: tool.rawValue, content: result))
                if let repair = example.repair {
                    // The one repair round after a failed check: a second call, its result, then the closing line.
                    let repairID = id + "_repair"
                    history.append(.assistant(repair.assistant, toolCalls: [LocalToolCall(id: repairID, name: repair.toolName.rawValue, arguments: repair.arguments)]))
                    history.append(.toolResult(callID: repairID, name: repair.toolName.rawValue, content: repair.toolResult))
                }
                if let after = example.afterResult { history.append(.assistant(after, toolCalls: [])) }
            }
        }
        return history
    }

    /// Wants the ideas budget: the session start and requests for an opinion or ideas.
    static func expectsIdeas(_ turn: LiveUserTurn) -> Bool {
        if turn.kind == .sessionStart { return true }
        let words = turn.text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        return ["idee", "avis", "penses", "pense quoi", "suggere", "propose", "inspire", "idea", "opinion", "think", "suggest"].contains { words.contains($0) }
    }

    static func hotSessionStartLine(_ language: NormalizedUtterance.Language) -> String {
        language == .french ? "Pas d'idées pour l'instant : une seule phrase." : "No ideas this time: one sentence only."
    }

    static func recapAcknowledgement(_ recap: String) -> String {
        NormalizedUtterance(recap).language == .english ? "OK." : "D'accord."
    }

    /// Speech never carries markup: a piece with a tag character is dropped whole.
    static func speakable(_ text: String) -> String? {
        guard !text.isEmpty, !text.contains("<"), !text.contains(">") else { return nil }
        return text
    }

    /// "<function=undo>" → "undo".
    static func functionName(in raw: String) -> String? {
        guard let start = raw.range(of: "<function=") else { return nil }
        let rest = raw[start.upperBound...]
        let name = rest.prefix { $0.isLetter || $0 == "_" }
        return LiveToolName(rawValue: String(name))?.rawValue
    }

    static func aspect(_ size: PSSize) -> Double? {
        size.height > 0 ? Double(size.width) / Double(size.height) : nil
    }

    static func errorName(_ error: Error) -> String {
        if let error = error as? LiveBrainError { return BrainSelector.errorName(error) }
        return String(String(describing: type(of: error)).prefix(40))
    }

    // MARK: - Deadlines

    enum Tick: Sendable {
        case event(LocalChatEvent)
        case firstTokenMissed
        case turnDeadline
    }

    /// The engine's events, with the first-token and turn deadlines woven in.
    /// Ending the returned stream ends the engine's (and so its generation).
    static func watched(_ source: AsyncThrowingStream<LocalChatEvent, Error>, clock: any LiveClock, firstToken: Double,
                        turn: Double) -> AsyncThrowingStream<Tick, Error> {
        let (stream, continuation) = AsyncThrowingStream<Tick, Error>.makeStream()
        let pump = Task {
            do {
                for try await event in source { continuation.yield(.event(event)) }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        let firstTokenTimer = Task {
            try? await clock.sleep(seconds: firstToken)
            if !Task.isCancelled { continuation.yield(.firstTokenMissed) }
        }
        let turnTimer = Task {
            try? await clock.sleep(seconds: turn)
            if !Task.isCancelled { continuation.yield(.turnDeadline) }
        }
        continuation.onTermination = { _ in
            pump.cancel()
            firstTokenTimer.cancel()
            turnTimer.cancel()
        }
        return stream
    }
}
