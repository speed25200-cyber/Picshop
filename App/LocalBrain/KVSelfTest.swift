// The KV engine's self-test (W3, D22 step 5): before `MLXLocalRuntime.makeEngine` hands out an `MLXKVEngine`, the
// engine must answer the same as itself started cold, on this iPhone, with these weights, this runtime and this build.
//
// - The script: 3 turns at temperature 0, 24 tokens each: a French text turn, a tool-call turn, and a picture turn
//   (with the previous call's result) on a 256 px procedural image (a gradient and a disc, Core Image generators).
// - Primary oracle: the warm engine (its suffix, restore or prefix path) against the same engine cold (a fresh cache,
//   the whole prompt, the same `TokenIterator` path) on the same transcript. ChatSession is not the gate: it rebuilds
//   Qwen3.5's cache on a tool-call turn with another prefill chunking, so greedy 4-bit outputs may drift on a correct
//   engine; `MLXChatEngine` runs the text turn as a logged secondary comparison only.
// - Pass (`KVSelfTestVerdict`): tool turns the same calls (names and argument JSON), text turns the same first 8 ids.
//   The picture turn is its own bit (`mediaAppendVerified`): if only it fails, the KV engine still runs and picture
//   turns restore the prefix and prefill the tail.
// - Scheduling: at utility priority, only when `LocalBrainHub.allowsBackgroundModelWork` (no canvas interaction for
//   10 s, thermal nominal, no export, analysis or Live turn running), checked before every turn: a touch between
//   turns pauses it and it resumes later, on the same warm engine (never mid-`next()`). The prefix snapshot is reused.
// - The verdict lives in UserDefaults (`picshop.kv.verified.<model>.<revision>.<runtime>.<build>`, `.media`) with a
//   Diagnostics note. A failure keeps W2's `MLXChatEngine` for that key.
#if canImport(MLXVLM)
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import MLXLMCommon
import PicshopCore
import PicshopIntent
import PicshopUI

final class KVSelfTest: @unchecked Sendable {
    static let shared = KVSelfTest()

    enum Phase: String, Sendable { case pending, waiting, running, passed, failed, mediaFailed, off }

    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private var phase: Phase = .pending

    /// The verdict keys for `info` on this runtime and build.
    static func key(_ info: LocalModelInfo, media: Bool = false) -> String {
        KVSelfTestVerdict.defaultsKey(modelID: info.id, revision: info.revision, runtimeRevision: MLXPrefixStore.runtimeRevision,
                                      build: MLXPrefixStore.build, media: media)
    }

    /// The text and tool turns passed for this key: the KV engine may run.
    static func isVerified(_ info: LocalModelInfo) -> Bool {
        UserDefaults.standard.object(forKey: key(info)) as? Bool == true
    }

    /// The picture turn passed too: picture turns append to the warm cache.
    static func mediaVerified(_ info: LocalModelInfo) -> Bool {
        isVerified(info) && UserDefaults.standard.object(forKey: key(info, media: true)) as? Bool == true
    }

    /// Whether a verdict exists for this key (passed or failed): the test never runs twice for it.
    static func hasVerdict(_ info: LocalModelInfo) -> Bool {
        UserDefaults.standard.object(forKey: key(info)) != nil
    }

    /// For Diagnostic Live.
    func describe(_ info: LocalModelInfo?) -> String {
        guard FeatureFlags.isOn(.kvEngine) else { return Phase.off.rawValue }
        if let info, Self.hasVerdict(info) {
            if !Self.isVerified(info) { return Phase.failed.rawValue }
            return Self.mediaVerified(info) ? Phase.passed.rawValue : Phase.mediaFailed.rawValue
        }
        return lock.withLock { phase.rawValue }
    }

    func cancel() {
        let running: Task<Void, Never>? = lock.withLock {
            defer { task = nil }
            if phase == .running || phase == .waiting { phase = .pending }
            return task
        }
        running?.cancel()
    }

