import Foundation
import PicshopCore

/// Cuts streaming reply text into chunks the speech synthesizer can start on
/// early: a short first chunk, then whole sentences.
public struct SpeechChunker: Sendable {
    private let language: NormalizedUtterance.Language
    private var buffer = ""
    public private(set) var lastEndsWithQuestion = false

    public init(language: NormalizedUtterance.Language) {
        self.language = language
    }

    public mutating func append(_ delta: String) -> [String] {
        // Phase 0 stub: everything is spoken at finish().
        buffer += delta
        return []
    }

    public mutating func finish() -> [String] {
        // Phase 0 stub.
        let text = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        buffer = ""
        guard !text.isEmpty else { return [] }
        lastEndsWithQuestion = text.hasSuffix("?")
        return [text]
    }
}

/// Makes model text fit to be read aloud.
public enum SpeakableText {
    public static func clean(_ text: String) -> String {
        // Phase 0 stub.
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
