import Foundation
import PicshopCore

// The pictures the dialogue LiveEval runs on, in the app so the Diagnostic Live runner can replay the corpus
// with the real model on the iPhone: the report's benchmark table screenshot (empty, with its values, or
// with the stray "1" of the old build) and a summer-sale poster. No pixels: the table grid and the scene
// maps are what the imaging layer would read, and `LiveEvalServices` answers as the Vision services do.

/// The benchmark screenshot of the report ("Claude Opus 5.5", 9 rows × 5 model columns, horizontal rules,
/// 1709 × 2048) and the poster, as grids, scene maps and documents.
public enum LiveEvalFixtures {
    public static let title = "Claude Opus 5.5"
    public static let headers = ["Opus 5.5", "Opus 5", "Fable 5.1", "Gemini 3.5 Pro", "GPT-6 Astra"]
    public static let labels = ["Agentic coding", "Agentic terminal coding", "Scaled tool use", "Multidisciplinary reasoning",
                                "Novel problem solving", "Agentic computer use", "Graduate-level reasoning", "Visual reasoning", "Knowledge work"]
    public static let canvas = PSSize(width: 1709, height: 2048)
    public static let dark = PSColor(hex: "#1C1C1E") ?? .black
    /// 32 px values on a 2048 px canvas, #1C1C1E, regular, centred.
    public static let style = TableGrid.Style(relativeSize: 0.0156, color: dark, weight: .regular, design: .sans, alignment: .center)

    /// The printed values, row-major (9 rows × 5 columns), one decimal and "%".
    public static let values: [[String]] = [
        ["80.9%", "77.2%", "74.5%", "76.2%", "74.9%"],
        ["59.3%", "50.0%", "47.8%", "54.2%", "58.1%"],
        ["86.2%", "81.6%", "79.3%", "83.0%", "80.4%"],
        ["40.1%", "36.8%", "33.9%", "38.4%", "37.7%"],
        ["71.4%", "66.0%", "61.2%", "68.9%", "70.3%"],
        ["66.3%", "61.4%", "58.8%", "54.7%", "49.9%"],
        ["87.0%", "84.3%", "83.1%", "86.4%", "85.7%"],
        ["80.7%", "77.9%", "75.0%", "79.8%", "76.1%"],
        ["79.4%", "74.6%", "70.2%", "73.3%", "75.8%"],
    ]

    // Geometry, normalised to the canvas (top-left origin).
    public static let bounds = PSRect(x: 0.03, y: 0.10, width: 0.94, height: 0.86)
    public static let labelColumnWidth = 0.35
    public static let headerHeight = 0.07

    // MARK: The benchmark screenshot

