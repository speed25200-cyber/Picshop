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

    public private(set) var state: State = .idle
    public private(set) var partialTranscript = ""
    public private(set) var level: Double = 0
    public var mode: Mode = .tapToTalk
    public var locale: Locale {
        didSet { if locale != oldValue { engineSession = nil } }
    }
    /// Seconds of silence after speech that end an utterance in tap/hands-free modes.
    public var silenceTimeout: TimeInterval = 1.1
    /// Maximum utterance length.
    public var maximumDuration: TimeInterval = 12

    /// Called with the final transcript of each utterance.
    public var onFinalTranscript: ((String) -> Void)?

    private let audioEngine = AVAudioEngine()
    private var engineSession: (any TranscriptionSession)?
    private var silenceTask: Task<Void, Never>?
    private var startedAt: Date?
    private var heardSpeech = false
    private var lastSpeechAt: Date?
    private var levelSmoother = 0.0

    public init(locale: Locale = Locale.current) {
        self.locale = locale
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

    public func toggle() {
        if isListening { stop() } else { start() }
    }

    public func start() {
        guard !isListening else { return }
        state = .preparing
        partialTranscript = ""
        heardSpeech = false
        lastSpeechAt = nil
        startedAt = Date()
        Task { await beginSession() }
    }

    /// Stops listening; the final transcript is delivered through `onFinalTranscript`.
    public func stop() {
        guard isListening else { return }
        state = .finishing
        silenceTask?.cancel()
        Task { await endSession(deliver: true) }
    }

    public func cancel() {
        silenceTask?.cancel()
        Task { await endSession(deliver: false) }
    }

    // MARK: - Session lifecycle

    private func beginSession() async {
        guard Self.permissionsGranted || (await Self.requestPermissions()) else {
            state = .unavailable(PicshopError.permissionDenied("the microphone").message)
            return
        }
        do {
            try configureAudioSession()
            let session = try await makeSession()
            engineSession = session
            let input = audioEngine.inputNode
            let format = input.outputFormat(forBus: 0)
            input.removeTap(onBus: 0)
            input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
                let rms = VoiceController.rms(of: buffer)
                Task { @MainActor [weak self] in self?.updateLevel(rms) }
                session.append(buffer)
            }
            audioEngine.prepare()
            try audioEngine.start()
            try await session.start { [weak self] text, isFinal in
                Task { @MainActor [weak self] in self?.handleResult(text, isFinal: isFinal) }
            }
            state = .listening
            scheduleTimeout()
        } catch {
            PSLog.error("voice start failed: \(error)", category: .speech)
            audioEngine.inputNode.removeTap(onBus: 0)
            audioEngine.stop()
            state = .unavailable(PicshopError.speechUnavailable(error.localizedDescription).message)
        }
    }

    private func endSession(deliver: Bool) async {
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        let session = engineSession
        engineSession = nil
        var finalText = partialTranscript
        if let session {
            if let text = try? await session.finish(), !text.isEmpty { finalText = text }
        }
        level = 0
        state = .idle
        let trimmed = finalText.trimmingCharacters(in: .whitespacesAndNewlines)
        if deliver, !trimmed.isEmpty {
            onFinalTranscript?(trimmed)
        }
        partialTranscript = ""
        if deliver, mode == .handsFree, !trimmed.isEmpty {
            // Brief pause so spoken feedback isn't transcribed, then keep listening.
            try? await Task.sleep(for: .milliseconds(900))
            if state == .idle { start() }
        }
    }

    private func handleResult(_ text: String, isFinal: Bool) {
        partialTranscript = text
        if !text.isEmpty {
            heardSpeech = true
            lastSpeechAt = Date()
        }
        if isFinal, state == .listening, mode != .pushToTalk {
            stop()
        }
    }

    private func updateLevel(_ rms: Double) {
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
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker, .duckOthers])
        try session.setActive(true, options: [])
    }

    private func makeSession() async throws -> any TranscriptionSession {
        if let existing = engineSession { return existing }
        if #available(iOS 26.0, macOS 26.0, *) {
            if await AnalyzerTranscriptionSession.isSupported(locale: locale) {
                return try await AnalyzerTranscriptionSession(locale: locale, inputFormat: audioEngine.inputNode.outputFormat(forBus: 0))
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
    func append(_ buffer: AVAudioPCMBuffer)
    /// Finishes recognition and returns the best final transcript.
    func finish() async throws -> String
}

/// iOS 26 `SpeechAnalyzer` session: fully on-device, streaming, multilingual.
@available(iOS 26.0, macOS 26.0, *)
final class AnalyzerTranscriptionSession: TranscriptionSession, @unchecked Sendable {
    private let transcriber: SpeechTranscriber
    private let analyzer: SpeechAnalyzer
    private let inputFormat: AVAudioFormat
    private var analyzerFormat: AVAudioFormat?
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

    init(locale: Locale, inputFormat: AVAudioFormat) async throws {
        transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [.volatileResults], attributeOptions: [])
        analyzer = SpeechAnalyzer(modules: [transcriber])
        self.inputFormat = inputFormat
        let installation = try await AssetInventory.assetInstallationRequest(supporting: [transcriber])
        if let installation {
            try await installation.downloadAndInstall()
        }
        analyzerFormat = await SpeechTranscriber.bestAvailableAudioFormat(compatibleWith: [transcriber])
        if let analyzerFormat, analyzerFormat != inputFormat {
            converter = AVAudioConverter(from: inputFormat, to: analyzerFormat)
        }
    }

    func start(onResult: @escaping @Sendable (String, Bool) -> Void) async throws {
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        self.continuation = continuation
        resultsTask = Task { [transcriber, weak self] in
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                    guard let self else { return }
                    self.lock.lock()
                    if result.isFinal {
                        self.finalText += (self.finalText.isEmpty ? "" : " ") + text
                        self.latest = self.finalText
                    } else {
                        self.latest = self.finalText.isEmpty ? text : self.finalText + " " + text
                    }
                    let snapshot = self.latest
                    self.lock.unlock()
                    onResult(snapshot, false)
                }
            } catch {
                PSLog.error("analyzer results ended: \(error)", category: .speech)
            }
        }
        try await analyzer.start(inputSequence: stream)
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        guard let continuation else { return }
        if let converter, let analyzerFormat {
            let ratio = analyzerFormat.sampleRate / inputFormat.sampleRate
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
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
        } else {
            continuation.yield(AnalyzerInput(buffer: buffer))
        }
    }

    func finish() async throws -> String {
        continuation?.finish()
        continuation = nil
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        resultsTask?.cancel()
        lock.lock()
        defer { lock.unlock() }
        return latest
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

    func append(_ buffer: AVAudioPCMBuffer) {
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
                self.lock.lock()
                let pending = self.finalContinuation
                self.finalContinuation = nil
                let latest = self.latest
                self.lock.unlock()
                pending?.resume(returning: latest)
            }
        }
        task?.cancel()
        return text
    }
}
#endif
