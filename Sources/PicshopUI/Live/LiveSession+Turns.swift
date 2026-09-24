#if canImport(SwiftUI) && canImport(UIKit)
import Foundation
import PicshopCore
import PicshopIntent
import PicshopSpeech

/// The turn flow: lanes, brain turns and their events, errors and fallbacks, the
/// voice, ideas, chips, choices, undo, and the resting-mode command pipeline.
extension LiveSession {
    // MARK: Brains

    func brainFor(_ kind: LiveBrainKind) -> (any LiveBrain)? {
        switch kind {
        case .claude: return claudeBrain
        case .onDevice: return onDeviceAvailable ? onDeviceBrain : nil
        case .local: return localBrain
        }
    }

    /// Key, consent, the Claude toggle, and not turned off from the badge.
    var claudeAllowed: Bool {
        guard let app, claudeBrain != nil, !claudeForcedOff else { return false }
        return LiveServices.shared.keyStore.hasKey && app.settings.liveUseClaude && app.settings.hasLiveConsent
    }

    /// Per turn: Claude, then the on-device model, then the local router (BrainSelector keeps the cooldowns).
    func chooseBrain(excluding failed: Set<LiveBrainKind> = []) -> LiveBrainKind {
        let inputs = BrainSelector.Inputs(claudeAllowed: claudeAllowed && !failed.contains(.claude),
                                          online: LiveServices.shared.reachability.isOnline,
                                          onDeviceAvailable: onDeviceAvailable && onDeviceBrain != nil && !failed.contains(.onDevice),
                                          now: clock.now())
        let kind = selector.choose(inputs)
        if failed.contains(kind) || brainFor(kind) == nil { return .local }
        return kind
    }

    func badge(for kind: LiveBrainKind) -> LiveRoute.Brain {
        switch kind {
        case .claude: return .claude
        case .onDevice: return .onDevice
        case .local: return app.map(Self.localBadge) ?? .commands
        }
    }

    // MARK: Commit

    /// The reducer committed a user turn: pick the lane (control, local, brain) and run it.
    func commitTurn(_ id: Int, text: String) {
        let now = clock.now()
        flushCaption(force: true)
        let typed = pendingTypedText.map { !$0.isEmpty && text.hasSuffix($0) } ?? false
        pendingTypedText = nil
        var next = LiveTranscript()
        next.turnID = id
        next.user = LiveCaption(stable: text)
        next.userIsFinal = true
        assignTranscript(next)
        let speechEnd = typed ? now : min(lastVoicedAt ?? now, now)
        latency.mark(.speechEnd, at: speechEnd, turn: id)
        latency.mark(.committed, at: now, turn: id)
        let words = text.split(whereSeparator: { $0.isWhitespace }).count
        if typed { debugDecision("commit #\(id): typed, \(words) words") }

        let language = NormalizedUtterance(text).language
        replyLanguage = language
        // Read fresh: the grammar bakes the playhead and the last tap into its intents.
        let grammar = RuleBasedIntentEngine().parse(text, context: currentIntentContext())
        currentKind = chooseBrain()
        assignRoute(brain: badge(for: currentKind))
        let jobRunning = backgroundJobs > 0 || (host?.liveIsBusy ?? false)
        // While a choice is pending its chips replace the ideas: "la dernière" is a candidate, not a chip.
        let choicePending = choices != nil
        let lane = LiveTurnRouter.route(text, grammar: grammar, brain: currentKind, ideasOnScreen: choicePending ? 0 : shownIdeas.count,
                                        jobRunning: jobRunning, fastLane: app?.settings.liveFastLane ?? true)
        var dismissesChoice = false
        if choicePending, LiveTurnRouter.dismissesPendingChoice(grammar) {
            if case .control = lane {} else { dismissesChoice = true }
        }
        let laneName: String
        switch lane {
        case .control: laneName = "control"
        case .local: laneName = dismissesChoice ? "control" : "local"
        case .brain: laneName = dismissesChoice ? "control" : "brain"
        }
        LiveServices.shared.record(LiveLogEntry(time: now, event: "turn", fields: [
            "id": String(id), "lane": laneName, "brain": currentKind.rawValue, "words": String(words), "chars": String(text.count), "typed": typed ? "1" : "0",
        ]))
        let kind: LiveUserTurn.Kind = typed ? .typed : .speech
        if dismissesChoice {
            // "annule", "aucun": the host drops the question (no brain can).
            cancelChoice()
            speak(Replies.reply(for: EditIntent(action: .cancel), language: language), language: language, turn: id)
            feed(.turn(id, .ended(endsWithQuestion: false), at: clock.now()))
            return
        }
        switch lane {
        case .control(let command):
            runControl(command, turn: id, language: language)
        case .local(let plan):
            if plan.isEmpty, currentKind == .local {
                // The grammar did not understand: the local router's planners may.
                startBrainTurn(id: id, kind: kind, text: text, isQuestion: false, forcedKind: .local)
            } else {
                runLocalPlan(plan, turn: id, text: text, language: language)
            }
        case .brain(let isQuestion):
            startBrainTurn(id: id, kind: kind, text: text, isQuestion: isQuestion)
        }
    }

