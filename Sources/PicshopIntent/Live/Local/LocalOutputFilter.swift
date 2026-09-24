import Foundation
import PicshopCore

/// Splits a local model's streamed text into what may be spoken and the tool
/// calls it wrote as text, so no markup ever reaches the voice.
///
/// Qwen3.5 writes tool calls in its XML-function dialect:
///
///     Je réchauffe un peu.
///     <tool_call>
///     <function=apply_edits>
///     <parameter=steps>
///     [{"action": "adjust", "parameter": "temperature", "amount": 15}]
///     </parameter>
///     </function>
///     </tool_call>
///
/// and now and then in the older JSON dialect
/// (`<tool_call>{"name": "undo", "arguments": {}}</tool_call>`). The filter:
/// - holds back any trailing prefix of a tag (`<tool_c`, `<thi`, `<|im_`), so a
///   tag cut across deltas is never spoken;
/// - drops `<think>…</think>` blocks and stray closing tags;
/// - stops at `<|im_end|>`, `<|endoftext|>`, a hallucinated `<|im_start|>` or
///   `<tool_response>`: whatever follows is not the assistant's to say;
/// - parses both dialects, framed by `<tool_call>` or bare (`<function=…>`, a
///   JSON object with a "name"), one or more calls per turn, and hands each
///   one over as soon as its `</function>` (or closing brace) arrives;
/// - reports an unreadable call as `.malformed` with its raw text;
/// - cleans speech: no tag, brace, bracket, markdown marker or emoji ever
///   reaches the voice, and leading blank lines are dropped.
///
/// Parameter values stay as the model wrote them: JSON arrays and objects are
/// parsed, scalars stay strings. ToolArgumentCoercer types them per tool.
public struct LocalOutputFilter: Sendable {
    public enum Piece: Sendable, Equatable {
        case speech(String)
        case toolCall(name: String, arguments: JSONValue)
        /// Markup that looked like a tool call but could not be read.
        case malformed(String)
    }

    private enum Mode: Sendable, Equatable { case speech, think, call, skip, stopped }

    private var mode: Mode = .speech
    /// Speech-mode text held back: a possible tag or a possible JSON call.
    private var pending = ""
    /// The call being read: after `<tool_call>`, or from `<function=` / `{` when bare.
    private var call = ""
    /// The call opened with `<tool_call>` (else it is bare: `<function=…>` or a JSON object).
    private var framed = false
    /// Raw text of an unreadable call, dropped up to its `</tool_call>` (or `</function>` when bare).
    private var skipped = ""
    private var spokeYet = false
    private var atLineStart = true
    /// A blank delta between speech and what follows: spoken only before more words,
    /// so no piece is blank. Pieces otherwise keep their spaces, as the model streamed them.
    private var heldSpace = false
    private var endedWithSpace = false

    static let stopTags = ["<|im_end|>", "<|endoftext|>", "<|im_start|>", "<tool_response>"]
    static let knownTags = ["<think>", "</think>", "<tool_call>", "</tool_call>", "<function=", "</function>", "<parameter=", "</parameter>",
                            "</tool_response>"] + stopTags
    /// A call longer than this many characters (checked as 4 UTF-8 bytes each) is garbage.
    static let maxCall = 6_000
    /// A generic tag (`<b>`, `<|vision_start|>`) is at most this long.
    static let maxTag = 48

    public init() {}

    public mutating func feed(_ delta: String) -> [Piece] {
        guard mode != .stopped, !delta.isEmpty else { return [] }
        var out: [Piece] = []
        let text = pending + delta
        pending = ""
        process(text, atEnd: false, into: &out)
        return Self.merged(out)
    }

    /// Flushes whatever was held back at the end of the generation: an open call
    /// is read if it is complete but for its closing tag, else reported malformed.
    /// The filter is then ready for another generation.
    public mutating func finish() -> [Piece] {
        var out: [Piece] = []
        if mode != .stopped {
            let text = pending
            pending = ""
            process(text, atEnd: true, into: &out)
        }
        closeOpenCalls(into: &out)
        self = LocalOutputFilter()
        return Self.merged(out)
    }

    // MARK: The state machine

