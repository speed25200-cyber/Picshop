import Foundation
@testable import PicshopCore
@testable import PicshopIntent

/// The benchmark screenshot of the report: "Claude Opus 5.5", 9 rows × 5 model columns, horizontal
/// rules, 1709 × 2048. Owned by T; B's tests read it. The API is frozen (contract §5); the pictures live in
/// PicshopIntent (`LiveEvalFixtures`) so the Diagnostic Live runner replays the same corpus on the iPhone.
enum TableFixtures {
    static let title = LiveEvalFixtures.title
    static let headers = LiveEvalFixtures.headers
    static let labels = LiveEvalFixtures.labels
    static let canvas = LiveEvalFixtures.canvas
    /// 32 px values on a 2048 px canvas, #1C1C1E, regular, centred.
    static let style = LiveEvalFixtures.style

    /// The printed values, row-major (9 rows × 5 columns), one decimal and "%".
    static let values = LiveEvalFixtures.values

    // Geometry, normalised to the canvas (top-left origin).
    static let bounds = LiveEvalFixtures.bounds
    static let labelColumnWidth = LiveEvalFixtures.labelColumnWidth
    static let headerHeight = LiveEvalFixtures.headerHeight

    /// The 9 × 5 grid, horizontal rules only. Without values every data cell is `.empty` and the
    /// columns carry no style or format (the imaging layer derives `bodyStyle` from the labels).
    static func benchmark(withValues: Bool = false) -> TableGrid { LiveEvalFixtures.benchmark(withValues: withValues) }

    /// The screenshot as a document (one image layer, no edits). A `grid` becomes its table memory, as if
    /// Picshop had erased the values of that table.
    static func document(grid: TableGrid? = nil) -> PhotoDocument { LiveEvalFixtures.benchmarkDocument(grid: grid) }

    /// The user's state: the giant bold "1" of the old build at the centre of r6c3 (row "Agentic computer
    /// use", column "Fable 5.1"), ungrouped and selected.
    static func strayOne(in document: PhotoDocument) -> PhotoDocument { LiveEvalFixtures.strayOne(in: document) }

    /// A text box of plausible width for `text`, centred in `content`.
    static func wordBox(_ text: String, in content: PSRect) -> PSRect { LiveEvalFixtures.wordBox(text, in: content) }
}

/// A screenshot of a table: no person, no subject (subjectMask throws noSubject unless `subject` is set),
/// and the grid it is given; `scene` is what `sceneMap(in:)` answers; `failingChecks` are the check tags
/// `verify` reports failed. The same services the Diagnostic Live runner uses.
typealias TableFakeServices = LiveEvalServices