    /// Stop talking, end, repeat, start over, cancel the job, or pick an idea by its number.
    private func runControl(_ command: LiveControlCommand, turn: Int, language: NormalizedUtterance.Language) {
        debugDecision("control: \(command)")
        switch command {
        case .stopTalking:
            audio?.speaker.stop(fadeMs: 60)
            captionOnly?.stop()
        case .endLive:
            speak(LiveLines.line(.stopping, language), language: language, turn: turn)
            feed(.turn(turn, .ended(endsWithQuestion: false), at: clock.now()))
            Task { @MainActor [weak self] in
                // Let the goodbye play, two seconds at most.
                for _ in 0..<20 {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    guard let self, self.isRunning else { return }
                    if !(self.audio?.speaker.isSpeaking ?? false) { break }
                }
                self?.end()
            }
            return
        case .repeatLast:
            for chunk in lastResponseChunks { speak(chunk, language: language, turn: turn) }
        case .startOver:
            let brains = [claudeBrain as (any LiveBrain)?, onDeviceBrain, localBrain].compactMap { $0 }
            Task { for brain in brains { await brain.reset() } }
            brainIdeas = []
            sinceLastReply = []
            lastResponseChunks = []
            refreshIdeas(immediately: true)
        case .cancelJob:
            if host?.liveCancelProcessing() ?? false {
                speak(LiveLines.line(.jobCancelled, language), language: language, turn: turn)
            }
        case .chooseIdea(let number):
            let shown = shownIdeas
            if !shown.isEmpty {
                let index = (number >= 1 && number <= shown.count) ? number - 1 : shown.count - 1
                feed(.turn(turn, .ended(endsWithQuestion: false), at: clock.now()))
                runIdea(shown[index])
                return
            }
        }
        feed(.turn(turn, .ended(endsWithQuestion: false), at: clock.now()))
    }

    /// The fast lane: the grammar's plan runs at once, a short local line confirms it.
    private func runLocalPlan(_ plan: EditPlan, turn: Int, text: String, language: NormalizedUtterance.Language) {
        guard let toolHandler else { return }
        let previous = brainTask
        supersedeRunningTurn(by: turn)
        brainTurnID = turn
        brainTurnKind = .speech
        responseChunks = []
        let generation = liveGeneration
        brainTask = Task { @MainActor [weak self] in
            if let previous { await previous.value }
            guard let self, self.isRunning else { return }
            self.feed(.turn(turn, .firstOutput, at: self.clock.now()))
            if let question = plan.clarification {
                self.speak(question, language: language, turn: turn)
                self.feed(.turn(turn, .ended(endsWithQuestion: true), at: self.clock.now()))
                return
            }
            self.feed(.turn(turn, .toolStarted, at: self.clock.now()))
            self.latency.mark(.toolStart, at: self.clock.now(), turn: turn)
            self.assignActivityTitle(Self.defaultActivity(.applyEdits, language))
            toolHandler.language = language
            self.liveEditDepth += 1
            let versionBefore = self.host?.liveVersion ?? 0
            let execution = await toolHandler.runPlan(plan)
            self.liveEditDepth -= 1
            self.noteBackgroundJob(execution)
            self.notePlayback(execution, turn: turn)
            self.assignActivityTitle(nil)
            self.latency.mark(.toolEnd, at: self.clock.now(), turn: turn)
            if self.isRunning, self.liveGeneration == generation {
                // Play, seek, compare or zoom change nothing: no 'applied' earcon for them.
                self.feed(.turn(turn, .toolFinished(changedDocument: execution.version > versionBefore), at: self.clock.now()))
            }
            let labels = execution.steps.filter { $0.status == .applied }.compactMap(\.label)
            // Only an edit this run added: after "annule" or "lecture" the chip would take away another one.
            if let label = execution.undoLabel(since: versionBefore) { self.offerUndo(label: label) }
            self.appendSinceLastReply("said '\(text.prefix(80))'; applied \(labels.isEmpty ? "nothing" : labels.joined(separator: ", "))")
            self.refreshIdeas()
            // Interrupted meanwhile: the edit stands, its confirmation is not spoken.
            guard !Task.isCancelled, self.brainTurnID == turn else { return }
            let reply = execution.allApplied ? (plan.reply ?? execution.outcomeText(language: language)) : execution.outcomeText(language: language)
            if !reply.isEmpty { self.speak(reply, language: language, turn: turn, isResponse: true) }
            self.feed(.turn(turn, .ended(endsWithQuestion: reply.hasSuffix("?")), at: self.clock.now()))
            self.lastResponseChunks = self.responseChunks
            if self.brainTurnID == turn { self.brainTurnID = nil }
        }
    }

    // MARK: Brain turns

    enum BrainOutcome {
        case done
        case cancelled
        case failedBeforeOutput(Error)
        case failedAfterOutput(Error)
    }

    /// Runs one user turn on a brain, after the previous turn's task, in a task tagged with the turn id.
    func startBrainTurn(id: Int, kind: LiveUserTurn.Kind, text: String, isQuestion: Bool, forcedKind: LiveBrainKind? = nil) {
        let previous = brainTask
        supersedeRunningTurn(by: id)
        brainTurnID = id
        brainTurnKind = kind
        brainProducedOutput = false
        responseChunks = []
        let language = kind == .sessionStart ? replyLanguage : NormalizedUtterance(text).language
        brainTask = Task { @MainActor [weak self] in
            if let previous { await previous.value }
            guard let self else { return }
            if let interrupt = self.pendingInterrupt {
                await interrupt.value
                self.pendingInterrupt = nil
            }
            guard self.isRunning, self.brainTurnID == id, !Task.isCancelled else { return }
            await self.runBrainTurn(id: id, kind: kind, text: text, language: language, isQuestion: isQuestion, forcedKind: forcedKind)
            if self.brainTurnID == id { self.brainTurnID = nil }
        }
    }

