#if canImport(PDFKit) && canImport(Vision)
import Foundation
import PDFKit
import Vision
import CoreText
import CoreGraphics
import PicshopCore

/// Writes an exported PDF through `PDFDocument.write(to:withOptions:)`, page by page as a
/// `PDFExportPlan` says:
/// - kept pages are the original pages with their marks as real annotations, so their
///   text, links, form fields and marks stay what they were;
/// - flattened pages are drawn into new vector content (their text stays text);
/// - rasterized pages (redactions; replaced words under 'Aplatir les pages modifiées') are
///   drawn at 300 dpi with the redaction boxes burned in, and get an invisible OCR text
///   layer that leaves out every word under a box. Nothing of a redacted word is left to
///   copy, search or extract.
/// The outline and internal links follow the new page order; a redacted document leaves
/// its Info dictionary and XMP metadata behind (a new document carries neither).
///
/// Platform-neutral (PDFKit, Core Graphics, Core Text, Vision): the macOS tests run it.
public struct PDFAssembler {
    /// One page to write: as composed for display (marks as annotations, inside a document),
    /// and, for a kept page, the fresh copy to write as it is.
    public struct Page {
        public var index: Int
        public var composed: PDFPage
        public var kept: PDFPage?

        public init(index: Int, composed: PDFPage, kept: PDFPage? = nil) {
            self.index = index
            self.composed = composed
            self.kept = kept
        }
    }

    public let model: PDFDocumentModel
    public let original: PDFDocument
    public let plan: PDFExportPlan

    /// Documents the written pages come from, alive until the file is written.
    private final class Keeper { var documents: [PDFDocument] = [] }
    private let keeper = Keeper()

    public init(model: PDFDocumentModel, original: PDFDocument, plan: PDFExportPlan) {
        self.model = model
        self.original = original
        self.plan = plan
    }

    public func write(_ pages: [Page], to url: URL) throws {
        let output = PDFDocument()
        var composedPages: [Int: PDFPage] = [:]
        var outputPages: [Int: PDFPage] = [:]
        var redactedWords: [String] = []
        for page in pages where plan.pages.indices.contains(page.index) {
            composedPages[page.index] = page.composed
            let written: PDFPage?
            switch plan.pages[page.index] {
            case .keep:
                written = page.kept ?? page.composed.copy() as? PDFPage
            case .flatten:
                written = drawnPage(page.composed)
            case .rasterize(let excluded):
                redactedWords += Self.words(under: excluded, on: page.composed)
                written = rasterizedPage(page.composed, excluded: excluded)
            }
            guard let written else { throw PicshopError.exportFailed("page \(page.index + 1)") }
            output.insert(written, at: output.pageCount)
            outputPages[page.index] = written
        }
        guard output.pageCount > 0 else { throw PicshopError.exportFailed("empty") }

        let drawn = Set(plan.pages.indices.filter { plan.pages[$0] != .keep })
        let mapper = DestinationMapper(model: model, original: original, composedPages: composedPages, outputPages: outputPages, drawn: drawn)
        // Links: kept pages carry theirs (re-pointed at the new order); drawn pages get them back.
        for (index, written) in outputPages {
            guard let composed = composedPages[index] else { continue }
            switch plan.pages[index] {
            case .keep:
                // A copied page's links may point at nothing (the copy left its document):
                // the same link on the original page knows its target.
                let source = mapper.originalPage(at: index)
                for link in written.annotations where Self.isLink(link) {
                    let twin = source?.annotations.first { Self.isLink($0) && $0.bounds == link.bounds }
                    if !mapper.repoint(link, twin: twin) { written.removeAnnotation(link) }
                }
            case .flatten:
                Self.copyLinks(from: composed, to: written, excluded: [], redacted: redactedWords, mapper: mapper)
            case .rasterize(let excluded):
                Self.copyLinks(from: composed, to: written, excluded: excluded, redacted: redactedWords, mapper: mapper)
            }
        }
        if let root = original.outlineRoot {
            let copy = PDFOutline()
            Self.copyOutline(root, into: copy, redacted: redactedWords, mapper: mapper)
            if copy.numberOfChildren > 0 { output.outlineRoot = copy }
        }
        if plan.stripsMetadata {
            output.documentAttributes = [:]
        } else {
            var attributes = original.documentAttributes ?? [:]
            attributes[PDFDocumentAttribute.modificationDateAttribute] = Date()
            output.documentAttributes = attributes
        }
        guard output.write(to: url, withOptions: nil) else { throw PicshopError.exportFailed("write") }
    }

