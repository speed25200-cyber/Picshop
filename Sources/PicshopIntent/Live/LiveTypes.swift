import Foundation
import PicshopCore

// Value types shared by Picshop Live's pure layer, its Apple-side session and
// the views. Pure Swift: builds and tests on Linux.

// MARK: - What the UI shows

/// The one state every Live view reads.
public enum LiveState: Equatable, Sendable {
    case off, connecting, listening, hearing, thinking, speaking, acting, dictating
    /// Shown 1.6 s, then back to listening or off.
    case problem(LiveProblem)
}

public enum LiveProblem: Equatable, Sendable {
    case noMicrophone, noSpeechRecognition(language: String), offline, refusal
    case keyInvalid, noCredit, noAccess, rateLimited, unavailable(String)
}

/// A caption split into its settled words and the recognizer's still-changing tail.
public struct LiveCaption: Equatable, Sendable {
    public var stable: String
    public var volatile: String

    public init(stable: String = "", volatile: String = "") {
        self.stable = stable
        self.volatile = volatile
    }

    public var text: String {
        if stable.isEmpty { return volatile }
        if volatile.isEmpty { return stable }
        return stable + " " + volatile
    }

    public var isEmpty: Bool { stable.isEmpty && volatile.isEmpty }
}

public struct LiveTranscript: Equatable, Sendable {
    public var turnID: Int
    public var user: LiveCaption
    public var userIsFinal: Bool
    /// Silent but not committed: breathing ellipsis.
    public var userPaused: Bool
    /// The chunk playing now, never ahead of the voice.
    public var assistant: String

    public init() {
        turnID = 0
        user = LiveCaption()
        userIsFinal = false
        userPaused = false
        assistant = ""
    }
}

public struct LiveActivity: Equatable, Sendable {
    /// Built from validated step labels, in the reply language.
    public var title: String
    public var progress: Double?

    public init(title: String, progress: Double? = nil) {
        self.title = title
        self.progress = progress
    }
}

public struct LiveRoute: Equatable, Sendable {
    public enum Brain: String, Sendable { case claude, onDevice, commands }
    public var brain: Brain
    /// True only after a 2xx on a request carrying an image block.
    public var sharesMedia: Bool
    public var imagesSent: Int
    public var isUploading: Bool

    public init(brain: Brain = .onDevice, sharesMedia: Bool = false, imagesSent: Int = 0, isUploading: Bool = false) {
        self.brain = brain
        self.sharesMedia = sharesMedia
        self.imagesSent = imagesSent
        self.isUploading = isUploading
    }
}

public struct LiveUndoOffer: Equatable, Sendable {
    public var id: Int
    public var label: String

    public init(id: Int, label: String) {
        self.id = id
        self.label = label
    }
}

public struct LiveReply: Equatable, Sendable {
    public var id: Int
    public var text: String
    public var isProblem: Bool
    public var isError: Bool

    public init(id: Int, text: String, isProblem: Bool = false, isError: Bool = false) {
        self.id = id
        self.text = text
        self.isProblem = isProblem
        self.isError = isError
    }
}

public struct LiveNotice: Equatable, Sendable {
    public enum Action: String, Sendable { case none, allowMicrophone, openSettings }
    public var id: Int
    public var text: String
    public var isProblem: Bool
    public var action: Action

    public init(id: Int, text: String, isProblem: Bool, action: Action = .none) {
        self.id = id
        self.text = text
        self.isProblem = isProblem
        self.action = action
    }
}

/// Numbered candidates the user picks from ("le deuxième", or a tap).
public struct LiveChoiceRequest: Equatable, Sendable {
    public struct Candidate: Equatable, Sendable, Identifiable {
        /// 1-based, as spoken.
        public var id: Int
        /// spokenDescription, e.g. dog (left).
        public var label: String

        public init(id: Int, label: String) {
            self.id = id
            self.label = label
        }
    }

    public var question: String
    public var candidates: [Candidate]
    public var allowsAll: Bool

