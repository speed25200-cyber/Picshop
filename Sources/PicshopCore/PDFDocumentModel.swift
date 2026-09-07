import Foundation

/// A mark added on top of a PDF page. Coordinates are normalised to the
/// page's *displayed* bounds (top-left origin, after rotation) so they stay
/// valid across zoom levels and devices.
public struct PDFMarkup: Hashable, Codable, Sendable, Identifiable {
    public enum Kind: Hashable, Codable, Sendable {
        case ink(strokes: [BrushStroke], color: PSColor, width: Double)
        case highlight(rects: [PSRect], color: PSColor)
        case underline(rects: [PSRect], color: PSColor)
        case strikeout(rects: [PSRect], color: PSColor)
        case redaction(rects: [PSRect])
        case text(TextElement)
        case image(MediaAsset, frame: PSRect)
        case signature(MediaAsset, frame: PSRect)
        case rectangle(PSRect, color: PSColor, width: Double)
        case pageNumber(TextElement)
    }

    public var id: UUID
    public var kind: Kind
    public var createdAt: Date

    public init(id: UUID = UUID(), kind: Kind, createdAt: Date = Date()) {
        self.id = id
        self.kind = kind
        self.createdAt = createdAt
    }

    public var label: String {
        switch kind {
        case .ink: return "Drawing"
        case .highlight: return "Highlight"
        case .underline: return "Underline"
        case .strikeout: return "Strikethrough"
        case .redaction: return "Redaction"
        case .text(let element): return "Text “\(element.text)”"
        case .image: return "Image"
        case .signature: return "Signature"
        case .rectangle: return "Rectangle"
        case .pageNumber: return "Page number"
        }
    }
}

/// One page of the edited document.
public struct PDFPageModel: Hashable, Codable, Sendable, Identifiable {
    public enum Source: Hashable, Codable, Sendable {
        /// Page `index` (0-based) of the original file.
        case original(index: Int)
        /// Page `index` of another imported PDF stored in the package.
        case imported(MediaAsset, index: Int)
        /// A full-page image (photo → page).
        case image(MediaAsset)
        /// Empty page of the given size in points.
        case blank(PSSize)
    }

    public var id: UUID
    public var source: Source
    /// Additional clockwise rotation in degrees: 0, 90, 180, 270.
    public var rotation: Int
    public var markups: [PDFMarkup]
    /// Media box in points (before extra rotation).
    public var size: PSSize

    public init(id: UUID = UUID(), source: Source, rotation: Int = 0, markups: [PDFMarkup] = [], size: PSSize = PSSize(width: 595, height: 842)) {
        self.id = id
        self.source = source
        self.rotation = rotation
        self.markups = markups
        self.size = size
    }

    /// Displayed size after rotation.
    public var displaySize: PSSize {
        (rotation / 90) % 2 == 1 ? PSSize(width: size.height, height: size.width) : size
    }
}

/// An editable PDF: an ordered list of pages that reference the original
/// file, with rotation and markups. The original bytes are never modified;
/// exports rebuild the document.
public struct PDFDocumentModel: Hashable, Codable, Sendable, Identifiable {
    public static let formatVersion = 1

    public var id: UUID
    public var formatVersion: Int
    public var title: String
    public var sourceAsset: MediaAsset
    public var pages: [PDFPageModel]
    public var currentPageIndex: Int
    public var createdAt: Date
    public var modifiedAt: Date

    public init(id: UUID = UUID(), title: String, sourceAsset: MediaAsset, pages: [PDFPageModel], currentPageIndex: Int = 0,
                createdAt: Date = Date(), modifiedAt: Date = Date()) {
        self.id = id
        self.formatVersion = Self.formatVersion
        self.title = title
        self.sourceAsset = sourceAsset
        self.pages = pages
        self.currentPageIndex = min(max(0, currentPageIndex), max(0, pages.count - 1))
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
    }

    /// Convenience: every page of the original file with the given sizes.
    public init(title: String, sourceAsset: MediaAsset, pageSizes: [PSSize]) {
        let pages = pageSizes.enumerated().map { PDFPageModel(source: .original(index: $0.offset), size: $0.element) }
        self.init(title: title, sourceAsset: sourceAsset, pages: pages)
    }

    public var pageCount: Int { pages.count }
    public var currentPage: PDFPageModel? { pages.indices.contains(currentPageIndex) ? pages[currentPageIndex] : nil }

    public mutating func touch() { modifiedAt = Date() }

    /// Resolves a 1-based spoken page number (nil / 0 → current page, -1 → last).
    public func resolvePageIndex(_ number: Int?) -> Int? {
        guard !pages.isEmpty else { return nil }
        guard let number, number != 0 else { return currentPageIndex }
        if number == -1 { return pages.count - 1 }
        let index = number - 1
        return pages.indices.contains(index) ? index : nil
    }

    public mutating func deletePage(at index: Int) {
        guard pages.indices.contains(index), pages.count > 1 else { return }
        pages.remove(at: index)
        currentPageIndex = min(currentPageIndex, pages.count - 1)
        touch()
    }

    public mutating func rotatePage(at index: Int, by degrees: Int) {
        guard pages.indices.contains(index) else { return }
        let normalized = ((pages[index].rotation + degrees) % 360 + 360) % 360
        pages[index].rotation = (normalized / 90) * 90
        touch()
    }

    public mutating func movePage(from index: Int, to destination: Int) {
        guard pages.indices.contains(index) else { return }
        let target = min(max(0, destination), pages.count - 1)
        guard target != index else { return }
        let page = pages.remove(at: index)
        pages.insert(page, at: target)
        currentPageIndex = target
        touch()
    }

    public mutating func duplicatePage(at index: Int) {
        guard pages.indices.contains(index) else { return }
        var copy = pages[index]
        copy.id = UUID()
        copy.markups = copy.markups.map { PDFMarkup(kind: $0.kind) }
        pages.insert(copy, at: index + 1)
        touch()
    }

    public mutating func insert(_ page: PDFPageModel, at index: Int) {
        pages.insert(page, at: min(max(0, index), pages.count))
        currentPageIndex = min(max(0, index), pages.count - 1)
        touch()
    }

    public mutating func addMarkup(_ markup: PDFMarkup, toPageAt index: Int) {
        guard pages.indices.contains(index) else { return }
        pages[index].markups.append(markup)
        touch()
    }

    public mutating func removeMarkup(id: UUID) {
        for index in pages.indices {
            pages[index].markups.removeAll { $0.id == id }
        }
        touch()
    }

    public mutating func goToPage(_ index: Int) {
        guard pages.indices.contains(index) else { return }
        currentPageIndex = index
    }

    /// All markups with their page index.
    public var allMarkups: [(pageIndex: Int, markup: PDFMarkup)] {
        pages.enumerated().flatMap { page in page.element.markups.map { (page.offset, $0) } }
    }
}
