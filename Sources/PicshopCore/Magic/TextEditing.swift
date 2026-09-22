import Foundation

/// Editing a video by editing its words. The captions carry the time of
/// every word, so striking words out of the transcript is the same as
/// cutting those moments out of the timeline — the way Descript works,
/// on the phone and offline.
public enum TranscriptEditor {
    /// Room left around a cut so the neighbouring words keep their attack and tail.
    public static let guardBand = 0.03
    /// Longest pause a cut takes with it; a longer silence after the words stays.
    public static let maximumPauseTaken = 0.6

    /// Timeline ranges that remove the words at `indices` (into `words`, sorted
    /// by time). Neighbouring struck words become one cut. Each cut takes the
    /// pause after it and keeps the one before, so the sentence closes up
    /// with a natural breath instead of a jump.
    public static func ranges(removing indices: Set<Int>, from words: [CaptionWord]) -> [TimeSpan] {
        let valid = indices.filter { words.indices.contains($0) }.sorted()
        guard !valid.isEmpty else { return [] }
        var runs: [ClosedRange<Int>] = []
        for index in valid {
            if let last = runs.last, last.upperBound + 1 == index {
                runs[runs.count - 1] = last.lowerBound...index
            } else {
                runs.append(index...index)
            }
        }
        var ranges: [TimeSpan] = []
        for run in runs {
            let first = words[run.lowerBound], last = words[run.upperBound]
            let previousEnd = run.lowerBound > 0 ? words[run.lowerBound - 1].end : max(0, first.start - 0.2)
            var start = first.start - guardBand
            if start < previousEnd + guardBand { start = max(previousEnd, (previousEnd + first.start) / 2) }
            var end: Double
            if run.upperBound + 1 < words.count {
                let nextStart = words[run.upperBound + 1].start
                end = min(nextStart - guardBand, last.end + maximumPauseTaken)
                if end < last.end { end = max(last.end, min(nextStart, (last.end + nextStart) / 2)) }
            } else {
                end = last.end + guardBand
            }
            start = max(0, start)
            guard end - start > 0.02 else { continue }
            ranges.append(TimeSpan(start: start, end: end))
        }
        return merged(ranges)
    }

    /// Sorted, non-overlapping ranges; ranges closer than 50 ms join.
    public static func merged(_ ranges: [TimeSpan]) -> [TimeSpan] {
        var result: [TimeSpan] = []
        for range in ranges.filter({ !$0.isEmpty }).sorted(by: { $0.start < $1.start }) {
            if let last = result.last, range.start <= last.end + 0.05 {
                result[result.count - 1] = TimeSpan(start: last.start, end: max(last.end, range.end))
            } else {
                result.append(range)
            }
        }
        return result
    }

    // MARK: - Fillers

    /// Hesitations a recogniser writes down, in French and English.
    public static let fillerWords: Set<String> = [
        "euh", "euhh", "euhm", "heu", "heum", "hum", "humm", "hmm", "hm", "mmh", "mhm", "mm", "bah", "beh",
        "um", "umm", "uh", "uhh", "uhm", "erm", "er", "ehm",
    ]

    /// Doubled words that are grammar, not stutter ("nous nous sommes", "had had").
    static let legitimateRepeats: Set<String> = ["nous", "vous", "had", "that", "is", "bien", "tres", "very", "so", "non", "no", "oui", "yes", "si"]

    /// Where the speaker hesitates.
    public struct Fillers: Sendable, Equatable {
        /// Words to strike: written hesitations and the first of a stuttered pair.
        public var wordIndices: Set<Int>
        /// Voiced sounds between two recognised words that the recogniser left
        /// out — almost always an "euh" it chose not to write.
        public var hesitations: [TimeSpan]

        public var isEmpty: Bool { wordIndices.isEmpty && hesitations.isEmpty }
        public var count: Int { wordIndices.count + hesitations.count }
    }

