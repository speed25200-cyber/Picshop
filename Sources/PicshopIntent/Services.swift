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
    /// The framing a photographer would choose (normalised), nil when the photo is already well framed.
    func bestCrop(in document: PhotoDocument) async throws -> PSRect?
    /// The main table (canvas space, normalised, top-left), with styles and formats, or nil (D8).
    /// `remembered` (PhotoDocument.rememberedTable): when it matches the picture, its geometry, styles and
    /// formats are kept and only occupancy is read again; then the result is never nil.
    func tableGrid(in document: PhotoDocument, remembered: TableGrid?) async throws -> TableGrid?
    /// What the picture holds (text blocks with their measured style, objects and people, the table,
    /// free areas) for the document's base state, or nil when it cannot be read. Cached per
    /// `document.baseStateKey` and computed off the main actor; one text pass is shared with the table
    /// and erase queries. Picshop text layers are not in it: callers lay them over with `overlaying(_:)`.
    func sceneMap(in document: PhotoDocument) async throws -> SceneMap?
    /// Act-then-verify: checks the rendered result (base and layers) against each request (OCR inside the
    /// regions, the detector for removed objects), with one render and one text pass for all of them.
    /// One report per request, in order. The default checks the document alone (`EditVerifier.structural`).
    func verify(_ requests: [VerificationRequest], in document: PhotoDocument) async throws -> [VerificationReport]
}

public extension PhotoAIServices {
    func describe(_ document: PhotoDocument) async throws -> SceneDescription { SceneDescription() }
    func bestCrop(in document: PhotoDocument) async throws -> PSRect? { nil }
    func tableGrid(in document: PhotoDocument, remembered: TableGrid?) async throws -> TableGrid? { nil }
    func sceneMap(in document: PhotoDocument) async throws -> SceneMap? { nil }
    func verify(_ requests: [VerificationRequest], in document: PhotoDocument) async throws -> [VerificationReport] {
        requests.map { EditVerifier.structural($0, in: document) }
    }
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
    /// Faces through a clip, sampled several times a second (source seconds).
    func faceSamples(for clip: VideoClip, timeline: VideoTimeline, progress: @escaping @Sendable (Double) -> Void) async throws -> [FaceSample]
    /// How good each moment of a clip looks and sounds, as offsets along its span.
    func momentScores(for clip: VideoClip, timeline: VideoTimeline, progress: @escaping @Sendable (Double) -> Void) async throws -> [MomentScore]
    /// Texts translated on device, in order (`source` nil = guess from the text).
    func translate(_ texts: [String], from source: String?, to target: String) async throws -> [String]
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
    func translate(_ texts: [String], from source: String?, to target: String) async throws -> [String] {
        throw PicshopError.unsupportedOperation("Translation")
    }
    func faceSamples(for clip: VideoClip, timeline: VideoTimeline, progress: @escaping @Sendable (Double) -> Void) async throws -> [FaceSample] {
        throw PicshopError.unsupportedOperation("Face blur")
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
    /// Open the photo picker for a colour reference ("prends les couleurs d'une autre photo").
    case pickColorReference
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
        case .message(let message):
            // The machine channel (D10) says what happened; it never stands for a document change of its own.
            return ExecutionReason.isMachineMessage(message)
        case .undo, .redo, .revert, .compare, .zoom, .export, .share, .play, .pause, .seek, .help, .pickMusic, .pickBackground, .pickColorReference, .clarify, .confirm, .cancel:
            return false
        case .selectLayer, .selectClip:
            return true
        }
    } }

    /// The reason code the effects carry, if any.
    public var reason: ExecutionReason? { ExecutionReason(effects: effects) }
    /// The table report the effects carry, if any.
    public var tableReport: TableEditReport? { TableEditReport(effects: effects) }
}

// MARK: - Machine channel (D10)

/// Why a step did not do what was asked, as a code the model and Live read. Carried in
/// `EditorEffect.message("reason:<code>")`; never spoken.
public enum ExecutionReason: String, Sendable, Equatable, CaseIterable {
    case noSubject = "no_subject"
    case notFound = "not_found"
    case noTable = "no_table"
    case unknownRow = "unknown_row"
    case unknownColumn = "unknown_column"
    case ambiguous
    case nothingToDo = "nothing_to_do"
    case tooMany = "too_many"
    case needsSelection = "needs_selection"
    case unsupported
    /// A scene-map id ("t7", "o3") that is not on the picture any more, or never was.
    case unknownRef = "unknown_ref"
    /// A region or point outside the picture, or too small to act on.
    case badRegion = "bad_region"
    /// editText, removeText or moveText with no text to act on.
    case noText = "no_text"
    /// The step applied but the check on the rendered result failed (act-then-verify).
    case verifyFailed = "verify_failed"

