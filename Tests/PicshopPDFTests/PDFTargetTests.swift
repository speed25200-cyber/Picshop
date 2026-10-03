#if canImport(PDFKit)
import XCTest
import PDFKit

/// The PDF tests run on the macOS runner (W0: redacted text cannot be extracted or found,
/// outline and links kept, a password fixture opens). Until they land: PDFKit is reachable.
final class PDFTargetTests: XCTestCase {
    func testPDFKitIsReachable() {
        let document = PDFDocument()
        document.insert(PDFPage(), at: 0)
        XCTAssertEqual(document.pageCount, 1)
    }
}
#endif