    private func runBrainTurn(id: Int, kind: LiveUserTurn.Kind, text: String, language: NormalizedUtterance.Language, isQuestion: Bool,
                              forcedKind: LiveBrainKind?) async {
        var failed: Set<LiveBrainKind> = []
        var brainKind = forcedKind ?? chooseBrain()
        while isRunning, brainTurnID == id, !Task.isCancelled {
            if kind == .sessionStart, brainKind != .claude {
                // Only Claude opens with ideas; the others greet locally.
                speak(LiveLines.line(.greetingLocal, language), language: language, turn: id)
                return
            }
            guard let brain = brainFor(brainKind) else {
                if brainKind == .local { return }
                brainKind = .local
                continue
            }
            currentKind = brainKind
            activeBrainKind = brainKind
            activeBrainTurnID = id
            assignRoute(brain: badge(for: brainKind))
            switch await stream(brain, brainKind: brainKind, id: id, kind: kind, text: text, language: language, isQuestion: isQuestion) {
            case .done, .cancelled:
                return
            case .failedBeforeOutput(let error):
                failed.insert(brainKind)
                brainFailed(error, kind: brainKind, beforeOutput: true, language: language)
                guard brainKind != .local else {
                    feed(.turn(id, .failed, at: clock.now()))
                    return
                }
                // The same turn, answered by the next brain.
                brainKind = chooseBrain(excluding: failed)
                debugDecision("turn #\(id) re-run on \(brainKind.rawValue)")
            case .failedAfterOutput(let error):
                brainFailed(error, kind: brainKind, beforeOutput: false, language: language)
                // The chunk being heard finishes, then the connection line.
                speak(LiveLines.line(.connectionLost, language), language: language, turn: id)
                feed(.turn(id, .ended(endsWithQuestion: false), at: clock.now()))
                return
            }
        }
    }

    private func stream(_ brain: any LiveBrain, brainKind: LiveBrainKind, id: Int, kind: LiveUserTurn.Kind, text: String,
                        language: NormalizedUtterance.Language, isQuestion: Bool) async -> BrainOutcome {
        guard let host, let toolProxy else { return .done }
        var image: LiveImage?
        if brainKind == .claude, wantsImages { image = await snapshotForTurn() }
        guard isRunning, brainTurnID == id, !Task.isCancelled else { return .cancelled }
        let turn = LiveUserTurn(id: id, kind: kind, text: text, language: language, image: image, editorState: host.liveContextSummary(),
                                sinceLastReply: drainSinceLastReply(), interruptedAfter: takeInterruptedAfter())
        toolHandler?.language = language
        var chunker = SpeechChunker(language: language)
        var gotOutput = false
        latency.mark(.requestSent, at: clock.now(), turn: id)
        let filler = isQuestion ? scheduleFiller(turn: id, language: language) : nil
        defer { filler?.cancel() }

        func opened() {
            guard !gotOutput else { return }
            gotOutput = true
            brainProducedOutput = true
            filler?.cancel()
            feed(.turn(id, .firstOutput, at: clock.now()))
        }

        do {
            for try await event in brain.respond(to: turn, tools: toolProxy) {
                guard isRunning, brainTurnID == id, !Task.isCancelled else { return .cancelled }
                switch event {
                case .started(let model):
                    latency.mark(.firstByte, at: clock.now(), turn: id)
                    LiveServices.shared.record(LiveLogEntry(time: clock.now(), event: "brain.started", fields: ["brain": brainKind.rawValue, "model": model]))
                case .text(let delta):
                    if !gotOutput { latency.mark(.firstText, at: clock.now(), turn: id) }
                    opened()
                    for chunk in chunker.append(delta) { speak(chunk, language: language, turn: id, isResponse: true) }
                case .toolStarted(_, let name, let activity):
                    // The reducer's tool counter is fed by LiveToolProxy.perform, which always returns.
                    opened()
                    latency.mark(.toolStart, at: clock.now(), turn: id)
                    assignActivityTitle(activity ?? Self.defaultActivity(name, language))
                case .toolFinished(_, _, let result):
                    latency.mark(.toolEnd, at: clock.now(), turn: id)
                    assignActivityTitle(nil)
                    // The inline Undo is offered by LiveToolProxy, which knows the version before the call.
                    if result.changedDocument { refreshIdeas() }
                case .ideas(let proposed):
                    receiveBrainIdeas(proposed)
                case .fallbackModel(let from, let to):
                    debugDecision("server fallback \(from ?? "?") -> \(to ?? "?")")
                    LiveServices.shared.record(LiveLogEntry(time: clock.now(), event: "brain.fallback", fields: ["from": from ?? "", "to": to ?? ""]))
                case .usage(let usage):
                    if brainKind == .claude { LiveServices.shared.add(usage) }
                    latency.record(usage: usage, bodyBytes: 0, turn: id)
                case .completed(let end):
                    for chunk in chunker.finish() { speak(chunk, language: language, turn: id, isResponse: true) }
                    if brainKind == .claude { selector.recordSuccess() }
                    finish(end, turn: id, language: language, endsWithQuestion: chunker.lastEndsWithQuestion, brainKind: brainKind)
                    return .done
                }
            }
            guard isRunning, brainTurnID == id, !Task.isCancelled else { return .cancelled }
            for chunk in chunker.finish() { speak(chunk, language: language, turn: id, isResponse: true) }
            finish(.answered, turn: id, language: language, endsWithQuestion: chunker.lastEndsWithQuestion, brainKind: brainKind)
            return .done
        } catch {
            if error is CancellationError || Task.isCancelled || brainTurnID != id || !isRunning { return .cancelled }
            return gotOutput ? .failedAfterOutput(error) : .failedBeforeOutput(error)
        }
    }

