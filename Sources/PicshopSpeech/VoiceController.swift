#if canImport(Speech) && canImport(AVFoundation)
import Foundation
import AVFoundation
import Speech
import Observation
import PicshopCore

/// Captures microphone audio and produces transcripts using the best
/// on-device recogniser available: `SpeechAnalyzer` (iOS 26) with the
/// `SFSpeechRecognizer` on-device mode as fallback. Publishes partial text,
/// input level (for the voice orb) and detects the end of an utterance.
@MainActor
@Observable
public final class VoiceController {
    public enum State: Equatable, Sendable {
        case idle
        case preparing
        case listening
        case finishing
        case unavailable(String)
    }

    public enum Mode: String, Sendable, CaseIterable {
        /// Hold the orb while speaking.
        case pushToTalk
        /// Tap to start, stops automatically after a pause.
        case tapToTalk
        /// Keeps listening for follow-up commands after each result.
        case handsFree
    }

    public private(set) var state: State = .idle {
        didSet {
            // Replies are not spoken into an open microphone.
            VoiceFeedback.shared.isMicrophoneActive = state == .preparing || state == .listening || state == .finishing
        }
    }
    public private(set) var partialTranscript = ""
    public private(set) var level: Double = 0
    public var mode: Mode = .tapToTalk
    /// Read by the next session; each utterance builds its own recogniser.
    public var locale: Locale
    /// Seconds of silence after speech that end an utterance in tap/hands-free modes.
    public var silenceTimeout: TimeInterval = 1.1
    /// Maximum utterance length.
    public var maximumDuration: TimeInterval = 12

    /// Called with the final transcript of each utterance.
    public var onFinalTranscript: ((String) -> Void)?

    /// Replaced after an audio configuration change: a fresh engine picks up the new hardware format.
    private var audioEngine = AVAudioEngine()
    private var engineSession: (any TranscriptionSession)?
    private var silenceTask: Task<Void, Never>?
    private var startedAt: Date?
    private var heardSpeech = false
    private var lastSpeechAt: Date?
    private var levelSmoother = 0.0
    /// Bumped by every start and stop: a session whose number is stale stops touching state or the engine.
    private var generation = 0
    /// True from the moment a session starts ending until the engine and recogniser are released.
    private var isEnding = false
    private var lastRecovery: Date?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    public init(locale: Locale = Locale.current) {
        self.locale = locale
        observeAudioChanges()
    }

    // MARK: - Permissions