    private mutating func process(_ input: String, atEnd: Bool, into out: inout [Piece]) {
        var text = input
        while !text.isEmpty {
            switch mode {
            case .stopped:
                text = ""
            case .think:
                if let close = text.asciiRange(of: "</think>") {
                    text = String(text[close.upperBound...])
                    mode = .speech
                    atLineStart = true
                    continue
                }
                if Self.firstStop(in: text) != nil {
                    mode = .stopped
                    text = ""
                    continue
                }
                if !atEnd { pending = Self.trailingTagPrefix(of: text, among: ["</think>"] + Self.stopTags) }
                text = ""
            case .skip:
                skipped += text
                text = ""
                if let close = skipped.asciiRange(of: "</tool_call>") ?? (framed ? nil : skipped.asciiRange(of: "</function>")) {
                    out.append(.malformed(String(skipped[..<close.upperBound])))
                    text = String(skipped[close.upperBound...])
                    skipped = ""
                    mode = .speech
                    continue
                }
                if let stop = Self.firstStop(in: skipped) {
                    out.append(.malformed(String(skipped[..<stop.lowerBound])))
                    skipped = ""
                    mode = .stopped
                    continue
                }
                if skipped.utf8.count > Self.maxCall * 4 { skipped = String(skipped.prefix(Self.maxCall)) }
            case .call:
                call += text
                // Nothing can close or break a call before a ">" or a closing bracket arrives.
                let decisive = text.utf8.contains(where: { $0 == UInt8(ascii: ">") || $0 == UInt8(ascii: "}") || $0 == UInt8(ascii: "]") })
                text = ""
                if !decisive {
                    if call.utf8.count > Self.maxCall * 4 {
                        mode = .skip
                        skipped = ""
                        text = call
                        call = ""
                    }
                    continue
                }
                if let stop = Self.firstStop(in: call) {
                    // The turn ends inside the call: read what came before it.
                    call = String(call[..<stop.lowerBound])
                    closeOpenCalls(into: &out)
                    mode = .stopped
                    continue
                }
                switch scanCall(atEnd: false) {
                case .complete(let piece, let rest):
                    out.append(piece)
                    call = ""
                    mode = .speech
                    text = rest
                case .malformed(let consumed, let rest):
                    if let consumed {
                        // A bare call with a known end: reported, and speech goes on after it.
                        out.append(.malformed(consumed))
                        mode = .speech
                        text = rest
                    } else {
                        mode = .skip
                        skipped = ""
                        text = call
                    }
                    call = ""
                case .needMore:
                    if call.utf8.count > Self.maxCall * 4 {
                        mode = .skip
                        skipped = ""
                        text = call
                        call = ""
                    } else if atEnd {
                        text = ""
                    }
                }
            case .speech:
                text = speechStep(text, atEnd: atEnd, into: &out)
            }
        }
    }

    /// Speaks up to the next `<` or `{`, then decides what that character opens.
    /// Returns the text still to process.
    private mutating func speechStep(_ text: String, atEnd: Bool, into out: inout [Piece]) -> String {
        // Searched as bytes: both markers are ASCII, so the index is a valid string index.
        guard let marker = text.utf8.firstIndex(where: { $0 == UInt8(ascii: "<") || $0 == UInt8(ascii: "{") }) else {
            speak(text, into: &out)
            return ""
        }
        speak(String(text[..<marker]), into: &out)
        let rest = String(text[marker...])

        if rest.hasPrefix("{") {
            switch Self.bareJSONStart(rest) {
            case .call:
                mode = .call
                framed = false
                call = ""
                return rest
            case .maybe where !atEnd:
                pending = rest
                return ""
            case .maybe, .no:
                // A stray brace is never spoken.
                return String(rest.dropFirst())
            }
        }

        if let tag = Self.knownTags.first(where: { rest.hasPrefix($0) }) {
            switch tag {
            case "<think>":
                mode = .think
                return String(rest.dropFirst(tag.count))
            case "<tool_call>":
                mode = .call
                framed = true
                call = ""
                return String(rest.dropFirst(tag.count))
            case "<function=":
                mode = .call
                framed = false
                call = ""
                return rest
            case "<parameter=":
                // Parameters with no function: unreadable, skipped to the end of the call.
                mode = .skip
                framed = false
                skipped = ""
                return rest
            case _ where Self.stopTags.contains(tag):
                mode = .stopped
                return ""
            default:
                // A stray closing tag.
                return String(rest.dropFirst(tag.count))
            }
        }
        if Self.knownTags.contains(where: { $0.count > rest.count && $0.hasPrefix(rest) }) {
            // The start of a tag: wait for the rest, or drop it at the end of the stream.
            if !atEnd { pending = rest }
            return ""
        }
        if let end = Self.genericTagEnd(rest) {
            // <b>, </i>, <|vision_start|>: markup, dropped.
            return String(rest[end...])
        }
        if Self.couldBeGenericTag(rest) {
            if !atEnd { pending = rest }
            return ""
        }
        // A literal "<" ("moins de 5 < 10"): never spoken.
        return String(rest.dropFirst())
    }