    // MARK: Pages

    /// Displayed size (rotation applied) of a page in points.
    public static func displayedSize(of page: PDFPage) -> CGSize {
        let box = page.bounds(for: .mediaBox)
        return page.rotation % 180 != 0 ? CGSize(width: box.height, height: box.width) : box.size
    }

    /// The page and its annotations drawn into a new one-page PDF: vector, its text still text.
    func drawnPage(_ page: PDFPage) -> PDFPage? {
        let size = Self.displayedSize(of: page)
        return makePDFPage(size: size) { context in
            context.saveGState()
            context.concatenate(page.transform(for: .mediaBox))
            page.draw(with: .mediaBox, to: context)
            context.restoreGState()
        }
    }

    /// The page as pixels (300 dpi, every mark burned in, the redaction boxes painted again on
    /// top), with an invisible text layer from OCR that leaves out the words under `excluded`.
    func rasterizedPage(_ page: PDFPage, excluded: [PSRect]) -> PDFPage? {
        let size = Self.displayedSize(of: page)
        let box = page.bounds(for: .mediaBox)
        let pixels = PDFExportPlan.rasterPixels(for: PSSize(width: Double(size.width), height: Double(size.height)))
        let scale = CGFloat(pixels.width) / max(1, size.width)
        guard let bitmap = CGContext(data: nil, width: pixels.width, height: pixels.height, bitsPerComponent: 8, bytesPerRow: 0,
                                     space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                     bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        bitmap.setFillColor(CGColor(gray: 1, alpha: 1))
        bitmap.fill(CGRect(x: 0, y: 0, width: pixels.width, height: pixels.height))
        bitmap.scaleBy(x: scale, y: scale)
        bitmap.concatenate(page.transform(for: .mediaBox))
        page.draw(with: .mediaBox, to: bitmap)
        // Belt and braces: the boxes again, opaque, in page space (where the annotations sit).
        bitmap.setFillColor(CGColor(gray: 0, alpha: 1))
        let pageSize = PSSize(width: Double(box.width), height: Double(box.height))
        for rect in excluded {
            bitmap.fill(Self.cgRect(PDFGeometry.pagePoints(fromBase: rect.insetBy(dx: -0.002, dy: -0.003), size: pageSize)))
        }
        guard let image = bitmap.makeImage() else { return nil }
        let rotation = ((page.rotation % 360) + 360) % 360
        let words = Self.recognizeWords(in: image).filter { word in
            PDFExportPlan.keeps(PDFGeometry.baseRect(fromDisplayed: word.rect, rotation: rotation), excluded: excluded)
        }
        return makePDFPage(size: size) { context in
            context.draw(image, in: CGRect(origin: .zero, size: size))
            Self.drawInvisibleText(words, pageSize: size, in: context)
        }
    }

    /// A one-page PDF of `size` points drawn by `body` (bottom-left origin), as a page of its own document.
    func makePDFPage(size: CGSize, _ body: (CGContext) -> Void) -> PDFPage? {
        let data = NSMutableData()
        var mediaBox = CGRect(origin: .zero, size: size)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else { return nil }
        context.beginPDFPage(nil)
        body(context)
        context.endPDFPage()
        context.closePDF()
        guard let document = PDFDocument(data: data as Data), let page = document.page(at: 0) else { return nil }
        keeper.documents.append(document)
        return page
    }

    static func cgRect(_ rect: PSRect) -> CGRect {
        CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height)
    }

    // MARK: OCR text layer

    public struct RecognizedWord: Sendable {
        public let text: String
        /// Displayed space, normalised, top-left origin.
        public let rect: PSRect
    }