    public init(question: String, candidates: [Candidate], allowsAll: Bool) {
        self.question = question
        self.candidates = candidates
        self.allowsAll = allowsAll
    }
}

/// `index` is 1-based.
public enum LiveCandidateChoice: Equatable, Sendable { case index(Int), all }

// MARK: - Ideas

/// SF Symbols an idea chip may show. Anything else becomes `sparkles`.
public enum IdeaSymbols {
    public static let allowed: Set<String> = [
        "sparkles", "wand.and.stars", "sun.max", "cloud.sun", "person.crop.circle", "camera.aperture", "eraser", "crop", "textformat",
        "paintpalette", "captions.bubble", "scissors", "music.note", "rectangle.portrait", "highlighter", "signature", "film.stack",
        "circle.lefthalf.filled", "camera.filters", "arrow.up.left.and.arrow.down.right",
    ]

    public static func sanitize(_ symbol: String?) -> String {
        guard let symbol, allowed.contains(symbol) else { return "sparkles" }
        return symbol
    }
}

/// A tappable suggestion. Tapping runs its validated steps locally, with no model call.
public struct LiveIdea: Equatable, Sendable, Identifiable, Codable {
    public enum Source: String, Sendable, Codable { case heuristic, onDevice, claude }

    /// FNV-1a 64-bit hex of the steps serialized with JSONValue.
    public let id: String
    /// 1...26 characters, at most 4 words (truncated by init).
    public var title: String
    /// At most 90 characters.
    public var why: String
    /// IdeaSymbols.sanitize.
    public var symbol: String
    /// 1...4, validated for the mode.
    public var steps: [RawIntentStep]
    public var source: Source

    public init(title: String, why: String, symbol: String?, steps: [RawIntentStep], source: Source) {
        id = LiveIdea.identifier(for: steps)
        let words = title.split(whereSeparator: { $0.isWhitespace }).prefix(4).joined(separator: " ")
        self.title = String(words.prefix(26))
        self.why = String(why.trimmingCharacters(in: .whitespacesAndNewlines).prefix(90))
        self.symbol = IdeaSymbols.sanitize(symbol)
        self.steps = steps
        self.source = source
    }

    static func identifier(for steps: [RawIntentStep]) -> String {
        let value = (try? JSONEncoder().encode(steps)).flatMap { try? JSONDecoder().decode(JSONValue.self, from: $0) } ?? .null
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in value.serialized().utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        let hex = String(hash, radix: 16)
        return String(repeating: "0", count: max(0, 16 - hex.count)) + hex
    }
}

public enum LiveIdeasState: Equatable, Sendable { case loading, ready([LiveIdea]) }

// MARK: - What the editor tells Live

public struct LiveImage: Sendable, Hashable {
    public var jpeg: Data
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var version: Int
    /// Video: clip<n>@<revision>.
    public var frameKey: String?

    public init(jpeg: Data, pixelWidth: Int, pixelHeight: Int, version: Int, frameKey: String? = nil) {
        self.jpeg = jpeg
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.version = version
        self.frameKey = frameKey
    }
}

public struct VideoFacts: Sendable, Equatable {
    public var duration: Double
    public var playhead: Double
    public var clipDurations: [Double]
    public var currentClip: Int?
    public var musicTracks: Int
    public var hasCaptions: Bool
    public var isVertical: Bool

    public init(duration: Double, playhead: Double, clipDurations: [Double], currentClip: Int?, musicTracks: Int, hasCaptions: Bool, isVertical: Bool) {
        self.duration = duration
        self.playhead = playhead
        self.clipDurations = clipDurations
        self.currentClip = currentClip
        self.musicTracks = musicTracks
        self.hasCaptions = hasCaptions
        self.isVertical = isVertical
    }
}

