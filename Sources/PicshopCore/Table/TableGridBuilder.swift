import Foundation

/// Builds a `TableGrid` from OCR words, ruling lines and bands, with no pixels: pure Swift, tested on
/// Linux. The imaging layer feeds it (TableDetection) and then fills the styles and the ink check.
///
/// Three strategies, in order: rules plus anchors; anchors only (a header line above left-aligned row
/// labels, which finds a table whose values were all erased); values (numeric rows and columns).
public enum TableGridBuilder {
    /// An OCR word; `box` is normalised with a top-left origin.
    public struct Word: Hashable, Codable, Sendable {
        public var text: String
        public var box: PSRect
        /// Index of the recognised line, top line first.
        public var line: Int
        public var confidence: Double

        public init(text: String, box: PSRect, line: Int, confidence: Double = 1) {
            self.text = text
            self.box = box
            self.line = line
            self.confidence = confidence
        }
    }

    /// A thin straight rule found by RulingLineDetector.
    public struct RulingLine: Hashable, Codable, Sendable {
        public enum Axis: String, Hashable, Codable, Sendable { case horizontal, vertical }
        public var axis: Axis
        /// y (horizontal) or x (vertical), normalised.
        public var position: Double
        /// Extent along the line, normalised.
        public var start: Double
        public var end: Double
        /// Normalised.
        public var thickness: Double
        /// 0…1.
        public var contrast: Double

        public init(axis: Axis, position: Double, start: Double, end: Double, thickness: Double, contrast: Double) {
            self.axis = axis
            self.position = position
            self.start = start
            self.end = end
            self.thickness = thickness
            self.contrast = contrast
        }
    }

    /// A stripe of flat colour (zebra rows, a tinted column).
    public struct Band: Hashable, Codable, Sendable {
        public var axis: RulingLine.Axis
        public var start: Double
        public var end: Double

        public init(axis: RulingLine.Axis, start: Double, end: Double) {
            self.axis = axis
            self.start = start
            self.end = end
        }
    }

    /// Everything the builder reads. Codable, so real OCR dumps become Linux fixtures.
    public struct Input: Hashable, Codable, Sendable {
        public var words: [Word]
        public var lines: [RulingLine]
        public var bands: [Band]
        /// Pixels of the analysed image.
        public var imageSize: PSSize
        /// The document's table memory, when it has one for this geometry.
        public var remembered: TableGrid?

        public init(words: [Word], lines: [RulingLine] = [], bands: [Band] = [], imageSize: PSSize, remembered: TableGrid? = nil) {
            self.words = words
            self.lines = lines
            self.bands = bands
            self.imageSize = imageSize
            self.remembered = remembered
        }
    }

    /// Geometry, texts, states from OCR (.empty/.placeholder/.printed) and per-column NumberFormat;
    /// styles are left nil (the imaging layer fills them). Nil below the D8 validity bar.
    ///
    /// With `remembered`: when nothing is found, or what is found covers the same place (bounds IoU
    /// ≥ 0.9), the remembered geometry, styles and formats come back with the occupancy read again
    /// from `words` (`source = .remembered`), so the result is never nil then.
    public static func build(_ input: Input) -> TableGrid? {
        let fresh = Detector(input)?.grid()
        guard let remembered = input.remembered, !remembered.dataCells.isEmpty else { return fresh }
        if let fresh, fresh.bounds.iou(remembered.bounds) < 0.9 { return fresh }
        return reoccupied(remembered, words: input.words)
    }

    /// `grid`'s geometry, names, styles and formats with its data cells read again from `words`
    /// (normalised boxes): printed, placeholder or empty, and nothing laid over yet.
    public static func reoccupied(_ grid: TableGrid, words: [Word]) -> TableGrid {
        var result = grid.withValuesErased()
        var texts: [Int: [Word]] = [:]
        for word in words where !word.text.trimmingCharacters(in: .whitespaces).isEmpty {
            let center = word.box.center
            guard let index = result.cells.firstIndex(where: { $0.kind == .data && $0.rect.contains(center) }) else { continue }
            texts[index, default: []].append(word)
        }
        for (index, members) in texts {
            let ordered = members.sorted { abs($0.box.midY - $1.box.midY) > $0.box.height * 0.5 ? $0.box.midY < $1.box.midY : $0.box.minX < $1.box.minX }
            let text = ordered.map(\.text).joined(separator: " ")
            result.cells[index].text = text
            result.cells[index].wordBoxes = ordered.map(\.box)
            result.cells[index].state = isPlaceholder(text) ? .placeholder : .printed
        }
        result.source = .remembered
        result.confidence = max(result.confidence, 0.5)
        return result
    }

    /// Cell texts that mean "nothing here" but are printed: "—", "–", "-", "n/a".
    public static func isPlaceholder(_ text: String) -> Bool {
        let folded = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return ["—", "–", "-", "‐", "−", "n/a", "na", "n.a.", "/", "…", "..."].contains(folded)
    }
}
