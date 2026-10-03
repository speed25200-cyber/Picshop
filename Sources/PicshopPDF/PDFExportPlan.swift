import Foundation
import PicshopCore

// What the export does to each page, decided from the model alone (pure Swift,
// tested on Linux). PDFEditingService carries it out with PDFKit.

/// The user's export choices.
public struct PDFExportOptions: Hashable, Sendable {
    /// 'Aplatir': every mark is burned into the page content; nothing stays an editable annotation.
    public var flattenAnnotations: Bool
    /// 'Aplatir les pages modifiées': pages whose words were replaced are rasterized, so the old
    /// words leave the file. Off, the old words stay under the new ones (and can be copied).
    public var flattenModifiedPages: Bool

    public init(flattenAnnotations: Bool = false, flattenModifiedPages: Bool = true) {
        self.flattenAnnotations = flattenAnnotations
        self.flattenModifiedPages = flattenModifiedPages
    }

    /// The defaults for a document: modified pages are flattened when it has replacements.
    public static func defaults(for model: PDFDocumentModel) -> PDFExportOptions {
        PDFExportOptions(flattenAnnotations: false, flattenModifiedPages: PDFExportPlan.hasReplacements(model))
    }
}

/// How one page is written.
public enum PDFPageTreatment: Hashable, Sendable {
    /// The page itself, its marks as real PDF annotations: text, links, form fields and marks stay editable.
    case keep
    /// Drawn into new page content (vector: its text stays text). For marks PDFKit cannot write as
    /// annotations (photos, signatures, replaced words), or every page under 'Aplatir'.
    case flatten
    /// Rasterized at `PDFExportPlan.rasterDPI` with every mark burned in; its text layer is rebuilt by OCR,
    /// leaving out the words under `excluded` (base space, normalised, top-left origin).
    case rasterize(excluded: [PSRect])
}

/// The export of a document, page by page.
public struct PDFExportPlan: Hashable, Sendable {
    public var pages: [PDFPageTreatment]
    /// Redacted documents leave the Info dictionary and the XMP metadata behind.
    public var stripsMetadata: Bool

    public static let rasterDPI: Double = 300
    /// Longest side of a rasterized page, so an oversized page cannot exhaust memory.
    public static let maxRasterSide = 5_000

    public init(pages: [PDFPageTreatment], stripsMetadata: Bool) {
        self.pages = pages
        self.stripsMetadata = stripsMetadata
    }

    public static func make(_ model: PDFDocumentModel, options: PDFExportOptions) -> PDFExportPlan {
        var redacted = false
        let pages = model.pages.map { page -> PDFPageTreatment in
            let redactions = page.markups.flatMap { markup -> [PSRect] in
                if case .redaction(let rects) = markup.kind { return rects }
                return []
            }
            if !redactions.isEmpty {
                redacted = true
                return .rasterize(excluded: redactions)
            }
            let replaces = page.markups.contains { if case .replacement = $0.kind { return true } else { return false } }
            if replaces, options.flattenModifiedPages { return .rasterize(excluded: []) }
            if options.flattenAnnotations, !page.markups.isEmpty { return .flatten }
            return page.markups.contains(where: needsDrawing) ? .flatten : .keep
        }
        return PDFExportPlan(pages: pages, stripsMetadata: redacted)
    }

    /// Marks PDFKit cannot write as annotations: they are drawn by the app (stamps).
    static func needsDrawing(_ markup: PDFMarkup) -> Bool {
        switch markup.kind {
        case .image, .signature, .replacement: return true
        case .ink, .highlight, .underline, .strikeout, .text, .pageNumber, .rectangle: return false
        case .redaction: return true
        }
    }

    public static func hasReplacements(_ model: PDFDocumentModel) -> Bool {
        model.allMarkups.contains { if case .replacement = $0.markup.kind { return true } else { return false } }
    }

    /// Whether the export leaves replaced words in the file (the export warns about it).
    public static func keepsReplacedWords(_ model: PDFDocumentModel, options: PDFExportOptions) -> Bool {
        let plan = make(model, options: options)
        return zip(model.pages, plan.pages).contains { page, treatment in
            guard page.markups.contains(where: { if case .replacement = $0.kind { return true } else { return false } }) else { return false }
            if case .rasterize = treatment { return false }
            return true
        }
    }

    /// Whether an OCR word (base space) may go in a rebuilt text layer: never one touching an excluded rect.
    public static func keeps(_ word: PSRect, excluded: [PSRect]) -> Bool {
        !excluded.contains { !$0.insetBy(dx: -0.002, dy: -0.002).intersection(word).isEmpty }
    }

    /// Pixel size of a page of `size` points rasterized at `dpi`, the longest side capped.
    public static func rasterPixels(for size: PSSize, dpi: Double = rasterDPI) -> (width: Int, height: Int) {
        guard size.width > 0, size.height > 0 else { return (1, 1) }
        var scale = dpi / 72
        let longest = max(size.width, size.height) * scale
        if longest > Double(maxRasterSide) { scale *= Double(maxRasterSide) / longest }
        return (max(1, Int((size.width * scale).rounded())), max(1, Int((size.height * scale).rounded())))
    }

    /// Outline labels and link texts that name a redacted word are dropped too.
    public static func mentionsRedacted(_ text: String, redacted: [String]) -> Bool {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        return redacted.contains { word in
            let needle = word.trimmingCharacters(in: .whitespacesAndNewlines).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            return !needle.isEmpty && folded.contains(needle)
        }
    }
}