    // MARK: Calls

    private enum Scan {
        case complete(Piece, rest: String)
        case needMore
        /// With `consumed`, the bad call's extent is known and `rest` follows it.
        case malformed(consumed: String?, rest: String)
    }

    /// Reads `call`. At the end of the stream, a call missing only its closing tags still counts.
    private func scanCall(atEnd: Bool) -> Scan {
        var body = Substring(call)
        while true {
            body = body.drop(while: \.isWhitespace)
            guard body.hasPrefix("<tool_call>") else { break }
            body = body.dropFirst("<tool_call>".count)
        }
        if body.isEmpty { return atEnd ? .malformed(consumed: nil, rest: "") : .needMore }

        if body.hasPrefix("<function=") {
            switch XMLCall.scan(body, allowMissingClose: atEnd) {
            case .complete(let name, let parameters, let end):
                var arguments: [String: JSONValue] = [:]
                for (key, value) in parameters { arguments[key] = Self.parameterValue(value) }
                return .complete(.toolCall(name: name, arguments: .object(arguments)), rest: Self.afterCall(body[end...]))
            case .needMore:
                return atEnd ? .malformed(consumed: nil, rest: "") : .needMore
            case .malformed:
                return .malformed(consumed: nil, rest: "")
            }
        }
        if body.hasPrefix("{") {
            guard let end = Self.endOfJSONObject(body) else {
                if atEnd, let piece = Self.jsonCall(body) { return .complete(piece, rest: "") }
                return atEnd ? .malformed(consumed: nil, rest: "") : .needMore
            }
            guard let piece = Self.jsonCall(body[..<end]) else {
                if framed { return .malformed(consumed: nil, rest: "") }
                return .malformed(consumed: String(body[..<end]), rest: Self.afterCall(body[end...]))
            }
            return .complete(piece, rest: Self.afterCall(body[end...]))
        }
        if !atEnd, "<function=".hasPrefix(String(body)) { return .needMore }
        return .malformed(consumed: nil, rest: "")
    }

    /// The stream is over: each open call is read if it is complete but for its
    /// closing tags, else reported; what follows a call is spoken.
    private mutating func closeOpenCalls(into out: inout [Piece]) {
        for _ in 0..<32 {
            switch mode {
            case .call:
                let text = call
                call = ""
                mode = .speech
                guard !text.allSatisfy(\.isWhitespace) else { continue }
                call = text
                let scan = scanCall(atEnd: true)
                call = ""
                switch scan {
                case .complete(let piece, let rest):
                    out.append(piece)
                    if !rest.isEmpty { process(rest, atEnd: true, into: &out) }
                case .needMore, .malformed:
                    out.append(.malformed(String(text.drop(while: \.isWhitespace))))
                }
            case .skip:
                if !skipped.isEmpty { out.append(.malformed(skipped)) }
                skipped = ""
                mode = .speech
            case .speech, .think, .stopped:
                return
            }
        }
    }

    /// What follows a call: its `</tool_call>` is consumed, the rest goes back to speech.
    private static func afterCall(_ text: Substring) -> String {
        let trimmed = text.drop(while: \.isWhitespace)
        if trimmed.hasPrefix("</tool_call>") { return String(trimmed.dropFirst("</tool_call>".count)) }
        return String(text)
    }

    /// A parameter value: JSON arrays, objects and quoted strings are parsed; anything else stays text.
    static func parameterValue(_ raw: Substring) -> JSONValue {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let first = value.first, first == "[" || first == "{" || first == "\"", let parsed = try? JSONValue.parse(value) { return parsed }
        return .string(value)
    }

    /// `{"name": "undo", "arguments": {...}}`, also with "parameters", string arguments,
    /// or wrapped in `{"function": {...}}`.
    static func jsonCall(_ text: Substring) -> Piece? {
        guard let object = ToolArgumentCoercer.lenientJSON(String(text))?.object else { return nil }
        let call = object["function"]?.object ?? object
        guard let name = call["name"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return nil }
        var arguments = call["arguments"] ?? call["parameters"] ?? .object([:])
        if case .string(let encoded) = arguments { arguments = ToolArgumentCoercer.lenientJSON(encoded) ?? .string(encoded) }
        if arguments == .null { arguments = .object([:]) }
        return .toolCall(name: name, arguments: arguments)
    }

