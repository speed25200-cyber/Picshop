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
    /// What the photo shows, for "décris la photo".
    func describe(_ document: PhotoDocument) async throws -> SceneDescription
}

public extension PhotoAIServices {
    func describe(_ document: PhotoDocument) async throws -> SceneDescription { SceneDescription() }
}

/// Facts about a photo, assembled into a sentence by the executor.
public struct SceneDescription: Sendable, Equatable {
    public var people: Int
    public var faces: Int
    /// English animal identifiers ("dog", "cat").
    public var animals: [String]
    /// English scene labels, most confident first ("beach", "sunset").
    public var labels: [String]
    public var hasText: Bool
    /// 0 = very dark … 1 = very bright.
    public var brightness: Double
    /// Mean saturation 0…1.
    public var colourfulness: Double

    public init(people: Int = 0, faces: Int = 0, animals: [String] = [], labels: [String] = [], hasText: Bool = false, brightness: Double = 0.5, colourfulness: Double = 0.5) {
        self.people = people
        self.faces = faces
        self.animals = animals
        self.labels = labels
        self.hasText = hasText
        self.brightness = brightness
        self.colourfulness = colourfulness
    }

    public var isEmpty: Bool { people == 0 && faces == 0 && animals.isEmpty && labels.isEmpty && !hasText }
}

/// Capabilities the executors need for video.
public protocol VideoAIServices: Sendable {
    func candidates(for target: ObjectTarget, in clip: VideoClip, timeline: VideoTimeline, at time: Double) async throws -> [ObjectCandidate]
    /// Renders a new media file with the object removed across the clip.
    func removeObject(candidates: [ObjectCandidate], target: ObjectTarget, from clip: VideoClip, timeline: VideoTimeline,
                      progress: @escaping @Sendable (Double) -> Void) async throws -> MediaAsset
    func stabilize(clip: VideoClip, timeline: VideoTimeline, progress: @escaping @Sendable (Double) -> Void) async throws -> MediaAsset
    /// Renders the clip's range played backwards.
    func reverse(clip: VideoClip, timeline: VideoTimeline, progress: @escaping @Sendable (Double) -> Void) async throws -> MediaAsset
    func extractFrame(at time: Double, timeline: VideoTimeline) async throws -> MediaAsset
    func freezeFrame(at time: Double, duration: Double, timeline: VideoTimeline) async throws -> MediaAsset
    /// Person/subject matte rendered as an alpha video, for background effects.
    func subjectMatte(for clip: VideoClip, timeline: VideoTimeline, progress: @escaping @Sendable (Double) -> Void) async throws -> MediaAsset

    // Magic tools. Each has a default that reports the tool as unavailable, so
    // fakes and older back ends only implement what they support.

    /// Words spoken in the timeline's own sound (clips, not music), with timeline times.
    func transcribe(timeline: VideoTimeline, progress: @escaping @Sendable (Double) -> Void) async throws -> (words: [CaptionWord], language: String?)
    /// The clips' mixed sound as mono PCM on the timeline clock (music excluded), for jump cuts.
    func dialogueSignal(timeline: VideoTimeline) async throws -> AudioSignal
    /// A sound track's source as mono PCM, for beat tracking.
    func musicSignal(track: AudioTrack) async throws -> AudioSignal
    /// Where the main subject is across a clip (clip-relative seconds, source-normalised points, y down).
    func focusSamples(for clip: VideoClip, timeline: VideoTimeline, progress: @escaping @Sendable (Double) -> Void) async throws -> [FocusSample]
    /// A copy of the clip's sound with the voice isolated from background noise.
    func isolateVoice(clip: VideoClip, timeline: VideoTimeline, progress: @escaping @Sendable (Double) -> Void) async throws -> MediaAsset
    /// Colour statistics of a clip, sampled from a few frames.
    func colorStatistics(clip: VideoClip, timeline: VideoTimeline) async throws -> ColorStatistics
    /// How good each moment of a clip looks and sounds, as offsets along its span.
    func momentScores(for clip: VideoClip, timeline: VideoTimeline, progress: @escaping @Sendable (Double) -> Void) async throws -> [MomentScore]
    /// Where the shot changes inside a clip, as offsets on the clip's own timeline span.
    func sceneCuts(for clip: VideoClip, timeline: VideoTimeline, sensitivity: Double, progress: @escaping @Sendable (Double) -> Void) async throws -> [Double]
    /// Follows whatever is at `point` (normalised, y down) in the finished picture at `time`,
    /// forwards and backwards within `span`; timeline times, as far as the subject stays visible.
    func track(point: PSPoint, at time: Double, within span: TimeSpan, timeline: VideoTimeline, progress: @escaping @Sendable (Double) -> Void) async throws -> [TrackSample]
}

