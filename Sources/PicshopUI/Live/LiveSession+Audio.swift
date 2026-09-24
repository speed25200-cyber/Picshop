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

    /// start(), then again after the consent sheet: permissions, consent, then connect.
    func beginLive(consentResolved: Bool) async {
        guard let app, host != nil, !isTornDown, !isRunning, !isStarting else { return }
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
            return
        }
        if microphone == .undetermined {
            microphoneAskedThisTime = true
            let granted = await AVAudioApplication.requestRecordPermission()
            guard granted else {
                restingPhase = nil
                showProblem(.noMicrophone, action: .allowMicrophone, running: false)
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

        // Consent (cross-owner rule 4): before the first request that carries user content.
        // On a cold launch the saved key may still be loading from the Keychain.
        let keyStore = LiveServices.shared.keyStore
        await keyStore.waitUntilLoaded()
        guard !isTornDown else { return }
        let settings = app.settings
        let claudeWouldRun = keyStore.hasKey && settings.liveUseClaude && !claudeForcedOff
            && LiveServices.shared.reachability.isOnline && selector.claudeDisabledReason == nil
        if !consentResolved, claudeWouldRun, !settings.hasLiveConsent, settings.liveConsentVersion >= 0 {
            assignNeedsConsent(true)
            return
        }
        await connect()
    }

    /// State .connecting until the audio and the recognizer are ready; target 400 ms once models are installed.
    private func connect() async {
        guard let app, let host else { return }
        let settings = app.settings
        let services = LiveServices.shared
        let startedAt = clock.now()
        liveGeneration += 1
        assignRunning(true)
        isConnecting = true
        publishState()
        services.beginSession()
        services.debug.isCollecting = settings.liveDebug
        machine.setOptions(.init(bargeInOnSpeaker: settings.liveBargeIn ? .full : .safe, turnTaking: UIAccessibility.isVoiceOverRunning))
        accumulator = TranscriptAccumulator()
        assignMuted(false)
        firstAudioMarked = []
        playbackHolds = false
        playbackTurn = nil
        sinceLastReply = []
        interruptedAfter = nil
        responseChunks = []
        var routeNow = route
        routeNow.sharesMedia = false
        routeNow.imagesSent = 0
        routeNow.isUploading = false
        assignRoute(routeNow)

        // Nothing else speaks or listens while Live owns the audio.
        host.liveSpeechSuppressed = true
        VoiceFeedback.shared.isSuppressed = true
        VoiceFeedback.shared.stop()
        if app.voice.isListening || app.voice.state == .finishing { app.voice.cancel() }
        UIApplication.shared.isIdleTimerDisabled = true
        Diagnostics.shared.redactsCommands = true
        observeLifecycle()

        // Audio and recognition, with the brains prepared in parallel.
        let stack = LiveAudioStack()
        audio = stack
        stack.onSegment = { [weak self] segment in self?.transcriptSegment(segment) }
        stack.onEngineEvent = { [weak self] event in self?.engineEvent(event) }
        stack.speaker.onSignal = { [weak self] turn, signal in self?.speakerSignal(turn, signal) }
        stack.speaker.onFallback = { [weak self] reason in self?.speakerFellBack(reason) }
        stack.speaker.rateMultiplier = settings.liveRate
        stack.speaker.preferredVoices = ["fr": settings.liveVoiceFR, "en": settings.liveVoiceEN].compactMapValues { $0 }
        if settings.liveSpeakerUsesSystem { stack.speaker.setUsesSystemSpeech(true) }
        captionOnly = settings.liveSpeaks ? nil : CaptionOnlySpeaker { [weak self] turn, signal in self?.speakerSignal(turn, signal) }
        let locale = settings.voiceLocale
        replyLanguage = locale.language.languageCode?.identifier == "fr" ? .french : .english
        stack.speaker.warmUp(languages: [replyLanguage == .french ? "fr" : "en"])

        let brains = Task { @MainActor in await self.prepareBrains() }
        let recognizer: Bool
        do {
            recognizer = try await stack.start(hdBluetooth: settings.liveHDBluetooth, locale: locale) { [weak self] in
                Task { @MainActor [weak self] in
                    self?.showNotice(L("Downloading the speech model…"), isProblem: false)
                }
            }
        } catch {
            PSLog.error("live: audio did not start: \(error)", category: .speech)
            brains.cancel()
            services.record(LiveLogEntry(time: clock.now(), event: "live.audio_failed", fields: ["error": String(describing: type(of: error))]))
            stopLive(reason: "audio failed")
            showProblem(.noMicrophone, action: .none, running: false)
            return
        }
        await brains.value
        guard isRunning, audio === stack else { return }
        isConnecting = false
        recognitionAvailable = recognitionAvailable && recognizer
        if notice?.isProblem == false { assignNotice(nil) }

        // The reducer starts listening: openMic, beginUserTurn, the open earcon and haptic.
        feed(.start(at: clock.now()))
        feed(.routeChanged(stack.engine.echoRisk))
        if !recognitionAvailable {
            // Typing still works; the voice still answers.
            let code = locale.language.languageCode?.identifier ?? "fr"
            showNotice(problemText(.noSpeechRecognition(language: code)), isProblem: true)
        }
        startLoop()
        offerVoiceHintIfNeeded()
        let elapsed = Int((clock.now() - startedAt) * 1000)
        services.record(LiveLogEntry(time: clock.now(), event: "live.start", fields: [
            "brain": currentKind.rawValue, "connect_ms": String(elapsed), "recognizer": audio?.transcriber?.engineName ?? "none",
            "echo_cancellation": stack.engine.echoCancellationActive ? "on" : "off", "route": stack.engine.route.rawValue,
        ]))
        debugDecision("Live started in \(elapsed) ms · \(currentKind.rawValue) · \(stack.engine.route.rawValue)")

        // The first turn: Claude greets and proposes ideas, the others greet locally.
        currentKind = chooseBrain()
        assignRoute(brain: badge(for: currentKind))
        if currentKind == .claude {
            startBrainTurn(id: machine.state.turn, kind: .sessionStart, text: "", isQuestion: false)
        } else {
            if settings.liveUseClaude, LiveServices.shared.keyStore.hasKey, !LiveServices.shared.reachability.isOnline {
                showNotice(problemText(.offline), isProblem: true)
            }
            speak(LiveLines.line(.greetingLocal, replyLanguage), turn: machine.state.turn)
        }
    }

    /// Claude (key read once), the on-device model, and the local router.
    private func prepareBrains() async {
        guard let app else { return }
        let settings = app.settings
        localBrain = LocalLiveBrain(router: app.router, mode: mode)
        #if canImport(FoundationModels)
        if onDeviceBrain == nil {
            onDeviceBrain = FoundationModelsLiveBrain(mode: mode)
        }
        #endif
        if let onDeviceBrain {
            onDeviceAvailable = await onDeviceBrain.isAvailable()
            if onDeviceAvailable { Task.detached(priority: .utility) { await onDeviceBrain.warmUp() } }
        }
        let keyStore = LiveServices.shared.keyStore
        guard keyStore.hasKey, settings.liveUseClaude, settings.hasLiveConsent, !claudeForcedOff else {
            claudeBrain = nil
            return
        }
        guard let key = await keyStore.readKey(), APIKeyFormat.looksValid(key), isRunning else {
            claudeBrain = nil
            return
        }
        let transport = LiveServices.makeTransport { [weak self] event in
            Task { @MainActor [weak self] in self?.imageUpload(event) }
        }
        claudeKey = key
        claudeTransport = transport
        let brain = ClaudeLiveBrain(mode: mode, apiKey: key, transport: transport, clock: clock, log: LiveServices.shared.logSink)
        claudeBrain = brain
        if LiveServices.shared.reachability.isOnline {
            // Writes the tools + system cache entry and opens the HTTP/2 connection.
            Task.detached(priority: .userInitiated) { await brain.warmUp() }
        }
        #if DEBUG
        if !keyStore.verifyKeychainAttributes() {
            debugDecision("Keychain item attributes differ from D7")
        }
        #endif
    }

    /// The one-time better-voice card, when the best installed voice for the language is standard quality.
    private func offerVoiceHintIfNeeded() {
        let services = LiveServices.shared
        let code = replyLanguage == .french ? "fr-FR" : "en-US"
        let preferred = replyLanguage == .french ? app?.settings.liveVoiceFR : app?.settings.liveVoiceEN
        let voice = SystemVoices.best(for: code, preferredIdentifier: preferred)
        services.debug.setVoice(audio?.speaker.voiceDescription ?? voice.map { "\($0.name) (\($0.language))" } ?? "system default")
        guard !services.hasShownVoiceHint, VoiceSelector.needsBetterVoiceHint(voice) else { return }
        services.hasShownVoiceHint = true
        assignShowsVoiceHint(true)
    }

    // MARK: Stop

    /// Ends the conversation: the reducer's stop effects, then audio, brains and hooks.
    func stopLive(reason: String) {
        let wasRunning = isRunning
        if wasRunning, !isConnecting { feed(.stop) }
        brainTask?.cancel()
        brainTask = nil
        if let turn = brainTurnID {
            interruptBrain(turn: turn, spokenText: responseChunks.joined(separator: " "))
        }
        brainTurnID = nil
        brainTurnKind = nil
        loopTask?.cancel()
        loopTask = nil
        audio?.stop()
        audio = nil
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
        claudeKey = nil
        claudeBrain = nil
        claudeTransport = nil
        if let host { host.liveSpeechSuppressed = false }
        VoiceFeedback.shared.isSuppressed = false
        UIApplication.shared.isIdleTimerDisabled = false
        Diagnostics.shared.redactsCommands = false
        var transcriptNow = transcript
        transcriptNow.userPaused = false
        transcriptNow.assistant = ""
        assignTranscript(transcriptNow)
        var routeNow = route
        routeNow.isUploading = false
        if let app { routeNow.brain = Self.localBadge(app) }
        assignRoute(routeNow)
        publishState()
        if wasRunning {
            LiveServices.shared.record(LiveLogEntry(time: clock.now(), event: "live.end", fields: ["reason": reason]))
            debugDecision("Live ended (\(reason))")
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
        publishState()
    }

    private func run(_ effect: LiveEffect) {
        switch effect {
        case .openMic:
            guard let audio else { return }
            // Without recognition (typing only) the microphone flow stays closed.
            let listens = recognitionAvailable
            if !audio.openMicNow(listens) {
                // After a pause or an interruption: the session and a fresh engine first.
                Task { @MainActor in await audio.openMic(listens) }
            }
        case .closeMic:
            audio?.closeMic()
        case .setInputMuted(let muted):
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
            audio?.speaker.stop(fadeMs: fadeMs)
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
        }
    }

    private func phaseChanged(from old: LivePhase, to new: LivePhase) {
        if old == .listening, new == .userSpeaking {
            if brainTurnKind == .sessionStart, let greeting = brainTurnID {
                // The user spoke before Claude's greeting began: it gives way instead of talking over them.
                cancelBrainTurn(greeting, spokenText: "")
                audio?.speaker.stop(fadeMs: 80)
                captionOnly?.stop()
            }
            // The user started talking: warm what the next turn needs.
            prefetchSnapshot()
            preconnectIfIdle()
        }
    }

    // MARK: Loops

    /// 50 Hz on the main actor: microphone features into the reducer, a 20 Hz tick,
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
            for frame in audio.engine.drainFeatures() {
                trackLevel(frame)
                feed(.audio(frame))
            }
        }
        if now - lastLoopTick >= 0.05 {
            lastLoopTick = now
            feed(.tick(now))
            flushCaption(force: false)
        }
        if now - lastMeterPublish >= 1.0 / 30 {
            lastMeterPublish = now
            publishMeter()
        }
        if now - lastDebugPush >= 0.1 {
            lastDebugPush = now
            pushDebug()
        }
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
        guard let audio else {
            meter.publish(inputTarget: 0, outputTarget: 0)
            return
        }
        let inputTarget = isMuted ? 0 : pow(min(max((levelDB - floorDB - 3) / 36, 0), 1), 0.8)
        var outputTarget = min(max((Double(audio.engine.outputLevelDB) + 50) / 40, 0), 1)
        if audio.speaker.usesSystemSpeech || captionOnly != nil {
            // speak() and captions-only bypass the engine: a gentle pulse while speaking.
            let t = clock.now()
            outputTarget = state == .speaking ? 0.35 + 0.25 * abs(sin(t * 7.1)) * abs(sin(t * 1.7)) : 0
        }
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
        if let audio {
            let risk: String
            switch machine.state.echoRisk {
            case .low: risk = "low"
            case .normal: risk = "normal"
            case .high: risk = "high"
            }
            debug.setAudio(brain: currentKind.rawValue, echoCancellation: audio.engine.echoCancellationActive, outputRoute: audio.engine.route.rawValue,
                           echoRisk: risk, bargeInMode: machine.state.effectiveBargeIn == .full ? "full" : "safe")
            debug.setVoice(audio.speaker.voiceDescription)
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
        case .failed(let reason):
            guard !machine.state.paused else { return }
            LiveServices.shared.record(LiveLogEntry(time: clock.now(), event: "audio.failed", fields: ["reason": String(reason.prefix(60))]))
            showProblem(.unavailable("audio"), action: .none, running: true)
        }
    }

    private func speakerFellBack(_ reason: String) {
        debugDecision("voice moved to speak(): \(reason); echo risk high")
        LiveServices.shared.record(LiveLogEntry(time: clock.now(), event: "speaker.fallback", fields: ["reason": String(reason.prefix(60))]))
        if let audio { feed(.routeChanged(audio.engine.echoRisk)) }
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
                guard let self, let app = self.app else { return }
                self.machine.setOptions(.init(bargeInOnSpeaker: app.settings.liveBargeIn ? .full : .safe, turnTaking: UIAccessibility.isVoiceOverRunning))
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