    private enum BareJSON { case call, maybe, no }

    /// `{` then `"`: a JSON object, never speech.
    private static func bareJSONStart(_ text: String) -> BareJSON {
        let after = text.dropFirst().drop(while: \.isWhitespace)
        guard let first = after.first else { return .maybe }
        return first == "\"" ? .call : .no
    }

    /// The index just past the leading JSON object, honouring strings and escapes.
    static func endOfJSONObject(_ text: Substring) -> Substring.Index? {
        var depth = 0
        var inString = false
        var escaped = false
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if inString {
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    inString = false
                }
            } else if character == "\"" {
                inString = true
            } else if character == "{" || character == "[" {
                depth += 1
            } else if character == "}" || character == "]" {
                depth -= 1
                if depth == 0 { return text.index(after: index) }
                if depth < 0 { return nil }
            }
            index = text.index(after: index)
        }
        return nil
    }

    // MARK: Tags

    private static func firstStop(in text: String) -> Range<String.Index>? {
        stopTags.compactMap { text.asciiRange(of: $0) }.min { $0.lowerBound < $1.lowerBound }
    }

    /// The end of `text` that could still become one of `tags`.
    private static func trailingTagPrefix(of text: String, among tags: [String]) -> String {
        guard let last = text.lastIndex(of: "<") else { return "" }
        let tail = String(text[last...])
        return tags.contains { $0.count > tail.count && $0.hasPrefix(tail) } ? tail : ""
    }

    /// `<b>`, `</em>`, `<|vision_start|>`: the index past the `>`.
    private static func genericTagEnd(_ text: String) -> String.Index? {
        guard couldBeGenericTag(text) else { return nil }
        var index = text.index(after: text.startIndex)
        var count = 1
        while index < text.endIndex, count <= maxTag {
            let character = text[index]
            if character == ">" { return text.index(after: index) }
            if character == "<" || character.isNewline { return nil }
            index = text.index(after: index)
            count += 1
        }
        return nil
    }

    /// `<` followed by a letter, `/`, `|`, `!` or `?`, on one line, not too long.
    private static func couldBeGenericTag(_ text: String) -> Bool {
        let body = text.dropFirst()
        guard let second = body.first else { return true }
        guard second.isLetter || "/|!?".contains(second) else { return false }
        return text.count <= maxTag && !body.contains(where: \.isNewline)
    }

    // MARK: Speech

    /// Characters a voice must never read.
    static let unspeakable: Set<Character> = ["*", "`", "{", "}", "[", "]", "|", "\\", "~", "<", ">", "^"]
    /// List and heading markers at the start of a line.
    static let lineMarkers: Set<Character> = ["#", "-", "•", "*", ">", "+"]

    private mutating func speak(_ text: String, into out: inout [Piece]) {
        guard !text.isEmpty else { return }
        var clean = ""
        for character in text {
            if character.isNewline {
                atLineStart = true
                if clean.last?.isWhitespace != true { clean.append(" ") }
                continue
            }
            if atLineStart {
                if character.isWhitespace {
                    if clean.last?.isWhitespace != true { clean.append(" ") }
                    continue
                }
                if Self.lineMarkers.contains(character) { continue }
                atLineStart = false
            }
            if Self.unspeakable.contains(character) { continue }
            if character == "_" {
                clean.append(" ")
                continue
            }
            if Self.isEmoji(character) { continue }
            if character.isWhitespace, clean.last?.isWhitespace == true { continue }
            clean.append(character)
        }
        guard !clean.isEmpty else { return }
        if clean.allSatisfy(\.isWhitespace) {
            // Spoken only if words follow: never a blank piece after a call or at the end.
            if spokeYet, !endedWithSpace { heldSpace = true }
            return
        }
        if !spokeYet {
            clean = String(clean.drop(while: \.isWhitespace))
            spokeYet = true
        } else if endedWithSpace {
            clean = String(clean.drop(while: \.isWhitespace))
        } else if heldSpace, clean.first?.isWhitespace == false {
            clean = " " + clean
        }
        heldSpace = false
        endedWithSpace = clean.last?.isWhitespace == true
        out.append(.speech(clean))
    }

    /// Pictographs, flags, keycaps and their joiners; letters, digits and punctuation are kept.
    static func isEmoji(_ character: Character) -> Bool {
        // ASCII and the Latin, Greek and Cyrillic letters (under U+0800) are never pictographs.
        if character.utf8.count <= 2 { return false }
        for scalar in character.unicodeScalars {
            let properties = scalar.properties
            if properties.isEmojiPresentation { return true }
            if properties.isEmoji, scalar.value > 0x2000, !(0x2010...0x206F).contains(scalar.value) { return true }
            if [0xFE0F, 0x200D, 0x20E3].contains(scalar.value) { return true }
        }
        return false
    }

    private static func merged(_ pieces: [Piece]) -> [Piece] {
        var result: [Piece] = []
        for piece in pieces {
            if case .speech(let text) = piece, case .speech(let previous)? = result.last {
                result[result.count - 1] = .speech(previous + text)
            } else {
                result.append(piece)
            }
        }
        return result
    }
}

