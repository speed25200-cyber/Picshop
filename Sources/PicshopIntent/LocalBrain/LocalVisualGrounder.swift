import Foundation
import PicshopCore

/// Box grounding on the local vision model (W2, D13). Intent cannot see PicshopUI's runtime, so it takes the
/// engine factory that lives here: per call it opens a short-lived engine (no tools, no history), sends the
/// JPEG with a one-line instruction, reads the first `[x1, y1, x2, y2]` (0–1000) or "none", and closes it.
/// No brain gate: MLX's ModelContainer already serialises generations, and a groundBox issued from a Live
/// tool call runs while the brain waits on the tool.
///
/// M5 installs it: `VisualGrounding.install(LocalVisualGrounder(makeEngine: { try await runtime.makeEngine($0) }, info: info))`.
public struct LocalVisualGrounder: VisualGrounder {
    private let makeEngine: LocalChatEngineFactory
    private let info: LocalModelInfo

    /// One generation, at most this long (§8.5).
    public static let timeout: Duration = .seconds(6)
    /// A box is four numbers: a short answer.
    static let maxTokens = 32

    /// The engine's whole system prompt: no persona, no tools, one job.
    public static let groundingSystem = """
        You find things in a picture. Answer with the box of the thing named, as [x1, y1, x2, y2] with integers 0-1000 \
        (top-left origin, x to the right, y down), or the single word none when it is not in the picture. Nothing else.
        """

    public init(makeEngine: @escaping LocalChatEngineFactory, info: LocalModelInfo) {
        self.makeEngine = makeEngine
        self.info = info
    }

    public func box(for phrase: String, imageJPEG: Data, language: NormalizedUtterance.Language) async -> PSRect? {
        let name = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard info.supportsVision, !name.isEmpty, !imageJPEG.isEmpty else { return nil }
        let makeEngine = self.makeEngine
        let message = Self.request(for: name, language: language)
        let answer = await Deadline.race(Self.timeout) { () async -> String? in
            guard let engine = try? await makeEngine(LocalChatSetup(system: Self.groundingSystem, tools: [], history: [],
                                                                    imageMaxPixels: LocalModelCatalog.imageMaxPixels)) else { return nil }
            var text = ""
            do {
                try await engine.prepare()
                var options = LocalGenerationOptions(style: .repair, maxTokens: Self.maxTokens)
                options.maxTokens = Self.maxTokens
                for try await event in engine.send([.user(message, imageJPEG: imageJPEG)], options: options) {
                    guard case .text(let chunk) = event else { continue }
                    text += chunk
                    // The first complete box is the answer: stop generating there (the stream's consumer ends).
                    if case .box? = Self.parse(text) { break }
                }
            } catch {
                await engine.close()
                return text.isEmpty ? nil : text
            }
            await engine.close()
            return text
        }
        guard let answer, case .box(let rect)? = Self.parse(answer) else { return nil }
        return rect
    }

    /// The one user line: the phrase in the speaker's language, quoted as data.
    static func request(for phrase: String, language: NormalizedUtterance.Language) -> String {
        let quoted = phrase.replacingOccurrences(of: "\"", with: "'").prefix(80)
        return language == .french
            ? "Où est « \(quoted) » ? Réponds [x1, y1, x2, y2] (0-1000) ou none."
            : "Where is \"\(quoted)\"? Answer [x1, y1, x2, y2] (0-1000) or none."
    }

    public enum Answer: Equatable, Sendable {
        case box(PSRect)
        case none
    }

    /// The first `[x1, y1, x2, y2]` in 0–1000 (as a normalised rect), or `.none` when the model says it is not
    /// there; nil while neither is readable yet. Boxes with a reversed or empty side, or out of range, are refused.
    public static func parse(_ text: String) -> Answer? {
        let scalars = Array(text.lowercased())
        var index = 0
        while index < scalars.count {
            if scalars[index] == "[" {
                var end = index + 1
                while end < scalars.count, scalars[end] != "]", scalars[end] != "[" { end += 1 }
                guard end < scalars.count else { break }
                if scalars[end] == "]" {
                    let inner = String(scalars[(index + 1)..<end])
                    let numbers = inner.split(whereSeparator: { $0 == "," || $0 == " " || $0 == ";" }).compactMap { Double($0) }
                    if numbers.count == 4, let rect = rect(numbers) { return .box(rect) }
                }
                index = end
                continue
            }
            index += 1
        }
        let words = TextFolding.tokens(text)
        if words.first == "none" || words.contains("none") || words.first == "aucun" || words.first == "rien" { return Answer.none }
        return nil
    }

    static func rect(_ numbers: [Double]) -> PSRect? {
        let (x1, y1, x2, y2) = (numbers[0], numbers[1], numbers[2], numbers[3])
        guard [x1, y1, x2, y2].allSatisfy({ (0...1000).contains($0) }), x2 > x1, y2 > y1 else { return nil }
        return PSRect(x: x1 / 1000, y: y1 / 1000, width: (x2 - x1) / 1000, height: (y2 - y1) / 1000)
    }
}
