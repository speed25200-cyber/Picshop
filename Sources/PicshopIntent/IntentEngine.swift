import Foundation
import PicshopCore

public enum EditorMode: String, Codable, Sendable {
    case photo
    case video
}

/// Everything the language layer may need to resolve references such as
/// "a bit more", "this clip", "the second one".
public struct IntentContext: Sendable {
    public var mode: EditorMode
    public var currentAdjustments: Adjustments
    public var hasSelection: Bool
    public var selectedIndex: Int?
    public var clipCount: Int
    public var textLayerCount: Int
    public var playheadSeconds: Double
    public var timelineDuration: Double
    public var frameRate: Double
    public var pendingClarification: ClarificationRequest?
    /// Normalised location of the most recent tap on the canvas, if any.
    public var lastTapPoint: PSPoint?
    public var canUndo: Bool
    public var canRedo: Bool
    /// BCP-47 language the user selected for voice, if any ("fr", "en").
    public var preferredLanguage: String?

    public init(mode: EditorMode, currentAdjustments: Adjustments = .neutral, hasSelection: Bool = false, selectedIndex: Int? = nil,
                clipCount: Int = 0, textLayerCount: Int = 0, playheadSeconds: Double = 0, timelineDuration: Double = 0, frameRate: Double = 30,
                pendingClarification: ClarificationRequest? = nil, lastTapPoint: PSPoint? = nil, canUndo: Bool = false, canRedo: Bool = false,
                preferredLanguage: String? = nil) {
        self.mode = mode
        self.currentAdjustments = currentAdjustments
        self.hasSelection = hasSelection
        self.selectedIndex = selectedIndex
        self.clipCount = clipCount
        self.textLayerCount = textLayerCount
        self.playheadSeconds = playheadSeconds
        self.timelineDuration = timelineDuration
        self.frameRate = frameRate
        self.pendingClarification = pendingClarification
        self.lastTapPoint = lastTapPoint
        self.canUndo = canUndo
        self.canRedo = canRedo
        self.preferredLanguage = preferredLanguage
    }

    public static let photo = IntentContext(mode: .photo)
    public static let video = IntentContext(mode: .video, clipCount: 1, timelineDuration: 10)
}

/// A component that turns an utterance into an `EditPlan`.
public protocol IntentEngine: Sendable {
    var kind: IntentEngineKind { get }
    /// Whether the engine can currently answer (model downloaded, device supported…).
    func isAvailable() async -> Bool
    func plan(_ utterance: String, context: IntentContext) async throws -> EditPlan
}