/// The Qwen XML-function payload: `<function=NAME>` then `<parameter=KEY>VALUE</parameter>`
/// pairs, then `</function>`. A value ends at its `</parameter>`, or, when the model
/// forgot it, at the next `<parameter=` or `</function>`.
enum XMLCall {
    enum Result {
        case complete(name: String, parameters: [(String, Substring)], end: Substring.Index)
        case needMore
        case malformed
    }

    static let open = "<function="
    static let close = "</function>"
    static let parameterOpen = "<parameter="
    static let parameterClose = "</parameter>"

    /// `text` starts with `<function=`. With `allowMissingClose` (end of stream),
    /// a missing `</function>` is forgiven, never a value cut before its end.
    static func scan(_ text: Substring, allowMissingClose: Bool) -> Result {
        guard text.hasPrefix(open) else { return .malformed }
        var index = text.index(text.startIndex, offsetBy: open.count)
        guard let nameEnd = text[index...].firstIndex(of: ">") else {
            return text[index...].contains(where: { $0.isWhitespace || $0 == "<" }) ? .malformed : .needMore
        }
        let name = text[index..<nameEnd].trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !name.contains(where: { $0.isWhitespace || $0 == "<" }) else { return .malformed }
        index = text.index(after: nameEnd)
        var parameters: [(String, Substring)] = []

        while true {
            index = text[index...].firstIndex(where: { !$0.isWhitespace }) ?? text.endIndex
            let rest = text[index...]
            if rest.isEmpty {
                return allowMissingClose ? .complete(name: name, parameters: parameters, end: index) : .needMore
            }
            if rest.hasPrefix(close) {
                return .complete(name: name, parameters: parameters, end: text.index(index, offsetBy: close.count))
            }
            if close.hasPrefix(String(rest)) || parameterOpen.hasPrefix(String(rest)) {
                return allowMissingClose ? .complete(name: name, parameters: parameters, end: index) : .needMore
            }
            guard rest.hasPrefix(parameterOpen) else { return .malformed }
            let keyStart = text.index(index, offsetBy: parameterOpen.count)
            guard let keyEnd = text[keyStart...].firstIndex(of: ">") else {
                return text[keyStart...].contains(where: { $0.isNewline || $0 == "<" }) ? .malformed : (allowMissingClose ? .malformed : .needMore)
            }
            let key = text[keyStart..<keyEnd].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty, !key.contains(where: { $0.isWhitespace || $0 == "<" }) else { return .malformed }
            let valueStart = text.index(after: keyEnd)
            let terminators = [parameterClose, parameterOpen, close].compactMap { tag in
                text[valueStart...].asciiRange(of: tag).map { (tag, $0) }
            }
            // A value cut by the end of the stream is never guessed at: the call is incomplete.
            guard let (tag, range) = terminators.min(by: { $0.1.lowerBound < $1.1.lowerBound }) else { return .needMore }
            parameters.append((key, text[valueStart..<range.lowerBound]))
            index = tag == parameterClose ? range.upperBound : range.lowerBound
        }
    }
}

extension StringProtocol {
    /// The first occurrence of an ASCII `needle`, searched as UTF-8 bytes (tags are
    /// ASCII, so the bounds are valid string indices). Much cheaper than a
    /// character-by-character search on long calls.
    func asciiRange(of needle: String) -> Range<Index>? {
        let pattern = Array(needle.utf8)
        guard let first = pattern.first else { return nil }
        let bytes = utf8
        var start = bytes.startIndex
        while let hit = bytes[start...].firstIndex(of: first) {
            var index = hit
            var matched = 0
            while matched < pattern.count, index < bytes.endIndex, bytes[index] == pattern[matched] {
                index = bytes.index(after: index)
                matched += 1
            }
            if matched == pattern.count { return hit..<index }
            if index == bytes.endIndex { return nil }
            start = bytes.index(after: hit)
        }
        return nil
    }
}
