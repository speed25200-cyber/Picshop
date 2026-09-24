#if os(iOS) && canImport(AVFoundation)
import Foundation
import AVFoundation
import PicshopCore
import PicshopIntent

/// The serial queue every Live AVAudioEngine call runs on: building, starting,
/// stopping, scheduling speech and earcons. The main thread never waits on the engine.
enum LiveAudioQueue {
    static let queue = DispatchQueue(label: "picshop.live.audio", qos: .userInteractive)

    static func run<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
            queue.async {
                do { continuation.resume(returning: try work()) } catch { continuation.resume(throwing: error) }
            }
        }
    }
}

/// The format Live's voice and earcons are scheduled in: mono Float32 at 24 kHz.
public enum LiveAudioFormat {
    public static let player: AVAudioFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24_000, channels: 1, interleaved: false)!
}

public enum LiveAudioError: Error, Sendable, Equatable {
    case noInput
    case engineStart(String)
}

/// The player nodes of one engine build. Only touched on `LiveAudioQueue`; a
/// rebuild or a stop invalidates it, and a stale handle schedules nothing.
public final class LivePlayerHandle: @unchecked Sendable {
    let engine: AVAudioEngine
    let voice: AVAudioPlayerNode
    let earcons: AVAudioPlayerNode
    /// Read and written on `LiveAudioQueue` only.
    var isValid = true

    init(engine: AVAudioEngine, voice: AVAudioPlayerNode, earcons: AVAudioPlayerNode) {
        self.engine = engine
        self.voice = voice
        self.earcons = earcons
    }

    /// On `LiveAudioQueue`: schedules one buffer of speech; `played` runs once it was heard.
    func scheduleVoice(_ buffer: AVAudioPCMBuffer, played: @escaping @Sendable () -> Void) -> Bool {
        guard isValid, engine.isRunning else { return false }
        voice.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { _ in played() }
        if !voice.isPlaying { voice.play() }
        return true
    }
}

/// Microphone loudness in 20 ms slices, the output level and the microphone
/// sink, written on the taps' thread and read on the main actor.
final class LiveTapState: @unchecked Sendable {
    private let lock = NSLock()
    private var ring: [AudioFrameFeatures] = []
    private var sliceSum: Double = 0
    private var sliceCount = 0
    private var isOpen = false
    private var isMuted = false
    private var outputDB: Float = -100
    private var sink: (@Sendable (AVAudioPCMBuffer, Double) -> Void)?
    private static let ringLimit = 250

    func setOpen(_ open: Bool) {
        lock.withLock {
            isOpen = open
            if !open { resetSlices() }
        }
    }

    func setMuted(_ muted: Bool) {
        lock.withLock {
            isMuted = muted
            if muted { resetSlices() }
        }
    }

    func setSink(_ sink: (@Sendable (AVAudioPCMBuffer, Double) -> Void)?) {
        lock.withLock { self.sink = sink }
    }

    var outputLevelDB: Float { lock.withLock { outputDB } }

    func drain() -> [AudioFrameFeatures] {
        lock.withLock {
            let frames = ring
            ring.removeAll(keepingCapacity: true)
            return frames
        }
    }

    private func resetSlices() {
        sliceSum = 0
        sliceCount = 0
    }

    /// Tap thread. `uptime` is when the buffer arrived, the end of its audio.
    func processInput(_ buffer: AVAudioPCMBuffer, uptime: Double) {
        let (open, sum0, count0, sink) = lock.withLock { (isOpen && !isMuted, sliceSum, sliceCount, self.sink) }
        guard open else { return }
        let frames = Int(buffer.frameLength)
        let sampleRate = buffer.format.sampleRate
        var produced: [AudioFrameFeatures] = []
        var sum = sum0
        var count = count0
        if frames > 0, sampleRate > 0, let samples = buffer.floatChannelData?[0] {
            let slice = max(1, Int(sampleRate * 0.02))
            for index in 0..<frames {
                let sample = Double(samples[index])
                sum += sample * sample
                count += 1
                if count >= slice {
                    let rms = (sum / Double(count)).squareRoot()
                    let db = Float(max(-100, 20 * log10(max(rms, 1e-7))))
                    let time = uptime - Double(frames - 1 - index) / sampleRate
                    produced.append(AudioFrameFeatures(rmsDB: db, time: time))
                    sum = 0
                    count = 0
                }
            }
        }
        lock.withLock {
            sliceSum = sum
            sliceCount = count
            ring.append(contentsOf: produced)
            if ring.count > Self.ringLimit { ring.removeFirst(ring.count - Self.ringLimit) }
        }
        sink?(buffer, uptime)
    }