    private func finish(_ end: LiveTurnEnd, turn: Int, language: NormalizedUtterance.Language, endsWithQuestion: Bool, brainKind: LiveBrainKind) {
        switch end {
        case .refused(let category):
            // Nothing the model half-said is kept; the refusal line, the problem, local ideas.
            audio?.speaker.stop(fadeMs: 60)
            captionOnly?.stop()
            responseChunks = []
            speak(LiveLines.line(.refusal, language), language: language, turn: turn)
            showProblem(.refusal, running: true)
            brainIdeas = []
            refreshIdeas(immediately: true)
            LiveServices.shared.record(LiveLogEntry(time: clock.now(), event: "brain.refused", fields: ["brain": brainKind.rawValue, "category": category ?? "none"]))
            feed(.turn(turn, .ended(endsWithQuestion: true), at: clock.now()))
        case .answered, .editApplied, .maxTokens, .loopLimit:
            feed(.turn(turn, .ended(endsWithQuestion: endsWithQuestion), at: clock.now()))
        }
        if !responseChunks.isEmpty { lastResponseChunks = responseChunks }
        activityTitleCleared()
        publishLatency(turn: turn)
    }

    private func activityTitleCleared() {
        if activityTitle != nil, !(host?.liveIsBusy ?? false) { assignActivityTitle(nil) }
    }

