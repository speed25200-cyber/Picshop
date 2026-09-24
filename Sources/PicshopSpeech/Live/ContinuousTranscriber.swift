#if canImport(Speech) && canImport(AVFoundation)
import Foundation
import AVFoundation
import CoreMedia
import Speech
import PicshopCore
import PicshopIntent

/// Live's speech recognition: one recognizer for the whole conversation, fed
/// every microphone buffer, yielding volatile and final segments timed on the
/// monotonic clock Live's reducer uses (ProcessInfo.systemUptime).
public protocol LiveTranscribing: AnyObject, Sendable {
    var segments: AsyncStream<TranscriptSegment> { get }
    func start() async throws
    /// Tap thread. `uptime` is when the buffer arrived.
    func append(_ buffer: AVAudioPCMBuffer, uptime: Double)
    /// A user turn begins (after a commit or a barge-in).
    func beginTurn()
    func stop() async
    /// "SpeechAnalyzer" or "SFSpeechRecognizer", for Diagnostic Live.
    var engineName: String { get }
}

/// Picks the recognizer for a Live session.
public enum LiveTranscriberFactory {
    /// SpeechAnalyzer when the locale is supported (its model installed first, with
    /// `installing` called when a download is needed), else the on-device
    /// SFSpeechRecognizer, else nil: Live then works by typing only.
    /// The locale is resolved with `SpeechTranscriber.supportedLocale(equivalentTo:)`; a model
    /// still downloading after 6 s keeps downloading while SFSpeechRecognizer takes this session.
    public static func make(locale: Locale, installing: @escaping @Sendable () -> Void) async -> (any LiveTranscribing)? {
        if #available(iOS 26.0, macOS 26.0, *) {
            if let resolved = await ContinuousTranscriber.resolvedLocale(for: locale) {
                do {
                    return try await ContinuousTranscriber(locale: resolved, installing: installing)
                } catch {
                    PSLog.error("live: SpeechAnalyzer unavailable (\(error)), trying SFSpeechRecognizer", category: .speech)
                }
            }
        }
        return LegacyContinuousTranscriber(locale: locale)
    }
}

/// Maps recognizer time (seconds of audio fed) to uptime. A gap in the audio (a
/// muted microphone, an engine rebuild) starts a new anchor.
struct TranscriberTimeline: Sendable {
    private var anchors: [(audio: Double, uptime: Double)] = []

    mutating func note(audioStart: Double, uptime: Double) {
        if let last = anchors.last {
            let predicted = last.uptime + (audioStart - last.audio)
            guard abs(predicted - uptime) > 0.25 else { return }
        }
        anchors.append((audioStart, uptime))
        if anchors.count > 64 { anchors.removeFirst(anchors.count - 64) }
    }

    func uptime(at audio: Double) -> Double? {
        guard audio.isFinite, let anchor = anchors.last(where: { $0.audio <= audio + 0.001 }) ?? anchors.first else { return nil }
        return anchor.uptime + (audio - anchor.audio)
    }
}

/// iOS 26 SpeechAnalyzer + SpeechTranscriber, kept for the whole Live session.
@available(iOS 26.0, macOS 26.0, *)
public final class ContinuousTranscriber: LiveTranscribing, @unchecked Sendable {
    public let segments: AsyncStream<TranscriptSegment>
    public var engineName: String { "SpeechAnalyzer" }

    private let transcriber: SpeechTranscriber
    private let analyzer: SpeechAnalyzer
    private let converter: AnalyzerInputConverter
    private let segmentContinuation: AsyncStream<TranscriptSegment>.Continuation
    private let lock = NSLock()
    private var input: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?
    private var timeline = TranscriberTimeline()
    private var framesFed: Double = 0

    /// The locale SpeechTranscriber supports for `locale` (Apple's equivalent first, then the same language), or nil.
    static func resolvedLocale(for locale: Locale) async -> Locale? {
        if let equivalent = await SpeechTranscriber.supportedLocale(equivalentTo: locale) { return equivalent }
        let supported = await SpeechTranscriber.supportedLocales
        return supported.first { $0.identifier(.bcp47) == locale.identifier(.bcp47) }
            ?? supported.first { $0.language.languageCode == locale.language.languageCode }
    }

    static func isSupported(locale: Locale) async -> Bool {
        await resolvedLocale(for: locale) != nil
    }