/// The editor facts sent with a Live turn.
public struct LiveEditorState: Sendable, Equatable {
    public var mode: EditorMode
    public var version: Int
    public var canvasPixels: PSSize? = nil
    /// History labels, oldest first, last 12.
    public var appliedEdits: [String] = []
    public var adjustments: Adjustments = .neutral
    public var selection: String? = nil
    public var pendingQuestion: String? = nil
    /// "1: dog (left)".
    public var candidates: [String] = []
    public var scene: SceneDescription? = nil
    public var video: VideoFacts? = nil
    /// Text layers, words near the playhead: sent as user-message data, never role:system.
    public var mediaText: [String] = []
    public var hasGenerativeEngine: Bool = false
    public var canUndo: Bool = false
    public var busyTitle: String? = nil

    public init(mode: EditorMode, version: Int) {
        self.mode = mode
        self.version = version
    }
}

public struct LiveRunResult: Sendable, Equatable {
    public var outcome: CommandOutcome
    public var effects: [EditorEffect]

    public init(outcome: CommandOutcome, effects: [EditorEffect] = []) {
        self.outcome = outcome
        self.effects = effects
    }
}

public struct LiveCommandReply: Sendable, Equatable {
    public var text: String
    public var isProblem: Bool
    public var isError: Bool
    public var language: String

    public init(text: String, isProblem: Bool, isError: Bool, language: String) {
        self.text = text
        self.isProblem = isProblem
        self.isError = isError
        self.language = language
    }
}

// MARK: - What a local run reports

public struct LiveStepResult: Sendable, Equatable {
    public enum Status: String, Sendable {
        case applied, info, needsClarification = "needs_clarification", needsUser = "needs_user", failed, ignored, skipped, running, queued
    }

    public var index: Int
    public var action: IntentAction
    public var status: Status
    public var label: String?
    public var message: String?
    public var candidates: [String]
    /// select_region | tap_to_erase | crop_handles
    public var needsUser: String?

    public init(index: Int, action: IntentAction, status: Status, label: String? = nil, message: String? = nil, candidates: [String] = [], needsUser: String? = nil) {
        self.index = index
        self.action = action
        self.status = status
        self.label = label
        self.message = message
        self.candidates = candidates
        self.needsUser = needsUser
    }
}

public struct LiveExecution: Sendable, Equatable {
    public var steps: [LiveStepResult]
    public var version: Int
    public var canUndo: Bool

    public init(steps: [LiveStepResult], version: Int, canUndo: Bool) {
        self.steps = steps
        self.version = version
        self.canUndo = canUndo
    }

    public var allApplied: Bool { !steps.isEmpty && steps.allSatisfy { $0.status == .applied } }

    public var anyApplied: Bool { steps.contains { $0.status == .applied } }

    /// What to say or show after a local run.
    public func outcomeText(language: NormalizedUtterance.Language) -> String {
        // Phase 0 stub.
        ""
    }
}

// MARK: - Claude key

public enum ClaudeKeyStatus: Equatable, Sendable { case unchecked, malformed, valid, invalid, noAccess, noCredit, rateLimited, offline, server(Int) }

/// Offline sanity check of an Anthropic API key, and log redaction.
public enum APIKeyFormat {
    /// Trimmed; sk-ant- prefix; not sk-ant-admin; 40...256 characters; [A-Za-z0-9_-] only.
    public static func looksValid(_ key: String) -> Bool {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard key.hasPrefix("sk-ant-"), !key.hasPrefix("sk-ant-admin"), (40...256).contains(key.count) else { return false }
        return key.unicodeScalars.allSatisfy(isKeyScalar)
    }

    /// sk-ant-...A1b2
    public static func mask(_ key: String) -> String {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        return "sk-ant-..." + String(key.suffix(4))
    }

    /// Every sk-ant-[A-Za-z0-9_-]+ becomes sk-ant-...
    public static func redact(_ text: String) -> String {
        text.replacingOccurrences(of: "sk-ant-[A-Za-z0-9_-]+", with: "sk-ant-...", options: .regularExpression)
    }

    private static func isKeyScalar(_ scalar: Unicode.Scalar) -> Bool {
        ("a"..."z").contains(scalar) || ("A"..."Z").contains(scalar) || ("0"..."9").contains(scalar) || scalar == "_" || scalar == "-"
    }
}