    /// Tap thread: what the loudspeaker plays (voice and earcons), for the orb.
    func processOutput(_ buffer: AVAudioPCMBuffer) {
        let frames = Int(buffer.frameLength)
        guard frames > 0, let samples = buffer.floatChannelData?[0] else { return }
        var sum: Double = 0
        for index in 0..<frames {
            let sample = Double(samples[index])
            sum += sample * sample
        }
        let rms = (sum / Double(frames)).squareRoot()
        let db = Float(max(-100, 20 * log10(max(rms, 1e-7))))
        lock.withLock { outputDB = db }
    }
}

/// Full-duplex audio for Live: one AVAudioEngine with voice processing (the echo
/// canceller), the microphone tap for recognition and loudness, and the player
/// nodes the assistant's voice and earcons play through, so the echo canceller
/// hears everything the loudspeaker says.
@MainActor
public final class LiveAudioEngine {
    public enum OutputRoute: String, Sendable {
        case speaker, receiver, headphones, bluetooth, airPlay, external, none
    }

    public enum Event: Sendable, Equatable {
        case interrupted(began: Bool, shouldResume: Bool)
        case routeChanged(OutputRoute, EchoRisk)
        /// A new engine replaced the old one: the voice queued on the old player is gone.
        case rebuilt
        case mediaServicesReset
        case failed(String)
    }

    public var onEvent: ((Event) -> Void)?
    public private(set) var isRunning = false
    /// False when voice processing could not be enabled: the microphone then hears the assistant.
    public private(set) var echoCancellationActive = false
    public private(set) var route: OutputRoute = .none
    public private(set) var isInputMuted = false
    /// Set by LiveSpeaker when its voice had to move to speak(), outside the echo canceller.
    public var bypassesEchoCanceller = false {
        didSet { if bypassesEchoCanceller != oldValue { publishRoute() } }
    }

    /// Low with headphones, normal on the loudspeaker with echo cancellation, high without it.
    public var echoRisk: EchoRisk {
        switch route {
        case .headphones, .bluetooth: return .low
        case .speaker, .receiver, .airPlay, .external, .none:
            return echoCancellationActive && !bypassesEchoCanceller ? .normal : .high
        }
    }

    /// The current player nodes; nil while stopped.
    public private(set) var players: LivePlayerHandle?

    /// The AVAudioEngine itself runs: false after an interruption or a media services reset, until `resume()`.
    public var isEngineRunning: Bool { players?.engine.isRunning ?? false }

    let tap = LiveTapState()
    private var observers: [NSObjectProtocol] = []
    private var engineObserver: NSObjectProtocol?
    private var lastRebuild: Double?
    private var pendingRebuild: Task<Void, Never>?
    private var isStarting = false
    /// Between pause() and resume(): configuration changes do not rebuild.
    private var isPaused = false
    /// Bumped by every stop, so a start that finishes after it tears its engine down.
    private var generation = 0

    public init() {}

    /// Called on the tap's thread with every microphone buffer while the mic is open, and when it arrived.
    public func setMicrophoneSink(_ sink: (@Sendable (AVAudioPCMBuffer, Double) -> Void)?) {
        tap.setSink(sink)
    }

    /// Opens or closes the feature and recognition flow without touching the engine.
    public func setMicrophoneOpen(_ open: Bool) {
        tap.setOpen(open)
    }

    /// The 20 ms loudness slices since the last call, oldest first.
    public func drainFeatures() -> [AudioFrameFeatures] {
        tap.drain()
    }

    /// dBFS of what the loudspeaker plays right now.
    public var outputLevelDB: Float { tap.outputLevelDB }

    // MARK: Start and stop

    /// Builds and starts a fresh engine with voice processing. Observes route
    /// changes, interruptions and configuration changes until `stop()`.
    public func start() async throws {
        guard !isRunning, !isStarting else { return }
        isStarting = true
        defer { isStarting = false }
        let tap = self.tap
        let muted = isInputMuted
        let startedGeneration = generation
        let built = try await LiveAudioQueue.run { try Self.build(tap: tap, muted: muted) }
        guard startedGeneration == generation else {
            // Stopped while starting.
            LiveAudioQueue.queue.async { Self.tearDown(built.handle) }
            return
        }
        players = built.handle
        echoCancellationActive = built.voiceProcessing
        isRunning = true
        if !built.voiceProcessing { PSLog.error("live: voice processing unavailable, echo risk high", category: .speech) }
        observeSession()
        observe(engine: built.handle.engine)
        publishRoute()
    }