    /// A question with no answer yet after 1.2 s: a short local line (never on command turns).
    private func scheduleFiller(turn id: Int, language: NormalizedUtterance.Language) -> Task<Void, Never> {
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard let self, !Task.isCancelled, self.isRunning, self.brainTurnID == id, !self.brainProducedOutput else { return }
            let line = LiveLines.filler(language, avoiding: self.lastFiller)
            self.lastFiller = line
            self.feed(.turn(id, .firstOutput, at: self.clock.now()))
            self.speak(line, language: language, turn: id)
            self.debugDecision("filler after 1.2 s without an answer")
        }
    }

    /// The reducer cancelled a turn (barge-in, tap, typing), or cut its voice after the
    /// stream ended: stop the stream if any, and repair the answering brain's history to
    /// what was heard. A local-lane turn has no brain to repair.
    func cancelBrainTurn(_ id: Int, spokenText: String) {
        interruptedAfter = spokenText.isEmpty ? nil : spokenText
        let turn = brainTurnID ?? id
        brainTask?.cancel()
        brainTask = nil
        brainTurnID = nil
        brainTurnKind = nil
        if !(host?.liveIsBusy ?? false) { assignActivityTitle(nil) }
        if activeBrainTurnID == turn { interruptBrain(turn: turn, spokenText: spokenText) }
        debugDecision("turn #\(turn) cancelled after \(spokenText.split(separator: " ").count) spoken words")
    }

    /// A new turn while another still streams (the greeting, a turn the reducer kept):
    /// the old one gives way, and its brain repairs its history before the next request.
    private func supersedeRunningTurn(by id: Int) {
        guard let running = brainTask, let oldTurn = brainTurnID, oldTurn != id else { return }
        running.cancel()
        interruptBrain(turn: oldTurn, spokenText: responseChunks.joined(separator: " "))
        debugDecision("turn #\(oldTurn) superseded by #\(id)")
    }

    /// brain.interrupt on the brain that answered `turn`; the next turn waits for it.
    func interruptBrain(turn: Int, spokenText: String) {
        guard let kind = activeBrainKind, let brain = brainFor(kind) else { return }
        activeBrainKind = nil
        activeBrainTurnID = nil
        pendingInterrupt = Task { await brain.interrupt(turn: turn, spokenText: spokenText) }
    }

    // MARK: Errors

    private func brainFailed(_ error: Error, kind: LiveBrainKind, beforeOutput: Bool, language: NormalizedUtterance.Language) {
        let brainError = Self.brainError(from: error)
        LiveServices.shared.record(LiveLogEntry(time: clock.now(), event: "brain.error", fields: [
            "brain": kind.rawValue, "error": Self.errorName(brainError), "before_output": beforeOutput ? "1" : "0",
        ]))
        guard kind == .claude else {
            debugDecision("\(kind.rawValue) brain failed: \(Self.errorName(brainError)); next brain")
            return
        }
        selector.recordFailure(brainError, now: clock.now())
        let keyStore = LiveServices.shared.keyStore
        switch brainError {
        case .missingKey, .invalidKey: keyStore.noteRejected(.invalid)
        case .noCredit: keyStore.noteRejected(.noCredit)
        case .forbidden, .modelUnavailable: keyStore.noteRejected(.noAccess)
        default: break
        }
        let problem = Self.problem(for: brainError)
        if beforeOutput {
            showProblem(problem, running: true)
        } else {
            showNotice(LiveLines.problem(problem, language), isProblem: true)
        }
        assignRoute(brain: badge(for: chooseBrain(excluding: [.claude])))
    }

    static func brainError(from error: Error) -> LiveBrainError {
        if let known = error as? LiveBrainError { return known }
        if let api = error as? ClaudeAPIError {
            switch api.status ?? 0 {
            case 401: return .invalidKey
            case 402: return .noCredit
            case 403: return .forbidden
            case 404: return .modelUnavailable
            case 413: return .requestTooLarge
            case 429: return .rateLimited(retryAfter: api.retryAfter)
            case 529: return .overloaded
            case 400: return .badRequest(requestID: api.requestID, message: api.message)
            case let status where status >= 500: return .server(status: status)
            default: return .unavailable(api.type)
            }
        }
        if error is URLError { return .network("url") }
        return .unavailable(String(describing: type(of: error)))
    }

    static func problem(for error: LiveBrainError) -> LiveProblem {
        switch error {
        case .missingKey, .invalidKey: return .keyInvalid
        case .noCredit: return .noCredit
        case .forbidden, .modelUnavailable: return .noAccess
        case .rateLimited: return .rateLimited
        case .network: return .offline
        case .overloaded, .server: return .unavailable("server")
        case .timeout: return .unavailable("timeout")
        case .badRequest, .requestTooLarge: return .unavailable("request")
        case .streamTruncated: return .unavailable("stream")
        case .unavailable(let reason): return .unavailable(reason)
        }
    }

    static func errorName(_ error: LiveBrainError) -> String {
        switch error {
        case .missingKey: return "missing_key"
        case .invalidKey: return "invalid_key"
        case .noCredit: return "no_credit"
        case .forbidden: return "forbidden"
        case .modelUnavailable: return "model_unavailable"
        case .rateLimited(let retryAfter): return "rate_limited_\(Int(retryAfter ?? -1))"
        case .overloaded: return "overloaded"
        case .server(let status): return "server_\(status)"
        case .badRequest(let requestID, _): return "bad_request_\(requestID ?? "none")"
        case .requestTooLarge: return "request_too_large"
        case .network: return "network"
        case .timeout(let stage): return "timeout_\(stage)"
        case .streamTruncated: return "stream_truncated"
        case .unavailable: return "unavailable"
        }
    }

    static func defaultActivity(_ tool: LiveToolName, _ language: NormalizedUtterance.Language) -> String {
        let french = language == .french
        switch tool {
        case .applyEdits: return french ? "Je m'en occupe…" : "On it…"
        case .undo: return french ? "J'annule…" : "Undoing…"
        case .compareBeforeAfter: return french ? "Avant, après…" : "Before and after…"
        case .proposeIdeas: return french ? "Quelques idées…" : "A few ideas…"
        }
    }

    // MARK: Voice

    /// One chunk to the voice, or to the captions when liveSpeaks is off.
    func speak(_ text: String, language: NormalizedUtterance.Language, turn: Int, isResponse: Bool = false) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, isRunning else { return }
        if isResponse {
            if responseChunks.isEmpty { latency.mark(.firstChunk, at: clock.now(), turn: turn) }
            responseChunks.append(clean)
        }
        if let captionOnly {
            captionOnly.enqueue(clean, turn: turn)
        } else {
            audio?.speaker.enqueue(clean, language: language == .french ? "fr" : "en", turn: turn)
        }
    }

    func speak(_ text: String, turn: Int) {
        speak(text, language: replyLanguage, turn: turn)
    }

    /// Speaker signals: the caption follows the chunk being heard (D11), then the reducer.
    func speakerSignal(_ turn: Int, _ signal: SpeakerSignal) {
        guard isRunning else { return }
        if case .chunkStarted(let text) = signal {
            pausePlaybackForVoice(turn: turn)
            var next = transcript
            next.assistant = text
            assignTranscript(next)
            if !firstAudioMarked.contains(turn) {
                firstAudioMarked.insert(turn)
                latency.mark(.firstAudio, at: clock.now(), turn: turn)
                publishLatency(turn: turn)
            }
        }
        feed(.speaker(turn, signal, at: clock.now()))
    }

    /// The voice starts while the video plays: playback pauses, so the soundtrack never
    /// covers the voice. Not for the turn whose own steps started it ("lecture"), nor
    /// for captions without a voice.
    private func pausePlaybackForVoice(turn: Int) {
        guard captionOnly == nil, machine.state.speakingSince == nil, playbackTurn != turn, host?.liveIsPlaying == true else { return }
        host?.livePausePlayback()
        debugDecision("video paused for the voice")
    }

    /// Remembers the turn whose run started playback.
    func notePlayback(_ execution: LiveExecution, turn: Int?) {
        guard let turn, execution.steps.contains(where: { $0.status == .applied && $0.action == .play }) else { return }
        playbackTurn = turn
    }

    func publishLatency(turn: Int) {
        let report = latency.report(turn: turn)
        var percentiles: [String: [Double]] = [:]
        for mark in LatencyTracker.Mark.allCases {
            if let values = latency.percentiles(mark) { percentiles[mark.rawValue] = [values.p50, values.p90] }
        }
        LiveServices.shared.debug.setLatency(last: report, percentiles: percentiles)
        guard !report.isEmpty else { return }
        var fields: [String: String] = ["id": String(turn), "brain": currentKind.rawValue]
        for (mark, ms) in report { fields[mark] = String(Int(ms)) }
        LiveServices.shared.record(LiveLogEntry(time: clock.now(), event: "latency", fields: fields))
    }

    /// At VAD speech start: reopen the HTTP/2 connection when Claude has been idle for more than 60 s.
    func preconnectIfIdle() {
        guard route.brain == .claude, let brain = claudeBrain, let transport = claudeTransport, let key = claudeKey else { return }
        Task { @MainActor [weak self] in
            guard let idle = await brain.secondsSinceLastRequest, idle > 60 else { return }
            let request = ClaudeRequestBuilder.keyCheckRequest(apiKey: key)
            Task.detached(priority: .userInitiated) { _ = try? await transport.send(request) }
            self?.debugDecision("pre-connect after \(Int(idle)) s idle")
        }
    }

    func imageUpload(_ event: URLSessionClaudeTransport.UploadEvent) {
        var next = route
        switch event {
        case .started:
            next.isUploading = true
        case .finished(let success):
            next.isUploading = false
            if success {
                // D13: Claude sees the picture only once a request carrying it got a 2xx.
                next.sharesMedia = true
                next.imagesSent += 1
            }
        }
        assignRoute(next)
    }

    // MARK: Snapshots

    private var wantsImages: Bool {
        guard let app else { return false }
        return app.settings.liveSendsImages && app.settings.hasLiveConsent
    }

    /// Photo: one render per document version; video: also per clip (contextGeneration).
    private var snapshotKey: String? {
        guard let host else { return nil }
        return mode == .video ? "\(host.liveVersion)#\(contextGeneration)" : "\(host.liveVersion)"
    }

    func prefetchSnapshot() {
        guard route.brain == .claude, wantsImages, let key = snapshotKey, snapshotCache?.key != key else { return }
        _ = snapshotTask(for: key)
    }

    private func snapshotForTurn() async -> LiveImage? {
        guard let key = snapshotKey else { return nil }
        if let cached = snapshotCache, cached.key == key { return cached.image }
        return await snapshotTask(for: key).value
    }

    private func snapshotTask(for key: String) -> Task<LiveImage?, Never> {
        if let current = snapshotTask, current.key == key { return current.task }
        guard let host else { return Task { nil } }
        let task = Task { @MainActor [weak self] () -> LiveImage? in
            let image = await host.liveSnapshotImage(maxPixel: 1024)
            self?.snapshotCache = (key, image)
            return image
        }
        snapshotTask = (key, task)
        return task
    }

    /// The host's intent context, once per document version and context change: only
    /// for the end-of-turn parse of each transcript segment, where the playhead and the
    /// last tap do not matter. A committed turn parses with `currentIntentContext()`.
    func intentContext() -> IntentContext {
        guard let host else { return IntentContext(mode: mode) }
        let key = "\(host.liveVersion)#\(contextGeneration)"
        if let cached = cachedIntentContext, cached.key == key { return cached.context }
        let context = host.liveIntentContext()
        cachedIntentContext = (key, context)
        return context
    }

    /// The host's intent context as it is now: the playhead where playback or a scrub
    /// left it, the point last tapped.
    func currentIntentContext() -> IntentContext {
        host?.liveIntentContext() ?? IntentContext(mode: mode)
    }

    // MARK: What happened since the last reply

    func appendSinceLastReply(_ line: String) {
        sinceLastReply.append(String(line.prefix(160)))
        if sinceLastReply.count > 12 { sinceLastReply.removeFirst(sinceLastReply.count - 12) }
    }

    private func drainSinceLastReply() -> [String] {
        defer { sinceLastReply = [] }
        return sinceLastReply
    }

    private func takeInterruptedAfter() -> String? {
        defer { interruptedAfter = nil }
        return interruptedAfter
    }

    // MARK: Host notifications

    func documentChanged(label: String?) {
        cachedIntentContext = nil
        if let label, liveEditDepth == 0, backgroundJobs == 0 {
            appendSinceLastReply("\(label) (manual)")
        }
        refreshIdeas()
    }

    func contextChanged() {
        contextGeneration += 1
        cachedIntentContext = nil
        refreshIdeas()
    }

    /// A step still running after the handler returned finishes in the background (onJobFinished).
    func noteBackgroundJob(_ execution: LiveExecution) {
        if execution.steps.contains(where: { $0.status == .running || $0.status == .queued }) { backgroundJobs += 1 }
    }

    /// A job that outlived its tool call finished.
    func jobFinished(_ execution: LiveExecution) {
        backgroundJobs = max(0, backgroundJobs - 1)
        let label = execution.steps.last(where: { $0.status == .applied })?.label
        if execution.anyApplied {
            audio?.playEarcon(.applied)
            if state != .hearing, state != .dictating { Haptics.live(.actionApplied) }
        }
        if let label { appendSinceLastReply("finished '\(label)'") }
        if let edit = execution.lastEditLabel { offerUndo(label: edit) }
        if isRunning, !isConnecting, state != .speaking, state != .hearing, execution.anyApplied {
            speak(LiveLines.line(.jobDone, replyLanguage), turn: machine.state.turn)
        }
        refreshIdeas()
    }

    // MARK: Ideas

    var shownIdeas: [LiveIdea] {
        if case .ready(let list) = ideas { return list }
        return []
    }

    private var chipLanguage: NormalizedUtterance.Language {
        psPrefersFrench ? .french : .english
    }

    /// Heuristic chips again, coalesced (a dial drag notifies many times): at once
    /// on attach and after chips, 150 ms later otherwise. `.loading` lasts 1.5 s at most.
    func refreshIdeas(immediately: Bool = false) {
        guard host != nil, !isTornDown else { return }
        ideasRefreshTask?.cancel()
        ideasRefreshTask = Task { @MainActor [weak self] in
            if !immediately { try? await Task.sleep(nanoseconds: 150_000_000) }
            guard let self, !Task.isCancelled else { return }
            self.recomputeIdeas()
        }
        if !ideasReady, ideasDeadlineTask == nil {
            ideasDeadlineTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                guard let self, !Task.isCancelled, !self.ideasReady else { return }
                // No scene yet: the generic set.
                self.ideasReady = true
                self.recomputeIdeas()
            }
        }
    }

    private func recomputeIdeas() {
        guard let host else { return }
        let summary = host.liveContextSummary()
        heuristicIdeas = IdeaEngine.heuristic(summary, dismissed: dismissedIdeas, language: chipLanguage)
        if !ideasReady {
            let sceneReady = summary.scene != nil || summary.video != nil || mode == .pdf
            guard sceneReady else { return }
            ideasReady = true
        }
        publishIdeas()
    }

    private func publishIdeas() {
        let fromBrain = brainIdeas.filter { !dismissedIdeas.contains($0.id) }
        let fill = heuristicIdeas.filter { !dismissedIdeas.contains($0.id) }
        var shown = fromBrain.isEmpty ? Array(fill.prefix(3)) : IdeaEngine.merge(current: [], incoming: fromBrain, dismissed: dismissedIdeas, fill: fill)
        if shown.isEmpty { shown = Array((fromBrain + fill).prefix(3)) }
        assignIdeas(.ready(shown))
    }

    /// propose_ideas, from Claude (through the tool handler and the event stream).
    func receiveBrainIdeas(_ incoming: [LiveIdea]) {
        let fresh = incoming.filter { !dismissedIdeas.contains($0.id) }
        guard !fresh.isEmpty else { return }
        let next = Array(fresh.prefix(3))
        guard next != brainIdeas else { return }
        brainIdeas = next
        ideasReady = true
        publishIdeas()
    }

    /// A chip: its validated steps run locally, no model call.
    func runIdea(_ idea: LiveIdea) {
        guard let toolHandler, !isTornDown else { return }
        let live = isRunning && !isConnecting
        let generation = liveGeneration
        var turn = machine.state.turn
        if live {
            feed(.ideaTapped(at: clock.now()))
            turn = machine.state.turn
            feed(.turn(turn, .toolStarted, at: clock.now()))
        } else {
            restingPhase = .acting
            publishState()
        }
        assignActivityTitle(idea.title)
        let language = live ? replyLanguage : chipLanguage
        toolHandler.language = language
        liveEditDepth += 1
        let versionBefore = host?.liveVersion ?? 0
        Task { @MainActor [weak self] in
            let execution = await toolHandler.runIdea(idea)
            guard let self else { return }
            self.liveEditDepth -= 1
            self.noteBackgroundJob(execution)
            self.assignActivityTitle(nil)
            let applied = execution.anyApplied
            if live, self.isRunning, self.liveGeneration == generation {
                self.feed(.turn(turn, .toolFinished(changedDocument: execution.version > versionBefore), at: self.clock.now()))
            } else {
                self.restingPhase = nil
                self.publishState()
            }
            self.brainIdeas.removeAll { $0.id == idea.id }
            self.appendSinceLastReply("tapped idea '\(idea.title)' -> \(applied ? "applied" : "not applied")")
            let line = applied ? LiveLines.ideaApplied(idea.title, language) : execution.outcomeText(language: language)
            if execution.undoLabel(since: versionBefore) != nil { self.offerUndo(label: idea.title) }
            if self.isRunning {
                // Interrupted meanwhile (the user spoke, the orb): the edit stands and is in
                // sinceLastReply; its line is not spoken over the user, nor queued behind them.
                let phase = self.machine.state.phase
                if self.machine.state.turn == turn, phase != .userSpeaking, phase != .interrupted {
                    self.speak(line, language: language, turn: turn)
                }
            } else if !line.isEmpty {
                self.showReply(line, isProblem: !applied, isError: false)
            }
            self.refreshIdeas(immediately: true)
        }
    }

    func dismissIdea(_ idea: LiveIdea) {
        dismissedIdeas.insert(idea.id)
        brainIdeas.removeAll { $0.id == idea.id }
        appendSinceLastReply("dismissed idea '\(idea.title)'")
        heuristicIdeas.removeAll { $0.id == idea.id }
        publishIdeas()
        refreshIdeas()
    }

    /// A numbered candidate, tapped or picked by voice.
    func runChoice(_ choice: LiveCandidateChoice) {
        guard let host else { return }
        liveEditDepth += 1
        Task { @MainActor [weak self] in
            let result = await host.liveChooseCandidate(choice)
            guard let self else { return }
            self.liveEditDepth -= 1
            switch choice {
            case .index(let number): self.appendSinceLastReply("chose candidate \(number)")
            case .all: self.appendSinceLastReply("chose all candidates")
            }
            if case .applied(let label) = result.outcome { self.offerUndo(label: label) }
            if !self.isRunning, let message = result.outcome.message, !message.isEmpty {
                self.showReply(message, isProblem: !result.outcome.isSuccess, isError: false)
            }
            self.refreshIdeas()
        }
    }

    /// "Annule" or the choice row's close button: the host drops the pending question.
    func cancelChoice() {
        guard let host, !isTornDown else { return }
        liveEditDepth += 1
        Task { @MainActor [weak self] in
            _ = await host.liveRun(EditIntent(action: .cancel))
            guard let self else { return }
            self.liveEditDepth -= 1
            self.appendSinceLastReply("dismissed the pending choice")
            self.refreshIdeas()
        }
    }

    /// A brain's tool call starts: the reducer counts it here rather than from the event
    /// stream, so a turn cancelled mid-tool still reports the end. Nil when not counted.
    func brainToolStarted() -> (turn: Int, generation: Int)? {
        guard isRunning, !isConnecting else { return nil }
        let turn = brainTurnID ?? machine.state.turn
        // The reducer ignores a stale turn's start; its end must not be fed either.
        guard turn == machine.state.turn else { return nil }
        if brainTurnID == turn { brainProducedOutput = true }
        feed(.turn(turn, .toolStarted, at: clock.now()))
        return (turn, liveGeneration)
    }

    func brainToolFinished(_ started: (turn: Int, generation: Int), changedDocument: Bool) {
        guard isRunning, liveGeneration == started.generation else { return }
        feed(.turn(started.turn, .toolFinished(changedDocument: changedDocument), at: clock.now()))
    }

    /// The inline Annuler.
    func undoLast() {
        guard let host else { return }
        liveEditDepth += 1
        let labels = host.liveUndo(count: 1, redo: false, toOriginal: false)
        liveEditDepth -= 1
        assignUndoOffer(nil)
        if let label = labels.first { appendSinceLastReply("undid '\(label)'") }
        refreshIdeas()
    }

    // MARK: Resting mode

    /// Outside Live: the existing local pipeline; nothing leaves the phone (D15).
    func runRestingCommand(_ text: String) {
        guard let host, !isTornDown else { return }
        restingPhase = .thinking
        publishState()
        Task { @MainActor [weak self] in
            let reply = await host.liveHandleCommand(text)
            guard let self else { return }
            self.restingPhase = nil
            self.publishState()
            if !reply.text.isEmpty { self.showReply(reply.text, isProblem: reply.isProblem, isError: reply.isError) }
            self.refreshIdeas()
        }
    }

    // MARK: Notices, problems, replies, undo offers

    func showNotice(_ text: String, isProblem: Bool, action: LiveNotice.Action = .none) {
        serial += 1
        let id = serial
        assignNotice(LiveNotice(id: id, text: text, isProblem: isProblem, action: action))
        guard action == .none else { return }
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: isProblem ? 6_000_000_000 : 4_000_000_000)
            guard let self, self.notice?.id == id else { return }
            self.assignNotice(nil)
        }
    }

    /// `.problem(p)` for 1.6 s, then back to listening or off; the notice stays a little longer.
    func showProblem(_ problem: LiveProblem, action: LiveNotice.Action = .none, running: Bool) {
        showNotice(problemText(problem), isProblem: true, action: action)
        problemToken += 1
        let token = problemToken
        problemState = problem
        publishState()
        if !isDictating { Haptics.live(.problem) }
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            guard let self, self.problemToken == token else { return }
            self.problemState = nil
            self.publishState()
        }
    }

    func problemText(_ problem: LiveProblem) -> String {
        LiveLines.problem(problem, isRunning ? replyLanguage : chipLanguage)
    }

    func showReply(_ text: String, isProblem: Bool, isError: Bool) {
        serial += 1
        let id = serial
        assignReply(LiveReply(id: id, text: text, isProblem: isProblem, isError: isError))
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: isError ? 7_000_000_000 : 4_000_000_000)
            guard let self, self.reply?.id == id else { return }
            self.assignReply(nil)
        }
    }

    func offerUndo(label: String) {
        serial += 1
        let id = serial
        assignUndoOffer(LiveUndoOffer(id: id, label: label))
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            guard let self, self.undoOffer?.id == id else { return }
            self.assignUndoOffer(nil)
        }
    }

    func debugDecision(_ text: String) {
        LiveServices.shared.debug.noteDecision(text)
    }
}

