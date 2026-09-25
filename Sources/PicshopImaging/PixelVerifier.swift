import Foundation
import PicshopCore
import PicshopIntent

/// The pixel side of act-then-verify: what OCR read and what the detectors found on one render of the
/// result (base and layers), held against each check of `EditVerifier.request`. Pure Swift, tested on
/// Linux; `VisionPhotoServices.verify(_:in:)` renders, reads and feeds it.
///
/// - textPresent passes when the words whose centre lies in the region read the text (`reads(_:as:)`,
///   or most of a long text's words), fails with what they read instead ("r2c1 reads '7'"). When OCR
///   read nothing there (a lone glyph it skips), the ink decides: ink there keeps the structural outcome
///   (the layer is there and reads right: passed), no ink at all fails ("missing": the text does not
///   show, e.g. white on white or off the canvas).
/// - textAbsent fails when the region still reads the text (any word when the check has none).
/// - objectAbsent fails when a detection of that label (or its kind) still covers the region.
/// - Anything the observation cannot tell keeps the structural outcome.
public enum PixelVerifier {
    /// Gray pixels of part of the render, for the ink test.
    public struct GrayPatch: Sendable {
        public var bytes: [UInt8]
        public var width: Int
        public var height: Int
        /// The canvas region the patch covers (normalised, top-left).
        public var region: PSRect

        public init(bytes: [UInt8], width: Int, height: Int, region: PSRect = .unit) {
            self.bytes = bytes
            self.width = width
            self.height = height
            self.region = region
        }

        public var isValid: Bool { width > 0 && height > 0 && bytes.count >= width * height && region.width > 0 && region.height > 0 }

        /// Ink share of a canvas rect (`TableGridRefiner.inkCoverage`); nil outside the patch.
        public func inkCoverage(in rect: PSRect) -> Double? {
            guard isValid else { return nil }
            let inside = rect.intersection(region)
            guard inside.area > 0, inside.area >= rect.area * 0.8 else { return nil }
            let local = PSRect(x: (inside.minX - region.minX) / region.width, y: (inside.minY - region.minY) / region.height,
                               width: inside.width / region.width, height: inside.height / region.height)
            return TableGridRefiner.inkCoverage(in: local, gray: bytes, width: width, height: height)
        }
    }

    /// What one render of the result showed.
    public struct Observation: Sendable {
        /// OCR of the rendered result (normalised, top-left), top line first.
        public var words: [TableGridBuilder.Word]
        /// Detections over the regions of the objectAbsent checks only.
        public var detections: [SceneMap.Object]
        /// Gray pixels of the render around the text checks; nil skips the ink test.
        public var patch: GrayPatch?
        /// Whether the detectors ran (false: objectAbsent keeps its structural outcome).
        public var objectsChecked: Bool

        public init(words: [TableGridBuilder.Word] = [], detections: [SceneMap.Object] = [], patch: GrayPatch? = nil, objectsChecked: Bool = true) {
            self.words = words
            self.detections = detections
            self.patch = patch
            self.objectsChecked = objectsChecked
        }
    }

    /// Ink share above which a region shows something.
    public static let inkPresent = 0.004

    /// One report per request, in order, method `.pixels`. `structural` is `EditVerifier.structural` of
    /// the same requests in the same order: it decides what the pixels leave open.
    public static func reports(for requests: [VerificationRequest], observation: Observation, structural: [VerificationReport]) -> [VerificationReport] {
        requests.enumerated().map { index, request in
            let known = index < structural.count && structural[index].intentID == request.intentID ? structural[index] : nil
            let items = request.checks.enumerated().map { offset, check -> VerificationReport.Item in
                let item = known.flatMap { offset < $0.items.count && $0.items[offset].check == check ? $0.items[offset] : nil }
                return evaluate(check, observation: observation, structural: item)
            }
            return VerificationReport(intentID: request.intentID, action: request.action, items: items, method: .pixels)
        }
    }

    /// One check against the observation; `structural` is the same check's document-only outcome.
    public static func evaluate(_ check: VerificationCheck, observation: Observation, structural: VerificationReport.Item? = nil) -> VerificationReport.Item {
        let fallback = structural ?? VerificationReport.Item(check: check, outcome: .unverified)
        switch check.kind {
        case .textPresent:
            let expected = check.text ?? ""
            let observed = text(in: check.region, of: observation.words)
            // A text the step wrote over other words (a header, a title): a collision, whatever it reads.
            if check.layerID != nil, !isCellTag(check.tag), let extra = collision(in: check.region, of: observation.words, expected: expected) {
                return VerificationReport.Item(check: check, outcome: .failed, observed: extra)
            }
            if reads(observed, as: expected) || readsMostOf(observed, expected: expected) {
                return VerificationReport.Item(check: check, outcome: .passed, observed: observed)
            }
            if !observed.isEmpty {
                return VerificationReport.Item(check: check, outcome: .failed, observed: observed)
            }
            // Nothing read: a lone glyph OCR skips, or nothing drawn at all.
            let core = check.region.insetBy(dx: check.region.width * 0.1, dy: check.region.height * 0.1)
            guard let ink = observation.patch?.inkCoverage(in: core) else { return fallback }
            if ink < inkPresent { return VerificationReport.Item(check: check, outcome: .failed, observed: nil) }
            return fallback
        case .textAbsent:
            let observed = text(in: check.region, of: observation.words)
            let still: Bool
            if let unwanted = check.text, !SceneMap.folded(unwanted).isEmpty {
                still = reads(observed, as: unwanted)
            } else {
                still = !observed.trimmingCharacters(in: .whitespaces).isEmpty
            }
            return VerificationReport.Item(check: check, outcome: still ? .failed : .passed, observed: still ? observed : nil)
        case .objectAbsent:
            guard observation.objectsChecked else { return fallback }
            let label = check.label ?? ""
            let kind = objectKind(of: label)
            let still = observation.detections.first { detection in
                let sameThing = detection.label == label || (kind != .object && detection.kind == kind) || (kind == .object && detection.kind == .object)
                let covered = detection.box.intersection(check.region).area
                return sameThing && (detection.box.iou(check.region) >= 0.4 || covered >= 0.6 * check.region.area)
            }
            return VerificationReport.Item(check: check, outcome: still == nil ? .passed : .failed, observed: still?.label)
        }
    }