    public static func requestPermissions() async -> Bool {
        let microphone = await AVAudioApplication.requestRecordPermission()
        guard microphone else { return false }
        let speech = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in continuation.resume(returning: status) }
        }
        return speech == .authorized
    }

    public static var permissionsGranted: Bool {
        AVAudioApplication.shared.recordPermission == .granted && SFSpeechRecognizer.authorizationStatus() == .authorized
    }

    // MARK: - Control

    public var isListening: Bool { state == .listening || state == .preparing }

    /// False while a session is still starting or being released.
    public var canStart: Bool {
        switch state {
        case .idle, .unavailable: return !isEnding
        case .preparing, .listening, .finishing: return false
        }
    }

    public func toggle() {
        if isListening { stop() } else { start() }
    }

    /// - Parameter waitingForSpeech: an automatic restart (follow-up question, hands-free)
    ///   lets a spoken reply finish first; a tap cuts it so the microphone does not hear it.
    public func start(waitingForSpeech: Bool = false) {
        guard canStart else { return }
        generation += 1
        let current = generation
        state = .preparing
        partialTranscript = ""
        heardSpeech = false
        lastSpeechAt = nil
        startedAt = Date()
        if !waitingForSpeech { VoiceFeedback.shared.stop() }
        Task { await beginSession(generation: current, waitingForSpeech: waitingForSpeech) }
    }

    /// Stops listening; the final transcript is delivered through `onFinalTranscript`.
    public func stop() {
        guard isListening else { return }
        guard state == .listening else {
            // Nothing was heard yet: stopping while preparing is a cancel.
            cancel()
            return
        }
        state = .finishing
        silenceTask?.cancel()
        Task { await endSession(deliver: true) }
    }

    public func cancel() {
        silenceTask?.cancel()
        Task { await endSession(deliver: false) }
    }

    // MARK: - Session lifecycle

    private func beginSession(generation current: Int, waitingForSpeech: Bool) async {
        var granted = Self.permissionsGranted
        if !granted { granted = await Self.requestPermissions() }
        guard current == generation else { return }
        guard granted else {
            state = .unavailable(PicshopError.permissionDenied("the microphone").message)
            return
        }
        if waitingForSpeech {
            await VoiceFeedback.shared.waitUntilFinished()
            guard current == generation else { return }
        }
        var created: (any TranscriptionSession)?
        var tapInstalled = false
        let engine = audioEngine
        do {
            try configureAudioSession()
            let session = try await makeSession()
            created = session
            guard current == generation else { throw CancellationError() }
            try await session.start { [weak self] text, isFinal in
                Task { @MainActor [weak self] in self?.handleResult(text, isFinal: isFinal, generation: current) }
            }
            guard current == generation, engine === audioEngine else { throw CancellationError() }
            // The format is read here, right before the tap, and nowhere earlier: a route change
            // during the awaits above (AirPods, a call, speech playback) makes an earlier read stale,
            // and a tap with a stale or empty format raises an exception Swift cannot catch.
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else {
                throw PicshopError.speechUnavailable("no microphone input")
            }
            session.prepare(inputFormat: format)
            input.removeTap(onBus: 0)
            input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
                let rms = VoiceController.rms(of: buffer)
                Task { @MainActor [weak self] in self?.updateLevel(rms, generation: current) }
                session.append(buffer)
            }
            tapInstalled = true
            engine.prepare()
            try engine.start()
            engineSession = session
            // Timeouts count from when the microphone is really open, not from the tap.
            startedAt = Date()
            state = .listening
            scheduleTimeout()
        } catch {
            if tapInstalled { engine.inputNode.removeTap(onBus: 0) }
            engine.stop()
            if let created { Task { _ = try? await created.finish() } }
            // A newer start or a stop took over: it owns the state now.
            guard current == generation else { return }
            if error is CancellationError {
                state = .idle
                return
            }
            PSLog.error("voice start failed: \(error)", category: .speech)
            state = .unavailable(PicshopError.speechUnavailable(error.localizedDescription).message)
        }
    }

    private func endSession(deliver: Bool) async {
        guard !isEnding else { return }
        isEnding = true
        generation += 1
        let current = generation
        silenceTask?.cancel()
        releaseEngine(rebuild: false)
        let session = engineSession
        engineSession = nil
        var finalText = partialTranscript
        if let session {
            if let text = try? await session.finish(), !text.isEmpty { finalText = text }
        }
        isEnding = false
        level = 0
        levelSmoother = 0
        guard current == generation else { return }
        state = .idle
        let trimmed = finalText.trimmingCharacters(in: .whitespacesAndNewlines)
        partialTranscript = ""
        if deliver, !trimmed.isEmpty {
            onFinalTranscript?(trimmed)
        }
        if deliver, mode == .handsFree, !trimmed.isEmpty {
            // Brief pause, then keep listening once any spoken reply is over.
            try? await Task.sleep(for: .milliseconds(900))
            if state == .idle, current == generation { start(waitingForSpeech: true) }
        }
    }

    /// Removes the tap and stops the engine; after a configuration change the engine is replaced.
    private func releaseEngine(rebuild: Bool) {
        let engine = audioEngine
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        engine.reset()
        if rebuild { audioEngine = AVAudioEngine() }
    }

    // MARK: - Audio interruptions

    private func observeAudioChanges() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .AVAudioEngineConfigurationChange, object: nil, queue: .main) { [weak self] notification in
            let engineID = (notification.object as AnyObject?).map(ObjectIdentifier.init)
            Task { @MainActor [weak self] in
                guard let self, engineID == nil || engineID == ObjectIdentifier(self.audioEngine) else { return }
                self.recoverFromAudioChange("engine configuration changed", restart: true)
            }
        })
        #if os(iOS) || os(tvOS) || os(visionOS)
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] notification in
            let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            guard raw.flatMap(AVAudioSession.InterruptionType.init(rawValue:)) == .began else { return }
            Task { @MainActor [weak self] in self?.recoverFromAudioChange("audio interrupted", restart: false) }
        })
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] notification in
            let raw = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            // Only a device coming or going changes the input format; our own category changes do not.
            guard let reason = raw.flatMap(AVAudioSession.RouteChangeReason.init(rawValue:)),
                  reason == .newDeviceAvailable || reason == .oldDeviceUnavailable else { return }
            Task { @MainActor [weak self] in self?.recoverFromAudioChange("audio route changed", restart: true) }
        })
        #endif
    }

    /// The hardware changed under a live session: drop it without delivering half a
    /// sentence, rebuild the engine, and listen again only if it was listening.
    private func recoverFromAudioChange(_ reason: String, restart: Bool) {
        guard !isEnding else { return }
        guard state == .listening else {
            // Idle: nothing to stop, but a fresh engine drops the old hardware format. While
            // preparing, the format is read just before the tap, after this change.
            if state == .idle { audioEngine = AVAudioEngine() }
            return
        }
        PSLog.info("voice: \(reason), restarting the microphone", category: .speech)
        silenceTask?.cancel()
        let now = Date()
        // Restart at most once every few seconds, so a flapping route cannot loop.
        let mayRestart = restart && (lastRecovery.map { now.timeIntervalSince($0) > 3 } ?? true)
        lastRecovery = now
        Task {
            await endSession(deliver: false)
            releaseEngine(rebuild: true)
            let after = generation
            guard mayRestart else { return }
            try? await Task.sleep(for: .milliseconds(350))
            if state == .idle, after == generation { start(waitingForSpeech: true) }
        }
    }

    private func handleResult(_ text: String, isFinal: Bool, generation current: Int) {
        guard current == generation else { return }
        partialTranscript = text
        if !text.isEmpty {
            heardSpeech = true
            lastSpeechAt = Date()
        }
        if isFinal, state == .listening, mode != .pushToTalk {
            stop()
        }
    }

    private func updateLevel(_ rms: Double, generation current: Int) {
        guard current == generation, state == .listening else { return }
        // Map RMS (≈0…0.3 for speech) to 0…1 with smoothing for the orb animation.
        let target = min(1, pow(rms * 6, 0.7))
        levelSmoother = levelSmoother * 0.6 + target * 0.4
        level = levelSmoother
        if target > 0.12 {
            heardSpeech = true
            lastSpeechAt = Date()
        }
    }

    private func scheduleTimeout() {
        silenceTask?.cancel()
        silenceTask = Task { [weak self] in
            while let self, !Task.isCancelled, self.state == .listening {
                try? await Task.sleep(for: .milliseconds(150))
                guard self.mode != .pushToTalk else { continue }
                let now = Date()
                if let started = self.startedAt, now.timeIntervalSince(started) > self.maximumDuration {
                    self.stop()
                    return
                }
                if self.heardSpeech, let last = self.lastSpeechAt, now.timeIntervalSince(last) > self.silenceTimeout {
                    self.stop()
                    return
                }
                if !self.heardSpeech, let started = self.startedAt, now.timeIntervalSince(started) > 6 {
                    // Nothing heard at all.
                    self.cancel()
                    return
                }
            }
        }
    }

    private func configureAudioSession() throws {
        #if os(iOS) || os(tvOS) || os(visionOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker, .duckOthers])
        try session.setActive(true, options: [])
        #endif
    }

    /// A fresh recogniser per utterance; its converter is built later from the tap's format.
    private func makeSession() async throws -> any TranscriptionSession {
        if #available(iOS 26.0, macOS 26.0, *) {
            if await AnalyzerTranscriptionSession.isSupported(locale: locale) {
                return try await AnalyzerTranscriptionSession(locale: locale)
            }
        }
        return try LegacyTranscriptionSession(locale: locale)
    }

    nonisolated static func rms(of buffer: AVAudioPCMBuffer) -> Double {
        guard let data = buffer.floatChannelData?[0] else { return 0 }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<count { sum += data[i] * data[i] }
        return Double((sum / Float(count)).squareRoot())
    }
}

