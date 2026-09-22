import Foundation

/// One recognised word with its time on the timeline.
public struct CaptionWord: Hashable, Codable, Sendable {
    public var text: String
    public var start: Double
    public var end: Double

    public init(text: String, start: Double, end: Double) {
        self.text = text
        self.start = start
        self.end = max(start, end)
    }

    public var duration: Double { end - start }
}

/// A caption line shown for a stretch of time.
public struct CaptionCue: Hashable, Codable, Sendable, Identifiable {
    public var id: UUID
    public var words: [CaptionWord]

    public init(id: UUID = UUID(), words: [CaptionWord]) {
        self.id = id
        self.words = words
    }

    public var text: String { words.map(\.text).joined(separator: " ") }
    public var span: TimeSpan { TimeSpan(start: words.first?.start ?? 0, end: words.last?.end ?? 0) }

    /// Index of the word being spoken at `time` (the last one started), for karaoke styles.
    public func activeWordIndex(at time: Double) -> Int? {
        guard let first = words.first, time >= first.start else { return nil }
        return words.lastIndex { $0.start <= time }
    }
}

/// How captions look. Each style is a complete, tasteful preset so nobody has
/// to design subtitles: pick one and the rest follows.
public enum CaptionStyle: String, Codable, Sendable, CaseIterable, Identifiable {
    /// White, semibold, soft shadow — broadcast subtitles.
    case classic
    /// Big bold words, the spoken word lights up in the accent colour (short-form video).
    case karaoke
    /// Words appear one by one as they are said.
    case reveal
    /// Text on a rounded translucent box.
    case boxed
    /// Small, lowercase, quiet — documentary.
    case minimal

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .classic: return "Classic"
        case .karaoke: return "Karaoke"
        case .reveal: return "Reveal"
        case .boxed: return "Boxed"
        case .minimal: return "Minimal"
        }
    }

    public var frenchName: String {
        switch self {
        case .classic: return "Classique"
        case .karaoke: return "Karaoké"
        case .reveal: return "Mot à mot"
        case .boxed: return "Encadré"
        case .minimal: return "Minimal"
        }
    }

    public var aliases: [String] {
        switch self {
        case .classic: return ["classic", "classique", "standard", "normal", "broadcast", "tele"]
        case .karaoke: return ["karaoke", "tiktok", "reel", "pop", "highlight", "surligne", "dynamique", "dynamic"]
        case .reveal: return ["reveal", "word by word", "mot a mot", "mot par mot", "one word", "un mot"]
        case .boxed: return ["boxed", "box", "encadre", "boite", "fond", "background"]
        case .minimal: return ["minimal", "minimaliste", "discret", "subtle", "sobre"]
        }
    }

    public static func matching(_ text: String) -> CaptionStyle? {
        let query = text.normalizedForMatching
        var best: (CaptionStyle, Int)?
        for style in allCases {
            for alias in style.aliases where query.contains(alias) {
                if best == nil || alias.count > best!.1 { best = (style, alias.count) }
            }
        }
        return best?.0
    }

    /// Longest line before a cue breaks, in characters.
    public var maximumCharacters: Int {
        switch self {
        case .karaoke, .reveal: return 18
        case .classic, .boxed: return 38
        case .minimal: return 44
        }
    }

    /// Longest time a cue stays on screen.
    public var maximumDuration: Double {
        switch self {
        case .karaoke, .reveal: return 1.6
        case .classic, .boxed, .minimal: return 3.6
        }
    }

    public var isUppercase: Bool { self == .karaoke }
}

/// Timed captions for a whole video.
public struct CaptionTrack: Hashable, Codable, Sendable {
    public var cues: [CaptionCue]
    public var style: CaptionStyle
    /// Vertical position of the caption's centre, 0 = top, 1 = bottom.
    public var verticalPosition: Double
    public var textColor: PSColor
    public var highlightColor: PSColor
    /// Font size relative to the frame's shorter side.
    public var scale: Double
    public var isVisible: Bool
    /// BCP-47 language of the words ("fr-FR", "en-US").
    public var language: String?