    public static func fillers(in words: [CaptionWord], envelope: LoudnessEnvelope? = nil) -> Fillers {
        let keys = words.map { key(for: $0.text) }
        var indices = Set<Int>()
        for (index, key) in keys.enumerated() where fillerWords.contains(key) {
            indices.insert(index)
        }
        // "je je pense" → the first "je" goes.
        for index in keys.indices.dropLast() {
            let key = keys[index]
            guard !key.isEmpty, key == keys[index + 1], !legitimateRepeats.contains(key), Double(key) == nil,
                  words[index + 1].start - words[index].end < 0.6 else { continue }
            indices.insert(index)
        }
        var hesitations: [TimeSpan] = []
        if let envelope, let threshold = SilenceDetector(sensitivity: 0.35).threshold(for: envelope) {
            for index in words.indices.dropLast() {
                let gap = TimeSpan(start: words[index].end + 0.08, end: words[index + 1].start - 0.08)
                guard gap.duration >= 0.25, gap.duration <= 2.0 else { continue }
                if let voiced = longestVoicedRun(in: gap, envelope: envelope, threshold: threshold), voiced.duration >= 0.25,
                   voiced.duration >= gap.duration * 0.45 {
                    hesitations.append(TimeSpan(start: max(words[index].end + guardBand, voiced.start - guardBand),
                                                end: min(words[index + 1].start - guardBand, voiced.end + guardBand)))
                }
            }
        }
        return Fillers(wordIndices: indices, hesitations: hesitations)
    }

    /// Ranges that remove every filler, merged.
    public static func ranges(removing fillers: Fillers, from words: [CaptionWord]) -> [TimeSpan] {
        merged(ranges(removing: fillers.wordIndices, from: words) + fillers.hesitations)
    }

    static func longestVoicedRun(in span: TimeSpan, envelope: LoudnessEnvelope, threshold: Float) -> TimeSpan? {
        guard envelope.hop > 0, !envelope.decibels.isEmpty else { return nil }
        let first = max(0, Int((span.start / envelope.hop).rounded(.down)))
        let last = min(envelope.decibels.count - 1, Int((span.end / envelope.hop).rounded(.up)))
        guard last > first else { return nil }
        var best: (Int, Int)?
        var runStart: Int?
        for index in first...(last + 1) {
            let voiced = index <= last && envelope.decibels[index] >= threshold
            if voiced, runStart == nil { runStart = index }
            if !voiced, let start = runStart {
                runStart = nil
                if best == nil || index - start > best!.1 - best!.0 { best = (start, index) }
            }
        }
        return best.map { TimeSpan(start: envelope.time(at: $0.0), end: envelope.time(at: $0.1)) }
    }

    // MARK: - Finding words

    /// Every place the phrase is said, as ranges of word indices. Punctuation,
    /// case and accents are ignored, so « coupe "bon alors" » finds "Bon, alors…".
    public static func occurrences(of phrase: String, in words: [CaptionWord]) -> [ClosedRange<Int>] {
        // Compared as one run of letters so "l'image" matches "l'" + "image" and the other way round.
        let needle = key(for: phrase)
        guard !needle.isEmpty else { return [] }
        let keys = words.map { key(for: $0.text) }
        var found: [ClosedRange<Int>] = []
        var index = 0
        while index < keys.count {
            var joined = ""
            var end = index
            var matched: Int?
            while end < keys.count, joined.count < needle.count {
                joined += keys[end]
                if joined == needle { matched = end; break }
                guard needle.hasPrefix(joined) else { break }
                end += 1
            }
            if let matched, !keys[index].isEmpty {
                found.append(index...matched)
                index = matched + 1
            } else {
                index += 1
            }
        }
        return found
    }

    /// The sentence around a word: from after the previous full stop to the next one.
    public static func sentence(containing index: Int, in words: [CaptionWord]) -> ClosedRange<Int> {
        guard words.indices.contains(index) else { return index...index }
        func endsSentence(_ i: Int) -> Bool { words[i].text.last.map { ".!?…".contains($0) } ?? false }
        var start = index
        while start > 0, !endsSentence(start - 1), words[start].start - words[start - 1].end < 1.2 { start -= 1 }
        var end = index
        while end < words.count - 1, !endsSentence(end), words[end + 1].start - words[end].end < 1.2 { end += 1 }
        return start...end
    }

    /// Lowercased, accent-free letters and digits only, used for matching.
    public static func key(for text: String) -> String {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).lowercased()
        return String(String.UnicodeScalarView(folded.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }))
    }
}