    /// The 9 × 5 grid, horizontal rules only. Without values every data cell is `.empty` and the columns
    /// carry no style or format (the imaging layer derives `bodyStyle` from the labels).
    public static func benchmark(withValues: Bool = false) -> TableGrid {
        let dataWidth = (bounds.width - labelColumnWidth) / Double(headers.count)
        let rowHeight = (bounds.height - headerHeight) / Double(labels.count)
        var columns = [TableGrid.Column(index: 0, rect: PSRect(x: bounds.minX, y: bounds.minY, width: labelColumnWidth, height: bounds.height), header: "", isLabel: true)]
        for (offset, header) in headers.enumerated() {
            let rect = PSRect(x: bounds.minX + labelColumnWidth + Double(offset) * dataWidth, y: bounds.minY, width: dataWidth, height: bounds.height)
            let columnValues = values.map { $0[offset] }
            columns.append(TableGrid.Column(index: offset + 1, rect: rect, header: header, isLabel: false,
                                            style: withValues ? style : nil,
                                            format: withValues ? TableGrid.NumberFormat.infer(from: columnValues) : nil))
        }
        var rows = [TableGrid.Row(index: 0, rect: PSRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: headerHeight), label: "", isHeader: true)]
        for (offset, label) in labels.enumerated() {
            let rect = PSRect(x: bounds.minX, y: bounds.minY + headerHeight + Double(offset) * rowHeight, width: bounds.width, height: rowHeight)
            rows.append(TableGrid.Row(index: offset + 1, rect: rect, label: label))
        }
        var cells: [TableGrid.Cell] = []
        for row in rows {
            for column in columns {
                let rect = PSRect(x: column.rect.minX, y: row.rect.minY, width: column.rect.width, height: row.rect.height)
                let content = rect.insetBy(dx: rect.width * 0.08, dy: rect.height * 0.12)
                let kind: TableGrid.CellKind
                var text = ""
                switch (row.isHeader, column.isLabel) {
                case (true, true): kind = .corner
                case (true, false): kind = .header; text = column.header
                case (false, true): kind = .label; text = row.label
                case (false, false): kind = .data; text = withValues ? values[row.index - 1][column.index - 1] : ""
                }
                let words = text.isEmpty ? [] : [wordBox(text, in: content)]
                cells.append(TableGrid.Cell(row: row.index, column: column.index, rect: rect, contentRect: content, text: text, wordBoxes: words,
                                            kind: kind, state: text.isEmpty ? .empty : .printed))
            }
        }
        return TableGrid(id: TableGrid.makeID(bounds: bounds, rows: rows, columns: columns), bounds: bounds, title: title, rows: rows,
                         columns: columns, cells: cells, headerRowCount: 1, labelColumnCount: 1, ruling: .horizontal, bodyStyle: style,
                         confidence: 0.92, source: .detected)
    }

    /// The screenshot as a document (one image layer, no edits). A `grid` becomes its table memory, as if
    /// Picshop had erased the values of that table.
    public static func benchmarkDocument(grid: TableGrid? = nil) -> PhotoDocument {
        var document = PhotoDocument(title: "Benchmark", baseImage: MediaAsset(kind: .image, relativePath: "media/benchmark.png", pixelSize: canvas))
        if let grid { document.tableMemory = TableMemory(grid: grid, geometryKey: document.tableGeometryKey) }
        return document
    }

    /// The user's state: the giant bold "1" of the old build at the centre of r6c3 (row "Agentic computer
    /// use", column "Fable 5.1"), ungrouped and selected.
    public static func strayOne(in document: PhotoDocument) -> PhotoDocument {
        var document = document
        guard let cell = benchmark().cell(dataRow: 6, dataColumn: 3) else { return document }
        let element = TextElement(text: "1", fontName: "SFProRounded-Bold", relativeSize: 0.06, color: .black, style: .shadowed, center: cell.contentRect.center)
        document.addLayer(Layer(name: "1", content: .text(element)))
        return document
    }

    /// A text box of plausible width for `text`, centred in `content`.
    public static func wordBox(_ text: String, in content: PSRect) -> PSRect {
        let height = style.relativeSize * 0.72
        let width = min(content.width, Double(text.count) * style.relativeSize * 0.55 * canvas.height / canvas.width)
        return PSRect(x: content.midX - width / 2, y: content.midY - height / 2, width: width, height: height)
    }

    /// The benchmark screenshot as a scene map: t1 the title, t2…t6 the headers, t7…t15 the row labels, the
    /// table, and a free band under the title.
    public static func benchmarkScene(withValues: Bool = false) -> SceneMap {
        let grid = benchmark(withValues: withValues)
        let document = benchmarkDocument()
        var texts = [SceneMap.TextBlock(id: "t1", text: title, box: PSRect(x: 0.03, y: 0.035, width: 0.42, height: 0.04),
                                        wordBoxes: [PSRect(x: 0.03, y: 0.035, width: 0.42, height: 0.04)],
                                        style: TableGrid.Style(relativeSize: 0.032, color: dark, weight: .bold, alignment: .leading), role: .title)]
        for (offset, column) in grid.dataColumns.enumerated() {
            guard let cell = grid.cells.first(where: { $0.row == 0 && $0.column == column.index }) else { continue }
            let box = wordBox(column.header, in: cell.contentRect)
            texts.append(SceneMap.TextBlock(id: "t\(offset + 2)", text: column.header, box: box, wordBoxes: [box],
                                            style: TableGrid.Style(relativeSize: 0.0156, color: dark, weight: .semibold), role: .tableHeader))
        }
        for (offset, row) in grid.dataRows.enumerated() {
            guard let cell = grid.cells.first(where: { $0.row == row.index && $0.column == 0 }) else { continue }
            let box = PSRect(x: cell.contentRect.minX, y: cell.contentRect.midY - 0.008, width: min(cell.contentRect.width, Double(row.label.count) * 0.0105), height: 0.016)
            texts.append(SceneMap.TextBlock(id: "t\(offset + 2 + grid.dataColumns.count)", text: row.label, box: box, wordBoxes: [box],
                                            style: TableGrid.Style(relativeSize: 0.0156, color: dark, alignment: .leading), role: .tableLabel))
        }
        return SceneMap(stateKey: document.baseStateKey, canvasSize: canvas, kind: .table, texts: texts, objects: [], table: grid,
                        freeAreas: [SceneMap.FreeArea(id: "f1", box: PSRect(x: 0.5, y: 0.02, width: 0.47, height: 0.07), background: .white)],
                        background: .white)
    }

    // MARK: A poster photo

    public static let posterCanvas = PSSize(width: 1080, height: 1350)
    public static let posterAssetPath = "media/poster.jpg"

    /// A summer-sale poster photo: a person (o1) in the middle, a bold white title at the top (t1), a subtitle
    /// under it (t2), a price at the bottom left (t3); sky free at the top right (f1), a flat band at the bottom (f2).
    public static func posterScene() -> SceneMap {
        let white = PSColor.white
        let texts = [
            SceneMap.TextBlock(id: "t1", text: "SOLDES D'ÉTÉ", box: PSRect(x: 0.12, y: 0.05, width: 0.76, height: 0.09),
                               wordBoxes: [PSRect(x: 0.12, y: 0.05, width: 0.44, height: 0.09), PSRect(x: 0.6, y: 0.05, width: 0.28, height: 0.09)],
                               style: TableGrid.Style(relativeSize: 0.075, color: white, weight: .bold), role: .title),
            SceneMap.TextBlock(id: "t2", text: "-50% sur tout", box: PSRect(x: 0.3, y: 0.16, width: 0.4, height: 0.04),
                               wordBoxes: [PSRect(x: 0.3, y: 0.16, width: 0.4, height: 0.04)],
                               style: TableGrid.Style(relativeSize: 0.032, color: white, weight: .medium), role: .heading),
            SceneMap.TextBlock(id: "t3", text: "29,99 €", box: PSRect(x: 0.06, y: 0.86, width: 0.22, height: 0.05),
                               wordBoxes: [PSRect(x: 0.06, y: 0.86, width: 0.22, height: 0.05)],
                               style: TableGrid.Style(relativeSize: 0.04, color: PSColor(hex: "#FFD60A") ?? .yellow, weight: .bold, alignment: .leading), role: .body),
        ]
        let objects = [SceneMap.Object(id: "o1", label: "person", box: PSRect(x: 0.3, y: 0.24, width: 0.4, height: 0.7), confidence: 0.94, kind: .person)]
        let areas = [
            SceneMap.FreeArea(id: "f1", box: PSRect(x: 0.7, y: 0.22, width: 0.28, height: 0.18), background: PSColor(hex: "#7EC8F0")),
            SceneMap.FreeArea(id: "f2", box: PSRect(x: 0.3, y: 0.93, width: 0.68, height: 0.06), background: PSColor(hex: "#E9D8B4")),
        ]
        return SceneMap(stateKey: posterDocument().baseStateKey, canvasSize: posterCanvas, kind: .photo, texts: texts, objects: objects,
                        freeAreas: areas, background: PSColor(hex: "#7EC8F0"))
    }

    public static func posterDocument() -> PhotoDocument {
        PhotoDocument(title: "Poster", baseImage: MediaAsset(kind: .image, relativePath: posterAssetPath, pixelSize: posterCanvas))
    }

    /// The services a poster runs on: the scene above, no table, the person as the subject.
    public static func posterServices(failingChecks: Set<String> = []) -> LiveEvalServices {
        let scene = posterScene()
        let person = scene.objects.first?.box ?? .unit
        return LiveEvalServices(grid: nil, scene: scene, failingChecks: failingChecks, subject: MaskReference(source: .subject, boundingBox: person))
    }
}