    public static func recognizeWords(in image: CGImage) -> [RecognizedWord] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = ["fr-FR", "en-US"]
        let handler = VNImageRequestHandler(cgImage: image, orientation: .up, options: [:])
        do {
            try handler.perform([request])
        } catch {
            PSLog.error("Export OCR failed: \(error)", category: .imaging)
            return []
        }
        var words: [RecognizedWord] = []
        for observation in request.results ?? [] {
            guard let candidate = observation.topCandidates(1).first else { continue }
            let string = candidate.string
            var searchStart = string.startIndex
            for piece in string.split(separator: " ", omittingEmptySubsequences: true) {
                guard let range = string.range(of: piece, range: searchStart..<string.endIndex) else { continue }
                searchStart = range.upperBound
                let box = (try? candidate.boundingBox(for: range)?.boundingBox) ?? observation.boundingBox
                // Vision: normalised, bottom-left origin → top-left origin.
                let rect = PSRect(x: Double(box.minX), y: Double(1 - box.maxY), width: Double(box.width), height: Double(box.height)).clampedToUnit()
                words.append(RecognizedWord(text: String(piece), rect: rect))
            }
        }
        return words
    }

    /// Text in rendering mode invisible over each word: selectable and searchable, never seen.
    static func drawInvisibleText(_ words: [RecognizedWord], pageSize: CGSize, in context: CGContext) {
        context.saveGState()
        context.setTextDrawingMode(.invisible)
        for word in words where !word.text.isEmpty {
            let rect = CGRect(x: CGFloat(word.rect.minX) * pageSize.width, y: CGFloat(1 - word.rect.maxY) * pageSize.height,
                              width: CGFloat(word.rect.width) * pageSize.width, height: CGFloat(word.rect.height) * pageSize.height)
            guard rect.width > 0.5, rect.height > 0.5 else { continue }
            let font = CTFontCreateWithName("Helvetica" as CFString, rect.height * 0.9, nil)
            let attributes = [NSAttributedString.Key(kCTFontAttributeName as String): font]
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: word.text, attributes: attributes) as CFAttributedString)
            let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
            context.saveGState()
            context.textMatrix = .identity
            context.translateBy(x: rect.minX, y: rect.minY + rect.height * 0.2)
            if width > 0 { context.scaleBy(x: rect.width / width, y: 1) }
            context.textPosition = .zero
            CTLineDraw(line, context)
            context.restoreGState()
        }
        context.restoreGState()
    }

    /// What the redaction boxes cover, read from the page's text layer (outline labels and links
    /// naming those words are dropped too).
    public static func words(under rects: [PSRect], on page: PDFPage) -> [String] {
        let box = page.bounds(for: .mediaBox)
        let size = PSSize(width: Double(box.width), height: Double(box.height))
        return rects.compactMap { rect in
            let text = page.selection(for: cgRect(PDFGeometry.pagePoints(fromBase: rect, size: size)))?.string?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return (text?.isEmpty ?? true) ? nil : text
        }
    }

    // MARK: Links and outline

    static func isLink(_ annotation: PDFAnnotation) -> Bool {
        (annotation.type ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "/")) == "Link"
    }

    /// The links of a drawn page, moved into the new page's space, except those over a redaction.
    static func copyLinks(from composed: PDFPage, to written: PDFPage, excluded: [PSRect], redacted: [String], mapper: DestinationMapper) {
        let transform = composed.transform(for: .mediaBox)
        let box = composed.bounds(for: .mediaBox)
        let size = PSSize(width: Double(box.width), height: Double(box.height))
        let covered = excluded.map { cgRect(PDFGeometry.pagePoints(fromBase: $0, size: size)) }
        for annotation in composed.annotations where isLink(annotation) {
            if covered.contains(where: { $0.intersects(annotation.bounds) }) { continue }
            let url = annotation.url ?? (annotation.action as? PDFActionURL)?.url
            if let url, PDFExportPlan.mentionsRedacted(url.absoluteString, redacted: redacted) { continue }
            let link = PDFAnnotation(bounds: annotation.bounds.applying(transform), forType: .link, withProperties: nil)
            if let url {
                link.url = url
            } else if let destination = annotation.destination ?? (annotation.action as? PDFActionGoTo)?.destination,
                      let mapped = mapper.destination(for: destination) {
                link.destination = mapped
            } else {
                continue
            }
            let border = PDFBorder()
            border.lineWidth = 0
            link.border = border
            written.addAnnotation(link)
        }
    }

    static func copyOutline(_ item: PDFOutline, into parent: PDFOutline, redacted: [String], mapper: DestinationMapper) {
        for index in 0..<item.numberOfChildren {
            guard let child = item.child(at: index) else { continue }
            if PDFExportPlan.mentionsRedacted(child.label ?? "", redacted: redacted) { continue }
            let copy = PDFOutline()
            copy.label = child.label
            if let destination = child.destination, let mapped = mapper.destination(for: destination) {
                copy.destination = mapped
            } else if let action = child.action as? PDFActionURL, let url = action.url {
                copy.action = PDFActionURL(url: url)
            }
            copyOutline(child, into: copy, redacted: redacted, mapper: mapper)
            guard copy.destination != nil || copy.action != nil || copy.numberOfChildren > 0 else { continue }
            parent.insertChild(copy, at: parent.numberOfChildren)
            copy.isOpen = child.isOpen
        }
    }
}

