#if canImport(SwiftUI) && canImport(PDFKit) && canImport(UIKit)
import Foundation
import UIKit
import PDFKit
import PicshopCore
import PicshopIntent
import PicshopPDF
import PicshopImaging

/// PDFKit off the main thread. PDFKit is not thread-safe, so this actor owns a
/// service of its own, and with it its own copies of the source documents and
/// of the composed document: nothing here is ever touched by the viewer.
/// Page thumbnails (cached by page hash), the library thumbnail, the export,
/// the words under a tap, the password, and every PDFKit read of the command
/// executor (it is the executor's PDFAIServices) go through it.
actor PDFBackgroundWorker {
    private let services: PDFEditingService
    /// The composed document for the last model (page navigation aside).
    private var composed: (key: Int, document: PDFDocument)?
    private var thumbnails: [String: UIImage] = [:]
    private var thumbnailOrder: [String] = []
    private static let thumbnailLimit = 64

    init(store: ProjectStore, projectID: UUID) {
        services = PDFEditingService(store: store, projectID: projectID)
    }

    private func composedDocument(for model: PDFDocumentModel) -> PDFDocument? {
        var key = model
        key.currentPageIndex = 0
        let hash = key.hashValue
        if let composed, composed.key == hash { return composed.document }
        guard let document = services.compose(model) else { return nil }
        composed = (hash, document)
        return document
    }

    /// One page as it looks with its markups, `height` points tall (1.5× pixels), cached by the page's hash.
    func pageThumbnail(_ index: Int, in model: PDFDocumentModel, height: CGFloat) -> UIImage? {
        guard model.pages.indices.contains(index) else { return nil }
        let key = "\(model.pages[index].hashValue)@\(Int(height))"
        if let cached = thumbnails[key] {
            if let position = thumbnailOrder.lastIndex(of: key) { thumbnailOrder.remove(at: position) }
            thumbnailOrder.append(key)
            return cached
        }
        guard let page = composedDocument(for: model)?.page(at: index) else { return nil }
        let image = services.thumbnail(page: page, height: height)
        thumbnails[key] = image
        thumbnailOrder.append(key)
        while thumbnailOrder.count > Self.thumbnailLimit {
            thumbnails[thumbnailOrder.removeFirst()] = nil
        }
        return image
    }

    /// The exported PDF, written to a temporary file.
    func export(_ model: PDFDocumentModel, options: PDFExportOptions? = nil) throws -> URL {
        try services.export(model, options: options)
    }

    /// Whether the source PDF still needs its password (the worker's own copy of it).
    func isLocked(_ model: PDFDocumentModel) -> Bool {
        services.isLocked(model)
    }

    /// Opens the worker's copy of the source with the password: its page sizes, nil when wrong.
    func unlock(_ model: PDFDocumentModel, password: String) -> [PSSize]? {
        let sizes = services.unlock(model, password: password)
        if sizes != nil { composed = nil; thumbnails = [:]; thumbnailOrder = [] }
        return sizes
    }

    func word(at point: PSPoint, pageIndex: Int, in model: PDFDocumentModel) -> PDFEditingService.WordHit? {
        services.word(at: point, pageIndex: pageIndex, in: model)
    }

    func pageText(pageIndex: Int, in model: PDFDocumentModel) -> String {
        services.pageText(pageIndex: pageIndex, in: model)
    }
}

/// The PDF command executor's services: every PDFKit call runs on the worker's executor,
/// on its own documents (the synchronous variants, so nothing hops to another thread);
/// only saving a page to Photos happens after.
extension PDFBackgroundWorker: PDFAIServices {
    func findText(_ query: String, in document: PDFDocumentModel, pageIndex: Int?) async throws -> [PDFTextHit] {
        try services.findTextNow(query, in: document, pageIndex: pageIndex, composed: composedDocument(for: document))
    }

    func extractPage(_ pageIndex: Int, from document: PDFDocumentModel) async throws -> MediaAsset {
        let (asset, url) = try services.renderPageFile(pageIndex, from: document, composed: composedDocument(for: document))
        try await PhotoLibrary.save(imageAt: url)
        return asset
    }

    func signatureAsset() async -> MediaAsset? {
        SignatureStore.currentAsset()
    }
}
#endif