    /// The kind a canonical label belongs to ("person" → person, "dog" → animal).
    public static func objectKind(of label: String) -> SceneMap.Object.Kind {
        switch label.lowercased() {
        case "person", "people", "man", "woman", "child", "boy", "girl", "baby": return .person
        case "face": return .face
        case "dog", "cat", "animal", "bird", "horse", "pet": return .animal
        default: return .object
        }
    }

    /// The words whose centre lies in `region`, in reading order (line, then left to right), joined by spaces.
    public static func text(in region: PSRect, of words: [TableGridBuilder.Word]) -> String {
        words.filter { region.contains($0.box.center) }
            .sorted { ($0.line, $0.box.minX) < ($1.line, $1.box.minX) }
            .map(\.text)
            .joined(separator: " ")
    }

    /// Whether OCR's `observed` says `expected`: case, accents and punctuation folded (`SceneMap.folded`,
    /// so "87,3" reads as "87.3" and "90 %" as "90%"), and, when `expected` is a number, the usual OCR
    /// swaps (l, I, |, ! → 1; O, o → 0; S → 5; B → 8; Z → 2). `observed` may hold more (a neighbour's
    /// word): holding the expected words, whole, is reading them ("1" is not read in "12").
    public static func reads(_ observed: String, as expected: String) -> Bool {
        let wanted = SceneMap.folded(expected)
        guard !wanted.isEmpty else { return true }
        func holds(_ text: String) -> Bool {
            let folded = SceneMap.folded(text)
            return folded == wanted || " \(folded) ".contains(" \(wanted) ")
        }
        if holds(observed) { return true }
        guard wanted.allSatisfy({ $0.isNumber || $0 == " " }) else { return false }
        return holds(String(observed.map { digitSwaps[$0] ?? $0 }))
    }

    /// A long text (4 words or more) reads when OCR found at least 80 % of its words, in any order: a
    /// wrapped paragraph or a stray misread word should not fail the check.
    static func readsMostOf(_ observed: String, expected: String) -> Bool {
        let wanted = SceneMap.folded(expected).split(separator: " ").map(String.init)
        guard wanted.count >= 4 else { return false }
        var seen = SceneMap.folded(observed).split(separator: " ").map(String.init)
        var found = 0
        for word in wanted {
            if let index = seen.firstIndex(of: word) {
                seen.remove(at: index)
                found += 1
            }
        }
        return Double(found) >= 0.8 * Double(wanted.count)
    }

    /// Words OCR read in `region` that are neither the expected text nor part of it (folded, with the digit
    /// swaps for numbers), joined; nil when there are none. A new text that lands on a header or a title
    /// shows it here, while the expected words alone (split or not) never do.
    static func collision(in region: PSRect, of words: [TableGridBuilder.Word], expected: String) -> String? {
        let wanted = Set(SceneMap.folded(expected).split(separator: " ").map(String.init))
        guard !wanted.isEmpty else { return nil }
        let swapped = Set(wanted.map { String($0.map { digitSwaps[$0] ?? $0 }) })
        let extra = words.filter { region.contains($0.box.center) }.sorted { ($0.line, $0.box.minX) < ($1.line, $1.box.minX) }.filter { word in
            let tokens = SceneMap.folded(word.text).split(separator: " ").map(String.init)
            guard !tokens.isEmpty else { return false }
            return !tokens.allSatisfy { wanted.contains($0) || swapped.contains(String($0.map { digitSwaps[$0] ?? $0 })) }
        }
        return extra.isEmpty ? nil : extra.map(\.text).joined(separator: " ")
    }

    /// "r6c3": a table cell's check (dense tables keep the plain read: a neighbour's value is no collision).
    static func isCellTag(_ tag: String) -> Bool {
        guard tag.first == "r", let c = tag.firstIndex(of: "c") else { return false }
        return Int(tag[tag.index(after: tag.startIndex)..<c]) != nil && Int(tag[tag.index(after: c)...]) != nil
    }

    /// Letters OCR reads for digits.
    static let digitSwaps: [Character: Character] = [
        "l": "1", "I": "1", "|": "1", "!": "1", "O": "0", "o": "0", "S": "5", "s": "5", "B": "8", "Z": "2", "z": "2",
    ]
}
