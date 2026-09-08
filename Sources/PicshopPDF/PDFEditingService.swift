#if canImport(PDFKit) && canImport(UIKit)
import Foundation
import PDFKit
import UIKit
import PicshopCore
import PicshopIntent
import PicshopImaging

/// PDFKit-backed services: import, composition, search, export, thumbnails,
/// signature storage and page → photo extraction.
public final class PDFEditingService: PDFAIServices, @unchecked Sendable {
    public let store: ProjectStore
    public let projectID: UUID
    private let lock = NSLock()
    private var documents: [String: PDFDocument] = [:]
    private let recognizer = PDFTextRecognizer()

    public init(store: ProjectStore, projectID: UUID) {
        self.store = store
        self.projectID = projectID
    }

    // MARK: Import

    /// Copies a PDF into a new project package and reads its page sizes.
    public static func importDocument(from sourceURL: URL, store: ProjectStore, title: String) throws -> PDFDocumentModel {
        let id = UUID()
        try store.createPackage(for: id)
        let relative = "\(Project.mediaDirectory)/original.pdf"
        let destination = store.url(for: relative, in: id)
        try? FileManager.default.removeItem(at: destination)
        let accessing = sourceURL.startAccessingSecurityScopedResource()
        defer { if accessing { sourceURL.stopAccessingSecurityScopedResource() } }
        try FileManager.default.copyItem(at: sourceURL, to: destination)
        guard let document = PDFDocument(url: destination), document.pageCount > 0 else { throw PicshopError.mediaUnavailable(sourceURL.lastPathComponent) }
        let sizes = (0..<document.pageCount).map { index -> PSSize in
            let page = document.page(at: index)
            return PSSize(page?.bounds(for: .mediaBox).size ?? CGSize(width: 595, height: 842))
        }
        let asset = MediaAsset(kind: .image, relativePath: relative, pixelSize: sizes.first ?? .zero, origin: .file)
        var model = PDFDocumentModel(title: title, sourceAsset: asset, pageSizes: sizes)
        model.id = id
        // Keep the original page rotation so display rotation stays additive.
        for index in model.pages.indices {
            if let page = document.page(at: index) { model.pages[index].rotation = 0; _ = page }
        }
        if let first = document.page(at: 0) {
            let thumb = first.thumbnail(of: CGSize(width: 512, height: 512), for: .mediaBox)
            if let cg = thumb.cgImage { ThumbnailGenerator.writeThumbnail(image: cg, projectID: id, store: store) }
        }
        return model
    }

    // MARK: Documents

    public func document(for asset: MediaAsset) -> PDFDocument? {
        lock.lock()
        defer { lock.unlock() }
        if let cached = documents[asset.relativePath] { return cached }
        let document = PDFDocument(url: store.url(for: asset.relativePath, in: projectID))
        documents[asset.relativePath] = document
        return document
    }

    public func image(for asset: MediaAsset) -> UIImage? {
        UIImage(contentsOfFile: store.url(for: asset.relativePath, in: projectID).path)
    }

    /// The composed, display-ready document.
    public func compose(_ model: PDFDocumentModel) -> PDFDocument? {
        guard let original = document(for: model.sourceAsset) else { return nil }
        return PDFComposer.compose(model, original: original, sources: { [weak self] asset in self?.document(for: asset) }, resolveImage: { [weak self] asset in self?.resolvedImage(for: asset) })
    }

    /// Total rotation the viewer applies to a page (original + model).
    public func originalRotation(of pageModel: PDFPageModel, in model: PDFDocumentModel) -> Int {
        if case .original(let index) = pageModel.source, let page = document(for: model.sourceAsset)?.page(at: index) { return page.rotation }
        if case .imported(let asset, let index) = pageModel.source, let page = document(for: asset)?.page(at: index) { return page.rotation }
        return 0
    }

    // MARK: PDFAIServices

    public func findText(_ query: String, in model: PDFDocumentModel, pageIndex: Int?) async throws -> [PDFTextHit] {
        guard let composed = compose(model) else { throw PicshopError.mediaUnavailable("pdf") }
        let selections = composed.findString(query, withOptions: [.caseInsensitive])
        var hits: [PDFTextHit] = []
        for selection in selections {
            for page in selection.pages {
                let index = composed.index(for: page)
                if let pageIndex, index != pageIndex { continue }
                let size = PSSize(page.bounds(for: .mediaBox).size)
                let rects = selection.selectionsByLine().compactMap { line -> PSRect? in
                    let bounds = line.bounds(for: page)
                    guard !bounds.isEmpty else { return nil }
                    return PDFGeometry.baseNormalized(fromPagePoints: PSRect(bounds), size: size)
                }
                if !rects.isEmpty { hits.append(PDFTextHit(pageIndex: index, rects: rects, text: selection.string ?? query)) }
            }
        }
        if !hits.isEmpty { return hits }
        // No text layer (scan, photo page): read the page with Vision.
        let indices = pageIndex.map { [$0] } ?? Array(0..<composed.pageCount)
        for index in indices {
            guard let page = composed.page(at: index), model.pages.indices.contains(index) else { continue }
            let text = recognizer.text(for: page, key: ocrKey(for: model, pageIndex: index))
            for run in recognizer.matches(for: query, in: text) {
                guard let first = run.first else { continue }
                let rect = run.dropFirst().reduce(first.baseRect) { $0.union($1.baseRect) }
                hits.append(PDFTextHit(pageIndex: index, rects: [rect], text: run.map(\.text).joined(separator: " "), background: first.background))
            }
        }
        return hits
    }