/// Services that answer as the Vision ones do for a fixture: the grid it is given, the scene map it is given
/// (its objects are the detection candidates), no subject unless one is set (subjectMask throws noSubject),
/// masks from the candidates' boxes, and the structural check for `verify`, with `failingChecks` (check
/// tags) reported failed to simulate a render that does not read.
public struct LiveEvalServices: PhotoAIServices {
    /// Call counts (a class box, so a copy of the services counts into the same place).
    public final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var counts: [String: Int] = [:]

        public init() {}

        public func hit(_ name: String) { lock.lock(); counts[name, default: 0] += 1; lock.unlock() }
        public func count(_ name: String) -> Int { lock.lock(); defer { lock.unlock() }; return counts[name, default: 0] }
        public var tableGrid: Int { count("tableGrid") }
        public var mask: Int { count("mask") }
        public var subjectMask: Int { count("subjectMask") }
        public var sceneMap: Int { count("sceneMap") }
        public var verify: Int { count("verify") }
    }

    public var grid: TableGrid?
    public var scene: SceneMap?
    public var failingChecks: Set<String>
    public var calls: Counter
    /// The subject mask when the picture has one (a poster with a person); nil throws noSubject.
    public var subject: MaskReference?

    public init(grid: TableGrid? = LiveEvalFixtures.benchmark(), scene: SceneMap? = nil, failingChecks: Set<String> = [], calls: Counter = Counter(),
                subject: MaskReference? = nil) {
        self.grid = grid
        self.scene = scene
        self.failingChecks = failingChecks
        self.calls = calls
        self.subject = subject
    }

    public func candidates(for target: ObjectTarget, in document: PhotoDocument) async throws -> [ObjectCandidate] {
        (scene?.objects ?? []).filter { $0.label == target.label || target.label == "object" }.map {
            ObjectCandidate(label: $0.label, boundingBox: $0.box, confidence: $0.confidence)
        }
    }

    public func mask(for candidates: [ObjectCandidate], target: ObjectTarget, in document: PhotoDocument) async throws -> MaskReference {
        calls.hit("mask")
        let box = candidates.map(\.boundingBox).reduce(PSRect.zero) { $0.union($1) }
        return MaskReference(source: .object(label: target.label, boundingBox: box), boundingBox: box)
    }

    public func subjectMask(in document: PhotoDocument) async throws -> MaskReference {
        calls.hit("subjectMask")
        guard let subject else { throw PicshopError.noSubject }
        return subject
    }

    public func horizonAngle(in document: PhotoDocument) async throws -> Double? { nil }

    public func framingRect(for target: ObjectTarget, in document: PhotoDocument) async throws -> PSRect? { nil }

    public func describe(_ document: PhotoDocument) async throws -> SceneDescription {
        SceneDescription(labels: ["screenshot", "document"], hasText: true, brightness: 0.92, colourfulness: 0.04)
    }

    public func tableGrid(in document: PhotoDocument, remembered: TableGrid?) async throws -> TableGrid? {
        calls.hit("tableGrid")
        return grid
    }

    public func sceneMap(in document: PhotoDocument) async throws -> SceneMap? {
        calls.hit("sceneMap")
        return scene
    }

    public func verify(_ requests: [VerificationRequest], in document: PhotoDocument) async throws -> [VerificationReport] {
        calls.hit("verify")
        return requests.map { request in
            var report = EditVerifier.structural(request, in: document)
            report.method = .pixels
            for index in report.items.indices where failingChecks.contains(report.items[index].check.tag) {
                report.items[index].outcome = .failed
                report.items[index].observed = nil
            }
            return report
        }
    }
}