    public init(cues: [CaptionCue] = [], style: CaptionStyle = .karaoke, verticalPosition: Double = 0.72, textColor: PSColor = .white,
                highlightColor: PSColor = PSColor(red: 1.0, green: 0.84, blue: 0.04), scale: Double = 1, isVisible: Bool = true, language: String? = nil) {
        self.cues = cues
        self.style = style
        self.verticalPosition = verticalPosition.clamped(to: 0.08...0.92)
        self.textColor = textColor
        self.highlightColor = highlightColor
        self.scale = scale.clamped(to: 0.5...2)
        self.isVisible = isVisible
        self.language = language
    }

    public var isEmpty: Bool { cues.isEmpty }

    /// The cue on screen at `time`.
    public func cue(at time: Double) -> CaptionCue? {
        guard isVisible else { return nil }
        return cues.first { $0.span.start <= time && time < $0.span.end + 0.15 }
    }

    public var transcript: String { cues.map(\.text).joined(separator: " ") }

    /// Rebuilds the cues from their words with the current style's line rules.
    public mutating func restyle(_ style: CaptionStyle) {
        self.style = style
        cues = CaptionBuilder.cues(from: cues.flatMap(\.words), style: style)
    }

    /// Captions after a range of the timeline was cut out: later words move earlier, removed words go.
    public func removing(_ range: TimeSpan) -> CaptionTrack {
        var copy = self
        let words = cues.flatMap(\.words).compactMap { word -> CaptionWord? in
            if word.end <= range.start { return word }
            if word.start >= range.end { return CaptionWord(text: word.text, start: word.start - range.duration, end: word.end - range.duration) }
            return nil
        }
        copy.cues = CaptionBuilder.cues(from: words, style: style)
        return copy
    }
}

/// Groups recognised words into readable caption cues.
public enum CaptionBuilder {
    /// Words are split into cues at sentence ends, long pauses, the style's
    /// line length and its maximum duration — the rules subtitlers follow.
    public static func cues(from words: [CaptionWord], style: CaptionStyle, pauseBreak: Double = 0.55) -> [CaptionCue] {
        let words = words.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.sorted { $0.start < $1.start }
        var cues: [CaptionCue] = []
        var current: [CaptionWord] = []
        var length = 0
        func flush() {
            if !current.isEmpty { cues.append(CaptionCue(words: current)) }
            current = []
            length = 0
        }
        for word in words {
            let text = word.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let cleaned = CaptionWord(text: text, start: word.start, end: word.end)
            if let last = current.last {
                let pause = cleaned.start - last.end
                let tooLong = length + 1 + text.count > style.maximumCharacters
                let tooSlow = cleaned.end - (current.first?.start ?? cleaned.start) > style.maximumDuration
                let sentenceEnded = last.text.last.map { ".!?…".contains($0) } ?? false
                if pause >= pauseBreak || tooLong || tooSlow || sentenceEnded { flush() }
            }
            current.append(cleaned)
            length += (length == 0 ? 0 : 1) + text.count
        }
        flush()
        // A lone short word hanging after a cue reads better on the previous line.
        var merged: [CaptionCue] = []
        for cue in cues {
            if cue.words.count == 1, let previous = merged.last,
               cue.words[0].start - (previous.words.last?.end ?? 0) < 0.25,
               previous.text.count + 1 + cue.text.count <= style.maximumCharacters,
               !(previous.words.last?.text.last.map { ".!?…".contains($0) } ?? false) {
                merged[merged.count - 1].words.append(contentsOf: cue.words)
            } else {
                merged.append(cue)
            }
        }
        return merged
    }

    /// Splits a phrase with a known time range into evenly timed words, for
    /// recognisers that only report timings per phrase.
    public static func words(in phrase: String, span: TimeSpan) -> [CaptionWord] {
        let tokens = phrase.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !tokens.isEmpty else { return [] }
        // Weight each word by its length so long words get more time.
        let weights = tokens.map { Double(max(2, $0.count)) }
        let total = weights.reduce(0, +)
        var cursor = span.start
        return zip(tokens, weights).map { token, weight in
            let duration = span.duration * weight / total
            defer { cursor += duration }
            return CaptionWord(text: token, start: cursor, end: cursor + duration)
        }
    }
}