// MARK: - Sessions

protocol TranscriptionSession: AnyObject, Sendable {
    func start(onResult: @escaping @Sendable (String, Bool) -> Void) async throws
    /// The microphone format, read right before the tap is installed.
    func prepare(inputFormat: AVAudioFormat)
    /// Called on the realtime audio thread.
    func append(_ buffer: AVAudioPCMBuffer)
    /// Finishes recognition and returns the best final transcript.
    func finish() async throws -> String
}

/// iOS 26 `SpeechAnalyzer` session: fully on-device, streaming, multilingual.
@available(iOS 26.0, macOS 26.0, *)
final class AnalyzerTranscriptionSession: TranscriptionSession, @unchecked Sendable {
    private let transcriber: SpeechTranscriber
    private let analyzer: SpeechAnalyzer
    private let analyzerFormat: AVAudioFormat?
    /// Guarded by `lock`: `append` runs on the audio thread while `finish` runs elsewhere.
    private var converter: AVAudioConverter?
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?
    private let lock = NSLock()
    private var latest = ""
    private var finalText = ""

    static func isSupported(locale: Locale) async -> Bool {
        let supported = await SpeechTranscriber.supportedLocales
        return supported.contains { $0.identifier(.bcp47) == locale.identifier(.bcp47) || $0.language.languageCode == locale.language.languageCode }
    }