    static let prefix = "reason:"

    /// `.message("reason:" + rawValue)`.
    public var effect: EditorEffect { .message(Self.prefix + rawValue) }

    /// The first reason among the effects.
    public init?(effects: [EditorEffect]) {
        for effect in effects {
            guard case .message(let message) = effect, message.hasPrefix(Self.prefix) else { continue }
            if let reason = ExecutionReason(rawValue: String(message.dropFirst(Self.prefix.count))) {
                self = reason
                return
            }
        }
        return nil
    }

    /// Messages of the machine channel ("reason:", "table:"): neutral for `changedDocument`.
    public static func isMachineMessage(_ message: String) -> Bool {
        message.hasPrefix(prefix) || message.hasPrefix(TableEditReport.prefix)
    }
}

/// What a table step did, for the model ("filled 44, kept 1, empty left 0"), the spoken line and the UI
/// toast. Carried in `EditorEffect.message("table:…")`.
public struct TableEditReport: Hashable, Sendable {
    public var action: IntentAction
    /// Cells written, cleared or highlighted.
    public var changed: Int
    /// Cells in scope left as they were (printed, or already filled).
    public var kept: Int
    /// Data cells still empty afterwards.
    public var emptyLeft: Int
    public var dataRows: Int
    public var dataColumns: Int
    /// "1", "random", "random 50–90".
    public var value: String?
    public var alternative: String?
    public var groupID: UUID?

    public init(action: IntentAction, changed: Int, kept: Int, emptyLeft: Int, dataRows: Int, dataColumns: Int,
                value: String? = nil, alternative: String? = nil, groupID: UUID? = nil) {
        self.action = action
        self.changed = changed
        self.kept = kept
        self.emptyLeft = emptyLeft
        self.dataRows = dataRows
        self.dataColumns = dataColumns
        self.value = value
        self.alternative = alternative
        self.groupID = groupID
    }

    static let prefix = "table:"
    static let valueLimit = 40

    /// `.message("table:action=fillCells;changed=44;kept=1;left=0;rows=9;cols=5;value=1;alt=random;group=<uuid>")`;
    /// value and alt percent-encoded; at most 200 characters.
    public var effect: EditorEffect {
        // The value and the alternative are the only open-ended fields: they shrink, the counts never do.
        for limit in [Self.valueLimit, 16, 8] {
            let message = message(valueLimit: limit)
            if message.count <= 200 { return .message(message) }
        }
        return .message(message(valueLimit: 0))
    }

    func message(valueLimit limit: Int) -> String {
        var fields = ["action=\(action.rawValue)", "changed=\(changed)", "kept=\(kept)", "left=\(emptyLeft)", "rows=\(dataRows)", "cols=\(dataColumns)"]
        if let value, limit > 0 { fields.append("value=" + Self.encode(String(value.prefix(limit)))) }
        if let alternative, limit > 0 { fields.append("alt=" + Self.encode(String(alternative.prefix(limit)))) }
        if let groupID { fields.append("group=" + groupID.uuidString) }
        return Self.prefix + fields.joined(separator: ";")
    }

    /// The first table report among the effects.
    public init?(effects: [EditorEffect]) {
        for effect in effects {
            guard case .message(let message) = effect, message.hasPrefix(Self.prefix) else { continue }
            var values: [String: String] = [:]
            for field in message.dropFirst(Self.prefix.count).split(separator: ";") {
                let parts = field.split(separator: "=", maxSplits: 1)
                guard parts.count == 2 else { continue }
                values[String(parts[0])] = String(parts[1])
            }
            guard let actionName = values["action"], let action = IntentAction(rawValue: actionName),
                  let changed = values["changed"].flatMap({ Int($0) }), let kept = values["kept"].flatMap({ Int($0) }),
                  let left = values["left"].flatMap({ Int($0) }), let rows = values["rows"].flatMap({ Int($0) }),
                  let columns = values["cols"].flatMap({ Int($0) }) else { continue }
            self.init(action: action, changed: changed, kept: kept, emptyLeft: left, dataRows: rows, dataColumns: columns,
                      value: values["value"].flatMap { $0.removingPercentEncoding }, alternative: values["alt"].flatMap { $0.removingPercentEncoding },
                      groupID: values["group"].flatMap { UUID(uuidString: $0) })
            return
        }
        return nil
    }

    /// Percent-encodes everything but letters, digits and a few safe marks, so ";" and "=" never break the fields.
    static func encode(_ text: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: ".-_~")
        return text.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }
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