    /// After a load and after the prefix is warmed: runs once per key, in the background, when the person is idle.
    func scheduleIfNeeded(runtime: MLXLocalRuntime) {
        guard FeatureFlags.isOn(.kvEngine), runtime.isUsable, let info = runtime.loadedContainerAndInfo()?.info, !Self.hasVerdict(info) else { return }
        let started: Bool = lock.withLock {
            guard task == nil else { return false }
            phase = .waiting
            task = Task.detached(priority: .utility) { [weak self] in
                guard let self else { return }
                await self.run(runtime: runtime, info: info)
                self.lock.withLock { self.task = nil }
            }
            return true
        }
        if started { PSLog.info("kv self-test scheduled for \(info.id)", category: .models) }
    }

    // MARK: The script

    private func setPhase(_ next: Phase) {
        lock.withLock { phase = next }
    }

    /// Waits until the person is idle (and the weights still loaded), checking every 2 s.
    private func waitForIdle(runtime: MLXLocalRuntime, info: LocalModelInfo) async -> Bool {
        setPhase(.waiting)
        while !Task.isCancelled {
            guard runtime.loadedContainerAndInfo()?.info.id == info.id else { return false }
            if await MainActor.run(body: { LocalBrainHub.shared.allowsBackgroundModelWork }) {
                setPhase(.running)
                return true
            }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
        return false
    }

    private func run(runtime: MLXLocalRuntime, info: LocalModelInfo) async {
        guard let container = runtime.loadedContainerAndInfo()?.container else { return }
        let setup = MLXPrefixStore.shared.prefixSetup(for: LocalModelLiveBrain.prefixSetup(mode: .photo, info: info)).setup
        let warm = MLXKVEngine(container: container, info: info, setup: setup, mediaAppendVerified: true)
        defer { Task { await warm.close() } }
        let options = LocalGenerationOptions(style: .repair, maxTokens: 24)
        var state = LiveEditorState(mode: .photo, version: 3)
        state.canvasPixels = PSSize(width: 4_032, height: 3_024)
        let turns: [(text: String, picture: Bool)] = [
            ("Bonjour ! Dis en une phrase ce que tu peux faire sur cette photo.", false),
            ("rends-la plus chaude", false),
            ("que vois-tu sur la photo ?", true),
        ]
        var owed: [LocalChatMessage] = []
        var textAndTools = true
        var media = true
        var notes: [String] = []
        for (index, script) in turns.enumerated() {
            guard await waitForIdle(runtime: runtime, info: info) else {
                PSLog.info("kv self-test paused (weights gone or cancelled) before turn \(index + 1)", category: .models)
                setPhase(.pending)
                return
            }
            let turn = LiveUserTurn(id: index, kind: .speech, text: script.text, language: .french, image: nil, editorState: state)
            let message = LocalLivePrompt.userMessage(turn, previous: index == 0 ? nil : state, imageAttached: script.picture)
            let messages = owed + [LocalChatMessage.user(message, imageJPEG: script.picture ? Self.picture() : nil)]
            owed = []
            // The cold reference first, on the warm engine's transcript before this turn.
            let transcript = warm.transcriptSnapshot()
            let cold = MLXKVEngine(container: container, info: info, setup: setup, mediaAppendVerified: true, coldOnly: true, transcript: transcript)
            let coldTurn = await Self.collect(cold, messages, options: options)
            await cold.close()
            // Cancelled (the app resigned active, the weights went): no further GPU work, the verdict waits.
            if Task.isCancelled {
                setPhase(.pending)
                return
            }
            let warmTurn = await Self.collect(warm, messages, options: options)
            guard let warmTurn, let coldTurn else {
                notes.append("turn \(index + 1): no output")
                if script.picture { media = false } else { textAndTools = false }
                continue
            }
            let agrees = KVSelfTestVerdict.agrees(warm: warmTurn.turn, cold: coldTurn.turn)
            notes.append("turn \(index + 1) \(warmTurn.path): \(agrees ? "same" : "different")")
            if !agrees {
                if script.picture { media = false } else { textAndTools = false }
            }
            for call in warmTurn.calls {
                owed.append(.toolResult(callID: call.id, name: call.name, content: "1 adjust applied: Warmth +15"))
            }
            if Task.isCancelled {
                setPhase(.pending)
                return
            }
            if index == 0 { await Self.logChatSessionComparison(container: container, info: info, setup: setup, messages: messages, kv: warmTurn.turn) }
        }
        let defaults = UserDefaults.standard
        defaults.set(textAndTools, forKey: Self.key(info))
        defaults.set(textAndTools && media, forKey: Self.key(info, media: true))
        setPhase(textAndTools ? (media ? .passed : .mediaFailed) : .failed)
        let line = "kv self-test \(info.id): \(textAndTools ? "passed" : "failed"), picture \(media ? "passed" : "failed") (\(notes.joined(separator: "; ")))"
        PSLog.info(line, category: .models)
        Diagnostics.shared.note(line)
    }

    private struct Collected {
        var turn: KVSelfTestTurn
        var calls: [LocalToolCall]
        var path: String
    }

    /// One turn on `engine`: its generated ids (from the engine's outcome) and its calls.
    private static func collect(_ engine: MLXKVEngine, _ messages: [LocalChatMessage], options: LocalGenerationOptions) async -> Collected? {
        var calls: [LocalToolCall] = []
        guard !Task.isCancelled else { return nil }
        do {
            try await engine.prepare()
            for try await event in engine.send(messages, options: options) {
                if case .toolCall(let call) = event { calls.append(call) }
            }
        } catch {
            PSLog.error("kv self-test: \(error)", category: .models)
            return nil
        }
        guard let outcome = engine.outcome, !outcome.cancelled else { return nil }
        return Collected(turn: KVSelfTestTurn(tokenIDs: outcome.generatedIDs, calls: outcome.calls), calls: calls, path: outcome.path)
    }

    /// The secondary comparison: W2's engine on the first turn, logged, never gating.
    private static func logChatSessionComparison(container: ModelContainer, info: LocalModelInfo, setup: LocalChatSetup, messages: [LocalChatMessage],
                                                 kv: KVSelfTestTurn) async {
        let engine = MLXChatEngine(container: container, info: info, setup: setup)
        var text = ""
        do {
            try await engine.prepare()
            for try await event in engine.send(messages, options: LocalGenerationOptions(style: .repair, maxTokens: 24)) {
                if case .text(let delta) = event { text += delta }
            }
        } catch {
            PSLog.info("kv self-test: ChatSession comparison failed: \(error)", category: .models)
        }
        await engine.close()
        PSLog.info("kv self-test: ChatSession said \(text.count) characters; the KV engine \(kv.tokenIDs.count) ids", category: .models)
    }

    /// 256 × 256: a warm gradient and an orange disc, as JPEG.
    static func picture() -> Data? {
        let side: CGFloat = 256
        let extent = CGRect(x: 0, y: 0, width: side, height: side)
        let gradient = CIFilter.linearGradient()
        gradient.point0 = CGPoint(x: 0, y: side)
        gradient.point1 = CGPoint(x: 0, y: 0)
        gradient.color0 = CIColor(red: 0.20, green: 0.42, blue: 0.80)
        gradient.color1 = CIColor(red: 0.86, green: 0.82, blue: 0.70)
        let disc = CIFilter.radialGradient()
        disc.center = CGPoint(x: side * 0.45, y: side * 0.40)
        disc.radius0 = Float(side * 0.18)
        disc.radius1 = Float(side * 0.18 + 2)
        disc.color0 = CIColor(red: 0.95, green: 0.45, blue: 0.12)
        disc.color1 = CIColor(red: 0, green: 0, blue: 0, alpha: 0)
        guard let background = gradient.outputImage?.cropped(to: extent), let subject = disc.outputImage?.cropped(to: extent) else { return nil }
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        return CIContext().jpegRepresentation(of: subject.composited(over: background).cropped(to: extent), colorSpace: space)
    }
}
#endif
