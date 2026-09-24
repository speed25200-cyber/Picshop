import Foundation
import PicshopCore

/// Claude over raw HTTPS + SSE: the streaming tool loop of one Live session.
///
/// Per turn: a checkpoint, then the user message ([open tool results, image
/// when the policy wants one, the words, media text]) and a role:system
/// message with the editor state. Then up to 6 requests and 3 apply_edits
/// calls. Tools run only after message_delta confirms stop_reason tool_use,
/// only from blocks after the last fallback block, and only once validated.
public actor ClaudeLiveBrain: LiveBrain {
    /// .claude
    public nonisolated let kind: LiveBrainKind
    private let mode: EditorMode
    private let apiKey: String
    private let transport: any ClaudeTransport
    private var options: ClaudeRequestOptions
    private let clock: any LiveClock
    private let log: (@Sendable (LiveLogEntry) -> Void)?
    private var lastRequestAt: Double?
    private let system: String
    private let toolDefinitions: [ClaudeToolDefinition]
    private let validator: ToolInputValidator
    private var conversation = LiveConversation()
    private var current: Task<Void, Never>?
    private var record: TurnRecord?
    private var warmingUp = false

    static let maxRequests = 6
    static let maxApplyEdits = 3
    static let retryMaxTokens = 4096
    /// Watchdogs, from the moment a request is sent.
    var firstByteTimeout = 5.0
    var firstOutputTimeout = 8.0
    var overloadRetryDelay = 0.3

    /// Where the running turn stands, so an interruption or an error can repair the history.
    private struct TurnRecord {
        enum Phase { case streaming, executing }
        enum Outcome { case running, answered, editApplied, refused, rolledBack, repaired }
        let id: Int
        let turn: LiveUserTurn
        var checkpoint: LiveConversation.Checkpoint
        var phase: Phase = .streaming
        var outcome: Outcome = .running
        /// Text or a tool reached the user.
        var produced = false
        /// Text yielded by the request in flight.
        var streamedText = ""
        /// Results of the in-flight response's calls that ran.
        var executed: [ClaudeContentBlock] = []
        var anyToolRan = false
        var appliedLabels: [String] = []
        var geometryChanged = false
        var version: Int
        var imageVersion: Int?
    }

    public init(mode: EditorMode, apiKey: String, transport: any ClaudeTransport, options: ClaudeRequestOptions = .init(),
                clock: any LiveClock = SystemLiveClock(), log: (@Sendable (LiveLogEntry) -> Void)? = nil) {
        kind = .claude
        self.mode = mode
        self.apiKey = apiKey
        self.transport = transport
        self.options = options
        self.clock = clock
        self.log = log
        system = LivePrompt.system(mode: mode)
        toolDefinitions = LiveToolSchema.tools(for: mode)
        validator = ToolInputValidator(mode: mode)
    }

    public var secondsSinceLastRequest: Double? {
        guard let lastRequestAt else { return nil }
        return clock.now() - lastRequestAt
    }

    /// Whether the conversation would attach a picture of this version to the next turn
    /// (lets the session skip the snapshot). Additive to contract 6.4.
    public func wantsImage(version: Int, frameKey: String?, kind: LiveUserTurn.Kind) -> Bool {
        conversation.images.wants(version: version, frameKey: frameKey, kind: kind, firstTurnOfEpoch: conversation.isFirstTurnOfEpoch)
    }

    /// The conversation as it stands, for diagnostics and tests.
    public var history: LiveConversation { conversation }

    public func isAvailable() async -> Bool {
        !apiKey.isEmpty
    }

    /// Writes the tools + system cache entry and opens the connection. Errors are ignored.
    public func warmUp() async {
        guard !warmingUp, !apiKey.isEmpty else { return }
        warmingUp = true
        defer { warmingUp = false }
        let request = ClaudeRequestBuilder(options: options).warmUpRequest(apiKey: apiKey, system: system, tools: toolDefinitions)
        let started = clock.now()
        let status = (try? await transport.send(request))?.status
        report("warmup", ["status": status.map(String.init) ?? "error", "ms": milliseconds(since: started), "bytes": "\(request.body?.count ?? 0)"])
    }

    public nonisolated func respond(to turn: LiveUserTurn, tools: any LiveToolHandler) -> AsyncThrowingStream<LiveBrainEvent, Error> {
        let (stream, continuation) = AsyncThrowingStream<LiveBrainEvent, Error>.makeStream()
        let driver = Task { await self.start(turn, handler: tools, output: continuation) }
        continuation.onTermination = { _ in driver.cancel() }
        return stream
    }

    public func interrupt(turn: Int, spokenText: String) async {
        if let current {
            current.cancel()
            await current.value
        }
        guard let record, record.id == turn else { return }
        repair(spoken: spokenText, force: true)
    }

    public func reset() async {
        if let current {
            current.cancel()
            await current.value
        }
        conversation = LiveConversation()
        record = nil
    }

    // MARK: The turn

    private func start(_ turn: LiveUserTurn, handler: any LiveToolHandler, output: AsyncThrowingStream<LiveBrainEvent, Error>.Continuation) async {
        if let previous = current { await previous.value }
        // A turn cancelled without interrupt(turn:spokenText:) is repaired as if nothing was heard.
        repair(spoken: "", force: false)
        let work = Task { await self.run(turn, handler: handler, output: output) }
        current = work
        await withTaskCancellationHandler {
            await work.value
        } onCancel: {
            work.cancel()
        }
    }

    private func run(_ turn: LiveUserTurn, handler: any LiveToolHandler, output: AsyncThrowingStream<LiveBrainEvent, Error>.Continuation) async {
        do {
            try await loop(turn, handler: handler, output: output)
            output.finish()
        } catch is CancellationError {
            output.finish()
        } catch {
            let mapped = Self.brainError(error)
            report("turn_failed", ["error": "\(mapped)"])
            repairAfterFailure()
            output.finish(throwing: mapped)
        }
    }

    private func loop(_ turn: LiveUserTurn, handler: any LiveToolHandler, output: AsyncThrowingStream<LiveBrainEvent, Error>.Continuation) async throws {
        begin(turn, compactFirst: false)
        var requests = 0
        var applyEditsCalls = 0
        var finalRound = false
        var maxTokensRetried = false
        var maxTokens = options.maxTokens
        var swallow = 0
        var announcedModel = false

        while true {
            try Task.checkCancellation()
            record?.phase = .streaming
            record?.streamedText = ""
            record?.executed = []
            let response = try await send(maxTokens: maxTokens, swallow: swallow, handler: handler, output: output, announce: !announcedModel)
            announcedModel = true
            requests += 1
            swallow = 0
            let acc = response.accumulator
            output.yield(.usage(acc.usage))
            let language = turn.language

            switch acc.stopReason {
            case .refusal?:
                // No tools from a refused response. Nothing ran yet: as if the turn never happened.
                let category = acc.stopDetails?["category"]?.string
                if record?.anyToolRan == true {
                    conversation.closeTurn(with: LiveLines.line(.refusal, language))
                    record?.outcome = .refused
                } else {
                    rollback()
                }
                output.yield(.completed(.refused(category: category)))
                return

            case .maxTokens? where acc.hasToolUse:
                // A tool input cut off by max_tokens is never run.
                if !maxTokensRetried {
                    maxTokensRetried = true
                    maxTokens = max(options.maxTokens, Self.retryMaxTokens)
                    swallow = response.textYielded.count
                    continue
                }
                conversation.appendAssistant([.text(acc.text.isEmpty ? "..." : acc.text)])
                record?.outcome = .answered
                output.yield(.completed(.maxTokens))
                return

            case .toolUse? where !acc.executableToolUses().isEmpty:
                conversation.appendAssistant(acc.content())
                record?.phase = .executing
                var results: [ClaudeContentBlock] = []
                var quiet = acc.hasTextBeforeFirstToolUse && !finalRound
                var changed = false
                var hitLimit = false
                for use in acc.executableToolUses() {
                    let name = LiveToolName(rawValue: use.name)
                    var result: LiveToolResult
                    if finalRound || requests >= Self.maxRequests || (name == .applyEdits && applyEditsCalls >= Self.maxApplyEdits) {
                        result = ToolResultEncoder.loopLimit()
                        hitLimit = true
                    } else {
                        let checked: Result<LiveToolCall, ToolValidationError>
                        if let early = response.validated[use.id] { checked = early } else { checked = await validate(use, handler: handler) }
                        switch checked {
                        case .success(let call):
                            if name == .applyEdits { applyEditsCalls += 1 }
                            record?.produced = true
                            record?.anyToolRan = true
                            let toolName = name ?? .applyEdits
                            output.yield(.toolStarted(id: use.id, name: toolName, activity: LiveActivityTitles.title(for: call.tool, language: language)))
                            result = await handler.perform(call)
                            output.yield(.toolFinished(id: use.id, name: toolName, result: result))
                            if case .proposeIdeas(let ideas) = call.tool { output.yield(.ideas(ideas.filter { !$0.steps.isEmpty })) }
                            note(call, result: result)
                            quiet = quiet && Self.spokeForItself(call, result: result)
                        case .failure(let error):
                            result = ToolResultEncoder.invalid(error)
                            quiet = false
                            report("tool_invalid", ["tool": use.name, "problems": "\(result.payload["problems"]?.array?.count ?? 1)"])
                        }
                    }
                    changed = changed || result.changedDocument
                    let block = ToolResultEncoder.block(result, toolUseID: use.id)
                    results.append(block)
                    record?.executed.append(block)
                    if Task.isCancelled { throw CancellationError() }
                }
                record?.phase = .streaming
                record?.executed = []
                if hitLimit && (finalRound || requests >= Self.maxRequests) {
                    conversation.deferToolResults(results)
                    record?.outcome = .answered
                    output.yield(.completed(.loopLimit))
                    return
                }
                if quiet && !hitLimit {
                    // The edit spoke for itself: no follow-up request; the results lead the next user message.
                    conversation.deferToolResults(results)
                    record?.outcome = .editApplied
                    output.yield(.completed(.editApplied))
                    return
                }
                finalRound = hitLimit
                conversation.appendToolResults(results, systemText: changed ? freshState() : nil)

            default:
                conversation.appendAssistant(acc.content())
                record?.outcome = .answered
                output.yield(.completed(acc.stopReason == .maxTokens ? .maxTokens : .answered))
                return
            }
        }
    }

    /// Checkpoint, compaction when due, then the user message and its context.
    private func begin(_ turn: LiveUserTurn, compactFirst: Bool) {
        let image = turn.image
        let wantsImage = image.map { conversation.images.wants(version: $0.version, frameKey: $0.frameKey, kind: turn.kind, firstTurnOfEpoch: conversation.isFirstTurnOfEpoch) } ?? false
        if compactFirst || (!conversation.messages.isEmpty && (conversation.needsCompaction || (wantsImage && conversation.images.epochIsFull))) {
            compact(for: turn)
        }
        let checkpoint = conversation.checkpoint()
        var blocks: [ClaudeContentBlock] = []
        var attachedVersion: Int?
        if let image, image.jpeg.count > 0,
           conversation.images.wants(version: image.version, frameKey: image.frameKey, kind: turn.kind, firstTurnOfEpoch: conversation.isFirstTurnOfEpoch) {
            blocks.append(.image(.base64(mediaType: "image/jpeg", data: image.jpeg.base64EncodedString())))
            conversation.images.noteAttached(version: image.version, frameKey: image.frameKey)
            conversation.noteImageAspect(image.pixelHeight > 0 ? Double(image.pixelWidth) / Double(image.pixelHeight) : nil)
            attachedVersion = image.version
        }
        let words = turn.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if turn.kind != .sessionStart, !words.isEmpty { blocks.append(.text(words)) }
        if let media = LivePrompt.mediaText(turn.editorState.mediaText) { blocks.append(.text(media)) }
        if blocks.isEmpty { blocks.append(.text(turn.kind == .sessionStart ? "(Live started)" : "(silence)")) }
        let lastSeen = attachedVersion == nil ? conversation.images.lastAttachedVersion : nil
        conversation.appendUserTurn(blocks: blocks, systemText: LivePrompt.turnContext(turn, imageVersion: attachedVersion, lastImageVersion: lastSeen))
        record = TurnRecord(id: turn.id, turn: turn, checkpoint: checkpoint, version: turn.editorState.version, imageVersion: attachedVersion)
    }

    private func compact(for turn: LiveUserTurn) {
        let summary = SessionSummary.build(applied: turn.editorState.appliedEdits, exchanges: conversation.exchanges, ideasOnScreen: turn.ideasOnScreen,
                                           openQuestion: turn.editorState.pendingQuestion)
        conversation.compact(summary: summary, image: nil)
        report("compacted", ["epoch": "\(conversation.epoch)"])
    }

    /// The state after tools changed the document: the version and the labels applied this turn.
    private func freshState() -> String? {
        guard let record else { return nil }
        var state = record.turn.editorState
        state.version = record.version
        state.appliedEdits = Array((state.appliedEdits + record.appliedLabels).suffix(12))
        state.adjustments = .neutral
        state.pendingQuestion = nil
        state.candidates = []
        return LivePrompt.editorState(state, lastImageVersion: conversation.images.lastAttachedVersion)
    }

    private func note(_ call: LiveToolCall, result: LiveToolResult) {
        if let execution = result.execution {
            record?.version = execution.version
            record?.appliedLabels += execution.steps.filter { $0.status == .applied }.compactMap(\.label)
            let geometric: Set<IntentAction> = [.crop, .setAspect, .rotate, .straighten, .flip, .resetOrientation, .expandCanvas, .autoCrop, .smartReframe]
            if execution.steps.contains(where: { $0.status == .applied && geometric.contains($0.action) }) { record?.geometryChanged = true }
        } else if let version = result.payload["version"]?.int {
            record?.version = version
            if result.changedDocument { record?.geometryChanged = true }
        }
    }

    /// apply_edits, undo and compare that fully worked need no comment from Claude.
    private static func spokeForItself(_ call: LiveToolCall, result: LiveToolResult) -> Bool {
        guard !result.isError else { return false }
        switch call.tool {
        case .applyEdits: return result.execution?.allApplied ?? false
        case .undo, .compare: return result.payload["ok"]?.bool == true
        case .proposeIdeas: return false
        }
    }

    private func validate(_ use: RawToolUse, handler: any LiveToolHandler) async -> Result<LiveToolCall, ToolValidationError> {
        let context = await handler.context()
        return validator.validate(use, context: context, grounding: grounding())
    }

    private func grounding() -> ToolInputValidator.Grounding {
        let canvas = record?.turn.editorState.canvasPixels.flatMap { $0.height > 0 ? $0.width / $0.height : nil }
        return ToolInputValidator.Grounding(imageAspect: conversation.lastImageAspect, canvasAspect: record?.geometryChanged == true ? nil : canvas)
    }

    // MARK: Requests

    private struct Streamed {
        var accumulator: MessageAccumulator
        var validated: [String: Result<LiveToolCall, ToolValidationError>]
        var textYielded: String
    }

    /// An `error` event in the stream, and whether output had already gone out.
    private struct StreamErrorEvent: Error {
        var type: String
        var message: String
        var afterOutput: Bool
    }

    /// One request with the retry policy: a 400 naming the fallback beta resends without it;
    /// 400 / 413 compact and resend once; 429 retries once within 2 s; 5xx and an early
    /// overloaded event retry once after 300 ms.
    private func send(maxTokens: Int, swallow: Int, handler: any LiveToolHandler, output: AsyncThrowingStream<LiveBrainEvent, Error>.Continuation,
                      announce: Bool) async throws -> Streamed {
        var retriedServer = false
        var retriedRateLimit = false
        var compacted = false
        while true {
            try Task.checkCancellation()
            if !conversation.invariantViolations().isEmpty {
                report("history_repaired", ["problems": "\(conversation.invariantViolations().count)"])
                rebuildTurn()
            }
            var requestOptions = options
            requestOptions.maxTokens = maxTokens
            let request = ClaudeRequestBuilder(options: requestOptions).streamingRequest(apiKey: apiKey, system: system, tools: toolDefinitions,
                                                                                        messages: conversation.messages)
            do {
                return try await stream(request, swallow: swallow, handler: handler, output: output, announce: announce)
            } catch let error as ClaudeAPIError {
                report("http_error", ["status": error.status.map(String.init) ?? "-", "type": error.type, "request_id": error.requestID ?? "-"])
                let early = record?.produced != true
                switch error.status ?? 0 {
                case 400 where options.useServerFallbacks && (error.message.contains("anthropic-beta") || error.message.contains("fallbacks")):
                    options.useServerFallbacks = false
                    continue
                case 400:
                    guard !compacted, early else { throw LiveBrainError.badRequest(requestID: error.requestID, message: error.message) }
                    compacted = true
                    rebuildTurn()
                    continue
                case 401: throw LiveBrainError.invalidKey
                case 402: throw LiveBrainError.noCredit
                case 403: throw LiveBrainError.forbidden
                case 404: throw LiveBrainError.modelUnavailable
                case 413:
                    guard !compacted, early else { throw LiveBrainError.requestTooLarge }
                    compacted = true
                    rebuildTurn()
                    continue
                case 429:
                    if !retriedRateLimit, let after = error.retryAfter, after <= 2 {
                        retriedRateLimit = true
                        try await clock.sleep(seconds: after)
                        continue
                    }
                    throw LiveBrainError.rateLimited(retryAfter: error.retryAfter)
                case let status where status >= 500:
                    if !retriedServer {
                        retriedServer = true
                        try await clock.sleep(seconds: overloadRetryDelay)
                        continue
                    }
                    throw status == 529 ? LiveBrainError.overloaded : LiveBrainError.server(status: status)
                case let status:
                    throw LiveBrainError.server(status: status)
                }
            } catch let event as StreamErrorEvent {
                report("stream_error", ["type": event.type])
                let retryable = event.type == "overloaded_error" || event.type == "api_error"
                if retryable, !event.afterOutput, record?.produced != true, !retriedServer {
                    retriedServer = true
                    try await clock.sleep(seconds: overloadRetryDelay)
                    continue
                }
                switch event.type {
                case "overloaded_error": throw LiveBrainError.overloaded
                case "api_error": throw LiveBrainError.server(status: 500)
                case "rate_limit_error": throw LiveBrainError.rateLimited(retryAfter: nil)
                case "request_too_large": throw LiveBrainError.requestTooLarge
                default: throw LiveBrainError.unavailable(event.type)
                }
            }
        }
    }

    /// Streams one request: parser, decoder, accumulator; validates each tool call at
    /// content_block_stop; yields text unless it was already said (`swallow` characters).
    private func stream(_ request: ClaudeHTTPRequest, swallow: Int, handler: any LiveToolHandler,
                        output: AsyncThrowingStream<LiveBrainEvent, Error>.Continuation, announce: Bool) async throws -> Streamed {
        let started = clock.now()
        lastRequestAt = started
        report("request", ["bytes": "\(request.body?.count ?? 0)", "image": request.carriesImage ? "1" : "0", "fallbacks": options.useServerFallbacks ? "1" : "0"])

        let progress = StreamProgress()
        let (relay, relayContinuation) = AsyncThrowingStream<Data, Error>.makeStream()
        let transport = self.transport
        let pump = Task {
            do {
                for try await chunk in transport.stream(request) { relayContinuation.yield(chunk) }
                relayContinuation.finish()
            } catch {
                relayContinuation.finish(throwing: error)
            }
        }
        let clock = self.clock
        let byteLimit = firstByteTimeout
        let outputLimit = firstOutputTimeout
        let watchdog = Task {
            do { try await clock.sleep(seconds: byteLimit) } catch { return }
            if !progress.gotByte {
                relayContinuation.finish(throwing: LiveBrainError.timeout(stage: "first_byte"))
                pump.cancel()
                return
            }
            do { try await clock.sleep(seconds: max(0, outputLimit - byteLimit)) } catch { return }
            if !progress.gotOutput {
                relayContinuation.finish(throwing: LiveBrainError.timeout(stage: "first_output"))
                pump.cancel()
            }
        }
        defer {
            pump.cancel()
            watchdog.cancel()
        }

        var parser = SSEParser()
        var state = StreamState(toSwallow: swallow)
        var firstByteAt: Double?
        for try await chunk in relay {
            if firstByteAt == nil { firstByteAt = clock.now() }
            progress.markByte()
            try await process(parser.feed(chunk), state: &state, handler: handler, output: output, announce: announce, progress: progress)
        }
        try Task.checkCancellation()
        try await process(parser.finish(), state: &state, handler: handler, output: output, announce: announce, progress: progress)
        let accumulator = state.accumulator
        guard accumulator.isComplete else { throw LiveBrainError.streamTruncated }

        let usage = accumulator.usage
        report("response", [
            "stop_reason": accumulator.stopReason?.raw ?? "-",
            "first_byte_ms": firstByteAt.map { milliseconds(from: started, to: $0) } ?? "-",
            "first_text_ms": state.firstTextAt.map { milliseconds(from: started, to: $0) } ?? "-",
            "input": "\(usage.inputTokens)", "output": "\(usage.outputTokens)",
            "cache_read": "\(usage.cacheReadInputTokens)", "cache_write": "\(usage.cacheCreationInputTokens)",
            "fallback": usage.servedByFallback || accumulator.lastFallbackIndex != nil ? "1" : "0",
            "model": accumulator.model ?? "-",
        ])
        return Streamed(accumulator: accumulator, validated: state.validated, textYielded: state.yielded)
    }

    /// What one request has produced so far.
    private struct StreamState {
        var accumulator = MessageAccumulator()
        var validated: [String: Result<LiveToolCall, ToolValidationError>] = [:]
        var toSwallow: Int
        var yielded = ""
        var firstTextAt: Double?
    }

    private func process(_ events: [SSEEvent], state: inout StreamState, handler: any LiveToolHandler,
                         output: AsyncThrowingStream<LiveBrainEvent, Error>.Continuation, announce: Bool, progress: StreamProgress) async throws {
        for event in events {
            let decoded: ClaudeStreamEvent?
            do {
                decoded = try ClaudeStreamEvent.decode(event)
            } catch {
                throw LiveBrainError.streamTruncated
            }
            guard let decoded else { continue }
            if case .error(let type, let message) = decoded {
                throw StreamErrorEvent(type: type, message: message, afterOutput: !state.yielded.isEmpty)
            }
            if case .messageStart(_, let model, _) = decoded, announce { output.yield(.started(model: model.isEmpty ? ClaudeRequestOptions.model : model)) }
            for out in state.accumulator.apply(decoded) {
                switch out {
                case .text(let delta):
                    progress.markOutput()
                    if state.firstTextAt == nil { state.firstTextAt = clock.now() }
                    var visible = Substring(delta)
                    if state.toSwallow > 0 {
                        let cut = min(state.toSwallow, visible.count)
                        visible = visible.dropFirst(cut)
                        state.toSwallow -= cut
                    }
                    guard !visible.isEmpty else { continue }
                    state.yielded += visible
                    record?.produced = true
                    record?.streamedText += visible
                    output.yield(.text(String(visible)))
                case .toolStarted:
                    progress.markOutput()
                case .toolFragment:
                    break
                case .toolCompleted(let use):
                    state.validated[use.id] = await validate(use, handler: handler)
                case .fallback(let from, let to):
                    report("fallback", ["from": from ?? "-", "to": to ?? "-"])
                    output.yield(.fallbackModel(from: from, to: to))
                }
            }
        }
    }

    // MARK: Repairs

    /// A 400, a 413 or broken history before any output: a fresh epoch, and the turn again.
    private func rebuildTurn() {
        guard let record else { return }
        conversation.rollback(to: record.checkpoint)
        begin(record.turn, compactFirst: true)
    }

    private func rollback() {
        guard let record else { return }
        conversation.rollback(to: record.checkpoint)
        self.record?.outcome = .rolledBack
    }

    /// After a cancellation: nothing reached the user -> as if the turn never happened;
    /// otherwise keep what ran and store exactly what was said.
    private func repair(spoken: String, force: Bool) {
        guard let current = record else { return }
        switch current.outcome {
        case .running:
            if !current.produced && !current.anyToolRan {
                rollback()
            } else if current.phase == .executing {
                conversation.recordInterruption(spoken: spoken, executedResults: current.executed)
            } else {
                conversation.recordInterruption(spoken: unsaid(spoken, since: current.checkpoint), executedResults: [])
            }
            record?.outcome = .repaired
        case .answered where force && !spoken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty:
            conversation.recordInterruption(spoken: spoken, executedResults: [])
            record?.outcome = .repaired
        default:
            break
        }
    }

    /// What was spoken minus what an earlier round of this turn already stored (the sentence before a tool).
    private func unsaid(_ spoken: String, since checkpoint: LiveConversation.Checkpoint) -> String {
        func flat(_ text: String) -> String { text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ") }
        let start = min(checkpoint.count, conversation.messages.count)
        let stored = flat(conversation.messages[start...].filter { $0.role == .assistant }.flatMap(\.content).compactMap(\.textValue).joined(separator: " "))
        let heard = flat(spoken)
        guard !stored.isEmpty, heard.hasPrefix(stored) else { return spoken }
        return String(heard.dropFirst(stored.count)).trimmingCharacters(in: .whitespaces)
    }

    private func repairAfterFailure() {
        guard let current = record, current.outcome == .running else { return }
        if !current.produced && !current.anyToolRan {
            rollback()
        } else {
            let executed = current.phase == .executing ? current.executed : []
            conversation.recordInterruption(spoken: current.streamedText, executedResults: executed)
            record?.outcome = .repaired
        }
    }

    // MARK: Helpers

    static func brainError(_ error: Error) -> LiveBrainError {
        if let known = error as? LiveBrainError { return known }
        if let api = error as? ClaudeAPIError { return .server(status: api.status ?? 0) }
        return .network(String(describing: type(of: error)))
    }

    private func report(_ event: String, _ fields: [String: String]) {
        log?(LiveLogEntry(time: clock.now(), event: event, fields: fields))
    }

    private func milliseconds(since start: Double) -> String {
        milliseconds(from: start, to: clock.now())
    }

    private func milliseconds(from start: Double, to end: Double) -> String {
        String(Int(((end - start) * 1000).rounded()))
    }
}

/// Byte and output flags shared between the stream and its watchdog.
private final class StreamProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var byte = false
    private var output = false

    var gotByte: Bool { lock.withLock { byte } }
    var gotOutput: Bool { lock.withLock { output } }

    func markByte() { lock.withLock { byte = true } }
    func markOutput() { lock.withLock { output = true } }
}
