#if canImport(AVFoundation)
import Foundation
import AVFoundation
import PicshopCore

/// Who holds the app's audio session: nobody, one push-to-talk command, or a Live
/// conversation, on the echo-cancelling duplex engine (`.live`) or on the simple
/// path (`.liveSimple`: VoiceController hears, `speak()` talks). Live wins: push-to-talk
/// is refused while the duplex engine owns the session, and inside `.liveSimple` its
/// acquire and release leave the conversation's session alone.
///
/// Every session call runs in order on one serial queue, off the main thread:
/// `setCategory` and `setActive` can block for tens of milliseconds.
@MainActor
public final class AudioSessionArbiter {
    public static let shared = AudioSessionArbiter()

    public enum Owner: Sendable, Equatable { case none, pushToTalk, live, liveSimple }

    public enum ArbiterError: Error, Sendable, Equatable { case ownedByLive }

    public private(set) var owner: Owner = .none

    /// The queue every AVAudioSession call runs on.
    nonisolated static let queue = DispatchQueue(label: "picshop.audio-session", qos: .userInitiated)

    private init() {}

    /// Configures and activates the session for `owner`.
    /// - Parameter hdBluetooth: Live only: A2DP output with the iPhone's own microphone (liveHDBluetooth).
    public func acquire(_ owner: Owner, hdBluetooth: Bool = false) async throws {
        switch owner {
        case .none: return
        case .pushToTalk:
            guard self.owner != .live else { throw ArbiterError.ownedByLive }
            // Live's simple path set the session up for the whole conversation: keep it.
            if self.owner == .liveSimple { return }
        case .live, .liveSimple: break
        }
        let previous = self.owner
        self.owner = owner
        do {
            try await Self.run { try Self.configure(owner, hdBluetooth: hdBluetooth) }
        } catch {
            if self.owner == owner { self.owner = previous }
            throw error
        }
    }

    /// Gives the session back. Push-to-talk leaves it active, as it always has; Live
    /// deactivates it so other apps' audio can resume. Push-to-talk inside `.liveSimple`
    /// does not own the session, so its release changes nothing.
    public func release(_ owner: Owner) {
        guard owner != .none, self.owner == owner else { return }
        self.owner = .none
        guard owner == .live || owner == .liveSimple else { return }
        Self.queue.async { Self.deactivateAfterLive() }
    }

    /// Live's session again after the media services were reset.
    public func reactivateLive(hdBluetooth: Bool) async throws {
        guard owner == .live else { return }
        try await Self.run { try Self.configure(.live, hdBluetooth: hdBluetooth) }
    }

    nonisolated private static func run(_ work: @escaping @Sendable () throws -> Void) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                do {
                    try work()
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    nonisolated private static func configure(_ owner: Owner, hdBluetooth: Bool) throws {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        switch owner {
        case .none:
            return
        case .pushToTalk:
            // Unchanged from VoiceController's own setup.
            try session.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker, .duckOthers])
            try session.setActive(true, options: [])
        case .live:
            // voiceChat: the system's echo canceller. No mixWithOthers: other apps pause during Live.
            // .allowBluetooth is the pre-iOS 26 name of .allowBluetoothHFP; it still compiles everywhere.
            let options: AVAudioSession.CategoryOptions = hdBluetooth
                ? [.defaultToSpeaker, .allowBluetoothA2DP]
                : [.defaultToSpeaker, .allowBluetooth, .allowBluetoothA2DP]
            try session.setCategory(.playAndRecord, mode: .voiceChat, options: options)
            try? session.setPreferredSampleRate(48_000)
            try? session.setPreferredIOBufferDuration(0.01)
            try session.setActive(true, options: [])
            if hdBluetooth, let builtIn = session.availableInputs?.first(where: { $0.portType == .builtInMic }) {
                // A2DP carries output only: the iPhone's microphone keeps the voice in high quality.
                try? session.setPreferredInput(builtIn)
            } else {
                try? session.setPreferredInput(nil)
            }
        case .liveSimple:
            // VoiceController's proven capture, set once for the conversation. .default (not
            // .measurement) keeps speak() loud on the loudspeaker.
            try session.setCategory(.playAndRecord, mode: .default,
                                    options: [.defaultToSpeaker, .allowBluetooth, .allowBluetoothA2DP, .duckOthers])
            try session.setActive(true, options: [])
        }
        #endif
    }

    /// Back to the launch default, so video playback does not stay in voice-chat processing.
    nonisolated private static func deactivateAfterLive() {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try? session.setPreferredInput(nil)
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
        try? session.setCategory(.soloAmbient, mode: .default, options: [])
        #endif
    }
}
#endif