public extension VideoAIServices {
    func transcribe(timeline: VideoTimeline, progress: @escaping @Sendable (Double) -> Void) async throws -> (words: [CaptionWord], language: String?) {
        throw PicshopError.unsupportedOperation("Captions")
    }
    func dialogueSignal(timeline: VideoTimeline) async throws -> AudioSignal { throw PicshopError.unsupportedOperation("Remove silences") }
    func musicSignal(track: AudioTrack) async throws -> AudioSignal { throw PicshopError.unsupportedOperation("Beat detection") }
    func focusSamples(for clip: VideoClip, timeline: VideoTimeline, progress: @escaping @Sendable (Double) -> Void) async throws -> [FocusSample] {
        throw PicshopError.unsupportedOperation("Smart reframe")
    }
    func isolateVoice(clip: VideoClip, timeline: VideoTimeline, progress: @escaping @Sendable (Double) -> Void) async throws -> MediaAsset {
        throw PicshopError.unsupportedOperation("Voice isolation")
    }
    func colorStatistics(clip: VideoClip, timeline: VideoTimeline) async throws -> ColorStatistics { throw PicshopError.unsupportedOperation("Colour match") }
    func track(point: PSPoint, at time: Double, within span: TimeSpan, timeline: VideoTimeline, progress: @escaping @Sendable (Double) -> Void) async throws -> [TrackSample] {
        throw PicshopError.unsupportedOperation("Tracking")
    }
    func sceneCuts(for clip: VideoClip, timeline: VideoTimeline, sensitivity: Double, progress: @escaping @Sendable (Double) -> Void) async throws -> [Double] {
        throw PicshopError.unsupportedOperation("Scene detection")
    }
    func momentScores(for clip: VideoClip, timeline: VideoTimeline, progress: @escaping @Sendable (Double) -> Void) async throws -> [MomentScore] {
        throw PicshopError.unsupportedOperation("Highlights")
    }
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
    /// Open the sound picker. `at` is the timeline second the new track starts
    /// at (nil = the playhead); `replace` swaps the existing tracks instead of
    /// adding another one.
    case pickMusic(query: String?, at: Double?, replace: Bool)
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

// MARK: - PDF

/// A located text match inside a PDF page.
public struct PDFTextHit: Hashable, Codable, Sendable {
    public var pageIndex: Int
    /// Normalised rectangles (top-left origin, in displayed page space).
    public var rects: [PSRect]
    public var text: String
    /// Colour of the page behind the words (sampled on scans), nil for white.
    public var background: PSColor?
    /// Installed font name matching the original words (read from the text layer, or estimated on scans).
    public var fontName: String?
    /// Point size of the original text relative to the page height; nil when only the glyph box is known (scans).
    public var relativeFontSize: Double?
    /// Punctuation glued to the last word on the page ("Monsieur," → ","); a replacement keeps it.
    public var suffix: String = ""

    public init(pageIndex: Int, rects: [PSRect], text: String, background: PSColor? = nil, fontName: String? = nil, relativeFontSize: Double? = nil) {
        self.pageIndex = pageIndex
        self.rects = rects
        self.text = text
        self.background = background
        self.fontName = fontName
        self.relativeFontSize = relativeFontSize
    }
}

/// PDFKit-backed capabilities the PDF executor needs.
public protocol PDFAIServices: Sendable {
    /// Finds `query` (case-insensitive). `pageIndex` nil searches the whole document.
    func findText(_ query: String, in document: PDFDocumentModel, pageIndex: Int?) async throws -> [PDFTextHit]
    /// Renders a page to an image asset in the project package and saves it to Photos.
    func extractPage(_ pageIndex: Int, from document: PDFDocumentModel) async throws -> MediaAsset
    /// The user's saved signature image, if any.
    func signatureAsset() async -> MediaAsset?
}
