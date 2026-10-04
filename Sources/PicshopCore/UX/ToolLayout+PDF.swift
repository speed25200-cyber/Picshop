import Foundation

// The PDF editor's tool homes (ux-spec §3.7). Owned by U4. Increment 1 keeps the PDF editor's current UI, so the
// table is empty until U4 fills it (the six modes, PDFToolCatalog's tools as homes).

extension ToolLayout {
    /// The PDF editor's table (empty until U4 lands the PDF frame).
    public static let pdf = ToolLayout(kind: .pdf, categories: [])
}