    /// A word under a displayed point: the PDF text layer first, then OCR for scans.
    public struct WordHit: Sendable {
        public var text: String
        /// Base (markup) space.
        public var rect: PSRect
        public var background: PSColor?
    }

    public func word(at displayedPoint: PSPoint, pageIndex: Int, in model: PDFDocumentModel) -> WordHit? {
        guard let composed = compose(model), let page = composed.page(at: pageIndex), model.pages.indices.contains(pageIndex) else { return nil }
        let bounds = page.bounds(for: .mediaBox)
        let size = PSSize(bounds.size)
        let base = PDFGeometry.basePoint(fromDisplayed: displayedPoint, rotation: page.rotation)
        let pagePoint = CGPoint(x: bounds.minX + base.x * bounds.width, y: bounds.minY + (1 - base.y) * bounds.height)
        if let selection = page.selectionForWord(at: pagePoint), let string = selection.string?.trimmingCharacters(in: .whitespacesAndNewlines), !string.isEmpty {
            let rect = selection.bounds(for: page)
            if !rect.isEmpty { return WordHit(text: string, rect: PDFGeometry.baseNormalized(fromPagePoints: PSRect(rect), size: size), background: nil) }
        }
        let text = recognizer.text(for: page, key: ocrKey(for: model, pageIndex: pageIndex))
        guard let word = recognizer.word(at: displayedPoint, in: text) else { return nil }
        return WordHit(text: word.text, rect: word.baseRect, background: word.background)
    }

    /// Whether the page has recognisable text at all (text layer or OCR).
    public func hasText(pageIndex: Int, in model: PDFDocumentModel) -> Bool {
        guard let composed = compose(model), let page = composed.page(at: pageIndex) else { return false }
        if let string = page.string, !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
        return !recognizer.text(for: page, key: ocrKey(for: model, pageIndex: pageIndex)).words.isEmpty
    }

    /// OCR cache key: the page identity, its source and rotation. Markups do not change the scan.
    private func ocrKey(for model: PDFDocumentModel, pageIndex: Int) -> String {
        let page = model.pages[pageIndex]
        return "\(page.id.uuidString)-\(page.rotation)-\(page.source.hashValue)"
    }

    public func extractPage(_ pageIndex: Int, from model: PDFDocumentModel) async throws -> MediaAsset {
        guard let composed = compose(model), let page = composed.page(at: pageIndex) else { throw PicshopError.mediaUnavailable("page") }
        let image = render(page: page, longestSide: 2400)
        try store.createPackage(for: projectID)
        let url = store.mediaURL(for: projectID).appendingPathComponent("page-\(pageIndex + 1)-\(UUID().uuidString).jpg")
        guard let cg = image.cgImage else { throw PicshopError.renderFailed("page render") }
        try ImageSupport.write(cg, to: url, type: .jpeg, quality: 0.95)
        try await PhotoLibrary.save(imageAt: url)
        return MediaAsset(kind: .image, relativePath: "\(Project.mediaDirectory)/\(url.lastPathComponent)", pixelSize: PSSize(width: Double(cg.width), height: Double(cg.height)), origin: .generated)
    }

    public func signatureAsset() async -> MediaAsset? {
        SignatureStore.currentAsset()
    }

    // MARK: Rendering

    public func render(page: PDFPage, longestSide: CGFloat) -> UIImage {
        let bounds = page.bounds(for: .mediaBox)
        let rotated = page.rotation % 180 != 0 ? CGSize(width: bounds.height, height: bounds.width) : bounds.size
        let scale = longestSide / max(rotated.width, rotated.height)
        let size = CGSize(width: rotated.width * scale, height: rotated.height * scale)
        return page.thumbnail(of: size, for: .mediaBox)
    }

    public func thumbnail(for pageIndex: Int, in model: PDFDocumentModel, height: CGFloat = 160) -> UIImage? {
        guard let composed = compose(model), let page = composed.page(at: pageIndex) else { return nil }
        return render(page: page, longestSide: height * 1.5)
    }

    public func thumbnail(page: PDFPage, height: CGFloat = 160) -> UIImage {
        render(page: page, longestSide: height * 1.5)
    }

