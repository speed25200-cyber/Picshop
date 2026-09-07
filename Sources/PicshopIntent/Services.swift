import Foundation
import PicshopCore

/// Vision/ML capabilities the executors need for photos. Implemented by the
/// imaging layer on Apple platforms and by fakes in tests.
public protocol PhotoAIServices: Sendable {
    /// Detects instances matching the target, ranked by confidence (0…1).
    func candidates(for target: ObjectTarget, in document: PhotoDocument) async throws -> [ObjectCandidate]
    /// Rasterises a mask covering the given candidates, saved into the project bundle.
    func mask(for candidates: [ObjectCandidate], target: ObjectTarget, in document: PhotoDocument) async throws -> MaskReference
    /// Mask of the salient subject (people first).
    func subjectMask(in document: PhotoDocument) async throws -> MaskReference
    /// Angle (degrees) that would level the horizon, if detectable.
    func horizonAngle(in document: PhotoDocument) async throws -> Double?
    /// Rectangle (normalised) tightly framing the target, for "crop to the face".
    func framingRect(for target: ObjectTarget, in document: PhotoDocument) async throws -> PSRect?
}

/// Capabilities the executors need for video.
public protocol VideoAIServices: Sendable {
    func candidates(for target: ObjectTarget, in clip: VideoClip, timeline: VideoTimeline, at time: Double) async throws -> [ObjectCandidate]
    /// Renders a new media file with the object removed across the clip.
    func removeObject(candidates: [ObjectCandidate], target: ObjectTarget, from clip: VideoClip, timeline: VideoTimeline,
                      progress: @escaping @Sendable (Double) -> Void) async throws -> MediaAsset
    func stabilize(clip: VideoClip, timeline: VideoTimeline, progress: @escaping @Sendable (Double) -> Void) async throws -> MediaAsset
    func extractFrame(at time: Double, timeline: VideoTimeline) async throws -> MediaAsset
    func freezeFrame(at time: Double, duration: Double, timeline: VideoTimeline) async throws -> MediaAsset
    /// Person/subject matte rendered as an alpha video, for background effects.
    func subjectMatte(for clip: VideoClip, timeline: VideoTimeline, progress: @escaping @Sendable (Double) -> Void) async throws -> MediaAsset
}

/// Things the executor cannot do itself and hands back to the UI/store.
public enum EditorEffect: Equatable, Sendable {
    case undo
    case redo
    case revert
    case compare
    case zoom(AmountSpec?, ObjectTarget?)
    case export
    case share
    case play
    case pause
    case seek(Double)
    case help
    case pickMusic(query: String?)
    case pickBackground
    case clarify(ClarificationRequest)
    case selectLayer(UUID)
    case selectClip(UUID)
    case message(String)
    case confirm
    case cancel
}

public struct ExecutionResult: Sendable, Equatable {
    public var outcome: CommandOutcome
    public var effects: [EditorEffect]
    /// Label for the undo history.
    public var label: String

    public init(outcome: CommandOutcome, effects: [EditorEffect] = [], label: String = "") {
        self.outcome = outcome
        self.effects = effects
        self.label = label
    }

    public static func applied(_ label: String, effects: [EditorEffect] = []) -> ExecutionResult {
        ExecutionResult(outcome: .applied(label: label), effects: effects, label: label)
    }

    public static func effect(_ effect: EditorEffect, label: String) -> ExecutionResult {
        ExecutionResult(outcome: .applied(label: label), effects: [effect], label: label)
    }

    public static func failed(_ message: String) -> ExecutionResult {
        ExecutionResult(outcome: .failed(message: message))
    }

    public static func clarify(_ request: ClarificationRequest) -> ExecutionResult {
        ExecutionResult(outcome: .needsClarification(request), effects: [.clarify(request)])
    }

    public var changedDocument: Bool { outcome.isSuccess && !label.isEmpty && effects.allSatisfy { effect in
        switch effect {
        case .undo, .redo, .revert, .compare, .zoom, .export, .share, .play, .pause, .seek, .help, .pickMusic, .pickBackground, .clarify, .message, .confirm, .cancel:
            return false
        case .selectLayer, .selectClip:
            return true
        }
    } }
}
