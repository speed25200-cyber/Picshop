#if canImport(SwiftUI) && canImport(PDFKit) && canImport(UIKit)
import Foundation
import UIKit
import PDFKit
import PicshopCore
import PicshopPDF

/// PDFKit off the main thread. PDFKit is not thread-safe, so this actor owns a
/// service of its own, and with it its own copies of the source documents and
/// of the composed document: nothing here is ever touched by the viewer.
/// Page thumbnails (cached by page hash), the library thumbnail, the export,
/// and the words under a tap all go through it.
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

    /// The flattened PDF, written to a temporary file.
    func export(_ model: PDFDocumentModel) throws -> URL {
        try services.export(model)
    }

    func word(at point: PSPoint, pageIndex: Int, in model: PDFDocumentModel) -> PDFEditingService.WordHit? {
        services.word(at: point, pageIndex: pageIndex, in: model)
    }

    func pageText(pageIndex: Int, in model: PDFDocumentModel) -> String {
        services.pageText(pageIndex: pageIndex, in: model)
    }
}
#endif