/// Runs a brain's tool calls on the editor through EditorToolHandler, and tells
/// the session which document changes are Live's own and which jobs outlive the call.
@MainActor
final class LiveToolProxy: LiveToolHandler {
    private let handler: EditorToolHandler
    private weak var session: LiveSession?

    init(handler: EditorToolHandler, session: LiveSession) {
        self.handler = handler
        self.session = session
    }

    func context() -> IntentContext {
        handler.context()
    }

    func perform(_ call: LiveToolCall) async -> LiveToolResult {
        let started = session?.brainToolStarted()
        let versionBefore = session?.host?.liveVersion ?? 0
        session?.liveEditDepth += 1
        let result = await handler.perform(call)
        session?.liveEditDepth -= 1
        guard let session else { return result }
        if let execution = result.execution {
            session.noteBackgroundJob(execution)
            session.notePlayback(execution, turn: started?.turn ?? session.brainTurnID)
            // Only apply_edits that raised the version: never after undo, compare or a seek.
            if case .applyEdits = call.tool, let label = execution.undoLabel(since: versionBefore) { session.offerUndo(label: label) }
        }
        if let started {
            let changed = result.changedDocument && (session.host?.liveVersion ?? 0) > versionBefore
            session.brainToolFinished(started, changedDocument: changed)
        }
        return result
    }
}