    /// Stops the engine and turns the microphone off. Idempotent.
    public func stop() {
        generation += 1
        isPaused = false
        pendingRebuild?.cancel()
        pendingRebuild = nil
        removeObservers()
        guard let handle = players else {
            isRunning = false
            return
        }
        players = nil
        isRunning = false
        LiveAudioQueue.queue.async { Self.tearDown(handle) }
    }

    /// Stops the AVAudioEngine, so the microphone indicator goes out, but keeps observing
    /// the session (an interruption's end still arrives). `resume()` builds a fresh engine.
    public func pause() {
        guard isRunning else { return }
        isPaused = true
        pendingRebuild?.cancel()
        pendingRebuild = nil
        if let engineObserver { NotificationCenter.default.removeObserver(engineObserver) }
        engineObserver = nil
        guard let handle = players else { return }
        players = nil
        LiveAudioQueue.queue.async { Self.tearDown(handle) }
    }

    /// inputNode.isVoiceProcessingInputMuted, plus a software gate when voice processing is off.
    public func setInputMuted(_ muted: Bool) {
        isInputMuted = muted
        tap.setMuted(muted)
        guard let handle = players, echoCancellationActive else { return }
        LiveAudioQueue.queue.async {
            guard handle.isValid else { return }
            handle.engine.inputNode.isVoiceProcessingInputMuted = muted
        }
    }

    // MARK: Output control

    /// Ramps the voice down over `fadeMs`, drops everything queued on it and restores the volume.
    public func fadeOutVoice(milliseconds fadeMs: Int) {
        guard let handle = players else { return }
        let steps = fadeMs > 0 ? 5 : 0
        LiveAudioQueue.queue.async {
            guard handle.isValid else { return }
            let start = handle.voice.volume
            for step in 0..<steps {
                handle.voice.volume = start * Float(steps - step - 1) / Float(steps)
                usleep(useconds_t(max(1, fadeMs) * 1000 / max(1, steps)))
            }
            handle.voice.stop()
            handle.voice.volume = 1
            if handle.engine.isRunning { handle.voice.play() }
        }
    }

    /// Plays an earcon on its own node of the same engine, so the echo canceller hears it too.
    public func playEarcon(_ buffer: AVAudioPCMBuffer) {
        guard let handle = players else { return }
        LiveAudioQueue.queue.async {
            guard handle.isValid, handle.engine.isRunning else { return }
            handle.earcons.scheduleBuffer(buffer, at: nil, options: .interrupts, completionHandler: nil)
            if !handle.earcons.isPlaying { handle.earcons.play() }
        }
    }

    // MARK: Build

    private struct Built: @unchecked Sendable {
        var handle: LivePlayerHandle
        var voiceProcessing: Bool
    }