    init(locale: Locale) async throws {
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [.volatileResults], attributeOptions: [])
        self.transcriber = transcriber
        analyzer = SpeechAnalyzer(modules: [transcriber])
        let installation = try await AssetInventory.assetInstallationRequest(supporting: [transcriber])
        if let installation {
            try await installation.downloadAndInstall()
        }
        analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
    }

    func prepare(inputFormat: AVAudioFormat) {
        let converter = Self.converter(from: inputFormat, to: analyzerFormat)
        lock.withLock { self.converter = converter }
    }

    private static func converter(from input: AVAudioFormat, to output: AVAudioFormat?) -> AVAudioConverter? {
        guard let output, input.sampleRate > 0, input.channelCount > 0, input != output else { return nil }
        return AVAudioConverter(from: input, to: output)
    }

    func start(onResult: @escaping @Sendable (String, Bool) -> Void) async throws {
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        lock.withLock { self.continuation = continuation }
        resultsTask = Task { [transcriber, weak self] in
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                    guard let self else { return }
                    let snapshot: String = self.lock.withLock {
                        if result.isFinal {
                            self.finalText += (self.finalText.isEmpty ? "" : " ") + text
                            self.latest = self.finalText
                        } else {
                            self.latest = self.finalText.isEmpty ? text : self.finalText + " " + text
                        }
                        return self.latest
                    }
                    onResult(snapshot, false)
                }
            } catch {
                PSLog.error("analyzer results ended: \(error)", category: .speech)
            }
        }
        try await analyzer.start(inputSequence: stream)
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        let inputFormat = buffer.format
        guard buffer.frameLength > 0, inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else { return }
        // One snapshot per buffer; a buffer in a new format (route change) gets a new converter.
        let (continuation, converter): (AsyncStream<AnalyzerInput>.Continuation?, AVAudioConverter?) = lock.withLock {
            if let current = self.converter, current.inputFormat != inputFormat {
                self.converter = Self.converter(from: inputFormat, to: analyzerFormat)
            } else if self.converter == nil, let analyzerFormat, analyzerFormat != inputFormat {
                self.converter = Self.converter(from: inputFormat, to: analyzerFormat)
            }
            return (self.continuation, self.converter)
        }
        guard let continuation else { return }
        if let converter, let analyzerFormat {
            let ratio = analyzerFormat.sampleRate / inputFormat.sampleRate
            guard ratio.isFinite, ratio > 0 else { return }
            let capacity = AVAudioFrameCount(min(Double(UInt32.max / 2), (Double(buffer.frameLength) * ratio).rounded(.up))) + 32
            guard let converted = AVAudioPCMBuffer(pcmFormat: analyzerFormat, frameCapacity: capacity) else { return }
            var consumed = false
            var error: NSError?
            converter.convert(to: converted, error: &error) { _, status in
                if consumed {
                    status.pointee = .noDataNow
                    return nil
                }
                consumed = true
                status.pointee = .haveData
                return buffer
            }
            if error == nil, converted.frameLength > 0 {
                continuation.yield(AnalyzerInput(buffer: converted))
            }
        } else if analyzerFormat == nil || analyzerFormat == inputFormat {
            continuation.yield(AnalyzerInput(buffer: buffer))
        }
    }

    func finish() async throws -> String {
        let continuation: AsyncStream<AnalyzerInput>.Continuation? = lock.withLock {
            defer { self.continuation = nil }
            return self.continuation
        }
        continuation?.finish()
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        resultsTask?.cancel()
        return lock.withLock { latest }
    }
}