    /// `locale` is already resolved. The model install is waited for 6 s at most
    /// (`LiveDeadline.Expired`); it goes on in the background for the next session.
    init(locale: Locale, installing: @escaping @Sendable () -> Void) async throws {
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [.volatileResults], attributeOptions: [.audioTimeRange])
        self.transcriber = transcriber
        analyzer = SpeechAnalyzer(modules: [transcriber])
        let installation = try await AssetInventory.assetInstallationRequest(supporting: [transcriber])
        if let installation {
            installing()
            let install = Task { try await installation.downloadAndInstall() }
            try await LiveDeadline.run(6) { try await install.value }
        }
        let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
        converter = AnalyzerInputConverter(outputFormat: format)
        let pair = AsyncStream<TranscriptSegment>.makeStream(bufferingPolicy: .bufferingNewest(64))
        segments = pair.stream
        segmentContinuation = pair.continuation
    }

    public func start() async throws {
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        lock.withLock { input = continuation }
        let transcriber = self.transcriber
        resultsTask = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    guard let self else { return }
                    let text = String(result.text.characters)
                    let start = result.range.start.seconds
                    let end = result.range.end.seconds
                    self.emit(text: text, start: start, end: end, isFinal: result.isFinal)
                }
            } catch {
                PSLog.error("live: analyzer results ended: \(error)", category: .speech)
            }
        }
        try await analyzer.start(inputSequence: stream)
    }

    private func emit(text: String, start: Double, end: Double, isFinal: Bool) {
        let now = ProcessInfo.processInfo.systemUptime
        let (startUptime, endUptime): (Double?, Double?) = lock.withLock { (timeline.uptime(at: start), timeline.uptime(at: end)) }
        let segmentEnd = min(endUptime ?? now, now)
        let segmentStart = min(startUptime ?? (segmentEnd - 1), segmentEnd)
        segmentContinuation.yield(TranscriptSegment(text: text, start: segmentStart, end: segmentEnd, isFinal: isFinal))
    }

    public func append(_ buffer: AVAudioPCMBuffer, uptime: Double) {
        guard let converted = converter.convert(buffer) else { return }
        let inputDuration = buffer.format.sampleRate > 0 ? Double(buffer.frameLength) / buffer.format.sampleRate : 0
        let rate = converted.format.sampleRate
        let continuation: AsyncStream<AnalyzerInput>.Continuation? = lock.withLock {
            guard let input else { return nil }
            timeline.note(audioStart: framesFed / max(rate, 1), uptime: uptime - inputDuration)
            framesFed += Double(converted.frameLength)
            return input
        }
        continuation?.yield(AnalyzerInput(buffer: converted))
    }

    /// Nothing to do: the reducer ignores a late final of the words already committed.
    public func beginTurn() {}

    public func stop() async {
        let continuation: AsyncStream<AnalyzerInput>.Continuation? = lock.withLock {
            defer { input = nil }
            return input
        }
        continuation?.finish()
        try? await analyzer.finalizeAndFinishThroughEndOfInput()
        resultsTask?.cancel()
        segmentContinuation.finish()
    }
}

/// SFSpeechRecognizer on the device, for locales SpeechTranscriber does not
/// support. A recognition task is limited in length, so it restarts at every
/// user turn and every 50 s.
public final class LegacyContinuousTranscriber: LiveTranscribing, @unchecked Sendable {
    public let segments: AsyncStream<TranscriptSegment>
    public var engineName: String { "SFSpeechRecognizer" }

    private let recognizer: SFSpeechRecognizer
    private let segmentContinuation: AsyncStream<TranscriptSegment>.Continuation
    private let converter = AnalyzerInputConverter(outputFormat: AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false))
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var taskStart: Double = 0
    private var generation = 0
    private var running = false

    init?(locale: Locale) {
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else { return nil }
        self.recognizer = recognizer
        let pair = AsyncStream<TranscriptSegment>.makeStream(bufferingPolicy: .bufferingNewest(64))
        segments = pair.stream
        segmentContinuation = pair.continuation
    }

    public func start() async throws {
        lock.withLock { running = true }
        restart(at: ProcessInfo.processInfo.systemUptime)
    }

    public func append(_ buffer: AVAudioPCMBuffer, uptime: Double) {
        let (started, running) = lock.withLock { (taskStart, self.running) }
        guard running else { return }
        if uptime - started > 50 {
            restart(at: uptime)
        }
        guard let converted = converter.convert(buffer) else { return }
        let request = lock.withLock { self.request }
        request?.append(converted)
    }

    public func beginTurn() {
        guard lock.withLock({ running }) else { return }
        restart(at: ProcessInfo.processInfo.systemUptime)
    }

    public func stop() async {
        let (request, task): (SFSpeechAudioBufferRecognitionRequest?, SFSpeechRecognitionTask?) = lock.withLock {
            running = false
            generation += 1
            defer { self.request = nil; self.task = nil }
            return (self.request, self.task)
        }
        request?.endAudio()
        task?.cancel()
        segmentContinuation.finish()
    }

    private func restart(at uptime: Double) {
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
        request.addsPunctuation = true
        let (old, oldTask, current): (SFSpeechAudioBufferRecognitionRequest?, SFSpeechRecognitionTask?, Int) = lock.withLock {
            generation += 1
            defer {
                self.request = request
                taskStart = uptime
            }
            return (self.request, self.task, generation)
        }
        old?.endAudio()
        oldTask?.cancel()
        let start = uptime
        let task = recognizer.recognitionTask(with: request) { [weak self] result, _ in
            guard let self, let result else { return }
            guard self.lock.withLock({ self.generation == current }) else { return }
            let transcription = result.bestTranscription
            let offset = transcription.segments.last.map { $0.timestamp + $0.duration } ?? 0
            let end = min(ProcessInfo.processInfo.systemUptime, start + max(offset, 0.1))
            self.segmentContinuation.yield(TranscriptSegment(text: transcription.formattedString, start: start, end: end, isFinal: result.isFinal))
        }
        lock.withLock {
            if generation == current { self.task = task } else { task.cancel() }
        }
    }
}
#endif
