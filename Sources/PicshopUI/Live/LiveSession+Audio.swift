#if canImport(SwiftUI) && canImport(UIKit)
import Foundation
import AVFoundation
import Speech
import UIKit
import PicshopCore
import PicshopIntent
import PicshopSpeech

/// Starting and ending Live, the audio loops, the reducer's events and effects,
/// app lifecycle, and dictation outside Live.
extension LiveSession {
    // MARK: Start

    /// start(): permissions, then connect. Everything runs on the iPhone: no consent to ask.
    func beginLive() async {
        guard app != nil, host != nil, !isTornDown, !isRunning, !isStarting else { return }
        isStarting = true
        cancelDictation()
        assignNotice(nil)
        // .connecting from the tap (contract 7.6), also while the permission prompts show.
        restingPhase = .connecting
        publishState()
        defer {
            isStarting = false
            if restingPhase == .connecting {
                restingPhase = nil
                publishState()
            }
        }

        // Microphone and speech recognition (Info.plist strings already cover both).
        let microphone = AVAudioApplication.shared.recordPermission
        if microphone == .denied {
            restingPhase = nil
            showProblem(.noMicrophone, action: .openSettings, running: false)
            sayWithoutLive(.noMicrophone)
            return
        }
        if microphone == .undetermined {
            microphoneAskedThisTime = true
            let granted = await AVAudioApplication.requestRecordPermission()
            guard granted else {
                restingPhase = nil
                showProblem(.noMicrophone, action: .allowMicrophone, running: false)
                sayWithoutLive(.noMicrophone)
                return
            }
        }
        var speech = SFSpeechRecognizer.authorizationStatus()
        if speech == .notDetermined {
            speech = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
            }
        }
        recognitionAvailable = speech == .authorized
        guard !isTornDown else { return }
        await connect()
    }

    /// State .connecting until the voice path is ready: 6 s at most for each path.
    /// The simple path is the default; duplex only with headphones once the self-test allowed it.
    private func connect() async {
        guard let app, let host else { return }
        let settings = app.settings
        let services = LiveServices.shared
        let startedAt = clock.now()
        liveGeneration += 1
        let generation = liveGeneration
        assignRunning(true)
        isConnecting = true
        publishState()
        services.debug.isCollecting = settings.liveDebug
        // The local model starts loading now, off the main actor, when memory and heat allow it.
        LocalBrainHub.shared.preload(reason: "live")
        accumulator = TranscriptAccumulator()
        assignMuted(false)
        firstAudioMarked = []
        playbackHolds = false
        playbackTurn = nil
        sinceLastReply = []
        interruptedAfter = nil
        responseChunks = []
        simpleEarFailed = false
        switchingToSimple = false
        framesExpected = false
        voiceDrainedAt = -.infinity
        voiceGaveUp = false
        saidModelLoading = false
        saidModelOff = false

        // Nothing else speaks or listens while Live owns the audio.
        host.liveSpeechSuppressed = true
        VoiceFeedback.shared.isSuppressed = true
        VoiceFeedback.shared.stop()
        if app.voice.isListening || app.voice.state == .finishing { app.voice.cancel() }
        UIApplication.shared.isIdleTimerDisabled = true
        Diagnostics.shared.redactsCommands = true
        observeLifecycle()

        captionOnly = settings.liveSpeaks ? nil : CaptionOnlySpeaker { [weak self] turn, signal in self?.speakerSignal(turn, signal) }
        let locale = settings.voiceLocale
        replyLanguage = locale.language.languageCode?.identifier == "fr" ? .french : .english
        let brains = Task { @MainActor in await self.prepareBrains() }

        // The voice path.
        let route = LiveAudioEngine.currentRoute()
        let headset = Self.isHeadset(route)
        var pathReason = "default"
        if settings.liveDuplexAllowed, headset {
            switch await startDuplex(locale: locale, generation: generation) {
            case .some(true):
                pathReason = "headphones"
            case .some(false):
                // The duplex engine runs but has no recognizer: VoiceController's own fallbacks do better.
                audio?.stop()
                audio = nil
                pathReason = "duplex_no_recognizer"
            case .none:
                pathReason = "duplex_failed"
            }
        } else if headset {
            pathReason = "duplex_not_allowed"
        }
        guard isRunning, liveGeneration == generation else {
            brains.cancel()
            return
        }
        if audio == nil {
            guard await startSimple(locale: locale, generation: generation) else {
                brains.cancel()
                return
            }
        }
        // The hub answers at once; Apple's model says whether it is available. 3 s at most.
        if !(await LiveDeadline.wait(brains, seconds: 3)) { debugDecision("brains still preparing after 3 s") }
        guard isRunning, liveGeneration == generation else { return }
        isConnecting = false
        if notice?.isProblem == false { assignNotice(nil) }
        let path: LiveVoicePath = audio != nil ? .duplex : .simple
        assignVoicePath(path)
        machine.setOptions(reducerOptions())
        services.record(LiveLogEntry(time: clock.now(), event: "live.path", fields: [
            "path": path.rawValue, "reason": pathReason, "route": route.rawValue,
        ]))

        // The reducer starts listening: openMic, beginUserTurn, the open earcon and haptic.
        feed(.start(at: clock.now()))
        feed(.routeChanged(currentEchoRisk()))
        startLoop()
        offerVoiceHintIfNeeded()
        let elapsed = Int((clock.now() - startedAt) * 1000)
        services.record(LiveLogEntry(time: clock.now(), event: "live.start", fields: [
            "brain": currentKind.rawValue, "connect_ms": String(elapsed), "path": path.rawValue,
            "recognizer": audio?.transcriber?.engineName ?? (path == .simple ? "VoiceController" : "none"),
            "echo_cancellation": audio?.engine.echoCancellationActive == true ? "on" : "off", "route": route.rawValue,
        ]))
        debugDecision("Live started in \(elapsed) ms · \(path.rawValue) · \(route.rawValue)")
        Diagnostics.shared.note("Live on (\(path.rawValue), \(route.rawValue))")

        if pathReason == "duplex_failed" || pathReason == "duplex_no_recognizer" {
            // Duplex was allowed but did not start: said on screen; the greeting follows on the simple path.
            showNotice(L("Duplex didn't start: Live takes turns to talk."), isProblem: false)
        }
        if !recognitionAvailable {
            // Speech recognition is not allowed: typing still works, the voice still answers, and Live says so.
            let code = locale.language.languageCode?.identifier ?? "fr"
            let problem = LiveProblem.noSpeechRecognition(language: code)
            showProblem(problem, action: .openSettings, running: true)
            speak(problemText(problem), turn: machine.state.turn)
        }

        // The first turn: a brain that opens sessions looks at the picture and proposes
        // ideas after a short local line; the others greet locally (or say the model is loading).
        currentKind = chooseBrain()
        assignRoute(liveRoute(for: currentKind))
        if brainFor(currentKind)?.capabilities.opensSession == true {
            speak(LiveLines.line(.greetingLooking, replyLanguage, mode: mode), turn: machine.state.turn)
            startBrainTurn(id: machine.state.turn, kind: .sessionStart, text: "", isQuestion: false)
        } else if LocalBrainHub.shared.status.phase == .loading {
            saidModelLoading = true
            speak(LiveLines.line(.modelLoading, replyLanguage), turn: machine.state.turn)
        } else {
            speak(LiveLines.line(.greetingLocal, replyLanguage), turn: machine.state.turn)
        }
    }

    /// The echo-cancelling engine, 6 s at most. True or false: it runs, with or without a
    /// recognizer. Nil: it did not start (or Live ended meanwhile); nothing of it is left.
    private func startDuplex(locale: Locale, generation: Int) async -> Bool? {
        guard let app else { return nil }
        let settings = app.settings
        let stack = LiveAudioStack()
        audio = stack
        stack.onSegment = { [weak self] segment in self?.transcriptSegment(segment) }
        stack.onEngineEvent = { [weak self] event in self?.engineEvent(event) }
        stack.speaker.onSignal = { [weak self] turn, signal in self?.speakerSignal(turn, signal) }
        stack.speaker.onFallback = { [weak self] reason in self?.speakerFellBack(reason) }
        stack.speaker.onVoiceFailure = { [weak self] reason in self?.voiceWentSilent(reason) }
        stack.speaker.rateMultiplier = settings.liveRate
        stack.speaker.preferredVoices = ["fr": settings.liveVoiceFR, "en": settings.liveVoiceEN].compactMapValues { $0 }
        if settings.liveSpeakerUsesSystem { stack.speaker.setUsesSystemSpeech(true) }
        stack.speaker.warmUp(languages: [replyLanguage == .french ? "fr" : "en"])
        let hdBluetooth = settings.liveHDBluetooth
        let installing: @Sendable () -> Void = { [weak self] in
            Task { @MainActor [weak self] in self?.showNotice(L("Downloading the speech model…"), isProblem: false) }
        }
        do {
            let recognizer = try await LiveDeadline.run(6) {
                try await stack.start(hdBluetooth: hdBluetooth, locale: locale, installing: installing)
            }
            guard isRunning, liveGeneration == generation, audio === stack else {
                stack.stop()
                return nil
            }
            return recognizer
        } catch {
            PSLog.error("live: the duplex engine did not start: \(error)", category: .speech)
            LiveServices.shared.record(LiveLogEntry(time: clock.now(), event: "live.duplex_failed", fields: ["error": Self.errorToken(error)]))
            debugDecision("duplex did not start (\(Self.errorToken(error))): simple path")
            stack.stop()
            if audio === stack { audio = nil }
            return nil
        }
    }

    /// The simple path: the conversation's audio session (6 s at most), VoiceController for
    /// the ear, `speak()` for the voice. False when it could not start: Live then ended,
    /// and said why.
    func startSimple(locale: Locale, generation: Int) async -> Bool {
        guard let app else { return false }
        let settings = app.settings
        let simple = SimpleLiveVoice(voice: app.voice)
        simple.onPartial = { [weak self] text in self?.simplePartial(text) }
        simple.onFinal = { [weak self] text in self?.simpleFinal(text) }
        simple.onFailure = { [weak self] message in self?.simpleEarGaveUp(message) }
        simple.onInterruption = { [weak self] began, shouldResume in self?.simpleInterruption(began: began, shouldResume: shouldResume) }
        simple.onRouteChange = { [weak self] in self?.simpleRouteChanged() }
        simple.onNothingRecognized = { [weak self] in self?.nothingRecognized() }
        simple.onSpeechModelInstalling = { [weak self] installing in self?.speechModelInstalling(installing) }
        simple.speaker.onSignal = { [weak self] turn, signal in self?.speakerSignal(turn, signal) }
        simple.speaker.onVoiceFailure = { [weak self] reason in self?.voiceWentSilent(reason) }
        simple.speaker.rateMultiplier = settings.liveRate
        simple.speaker.preferredVoices = ["fr": settings.liveVoiceFR, "en": settings.liveVoiceEN].compactMapValues { $0 }
        // A cold voice (the first line after launch, a Premium voice) is slow to start: loaded now.
        simple.speaker.warmUp(languages: [replyLanguage == .french ? "fr" : "en"])
        self.simple = simple
        do {
            try await LiveDeadline.run(6) { try await simple.start(locale: locale) }
        } catch {
            simple.stop()
            guard self.simple === simple else { return false }
            self.simple = nil
            guard isRunning, liveGeneration == generation else { return false }
            PSLog.error("live: the simple voice path did not start: \(error)", category: .speech)
            LiveServices.shared.record(LiveLogEntry(time: clock.now(), event: "live.audio_failed", fields: ["path": "simple", "error": Self.errorToken(error)]))
            let language = replyLanguage
            stopLive(reason: "audio failed")
            // Live has no voice any more: the problem is shown, and said by the fallback voice.
            let problem = LiveProblem.unavailable("audio_start")
            showProblem(problem, running: false)
            SpokenFallback.say(LiveLines.problem(problem, language), language: language)
            return false
        }
        guard isRunning, liveGeneration == generation, self.simple === simple else {
            simple.stop()
            if self.simple === simple { self.simple = nil }
            return false
        }
        // Measured on the conversation's own session (its category decides the Bluetooth profile).
        simpleHeadset = Self.simpleRouteKeepsEchoOut()
        simpleUtteranceOverVoice = nil
        return true
    }

    /// This conversation's brains, from LocalBrainHub: the local model when it is loaded,
    /// Apple's on-device model, and the rules-only grammar. Never waits on the weights.
    private func prepareBrains() async {
        let set = LocalBrainHub.shared.makeLiveBrains(mode: mode)
        modelBrain = set.model
        modelBrainCheckedAt = clock.now()
        onDeviceBrain = set.onDevice
        localBrain = set.local
        onDeviceAvailable = false
        if let onDevice = set.onDevice {
            onDeviceAvailable = await onDevice.isAvailable()
            if onDeviceAvailable { Task.detached(priority: .utility) { await onDevice.warmUp() } }
        }
        if let model = set.model {
            Task.detached(priority: .userInitiated) { await model.warmUp() }
        }
    }

    /// The one-time better-voice card, when the best installed voice for the language is standard quality.
    private func offerVoiceHintIfNeeded() {
        let services = LiveServices.shared
        let code = replyLanguage == .french ? "fr-FR" : "en-US"
        let preferred = replyLanguage == .french ? app?.settings.liveVoiceFR : app?.settings.liveVoiceEN
        let voice = SystemVoices.best(for: code, preferredIdentifier: preferred)
        let description = activeSpeaker?.voiceDescription ?? ""
        services.debug.setVoice(description.isEmpty ? (voice.map { "\($0.name) (\($0.language))" } ?? "system default") : description)
        guard !services.hasShownVoiceHint, VoiceSelector.needsBetterVoiceHint(voice) else { return }
        services.hasShownVoiceHint = true
        assignShowsVoiceHint(true)
    }

    // MARK: The voice path

    /// The voice in use: the duplex engine's, or the simple path's `speak()`.
    var activeSpeaker: LiveSpeaker? { audio?.speaker ?? simple?.speaker }

    static func isHeadset(_ route: LiveAudioEngine.OutputRoute) -> Bool {
        route == .headphones || route == .bluetooth
    }

    /// The simple path may keep its ear open over the voice only when the voice cannot reach
    /// the microphone: wired headphones, or a Bluetooth device that also carries the microphone
    /// (AirPods on `.playAndRecord` with `.allowBluetooth` use HFP both ways). A Bluetooth
    /// speaker (A2DP out, the iPhone's own microphone in) has no echo canceller: half-duplex.
    static func simpleRouteKeepsEchoOut() -> Bool {
        let route = AVAudioSession.sharedInstance().currentRoute
        guard let output = route.outputs.first?.portType else { return false }
        if output == .headphones { return true }
        let bluetooth: [AVAudioSession.Port] = [.bluetoothHFP, .bluetoothLE, .bluetoothA2DP]
        guard bluetooth.contains(output) else { return false }
        return route.inputs.first?.portType != .builtInMic
    }

    /// The simple path's ear waits this long after the voice drained on the loudspeaker.
    static let simpleEchoTail = 0.45

    /// The reducer's options for the path in use. Simple: the recognizer ends each
    /// utterance, and on the loudspeaker the ear is closed while the voice talks.
    func reducerOptions() -> LiveTurnMachine.Options {
        let bargeIn: BargeInMode = (app?.settings.liveBargeIn ?? false) ? .full : .safe
        let voiceOver = UIAccessibility.isVoiceOverRunning
        if simple != nil {
            let halfDuplex = !simpleHeadset && captionOnly == nil
            return .init(bargeInOnSpeaker: bargeIn, turnTaking: halfDuplex || voiceOver, externalEndpointing: true)
        }
        return .init(bargeInOnSpeaker: bargeIn, turnTaking: voiceOver)
    }

    /// Low with headphones or captions only; on the loudspeaker the simple path has no echo canceller.
    func currentEchoRisk() -> EchoRisk {
        if let audio { return audio.engine.echoRisk }
        return simpleHeadset || captionOnly != nil ? .low : .high
    }

    /// Whether the simple path's ear should be open now, from the reducer's state.
    private func simpleEarShouldBeOpen() -> Bool {
        guard isRunning, !isConnecting, !switchingToSimple, recognitionAvailable, !simpleEarFailed, !playbackHolds else { return false }
        let turn = machine.state
        guard !turn.muted, !turn.turnTakingMuted else { return false }
        let halfDuplex = !simpleHeadset && captionOnly == nil
        switch turn.phase {
        case .idle:
            return false
        case .listening, .userSpeaking, .interrupted:
            break
        case .thinking, .acting, .speaking:
            // On the loudspeaker the ear waits for the whole answer: a TV's words while
            // the brain thinks would otherwise count as the user's and cancel the reply.
            if halfDuplex { return false }
        }
        // Half-duplex on the loudspeaker: never while the voice has something to say.
        if halfDuplex, activeSpeaker?.isSpeaking == true { return false }
        return true
    }

    /// Opens or closes the simple path's ear to match the reducer: after every event and
    /// at 50 Hz, so a missed effect can never leave it deaf or listening to the voice.
    func reconcileSimpleEar() {
        guard let simple else { return }
        if simpleEarShouldBeOpen() {
            guard !simple.wantsListening else { return }
            let halfDuplex = !simpleHeadset && captionOnly == nil
            let tail = halfDuplex ? max(0, Self.simpleEchoTail - (clock.now() - voiceDrainedAt)) : 0
            simpleUtteranceOverVoice = nil
            simple.listen(after: tail)
        } else if simple.wantsListening {
            simpleUtteranceOverVoice = nil
            simple.pauseListening()
        }
    }

    func simplePartial(_ text: String) {
        guard isRunning, !isConnecting, simple != nil else { return }
        if simpleUtteranceOverVoice == nil, !text.isEmpty {
            // Recognition lags the sound by a few hundred milliseconds: just after the drain still counts.
            simpleUtteranceOverVoice = activeSpeaker?.isSpeaking == true || clock.now() - voiceDrainedAt < 0.6
        }
        feed(.transcript(TranscriptSnapshot(volatile: text), grammar: nil, at: clock.now()))
    }

    func simpleFinal(_ text: String) {
        guard isRunning, !isConnecting, let simple else { return }
        let now = clock.now()
        let overVoice = simpleUtteranceOverVoice == true
        simpleUtteranceOverVoice = nil
        if overVoice, isEchoOfReply(text), activeSpeaker?.isSpeaking == true || now - voiceDrainedAt < 2 {
            // The voice heard back (a Bluetooth speaker taken for headphones): never the user's turn.
            debugDecision("final dropped: it repeats the reply being spoken")
            feed(.utterance("", at: now))
            return
        }
        if !text.isEmpty { lastVoicedAt = min(simple.lastPartialAt ?? now, now) }
        feed(.utterance(text, at: now))
    }

    /// At least 60% of the final's words (two or more) are words of the current or last reply.
    private func isEchoOfReply(_ text: String) -> Bool {
        let heard = NormalizedUtterance(text).tokens
        guard heard.count >= 2 else { return false }
        // The reply so far, the last one, and the line being heard (a greeting or a filler is not in the replies).
        let reply = Set(NormalizedUtterance((responseChunks + lastResponseChunks + [transcript.assistant]).joined(separator: " ")).tokens)
        guard !reply.isEmpty else { return false }
        let shared = heard.filter { reply.contains($0) }.count
        return Double(shared) >= 0.6 * Double(heard.count)
    }

    /// The ear failed twice in a row: said and shown; a tap on the orb retries it. A recognizer
    /// failure (no on-device recognizer for the language while its model downloads, for example)
    /// says that dictation is unavailable, not that the user is too far.
    private func simpleEarGaveUp(_ message: String) {
        guard isRunning, !simpleEarFailed, let app else { return }
        simpleEarFailed = true
        LiveServices.shared.record(LiveLogEntry(time: clock.now(), event: "voice.failed", fields: ["part": "ear", "reason": String(message.prefix(60))]))
        debugDecision("ear failed twice: \(message)")
        let allowed = VoiceController.permissionsGranted
        let problem: LiveProblem
        if !allowed {
            problem = .noMicrophone
        } else if app.voice.lastFailureWasRecognizer {
            problem = .noSpeechRecognition(language: app.settings.voiceLocale.language.languageCode?.identifier ?? "fr")
        } else {
            problem = .notHearing
        }
        showProblem(problem, action: allowed ? .none : .openSettings, running: true)
        speak(problemText(problem), turn: machine.state.turn)
    }

    /// The speech model downloads (the simple path hears with SFSpeechRecognizer meanwhile):
    /// said on screen. Once it is installed, an ear that gave up tries again by itself.
    private func speechModelInstalling(_ installing: Bool) {
        guard isRunning, simple != nil else { return }
        debugDecision(installing ? "speech model downloading" : "speech model download over")
        if installing {
            showNotice(L("Downloading the speech model…"), isProblem: false)
        } else if simpleEarFailed {
            retrySimpleEar(byTap: false)
        }
    }

    func retrySimpleEar(byTap: Bool = true) {
        guard let simple else { return }
        simpleEarFailed = false
        simple.retry()
        debugDecision(byTap ? "ear retried after a tap" : "ear retried: the speech model is installed")
        if byTap { Haptics.live(.bargeIn) }
        reconcileSimpleEar()
    }

    /// Sound, but no words, three utterances in a row.
    private func nothingRecognized() {
        guard isRunning, !isConnecting, machine.state.phase == .listening else { return }
        LiveServices.shared.record(LiveLogEntry(time: clock.now(), event: "voice.failed", fields: ["part": "ear", "reason": "sound_without_words"]))
        debugDecision("three utterances with sound and no words")
        showProblem(.notHearing, running: true)
        speak(problemText(.notHearing), turn: machine.state.turn)
    }

    private func simpleInterruption(began: Bool, shouldResume: Bool) {
        guard isRunning, !isConnecting, simple != nil else { return }
        debugDecision(began ? "audio interrupted (call, Siri)" : "audio interruption ended\(shouldResume ? ", resuming" : "")")
        feed(.audioInterruption(began: began, shouldResume: shouldResume, at: clock.now()))
    }

    /// Headphones in or out on the simple path: half-duplex on the loudspeaker (and a Bluetooth speaker).
    private func simpleRouteChanged() {
        guard isRunning, simple != nil else { return }
        let route = LiveAudioEngine.currentRoute()
        let headset = Self.simpleRouteKeepsEchoOut()
        guard headset != simpleHeadset else { return }
        simpleHeadset = headset
        machine.setOptions(reducerOptions())
        feed(.routeChanged(currentEchoRisk()))
        debugDecision("route \(route.rawValue): \(headset ? "the ear stays open over the voice" : "half-duplex")")
    }

    /// Any duplex fault (no microphone frames, the engine failed or could not rebuild, the
    /// voice's buffers cleared, a stuck speaker): the conversation moves to the simple
    /// path, shows the problem and says so. It never comes back to duplex by itself.
    func switchToSimple(reason: String) {
        guard isRunning, !isConnecting, !switchingToSimple, audio != nil, let app else { return }
        switchingToSimple = true
        let generation = liveGeneration
        debugDecision("voice path -> simple: \(reason)")
        Diagnostics.shared.note("Live voice path -> simple")
        LiveServices.shared.record(LiveLogEntry(time: clock.now(), event: "live.path_simple", fields: ["reason": String(reason.prefix(60))]))
        // Whatever was answering stops; the reducer waits while the path changes.
        feed(.audioInterruption(began: true, shouldResume: false, at: clock.now()))
        let stack = audio
        audio = nil
        stack?.stop()
        framesExpected = false
        isConnecting = true
        publishState()
        let locale = app.settings.voiceLocale
        Task { @MainActor [weak self] in
            guard let self else { return }
            let started = await self.startSimple(locale: locale, generation: generation)
            self.switchingToSimple = false
            guard started, self.isRunning, self.liveGeneration == generation else { return }
            self.isConnecting = false
            self.assignVoicePath(.simple)
            self.machine.setOptions(self.reducerOptions())
            self.feed(.routeChanged(self.currentEchoRisk()))
            self.feed(.audioInterruption(began: false, shouldResume: true, at: self.clock.now()))
            self.showProblem(.audioFailed, running: true)
            self.speak(LiveLines.line(.micRestarted, self.replyLanguage), turn: self.machine.state.turn)
        }
    }

    /// `speak()` stayed silent, or a speaker was stuck on the simple path: the replies go on
    /// as captions for the rest of this turn (on duplex, the simple path first). The next
    /// committed turn tries the voice again (`restoreVoiceAfterSilence`).
    func voiceWentSilent(_ reason: String) {
        guard isRunning else { return }
        LiveServices.shared.record(LiveLogEntry(time: clock.now(), event: "voice.failed", fields: ["part": "voice", "path": voicePath.rawValue, "reason": String(reason.prefix(60))]))
        debugDecision("voice silent: \(reason)")
        guard !voiceGaveUp, !switchingToSimple else { return }
        if audio != nil {
            switchToSimple(reason: "voice: \(reason)")
            return
        }
        voiceGaveUp = true
        activeSpeaker?.stop(fadeMs: 0)
        captionOnly = CaptionOnlySpeaker { [weak self] turn, signal in self?.speakerSignal(turn, signal) }
        machine.setOptions(reducerOptions())
        feed(.routeChanged(currentEchoRisk()))
        // Speaking is impossible: the problem, and a caption that stays 7 s.
        showProblem(.voiceFailed, running: true)
        showReply(problemText(.voiceFailed), isProblem: true, isError: true)
    }

    /// A new user turn after the voice went silent: the voice is tried again (it may only
    /// have been slow to start). Captions chosen in Settings (liveSpeaks off) stay.
    func restoreVoiceAfterSilence() {
        guard voiceGaveUp else { return }
        voiceGaveUp = false
        captionOnly?.stop()
        captionOnly = nil
        machine.setOptions(reducerOptions())
        feed(.routeChanged(currentEchoRisk()))
        debugDecision("voice tried again for this turn")
    }

    static func errorToken(_ error: Error) -> String {
        if error is LiveDeadline.Expired { return "timeout" }
        if error is CancellationError { return "cancelled" }
        return String(String(describing: type(of: error)).prefix(40))
    }

    // MARK: Stop

    /// Ends the conversation: the reducer's stop effects, then audio, brains and hooks.
    func stopLive(reason: String) {
        let wasRunning = isRunning
        if wasRunning, !isConnecting { feed(.stop) }
        brainTask?.cancel()
        brainTask = nil
        sessionStartWatchdog?.cancel()
        sessionStartWatchdog = nil
        if let turn = brainTurnID {
            interruptBrain(turn: turn, spokenText: responseChunks.joined(separator: " "))
        }
        brainTurnID = nil
        brainTurnKind = nil
        loopTask?.cancel()
        loopTask = nil
        audio?.stop()
        audio = nil
        simple?.stop()
        simple = nil
        switchingToSimple = false
        simpleEarFailed = false
        framesExpected = false
        captionOnly?.stop()
        captionOnly = nil
        removeLifecycleObservers()
        isConnecting = false
        problemState = nil
        pendingCaption = nil
        playbackHolds = false
        assignRunning(false)
        assignActivityTitle(nil)
        meter.reset()
        // The model brain holds its conversation cache: the next Live asks the hub again.
        modelBrain = nil
        assignVoicePath(.simple)
        if let host { host.liveSpeechSuppressed = false }
        VoiceFeedback.shared.isSuppressed = false
        UIApplication.shared.isIdleTimerDisabled = false
        Diagnostics.shared.redactsCommands = false
        var transcriptNow = transcript
        transcriptNow.userPaused = false
        transcriptNow.assistant = ""
        assignTranscript(transcriptNow)
        if let app { assignRoute(Self.restingRoute(app)) }
        publishState()
        if wasRunning {
            LiveServices.shared.record(LiveLogEntry(time: clock.now(), event: "live.end", fields: ["reason": reason]))
            debugDecision("Live ended (\(reason))")
            Diagnostics.shared.note("Live off (\(reason))")
        }
    }

    // MARK: The reducer

    /// Feeds one event to the reducer and runs its effects. Events raised while
    /// effects run (a speaker signal from a stop, for example) wait their turn.
    func feed(_ event: LiveEvent) {
        eventQueue.append(event)
        guard !isFeeding else { return }
        isFeeding = true
        defer { isFeeding = false }
        while !eventQueue.isEmpty {
            let next = eventQueue.removeFirst()
            let before = machine.state
            let effects = machine.handle(next)
            // End-of-turn and barge-in decisions, with the reducer's reasons (never words).
            if let decision = machine.state.lastDecision, decision != before.lastDecision { debugDecision(decision) }
            for effect in effects { run(effect) }
            if before.phase != machine.state.phase { phaseChanged(from: before.phase, to: machine.state.phase) }
        }
        reconcileSimpleEar()
        publishState()
    }

    private func run(_ effect: LiveEffect) {
        switch effect {
        case .openMic:
            if simple != nil {
                reconcileSimpleEar()
                return
            }
            guard let audio else { return }
            // Without recognition (typing only) the microphone flow stays closed.
            let listens = recognitionAvailable
            if !audio.openMicNow(listens) {
                // After a pause or an interruption: the session and a fresh engine first.
                Task { @MainActor in await audio.openMic(listens) }
            }
        case .closeMic:
            if simple != nil {
                reconcileSimpleEar()
                return
            }
            audio?.closeMic()
        case .setInputMuted(let muted):
            if simple != nil {
                // Unmuted after the voice: the ear reopens after the echo tail (reconcile).
                reconcileSimpleEar()
                return
            }
            audio?.setInputMuted(muted)
        case .beginUserTurn(let time):
            accumulator.beginTurn(at: time)
            audio?.transcriber?.beginTurn()
        case .showCaption(let snapshot, let paused):
            pendingCaption = (snapshot, paused)
            flushCaption(force: false)
        case .commitTurn(let id, let text):
            commitTurn(id, text: text)
        case .cancelTurn(let id, let spokenText):
            cancelBrainTurn(id, spokenText: spokenText)
        case .stopSpeaking(let fadeMs):
            activeSpeaker?.stop(fadeMs: fadeMs)
            captionOnly?.stop()
        case .pausePlayback:
            host?.livePausePlayback()
        case .earcon(let earcon):
            audio?.playEarcon(earcon)
        case .haptic(let haptic):
            // No vibration while the user speaks: the microphone would hear it.
            guard state != .hearing, state != .dictating else { return }
            Haptics.live(haptic)
        case .autoPaused:
            Task { @MainActor in
                self.stopLive(reason: "auto-pause")
                self.showNotice(LiveLines.line(.resume, self.replyLanguage), isProblem: false)
            }
        case .turnTimedOut(let id):
            // No answer within the thinking deadline: the turn stops, counts against its brain, and Live says so.
            let kind = activeBrainTurnID == id ? (activeBrainKind ?? currentKind) : currentKind
            let hadOutput = brainProducedOutput
            cancelBrainTurn(id, spokenText: "")
            let error = LiveBrainError.timeout(stage: "turn")
            selector.recordFailure(kind, error, now: clock.now())
            LiveServices.shared.record(LiveLogEntry(time: clock.now(), event: "brain.error", fields: [
                "brain": kind.rawValue, "error": BrainSelector.errorName(error), "before_output": hadOutput ? "0" : "1",
            ]))
            showProblem(.brainTimeout, running: true)
            speak(LiveLines.problem(.brainTimeout, replyLanguage), turn: machine.state.turn)
        case .speakerStuck:
            // A line that never started or never drained: never silent, never stuck.
            LiveServices.shared.record(LiveLogEntry(time: clock.now(), event: "voice.failed", fields: ["part": "voice", "path": voicePath.rawValue, "reason": "speaker_stuck"]))
            if audio != nil {
                switchToSimple(reason: "speaker stuck")
            } else {
                voiceWentSilent("speaker stuck")
            }
        }
    }

    private func phaseChanged(from old: LivePhase, to new: LivePhase) {
        if old == .listening, new == .userSpeaking {
            if brainTurnKind == .sessionStart, let greeting = brainTurnID {
                // The user spoke before the brain's opening line began: it gives way instead of talking over them.
                cancelBrainTurn(greeting, spokenText: "")
                activeSpeaker?.stop(fadeMs: 80)
                captionOnly?.stop()
            }
            // The user started talking: warm what the next turn needs.
            prefetchSnapshot()
        }
    }

    // MARK: Loops

    /// 50 Hz on the main actor: microphone features into the reducer (duplex), a 20 Hz tick,
    /// captions at 20 Hz at most, the meter at 30 Hz and the debug model at 10 Hz.
    private func startLoop() {
        loopTask?.cancel()
        loopTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self, self.isRunning else { return }
                self.loopStep()
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
        }
    }

    private func loopStep() {
        let now = clock.now()
        let playing = host?.liveIsPlaying ?? false
        if playing != playbackHolds { playbackChanged(playing) }
        if let audio {
            let frames = audio.engine.drainFeatures()
            if !frames.isEmpty { lastFrameAt = now }
            for frame in frames {
                trackLevel(frame)
                feed(.audio(frame))
            }
            checkDuplexFrames(audio, now: now)
        }
        if now - lastLoopTick >= 0.05 {
            lastLoopTick = now
            feed(.tick(now))
            flushCaption(force: false)
        }
        reconcileSimpleEar()
        if now - lastMeterPublish >= 1.0 / 30 {
            lastMeterPublish = now
            publishMeter()
        }
        if now - lastDebugPush >= 0.1 {
            lastDebugPush = now
            pushDebug()
        }
    }

    /// Duplex health: while the reducer listens with the microphone open, frames must come.
    /// None for 2.5 s: the engine is deaf, and the simple path takes over.
    private func checkDuplexFrames(_ audio: LiveAudioStack, now: Double) {
        let phase = machine.state.phase
        let expected = !isConnecting && !switchingToSimple && audio.isMicOpen && !audio.engine.isInputMuted
            && (phase == .listening || phase == .userSpeaking)
        if expected, !framesExpected { lastFrameAt = now }
        framesExpected = expected
        guard expected, now - lastFrameAt > 2.5 else { return }
        switchToSimple(reason: "no microphone audio for 2.5 s")
    }

    /// The video's sound is not in the echo canceller's reference: while it plays Live
    /// does not hear (the reducer is muted; the user's own mute is kept apart), and when
    /// it stops a fresh user turn begins, so nothing the soundtrack said becomes the user's.
    private func playbackChanged(_ playing: Bool) {
        playbackHolds = playing
        feed(.mute(isMuted || playing))
        if !playing, machine.state.phase != .userSpeaking {
            accumulator.beginTurn(at: clock.now())
            audio?.transcriber?.beginTurn()
        }
        debugDecision(playing ? "video playing: not hearing" : "video stopped: hearing again")
    }

    /// A slow noise-floor follower for the meter, the latency marks and Diagnostic Live.
    private func trackLevel(_ frame: AudioFrameFeatures) {
        let db = Double(frame.rmsDB)
        levelDB = db
        floorDB += (db < floorDB ? 0.05 : 0.002) * (db - floorDB)
        floorDB = min(max(floorDB, -80), -30)
        if db > max(floorDB + 12, -55) { lastVoicedAt = frame.time }
    }

    private func publishMeter() {
        let t = clock.now()
        // speak() and captions bypass the engine: a gentle pulse while speaking.
        let pulse = state == .speaking ? 0.35 + 0.25 * abs(sin(t * 7.1)) * abs(sin(t * 1.7)) : 0
        if let simple {
            meter.publish(inputTarget: isMuted ? 0 : simple.level, outputTarget: pulse)
            return
        }
        guard let audio else {
            meter.publish(inputTarget: 0, outputTarget: 0)
            return
        }
        let inputTarget = isMuted ? 0 : pow(min(max((levelDB - floorDB - 3) / 36, 0), 1), 0.8)
        var outputTarget = min(max((Double(audio.engine.outputLevelDB) + 50) / 40, 0), 1)
        if audio.speaker.usesSystemSpeech || captionOnly != nil { outputTarget = pulse }
        meter.publish(inputTarget: inputTarget, outputTarget: outputTarget)
    }

    private func pushDebug() {
        let debug = LiveServices.shared.debug
        guard let app, app.settings.liveDebug else {
            debug.isCollecting = false
            return
        }
        debug.isCollecting = true
        debug.pushLevel(aboveFloorDB: max(0, levelDB - floorDB), floorDB: floorDB)
        debug.setVoicePath(voicePath.rawValue)
        let risk = Self.describe(machine.state.echoRisk)
        let bargeIn = machine.state.effectiveBargeIn == .full ? "full" : "safe"
        if let audio {
            debug.setAudio(brain: currentKind.rawValue, echoCancellation: audio.engine.echoCancellationActive, outputRoute: audio.engine.route.rawValue,
                           echoRisk: risk, bargeInMode: bargeIn)
            debug.setVoice(audio.speaker.voiceDescription)
        } else if let simple {
            debug.setAudio(brain: currentKind.rawValue, echoCancellation: false, outputRoute: simpleHeadset ? "headphones" : "speaker",
                           echoRisk: risk, bargeInMode: bargeIn)
            debug.setVoice(captionOnly != nil ? "captions" : simple.speaker.voiceDescription)
        }
    }

    /// Captions go out at 20 Hz at most; a commit flushes at once.
    func flushCaption(force: Bool) {
        guard let pending = pendingCaption else { return }
        let now = clock.now()
        guard force || now - lastCaptionPublish >= 0.05 else { return }
        pendingCaption = nil
        lastCaptionPublish = now
        var next = transcript
        if next.userIsFinal {
            // A new user turn: the previous exchange leaves the caption zone.
            next = LiveTranscript()
            next.turnID = machine.state.turn + 1
        }
        next.user = LiveCaption(stable: pending.snapshot.finalized, volatile: pending.snapshot.volatile)
        next.userPaused = pending.paused
        assignTranscript(next)
    }

    // MARK: Audio events

    func transcriptSegment(_ segment: TranscriptSegment) {
        guard isRunning, !isConnecting, recognitionAvailable else { return }
        let snapshot = accumulator.apply(segment)
        let grammar = snapshot.text.isEmpty ? nil : RuleBasedIntentEngine().parse(snapshot.text, context: intentContext())
        feed(.transcript(snapshot, grammar: grammar, at: clock.now()))
    }

    private func engineEvent(_ event: LiveAudioEngine.Event) {
        guard isRunning else { return }
        switch event {
        case .interrupted(let began, let shouldResume):
            debugDecision(began ? "audio interrupted (call, Siri)" : "audio interruption ended\(shouldResume ? ", resuming" : "")")
            feed(.audioInterruption(began: began, shouldResume: shouldResume, at: clock.now()))
        case .routeChanged(let route, let risk):
            debugDecision("route \(route.rawValue): echo risk \(Self.describe(risk))")
            feed(.routeChanged(risk))
        case .rebuilt:
            debugDecision("audio engine rebuilt")
        case .mediaServicesReset:
            debugDecision("media services reset")
            // speak() (the fallback voice) held a synthesizer that is no longer valid.
            audio?.speaker.resetSystemVoice()
        case .failed(let reason):
            guard !machine.state.paused else { return }
            LiveServices.shared.record(LiveLogEntry(time: clock.now(), event: "audio.failed", fields: ["reason": String(reason.prefix(60))]))
            // A dead microphone or engine is never final: the simple path takes over and says so.
            switchToSimple(reason: "engine failed: \(reason.prefix(40))")
        }
    }

    /// The engine voice moved to speak(): on duplex that is a fault, so the simple path takes over.
    private func speakerFellBack(_ reason: String) {
        debugDecision("voice moved to speak(): \(reason)")
        LiveServices.shared.record(LiveLogEntry(time: clock.now(), event: "speaker.fallback", fields: ["reason": String(reason.prefix(60))]))
        guard audio != nil, let app, !app.settings.liveSpeakerUsesSystem else { return }
        switchToSimple(reason: "voice: \(reason)")
    }

    static func describe(_ risk: EchoRisk) -> String {
        switch risk {
        case .low: return "low"
        case .normal: return "normal"
        case .high: return "high"
        }
    }

    // MARK: App lifecycle

    private func observeLifecycle() {
        guard lifecycleObservers.isEmpty else { return }
        let center = NotificationCenter.default
        lifecycleObservers.append(center.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isRunning, !self.isConnecting else { return }
                self.feed(.appWillResignActive(at: self.clock.now()))
            }
        })
        lifecycleObservers.append(center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                // Back within 60 s: listening again; later, the reducer's autoPaused ends Live.
                guard let self, self.isRunning, !self.isConnecting else { return }
                self.feed(.appDidBecomeActive(at: self.clock.now()))
            }
        })
        lifecycleObservers.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isRunning else { return }
                self.feed(.appDidEnterBackground)
                self.stopLive(reason: "background")
            }
        })
        lifecycleObservers.append(center.addObserver(forName: UIAccessibility.voiceOverStatusDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isRunning else { return }
                self.machine.setOptions(self.reducerOptions())
            }
        })
    }

    private func removeLifecycleObservers() {
        for observer in lifecycleObservers { NotificationCenter.default.removeObserver(observer) }
        lifecycleObservers = []
    }

    // MARK: Dictation (outside Live)

    /// The editor's dictation goes to this session (contract 7.1), claimed at every
    /// dictation start: a session SwiftUI created and threw away never holds it.
    func claimVoice() {
        guard let app, !isTornDown else { return }
        LiveSession.voiceOwner = WeakLiveSession(self)
        app.voice.onFinalTranscript = { [weak self] text in
            guard let self, !self.isTornDown else { return }
            self.dictationFinished(text)
        }
        app.voice.onPartialTranscript = { [weak self] text in
            guard let self, !self.isTornDown else { return }
            self.dictationPartial(text)
        }
    }

    func releaseVoice() {
        guard let app, LiveSession.voiceOwner?.session === self else { return }
        LiveSession.voiceOwner = nil
        app.voice.onFinalTranscript = nil
        app.voice.onPartialTranscript = nil
    }

    func beginDictation(hold: Bool) {
        guard let app, !isTornDown, !isRunning, !isStarting, !isDictating else { return }
        claimVoice()
        dictationIsHold = hold
        dictationStopRequested = false
        app.voice.mode = hold ? .pushToTalk : .tapToTalk
        isDictating = true
        restingPhase = nil
        assignReply(nil)
        var next = LiveTranscript()
        next.turnID = transcript.turnID + 1
        assignTranscript(next)
        publishState()
        app.voice.start()
        dictationTask?.cancel()
        let begun = clock.now()
        dictationTask = Task { @MainActor [weak self] in
            var sawListening = false
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 33_000_000)
                guard let self, self.isDictating, let app = self.app else { return }
                self.meter.publish(inputTarget: app.voice.level, outputTarget: 0)
                let waitedTooLong = !sawListening && self.clock.now() - begun > 4
                switch app.voice.state {
                case .preparing, .finishing:
                    guard waitedTooLong, app.voice.state == .preparing else { continue }
                    self.cancelDictation()
                    return
                case .listening:
                    sawListening = true
                case .unavailable:
                    self.isDictating = false
                    self.meter.reset()
                    self.publishState()
                    let problem: LiveProblem = VoiceController.permissionsGranted ? .noSpeechRecognition(language: app.settings.voiceLocale.language.languageCode?.identifier ?? "fr") : .noMicrophone
                    self.showNotice(self.problemText(problem), isProblem: true, action: VoiceController.permissionsGranted ? .none : .openSettings)
                    return
                case .idle:
                    guard sawListening || self.dictationStopRequested || waitedTooLong else { continue }
                    // Ended with nothing heard: back to rest.
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    guard self.isDictating else { return }
                    self.isDictating = false
                    self.meter.reset()
                    self.publishState()
                    return
                }
            }
        }
    }

    func cancelDictation() {
        guard isDictating else { return }
        isDictating = false
        dictationTask?.cancel()
        dictationTask = nil
        app?.voice.cancel()
        meter.reset()
        publishState()
    }

    private func dictationPartial(_ text: String) {
        guard isDictating else { return }
        var next = transcript
        next.user = LiveCaption(stable: "", volatile: text)
        let now = clock.now()
        guard now - lastCaptionPublish >= 0.05 else { return }
        lastCaptionPublish = now
        assignTranscript(next)
    }

    private func dictationFinished(_ text: String) {
        let wasDictating = isDictating
        isDictating = false
        dictationTask?.cancel()
        dictationTask = nil
        meter.reset()
        if wasDictating {
            var next = transcript
            next.user = LiveCaption(stable: text)
            next.userIsFinal = true
            assignTranscript(next)
        }
        publishState()
        guard !isRunning else { return }
        runRestingCommand(text)
    }
}

/// The session that last claimed app.voice, so a torn-down one only clears its own hooks.
struct WeakLiveSession {
    weak var session: LiveSession?

    init(_ session: LiveSession) {
        self.session = session
    }
}

extension LiveSession {
    @MainActor static var voiceOwner: WeakLiveSession?
}
#endif
