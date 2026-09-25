import Foundation

/// A thing on the scene map, by the short id the model and the grammar use (`EditIntent.ref`).
public enum SceneRef: Hashable, Codable, Sendable {
    /// "t3": printed text block 3 (OCR, reading order).
    case text(Int)
    /// "l2": the 2nd Picshop text layer on its own (document order, table cells excluded).
    case layer(Int)
    /// "o1": a detected object or person.
    case object(Int)
    /// "f1": a free area.
    case area(Int)

    /// "t3", "T3", "t 3", "#t3", "l2", "o1", "f1"; nil for anything else (strict: no guessing).
    public init?(_ string: String) {
        var key = string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if key.hasPrefix("#") { key.removeFirst() }
        key = key.replacingOccurrences(of: " ", with: "")
        guard let letter = key.first, let number = Int(key.dropFirst()), number >= 1, number <= 999 else { return nil }
        switch letter {
        case "t": self = .text(number)
        case "l": self = .layer(number)
        case "o": self = .object(number)
        case "f": self = .area(number)
        default: return nil
        }
    }

    /// The id as the scene map prints it: "t3".
    public var id: String {
        switch self {
        case .text(let n): return "t\(n)"
        case .layer(let n): return "l\(n)"
        case .object(let n): return "o\(n)"
        case .area(let n): return "f\(n)"
        }
    }

    /// Text blocks (printed or layer) can be edited, moved and erased as text.
    public var isText: Bool {
        switch self {
        case .text, .layer: return true
        case .object, .area: return false
        }
    }
}

extension TextElement {
    /// Where the text shows on a canvas of `canvasSize`, estimated from its size and length (no font
    /// metrics): a scene-map box for a layer, a verification region, a canvas highlight.
    public func estimatedBox(canvasSize: PSSize) -> PSRect {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let height = relativeSize * max(1, lineSpacing) * 1.2 * Double(max(1, lines.count))
        let longest = lines.map(\.count).max() ?? text.count
        let aspect = canvasSize.width > 0 && canvasSize.height > 0 ? canvasSize.height / canvasSize.width : 1
        let width = frameWidth ?? min(maxRelativeWidth, Double(max(1, longest)) * relativeSize * 0.55 * aspect)
        return PSRect(x: center.x - width / 2, y: center.y - height / 2, width: width, height: height)
    }
}

/// The typography a text primitive asks for (`EditIntent.textStyle`): addText, editText, moveText.
/// Every part left nil comes from `match` (a block's measured style, or the text nearest the new
/// one), else from the block being edited, else from the action's defaults. Colour stays in
/// `EditIntent.color`.
public struct TextStyleSpec: Hashable, Codable, Sendable {
    public enum Size: Hashable, Codable, Sendable {
        /// Font size / canvas height (`TextElement.relativeSize`), 0.006…0.3.
        case relative(Double)
        /// × the matched or current size, 0.25…4 ("plus gros" ≈ 1.35).
        case scale(Double)
        /// A size class, as the scene map prints them.
        case preset(SceneMap.SizeClass)
    }

    /// Where the unspecified parts of the style come from.
    public enum Match: Hashable, Codable, Sendable {
        /// The measured text nearest to where the new text goes ("dans le même style").
        case nearby
        /// That block's measured style ("comme le titre" -> the title's ref).
        case ref(SceneRef)
    }

    public static let relativeSizeRange: ClosedRange<Double> = 0.006...0.3
    public static let scaleRange: ClosedRange<Double> = 0.25...4

    public var size: Size?
    public var weight: TableGrid.FontWeight?
    public var design: TableGrid.FontDesign?
    public var alignment: TextElement.Alignment?
    public var match: Match?

    public init(size: Size? = nil, weight: TableGrid.FontWeight? = nil, design: TableGrid.FontDesign? = nil,
                alignment: TextElement.Alignment? = nil, match: Match? = nil) {
        self.size = size
        self.weight = weight
        self.design = design
        self.alignment = alignment
        self.match = match
    }

    public var isEmpty: Bool { size == nil && weight == nil && design == nil && alignment == nil && match == nil }

    /// `base` with this spec's parts laid on top; sizes are clamped to their ranges.
    public func applied(to base: TableGrid.Style) -> TableGrid.Style {
        var style = base
        switch size {
        case .relative(let value)?: style.relativeSize = value.clamped(to: Self.relativeSizeRange)
        case .scale(let factor)?: style.relativeSize = (base.relativeSize * factor.clamped(to: Self.scaleRange)).clamped(to: Self.relativeSizeRange)
        case .preset(let sizeClass)?: style.relativeSize = sizeClass.relativeSize
        case nil: break
        }
        if let weight { style.weight = weight }
        if let design { style.design = design }
        if let alignment { style.alignment = alignment }
        return style
    }
}