/// `SFSpeechRecognizer` session (on-device when the language supports it).
final class LegacyTranscriptionSession: TranscriptionSession, @unchecked Sendable {
    private let recognizer: SFSpeechRecognizer
    private let request = SFSpeechAudioBufferRecognitionRequest()
    private var task: SFSpeechRecognitionTask?
    private let lock = NSLock()
    private var latest = ""
    private var finalContinuation: CheckedContinuation<String, Never>?

    init(locale: Locale) throws {
        guard let recognizer = SFSpeechRecognizer(locale: locale) ?? SFSpeechRecognizer() else {
            throw PicshopError.speechUnavailable("no recogniser for \(locale.identifier)")
        }
        self.recognizer = recognizer
        request.shouldReportPartialResults = true
        request.taskHint = .search
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }
        if #available(iOS 16.0, *) {
            request.addsPunctuation = false
        }
    }

    func start(onResult: @escaping @Sendable (String, Bool) -> Void) async throws {
        guard recognizer.isAvailable else { throw PicshopError.speechUnavailable("recogniser unavailable") }
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            if let result {
                let text = result.bestTranscription.formattedString
                self.lock.lock()
                self.latest = text
                let continuation = result.isFinal ? self.finalContinuation : nil
                if result.isFinal { self.finalContinuation = nil }
                self.lock.unlock()
                onResult(text, result.isFinal)
                continuation?.resume(returning: text)
            }
            if error != nil {
                self.lock.lock()
                let continuation = self.finalContinuation
                self.finalContinuation = nil
                let text = self.latest
                self.lock.unlock()
                continuation?.resume(returning: text)
            }
        }
    }

    func prepare(inputFormat: AVAudioFormat) {}

    func append(_ buffer: AVAudioPCMBuffer) {
        guard buffer.frameLength > 0 else { return }
        request.append(buffer)
    }

    func finish() async throws -> String {
        request.endAudio()
        let text: String = await withCheckedContinuation { continuation in
            lock.lock()
            finalContinuation = continuation
            lock.unlock()
            // Guard against recognisers that never send a final result.
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(1.5))
                guard let self else { return }
                let (pending, latest) = self.lock.withLock {
                    let pending = self.finalContinuation
                    self.finalContinuation = nil
                    return (pending, self.latest)
                }
                pending?.resume(returning: latest)
            }
        }
        task?.cancel()
        return text
    }
}
#endif