/// Captions without a voice (liveSpeaks off): each chunk stays on screen for a
/// reading time, far below 25 words per second, with the same signals as the speaker.
@MainActor
final class CaptionOnlySpeaker {
    private let onSignal: (Int, SpeakerSignal) -> Void
    private var queue: [(text: String, turn: Int)] = []
    private var current: Task<Void, Never>?
    private var lastTurn = 0

    init(onSignal: @escaping (Int, SpeakerSignal) -> Void) {
        self.onSignal = onSignal
    }

    func enqueue(_ text: String, turn: Int) {
        lastTurn = turn
        onSignal(turn, .chunkQueued)
        queue.append((text, turn))
        pump()
    }

    func stop() {
        let hadWork = current != nil || !queue.isEmpty
        current?.cancel()
        current = nil
        queue = []
        if hadWork { onSignal(lastTurn, .drained) }
    }

    private func pump() {
        guard current == nil, !queue.isEmpty else { return }
        let (text, turn) = queue.removeFirst()
        onSignal(turn, .chunkStarted(text))
        let words = text.split(whereSeparator: { $0.isWhitespace }).count
        let seconds = max(0.8, Double(words) / 5)
        current = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            self.current = nil
            self.onSignal(turn, .chunkFinished)
            if self.queue.isEmpty { self.onSignal(turn, .drained) } else { self.pump() }
        }
    }
}
#endif