    /// On `LiveAudioQueue`, in the order voice processing requires: enable it before any
    /// connection, attach the players, read the input format right before the tap.
    nonisolated private static func build(tap: LiveTapState, muted: Bool) throws -> Built {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        var voiceProcessing = true
        do {
            try input.setVoiceProcessingEnabled(true)
        } catch {
            voiceProcessing = false
        }
        if voiceProcessing {
            input.isVoiceProcessingAGCEnabled = true
            var ducking = input.voiceProcessingOtherAudioDuckingConfiguration
            ducking.enableAdvancedDucking = true
            ducking.duckingLevel = .min
            input.voiceProcessingOtherAudioDuckingConfiguration = ducking
            input.isVoiceProcessingInputMuted = muted
        }
        let voice = AVAudioPlayerNode()
        let earcons = AVAudioPlayerNode()
        engine.attach(voice)
        engine.attach(earcons)
        engine.connect(voice, to: engine.mainMixerNode, format: LiveAudioFormat.player)
        engine.connect(earcons, to: engine.mainMixerNode, format: LiveAudioFormat.player)
        // Read here, never earlier: a tap with a stale or empty format raises an exception Swift cannot catch.
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            if voiceProcessing { try? input.setVoiceProcessingEnabled(false) }
            throw LiveAudioError.noInput
        }
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            tap.processInput(buffer, uptime: ProcessInfo.processInfo.systemUptime)
        }
        engine.mainMixerNode.installTap(onBus: 0, bufferSize: 1024, format: nil) { buffer, _ in
            tap.processOutput(buffer)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            engine.mainMixerNode.removeTap(onBus: 0)
            if voiceProcessing { try? input.setVoiceProcessingEnabled(false) }
            throw LiveAudioError.engineStart(String(describing: error))
        }
        voice.play()
        earcons.play()
        return Built(handle: LivePlayerHandle(engine: engine, voice: voice, earcons: earcons), voiceProcessing: voiceProcessing)
    }

    /// Voice processing goes off before the engine stops: the reverse order can crash in
    /// AURemoteIO on iOS 18 and later.
    nonisolated private static func tearDown(_ handle: LivePlayerHandle) {
        handle.isValid = false
        let engine = handle.engine
        handle.voice.stop()
        handle.earcons.stop()
        engine.inputNode.removeTap(onBus: 0)
        engine.mainMixerNode.removeTap(onBus: 0)
        if engine.inputNode.isVoiceProcessingEnabled {
            try? engine.inputNode.setVoiceProcessingEnabled(false)
        }
        engine.stop()
        engine.reset()
    }

    // MARK: Recovery

    /// A configuration change stops the engine: rebuild it, at most once every 3 s.
    private func scheduleRebuild(reason: String) {
        guard isRunning, !isPaused, pendingRebuild == nil else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let wait = lastRebuild.map { max(0, 3 - (now - $0)) } ?? 0
        pendingRebuild = Task { @MainActor [weak self] in
            if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
            guard let self, !Task.isCancelled else { return }
            self.pendingRebuild = nil
            // A real change stops the engine; one that left it running (voice processing
            // settling after a build) needs nothing, and must not start a rebuild loop.
            guard !self.isEngineRunning else { return }
            await self.rebuild(reason: reason)
        }
    }

    private func rebuild(reason: String) async {
        guard isRunning, !isStarting else { return }
        isStarting = true
        defer { isStarting = false }
        lastRebuild = ProcessInfo.processInfo.systemUptime
        PSLog.info("live: audio engine rebuilt (\(reason))", category: .speech)
        if let engineObserver { NotificationCenter.default.removeObserver(engineObserver) }
        engineObserver = nil
        if let old = players {
            players = nil
            LiveAudioQueue.queue.async { Self.tearDown(old) }
        }
        let tap = self.tap
        let muted = isInputMuted
        do {
            let built = try await LiveAudioQueue.run { try Self.build(tap: tap, muted: muted) }
            guard isRunning else {
                LiveAudioQueue.queue.async { Self.tearDown(built.handle) }
                return
            }
            players = built.handle
            echoCancellationActive = built.voiceProcessing
            observe(engine: built.handle.engine)
            publishRoute()
            onEvent?(.rebuilt)
        } catch {
            PSLog.error("live: audio engine rebuild failed: \(error)", category: .speech)
            onEvent?(.failed(String(describing: error)))
        }
    }

    /// After an interruption ended or the app came back: a running engine is kept, a stopped one rebuilt.
    public func resume() async {
        guard isRunning else { return }
        isPaused = false
        if let handle = players, handle.engine.isRunning { return }
        await rebuild(reason: "resume")
    }

    private func observe(engine: AVAudioEngine) {
        engineObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.scheduleRebuild(reason: "configuration change") }
        }
    }

    private func observeSession() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.publishRoute() }
        })
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] notification in
            let info = notification.userInfo
            let type = (info?[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap(AVAudioSession.InterruptionType.init(rawValue:))
            let options = AVAudioSession.InterruptionOptions(rawValue: (info?[AVAudioSessionInterruptionOptionKey] as? UInt) ?? 0)
            guard let type else { return }
            let began = type == .began
            let shouldResume = options.contains(.shouldResume)
            Task { @MainActor [weak self] in self?.onEvent?(.interrupted(began: began, shouldResume: shouldResume)) }
        })
        observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
            // The owner reactivates the session, then calls resume(), which rebuilds.
            Task { @MainActor [weak self] in
                guard let self, self.isRunning else { return }
                self.onEvent?(.mediaServicesReset)
            }
        })
    }

    private func removeObservers() {
        let center = NotificationCenter.default
        for observer in observers { center.removeObserver(observer) }
        observers = []
        if let engineObserver { center.removeObserver(engineObserver) }
        engineObserver = nil
    }

    private func publishRoute() {
        route = Self.currentRoute()
        onEvent?(.routeChanged(route, echoRisk))
    }

    /// Where the voice plays now.
    public nonisolated static func currentRoute() -> OutputRoute {
        guard let port = AVAudioSession.sharedInstance().currentRoute.outputs.first?.portType else { return .none }
        switch port {
        case .builtInSpeaker: return .speaker
        case .builtInReceiver: return .receiver
        case .headphones: return .headphones
        case .bluetoothA2DP, .bluetoothHFP, .bluetoothLE: return .bluetooth
        case .airPlay: return .airPlay
        default: return .external
        }
    }
}
#endif