    // MARK: Export

    /// Exports a flattened PDF: page content stays vector/text, every markup
    /// (including image and signature stamps, which have no appearance stream
    /// through PDFKit) is drawn into the page.
    public func export(_ model: PDFDocumentModel) throws -> URL {
        guard let composed = compose(model) else { throw PicshopError.exportFailed("compose") }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("exports", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = model.title.replacingOccurrences(of: "/", with: "-")
        let url = directory.appendingPathComponent("\(name).pdf")
        try? FileManager.default.removeItem(at: url)
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 595, height: 842))
        try renderer.writePDF(to: url) { context in
            for index in 0..<composed.pageCount {
                guard let page = composed.page(at: index) else { continue }
                let box = page.bounds(for: .mediaBox)
                let rotated = page.rotation % 180 != 0
                let size = rotated ? CGSize(width: box.height, height: box.width) : box.size
                context.beginPage(withBounds: CGRect(origin: .zero, size: size), pageInfo: [:])
                let cg = context.cgContext
                cg.saveGState()
                // UIKit PDF contexts are top-left; PDFKit draws in bottom-left page space.
                cg.translateBy(x: 0, y: size.height)
                cg.scaleBy(x: 1, y: -1)
                cg.concatenate(page.transform(for: .mediaBox))
                page.draw(with: .mediaBox, to: cg)
                cg.restoreGState()
            }
        }
        return url
    }

    /// Copies another PDF into the package for merging; returns its page models.
    public func importForMerge(_ sourceURL: URL) throws -> [PDFPageModel] {
        try store.createPackage(for: projectID)
        let relative = "\(Project.mediaDirectory)/merge-\(UUID().uuidString).pdf"
        let destination = store.url(for: relative, in: projectID)
        let accessing = sourceURL.startAccessingSecurityScopedResource()
        defer { if accessing { sourceURL.stopAccessingSecurityScopedResource() } }
        try FileManager.default.copyItem(at: sourceURL, to: destination)
        guard let document = PDFDocument(url: destination) else { throw PicshopError.mediaUnavailable(sourceURL.lastPathComponent) }
        let asset = MediaAsset(kind: .image, relativePath: relative, pixelSize: .zero, origin: .file)
        return (0..<document.pageCount).map { index in
            PDFPageModel(source: .imported(asset, index: index), size: PSSize(document.page(at: index)?.bounds(for: .mediaBox).size ?? CGSize(width: 595, height: 842)))
        }
    }

    /// Stores a photo in the package to be placed on a page.
    public func importImage(_ image: UIImage) throws -> MediaAsset {
        try store.createPackage(for: projectID)
        let url = store.mediaURL(for: projectID).appendingPathComponent("image-\(UUID().uuidString).png")
        guard let data = image.pngData() else { throw PicshopError.renderFailed("png") }
        try data.write(to: url)
        return MediaAsset(kind: .image, relativePath: "\(Project.mediaDirectory)/\(url.lastPathComponent)", pixelSize: PSSize(image.size), origin: .file)
    }
}

/// The user's signature, stored once in Application Support and reused across documents.
public enum SignatureStore {
    static var directory: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        let url = support.appendingPathComponent("Signature", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    public static var fileURL: URL { directory.appendingPathComponent("signature.png") }

    public static func currentAsset() -> MediaAsset? {
        guard let image = UIImage(contentsOfFile: fileURL.path) else { return nil }
        return MediaAsset(kind: .image, relativePath: fileURL.path, pixelSize: PSSize(image.size), origin: .file)
    }

    public static func currentImage() -> UIImage? {
        UIImage(contentsOfFile: fileURL.path)
    }

    /// Rasterises strokes (normalised in a 3:1 box) to a transparent PNG.
    public static func save(strokes: [BrushStroke], color: PSColor = .black) throws {
        let size = CGSize(width: 900, height: 300)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            let cg = context.cgContext
            cg.setStrokeColor(color.cgColor)
            cg.setLineCap(.round)
            cg.setLineJoin(.round)
            for stroke in strokes {
                cg.setLineWidth(max(2, stroke.radius * 2 * size.width))
                let points = stroke.points.map { CGPoint(x: $0.x * size.width, y: $0.y * size.height) }
                guard let first = points.first else { continue }
                cg.beginPath()
                cg.move(to: first)
                for point in points.dropFirst() { cg.addLine(to: point) }
                cg.strokePath()
            }
        }
        guard let data = image.pngData() else { throw PicshopError.renderFailed("signature") }
        try data.write(to: fileURL, options: .atomic)
    }

    public static func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}

/// Resolves signature assets that live outside the project package.
public extension PDFEditingService {
    func resolvedImage(for asset: MediaAsset) -> UIImage? {
        if asset.relativePath.hasPrefix("/") { return UIImage(contentsOfFile: asset.relativePath) }
        return image(for: asset)
    }
}
#endif