/// Points destinations of the original document (or of the composed pages) at the written pages.
struct DestinationMapper {
    let model: PDFDocumentModel
    let original: PDFDocument
    let composedPages: [Int: PDFPage]
    let outputPages: [Int: PDFPage]
    /// Pages drawn anew (flattened or rasterized): their space is the composed page's after rotation.
    let drawn: Set<Int>

    /// The model index of the written page that shows a page of the original or composed documents.
    func outputIndex(for page: PDFPage) -> Int? {
        if let entry = composedPages.first(where: { $0.value === page }) { return entry.key }
        guard let document = page.document, document === original else { return nil }
        let originalIndex = original.index(for: page)
        return model.pages.firstIndex { if case .original(let source) = $0.source { return source == originalIndex } else { return false } }
    }

    func destination(for destination: PDFDestination) -> PDFDestination? {
        guard let page = destination.page, let index = outputIndex(for: page), let written = outputPages[index] else { return nil }
        var point = destination.point
        let unspecified = point.x >= kPDFDestinationUnspecifiedValue / 2 || point.y >= kPDFDestinationUnspecifiedValue / 2
        if unspecified {
            point = CGPoint(x: 0, y: written.bounds(for: .mediaBox).height)
        } else if drawn.contains(index), let composed = composedPages[index] {
            point = point.applying(composed.transform(for: .mediaBox))
        }
        return PDFDestination(page: written, at: point)
    }

    /// The original page a model page shows, when it comes from the original document.
    func originalPage(at index: Int) -> PDFPage? {
        guard model.pages.indices.contains(index), case .original(let source) = model.pages[index].source else { return nil }
        return original.page(at: source)
    }

    /// Re-points a kept page's link at the new order, reading the target from its `twin` on the
    /// original page when the copy lost it; false when the target page is gone.
    func repoint(_ link: PDFAnnotation, twin: PDFAnnotation? = nil) -> Bool {
        if link.url != nil || link.action is PDFActionURL { return true }
        let own = link.destination ?? (link.action as? PDFActionGoTo)?.destination
        let original = twin?.destination ?? (twin?.action as? PDFActionGoTo)?.destination
        let candidates = [original, own].compactMap { $0 }
        guard !candidates.isEmpty else { return true }
        guard let mapped = candidates.lazy.compactMap({ self.destination(for: $0) }).first else { return false }
        link.action = nil
        link.destination = mapped
        return true
    }
}

/// Opening protected PDFs (PDFKit's `unlock(withPassword:)`), shared by the editor and the tests.
public enum PDFProtection {
    /// The page sizes of an opened document, in points.
    public static func pageSizes(of document: PDFDocument) -> [PSSize] {
        (0..<document.pageCount).map { index -> PSSize in
            let size = document.page(at: index)?.bounds(for: .mediaBox).size ?? CGSize(width: 595, height: 842)
            return PSSize(width: Double(size.width), height: Double(size.height))
        }
    }

    /// Unlocks `document` with `password`: true when it is open (or was never locked).
    public static func unlock(_ document: PDFDocument, password: String) -> Bool {
        guard document.isLocked else { return true }
        return document.unlock(withPassword: password)
    }
}
#endif

#if canImport(PDFKit) && canImport(UIKit) && canImport(Vision)
import UIKit

/// The export of an edited document: each page composed as the viewer shows it (UIKit
/// annotations and stamps), then written by `PDFAssembler`.
struct PDFExporter {
    let model: PDFDocumentModel
    let original: PDFDocument
    let options: PDFExportOptions
    let sources: PDFComposer.SourceProvider
    let resolveImage: (MediaAsset) -> UIImage?

    func write(to url: URL) throws {
        let plan = PDFExportPlan.make(model, options: options)
        var pages: [PDFAssembler.Page] = []
        var holders: [PDFDocument] = []
        for (index, pageModel) in model.pages.enumerated() {
            guard let composed = PDFComposer.composedPage(pageModel, original: original, sources: sources, resolveImage: resolveImage) else { continue }
            // Drawing needs the page inside a document.
            let holder = PDFDocument()
            holder.insert(composed, at: 0)
            holders.append(holder)
            var kept: PDFPage?
            if plan.pages[index] == .keep {
                kept = PDFComposer.composedPage(pageModel, original: original, sources: sources, resolveImage: resolveImage)
            }
            pages.append(PDFAssembler.Page(index: index, composed: composed, kept: kept))
        }
        try withExtendedLifetime(holders) {
            try PDFAssembler(model: model, original: original, plan: plan).write(pages, to: url)
        }
    }
}
#endif
