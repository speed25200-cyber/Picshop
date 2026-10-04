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

    // MARK: A lake photo (W2: masks and selections)

    public static let lakeCanvas = PSSize(width: 1600, height: 1200)
    public static let lakeAssetPath = "media/lake.jpg"
    static let lakePerson = PSRect(x: 0.12, y: 0.3, width: 0.24, height: 0.62)
    static let lakeCup = PSRect(x: 0.62, y: 0.62, width: 0.12, height: 0.16)

    /// A portrait by a lake (W2): a person on the left (o1), a blue cup on a table on the right (o2), sky above,
    /// water behind. No text.
    public static func lakeScene() -> SceneMap {
        let objects = [
            SceneMap.Object(id: "o1", label: "person", box: lakePerson, confidence: 0.95, kind: .person),
            SceneMap.Object(id: "o2", label: "cup", box: lakeCup, confidence: 0.9, kind: .object),
        ]
        return SceneMap(stateKey: lakeDocument().baseStateKey, canvasSize: lakeCanvas, kind: .photo, texts: [], objects: objects, freeAreas: [],
                        background: PSColor(hex: "#8FB8D8"))
    }

    public static func lakeDocument() -> PhotoDocument {
        PhotoDocument(title: "Lake", baseImage: MediaAsset(kind: .image, relativePath: lakeAssetPath, pixelSize: lakeCanvas))
    }

    /// The services of the lake photo: the scene above, the person as the subject, and the mask simulation
    /// (SAM and depth installed, one face, the person and the cup as Vision's objects).
    public static func lakeServices(failingChecks: Set<String> = []) -> LiveEvalServices {
        let person = ObjectCandidate(label: "person", boundingBox: lakePerson, confidence: 0.95)
        let cup = ObjectCandidate(label: "cup", boundingBox: lakeCup, confidence: 0.9)
        let masks = MaskSimulation(faces: [PSRect(x: 0.18, y: 0.32, width: 0.1, height: 0.12)], objects: [person, cup])
        return LiveEvalServices(grid: nil, scene: lakeScene(), failingChecks: failingChecks, subject: MaskReference(source: .subject, boundingBox: lakePerson),
                                masks: masks, grounds: true)
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
    /// The W2 mask and selection services, structurally (`MaskSimulation`); nil keeps the W1 host (no masks: the
    /// handlers say so and selectiveAdjust keeps its legacy op).
    public var masks: MaskSimulation?
    /// The vision-language model's boxes (`groundBox`); off by default, as on a device without one.
    public var grounds: Bool

    public init(grid: TableGrid? = LiveEvalFixtures.benchmark(), scene: SceneMap? = nil, failingChecks: Set<String> = [], calls: Counter = Counter(),
                subject: MaskReference? = nil, masks: MaskSimulation? = nil, grounds: Bool = false) {
        self.grid = grid
        self.scene = scene
        self.failingChecks = failingChecks
        self.calls = calls
        self.subject = subject
        self.masks = masks
        self.grounds = grounds
    }

    public func candidates(for target: ObjectTarget, in document: PhotoDocument) async throws -> [ObjectCandidate] {
        // A face part (W2's lowering): one candidate per face the mask simulation knows, as Vision's landmarks.
        if let faces = masks?.faces, ["teeth", "eyes", "lips", "skin", "face", "mouth"].contains(target.label) {
            return faces.map { ObjectCandidate(label: target.label, boundingBox: $0, confidence: 0.9) }
        }
        return (scene?.objects ?? []).filter { $0.label == target.label || target.label == "object" }.map {
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

    // MARK: Masks and selections (W2)

    func simulation() throws -> MaskSimulation {
        guard let masks else { throw PicshopError.unsupportedOperation("Masks") }
        return masks
    }

    public func aiMask(_ request: AIMaskRequest, in document: PhotoDocument) async throws -> AIMaskResult {
        calls.hit("aiMask")
        return try simulation().aiMask(request, in: document)
    }

    public func depthMap(in document: PhotoDocument) async throws -> RasterRef {
        try simulation().depthMap(in: document)
    }

    public func rasterize(_ stack: MaskStack, in document: PhotoDocument) async throws -> AIMaskResult {
        try simulation().rasterize(stack, in: document)
    }

    // W3: layers (the synthetic rasters keep the structural checks meaningful, §8.7).
    public func aiMask(_ request: AIMaskRequest, in document: PhotoDocument, layer: UUID?) async throws -> AIMaskResult {
        calls.hit("aiMask")
        return try simulation().aiMask(request, in: document, layer: layer)
    }

    public func rasterizeLayers(_ request: LayerRasterRequest, in document: PhotoDocument) async throws -> LayerRasterResult {
        calls.hit("rasterizeLayers")
        return (masks ?? MaskSimulation()).rasterizeLayers(request, in: document)
    }

    public func contentSize(of layerID: UUID, in document: PhotoDocument) async -> PSSize? {
        (masks ?? MaskSimulation()).contentSize(of: layerID, in: document)
    }

    public func combineSelection(_ current: PhotoSelection?, with new: RasterRef, mode: CombineMode?, in document: PhotoDocument) async throws -> PhotoSelection {
        try simulation().combineSelection(current, with: new, mode: mode, in: document)
    }

    public func modifySelection(_ selection: PhotoSelection, _ change: SelectionChange, in document: PhotoDocument) async throws -> PhotoSelection {
        try simulation().modifySelection(selection, change, in: document)
    }

    public func refineSelection(_ selection: PhotoSelection, _ refinement: SelectionRefinement, in document: PhotoDocument) async throws -> PhotoSelection {
        try simulation().refineSelection(selection, refinement, in: document)
    }

    public func sampleColors(at points: [PSPoint], radius: Int, in document: PhotoDocument) async throws -> [LabColor] {
        try simulation().sampleColors(at: points, radius: radius)
    }

    public func wandMask(at point: PSPoint, tolerance: Double, contiguous: Bool, sampleSize: Int, in document: PhotoDocument) async throws -> AIMaskResult {
        try simulation().wandMask(at: point, tolerance: tolerance, contiguous: contiguous, in: document)
    }

    public func pixelProbes(_ requests: [PixelProbeRequest], before: PhotoDocument, after: PhotoDocument) async -> [PixelProbeResult] {
        calls.hit("pixelProbes")
        return masks?.pixelProbes(requests, before: before, after: after) ?? []
    }

    public func groundBox(_ phrase: String, in document: PhotoDocument) async -> PSRect? {
        calls.hit("groundBox")
        guard grounds else { return nil }
        return masks?.groundBox(phrase)
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

// MARK: - Masks and selections, structurally (W2)

/// The W2 mask and selection services as a structural simulation, for the hosts that have no pixels (LiveEval, the
/// M lane, the S lane): deterministic rasters (coverage 0.3 unless the request says more), boxes from the
/// candidates, selections that combine coverages (add a + b·(1 − a), subtract a·(1 − b), intersect a·b), and
/// pixel probes whose Lab statistics move the way the documents say (a dial inside its mask, a fill colour, a
/// blur), so the pixel postconditions pass on correct edits and fail on wrong ones without a renderer.
public struct MaskSimulation: Sendable {
    /// What the picture has: AI regions not listed in `absent` are found.
    public var absent: Set<MaskRegion>
    /// Colour names (and Color Range presets) that are not in the picture: a colour range of them covers nothing.
    public var absentColors: Set<String>
    /// SAM installed: boxes and points always segment; without it only an overlapping candidate does.
    public var samInstalled: Bool
    /// The camera disparity or the depth model: without it near and far throw modelUnavailable.
    public var hasDepth: Bool
    /// The faces left to right (people parts with an index), and the boxes of the scene's objects.
    public var faces: [PSRect]
    public var objects: [ObjectCandidate]
    /// What only the vision-language model finds (Vision's candidates miss it): `groundBox` answers for these too.
    public var groundable: [ObjectCandidate]

    public init(absent: Set<MaskRegion> = [], absentColors: Set<String> = ["purple", "violet", "magentas"], samInstalled: Bool = true,
                hasDepth: Bool = true, faces: [PSRect] = [PSRect(x: 0.4, y: 0.25, width: 0.15, height: 0.18)], objects: [ObjectCandidate] = [],
                groundable: [ObjectCandidate] = []) {
        self.absent = absent
        self.absentColors = absentColors
        self.samInstalled = samInstalled
        self.hasDepth = hasDepth
        self.faces = faces
        self.objects = objects
        self.groundable = groundable
    }

    /// The default coverage of a simulated AI raster.
    public static let coverage = 0.3
    static let side = PhotoSelection.workingLongestSide

    /// A raster whose path carries its coverage ("masks/sim-<hash>-c0.300.png"), so a later combine reads it back.
    public static func raster(_ origin: RasterRef.Origin, label: String?, key: String, coverage: Double, box: PSRect = .unit, document: PhotoDocument,
                              bitDepth: Int = 8) -> RasterRef {
        let aspect = max(0.1, document.canvasSize.aspectRatio.isFinite && document.canvasSize.aspectRatio > 0 ? document.canvasSize.aspectRatio : 1)
        let width = aspect >= 1 ? side : Int((Double(side) * aspect).rounded())
        let height = aspect >= 1 ? Int((Double(side) / aspect).rounded()) : side
        let path = "masks/sim-\(StableHash.hex(key + "|" + origin.rawValue + "|" + (label ?? "")))-c\(String(format: "%.3f", coverage)).png"
        return RasterRef(path: path, origin: origin, pixelWidth: width, pixelHeight: height, bitDepth: bitDepth, boundingBox: box.clampedToUnit(),
                         label: label, stateKey: document.baseStateKey)
    }

    /// The coverage a simulated raster's path carries, else the default.
    public static func coverage(of path: String) -> Double {
        guard let range = path.range(of: "-c", options: .backwards), path.hasSuffix(".png") else { return coverage }
        return Double(path[range.upperBound...].dropLast(4)) ?? coverage
    }

    func result(_ origin: RasterRef.Origin, label: String?, key: String, coverage: Double = MaskSimulation.coverage, box: PSRect = .unit,
                document: PhotoDocument, usedModel: Bool = false, approximate: Bool = false) -> AIMaskResult {
        AIMaskResult(raster: Self.raster(origin, label: label, key: key, coverage: coverage, box: box, document: document), coverage: coverage,
                     usedModel: usedModel, isApproximate: approximate)
    }

    /// The coverage of a box mask: a share of its area.
    static func boxCoverage(_ box: PSRect) -> Double { (box.clampedToUnit().area * 0.8).clamped(to: 0.01...0.95) }

    public func aiMask(_ request: AIMaskRequest, in document: PhotoDocument) throws -> AIMaskResult {
        func found(_ region: MaskRegion) throws {
            if absent.contains(region) { throw PicshopError.objectNotFound(region.rawValue) }
        }
        switch request {
        case .subject:
            try found(.subject)
            return result(.subject, label: nil, key: "subject", coverage: 0.35, box: PSRect(x: 0.3, y: 0.2, width: 0.4, height: 0.7), document: document)
        case .background:
            try found(.subject)
            return result(.background, label: nil, key: "background", coverage: 0.65, document: document)
        case .people:
            try found(.people)
            return result(.people, label: nil, key: "people", coverage: 0.3, document: document)
        case .sky:
            try found(.sky)
            return result(.sky, label: nil, key: "sky", coverage: 0.35, box: PSRect(x: 0, y: 0, width: 1, height: 0.4), document: document,
                          approximate: !samInstalled)
        case .vegetation:
            try found(.vegetation)
            return result(.vegetation, label: nil, key: "vegetation", coverage: 0.2, document: document)
        case .water:
            try found(.water)
            return result(.water, label: nil, key: "water", coverage: 0.15, document: document)
        case .person(let index):
            try found(.people)
            guard index >= 1, index <= max(1, faces.count) else { throw PicshopError.objectNotFound("person") }
            return result(.person, label: String(index), key: "person\(index)", coverage: 0.2, document: document)
        case .personPart(let region, let person):
            try found(region)
            if region == .hair || region == .bodySkin { throw PicshopError.objectNotFound(region.rawValue) }
            let index = person ?? 1
            guard index >= 1, index <= faces.count else { throw PicshopError.objectNotFound("face") }
            let face = faces[index - 1]
            return result(.facePart, label: "\(region.rawValue):\(index)", key: "\(region.rawValue)\(index)", coverage: Self.boxCoverage(face) * 0.4, box: face,
                          document: document)
        case .candidates(let list, let target):
            guard !list.isEmpty else { throw PicshopError.objectNotFound(target.label) }
            let box = list.map(\.boundingBox).reduce(list[0].boundingBox) { $0.union($1) }
            let part = ["face", "skin", "eyes", "lips", "teeth", "hair"].contains(target.label)
            let label = part ? "\(target.label == "skin" ? "faceSkin" : target.label):1" : target.label
            return result(part ? .facePart : .object, label: label, key: "candidates-\(target.label)-\(box)", coverage: Self.boxCoverage(box), box: box,
                          document: document)
        case .object(let target):
            guard let object = objects.first(where: { $0.label == target.label }) else {
                if samInstalled { throw PicshopError.objectNotFound(target.label) }
                throw PicshopError.modelUnavailable(ModelOfferText.samID)
            }
            return result(.object, label: target.label, key: "object-\(target.label)", coverage: Self.boxCoverage(object.boundingBox), box: object.boundingBox,
                          document: document, usedModel: samInstalled)
        case .sceneObject(let number):
            guard number >= 1, number <= objects.count else { throw PicshopError.objectNotFound("object") }
            let object = objects[number - 1]
            return result(.object, label: object.label, key: "o\(number)", coverage: Self.boxCoverage(object.boundingBox), box: object.boundingBox,
                          document: document, usedModel: samInstalled)
        case .box(let rect, let label):
            if !samInstalled, !objects.contains(where: { $0.boundingBox.intersection(rect).area > rect.area * 0.3 }) {
                throw PicshopError.modelUnavailable(ModelOfferText.samID)
            }
            return result(.object, label: label, key: "box-\(rect)", coverage: Self.boxCoverage(rect), box: rect, document: document, usedModel: samInstalled)
        case .points(let prompts, let label):
            guard let first = prompts.first(where: \.isPositive) else { throw PicshopError.objectNotFound(label ?? "object") }
            let box = PSRect(x: first.point.x - 0.1, y: first.point.y - 0.1, width: 0.2, height: 0.2).clampedToUnit()
            if !samInstalled, !objects.contains(where: { $0.boundingBox.contains(first.point) }) {
                throw PicshopError.modelUnavailable(ModelOfferText.samID)
            }
            return result(.object, label: label, key: "points-\(prompts)", coverage: Self.boxCoverage(box), box: box, document: document,
                          usedModel: samInstalled, approximate: !samInstalled)
        }
    }

    public func depthMap(in document: PhotoDocument) throws -> RasterRef {
        guard hasDepth else { throw PicshopError.modelUnavailable(ModelOfferText.depthID) }
        return Self.raster(.depth, label: nil, key: "depth", coverage: 1, document: document, bitDepth: 16)
    }

    /// A stack's estimated coverage: its first component's, then the stack's expand, invert and density.
    public func coverage(of stack: MaskStack) -> Double {
        var value = 0.0
        for component in stack.components {
            var part: Double
            switch component.kind {
            case .raster(let raster): part = Self.coverage(of: raster.path)
            case .brush(let spec): part = spec.strokes.isEmpty ? 0 : 0.1
            case .linear: part = 0.35
            case .radial(let spec): part = (Double.pi * spec.radiusX * spec.radiusY).clamped(to: 0.01...1)
            case .colorRange(let spec):
                let names = Set(spec.samples.map { "\(Int($0.l)),\(Int($0.a)),\(Int($0.b))" })
                let preset = spec.preset?.rawValue
                let missing = (preset.map(absentColors.contains) ?? false) || spec.samples.contains { sample in absentLabs.contains { abs($0.a - sample.a) + abs($0.b - sample.b) < 12 } }
                part = missing || (names.isEmpty && preset == nil) ? 0 : 0.2 + spec.fuzziness * 0.1
            case .luminanceRange(let spec): part = (spec.high - spec.low).clamped(to: 0...1) * 0.8
            case .depthRange(let spec): part = (spec.high - spec.low).clamped(to: 0...1) * 0.7
            case .unsupported: continue
            }
            if component.isInverted { part = 1 - part }
            part *= component.opacity
            switch component.mode {
            case .add: value = value + part * (1 - value)
            case .subtract: value = value * (1 - part)
            case .intersect: value = value * part
            }
        }
        if stack.expand != 0 { value = (value + stack.expand * 0.05).clamped(to: 0...1) }
        if stack.isInverted { value = 1 - value }
        return (value * stack.density).clamped(to: 0...1)
    }

    /// The Lab colours the absent colour names stand for.
    var absentLabs: [LabColor] {
        absentColors.compactMap { PSColor.named($0) }.map { MaskMath.lab($0) }
    }

    public func rasterize(_ stack: MaskStack, in document: PhotoDocument) -> AIMaskResult {
        let value = coverage(of: stack)
        return result(.selection, label: nil, key: "stack-\(stack.contentKey)", coverage: value, document: document)
    }

    public func combineSelection(_ current: PhotoSelection?, with new: RasterRef, mode: CombineMode?, in document: PhotoDocument) -> PhotoSelection {
        let b = Self.coverage(of: new.path)
        let a = current?.coverage ?? 0
        let value: Double
        switch (current == nil ? nil : mode) {
        case nil: value = b
        case .add?: value = min(1, a + b * (1 - a))
        case .subtract?: value = a * (1 - b)
        case .intersect?: value = a * b
        }
        let previous = current?.mask.boundingBox ?? .unit
        let box: PSRect
        switch (current == nil ? nil : mode) {
        case nil: box = new.boundingBox
        case .add?: box = previous.union(new.boundingBox)
        case .subtract?: box = previous
        case .intersect?: box = previous.intersection(new.boundingBox)
        }
        return selection(value, steps: current?.steps ?? [], refinement: current?.refinement, layerID: document.localAdjustmentsLayerID ?? UUID(),
                         key: "\(current?.mask.relativePath ?? "")|\(new.path)|\(mode?.rawValue ?? "new")", box: box, document: document)
    }

    func selection(_ coverage: Double, steps: [SelectionStep], refinement: SelectionRefinement?, layerID: UUID, key: String, box: PSRect = .unit,
                   document: PhotoDocument) -> PhotoSelection {
        let raster = Self.raster(.selection, label: nil, key: key, coverage: coverage, box: box, document: document)
        return PhotoSelection(mask: MaskReference(relativePath: raster.path, source: .region("selection"), boundingBox: raster.boundingBox), layerID: layerID,
                              steps: steps, refinement: refinement, coverage: coverage, pixelWidth: raster.pixelWidth, pixelHeight: raster.pixelHeight)
    }

    public func modifySelection(_ current: PhotoSelection, _ change: SelectionChange, in document: PhotoDocument) -> PhotoSelection {
        let a = current.coverage
        let value: Double
        switch change {
        case .invert: value = 1 - a
        case .grow(let pixels): value = min(1, a + pixels / 1000 * 0.2)
        case .shrink(let pixels): value = max(0, a - pixels / 1000 * 0.2)
        case .feather, .smooth: value = a
        }
        let box = change == .invert ? PSRect.unit : current.mask.boundingBox
        return selection(value, steps: current.steps, refinement: current.refinement, layerID: current.layerID,
                         key: "\(current.mask.relativePath)|\(change)", box: box, document: document)
    }

    public func refineSelection(_ current: PhotoSelection, _ refinement: SelectionRefinement, in document: PhotoDocument) -> PhotoSelection {
        let value = (current.coverage + refinement.shiftEdge * 0.02).clamped(to: 0...1)
        return selection(value, steps: current.steps, refinement: refinement, layerID: current.layerID,
                         key: "\(current.mask.relativePath)|refine|\(refinement)", box: current.mask.boundingBox, document: document)
    }

    public func sampleColors(at points: [PSPoint], radius: Int) -> [LabColor] {
        points.map { point in LabColor(l: 40 + point.y * 30, a: 10 - point.x * 20, b: 20 - point.y * 30) }
    }

    public func wandMask(at point: PSPoint, tolerance: Double, contiguous: Bool, in document: PhotoDocument) -> AIMaskResult {
        result(.selection, label: nil, key: "wand-\(point)-\(tolerance)-\(contiguous)", coverage: (0.05 + tolerance * 0.3).clamped(to: 0.01...0.9),
               box: PSRect(x: point.x - 0.15, y: point.y - 0.15, width: 0.3, height: 0.3), document: document)
    }

    /// The box of what a phrase names: the first candidate whose label is in the phrase.
    public func groundBox(_ phrase: String) -> PSRect? {
        let words = Set(TextFolding.tokens(phrase))
        return (objects + groundable).first { words.contains($0.label) }?.boundingBox
    }

    // MARK: Layers (W3)

    /// `aiMask(_:in:layer:)`: the same simulated regions on a layer's own pixels (its content space).
    public func aiMask(_ request: AIMaskRequest, in document: PhotoDocument, layer: UUID?) throws -> AIMaskResult {
        var result = try aiMask(request, in: document)
        // Made for that layer's own state, as the renderer's content-space proxy stamps it.
        result.raster.stateKey = document.maskStateKey(on: layer)
        return result
    }

    /// `rasterizeLayers`: a synthetic canvas-sized asset whose opaque bounds are the union of the flattened layers'
    /// placed bounds (the whole canvas for the visible composite), so the structure edits place it as a renderer would.
    public func rasterizeLayers(_ request: LayerRasterRequest, in document: PhotoDocument) -> LayerRasterResult {
        let bounds: PSRect
        let key: String
        switch request {
        case .visible:
            bounds = .unit
            key = "visible-\(document.layers.map(\.id.uuidString).joined())"
        case .layers(let ids), .merged(let ids):
            let boxes = ids.compactMap { document.layer(id: $0) }.map { layer -> PSRect in
                guard layer.id != document.baseLayerID, let size = LayerPlacement.contentSize(of: layer, canvasSize: document.canvasSize) else { return .unit }
                return LayerPlacement.bounds(for: layer, contentSize: size, canvasSize: document.canvasSize, isBase: false).clampedToUnit()
            }
            bounds = boxes.dropFirst().reduce(boxes.first ?? .unit) { $0.union($1) }
            key = ids.map(\.uuidString).joined(separator: ",")
        }
        let pixels = PSSize(width: (bounds.width * document.canvasSize.width).rounded(), height: (bounds.height * document.canvasSize.height).rounded())
        let asset = MediaAsset(kind: .image, relativePath: "media/raster-\(StableHash.hex(key)).png", pixelSize: pixels.isEmpty ? document.canvasSize : pixels)
        return LayerRasterResult(asset: asset, opaqueBounds: bounds)
    }

    /// Text and shape sizes at the canvas size: a shape's relative size, a text's from its font size.
    public func contentSize(of layerID: UUID, in document: PhotoDocument) -> PSSize? {
        guard let layer = document.layer(id: layerID) else { return nil }
        if let size = LayerPlacement.contentSize(of: layer, canvasSize: document.canvasSize) { return size }
        guard let element = layer.textElement else { return nil }
        let em = max(2, element.relativeSize * document.canvasSize.height)
        return PSSize(width: min(Double(max(1, element.text.count)) * 0.55 * em, element.maxRelativeWidth * document.canvasSize.width), height: em * 1.25)
    }

    /// The W3 probes from document facts: merges, stamps, via copy/cut and an applied mask keep the composite; a new or
    /// edited fill, gradient or non-neutral adjustment layer changes it; a layer mask covers what its stack covers.
    func layerProbe(_ request: PixelProbeRequest, before: PhotoDocument, after: PhotoDocument) -> PixelProbeResult? {
        let probe = request.probe
        if probe == .compositeUnchanged {
            let stats = global(Self.base, document: before)
            let regions = PixelStats.Regions(inside: stats, outside: stats, coverage: 1)
            return PixelProbeResult(request: request, before: regions, after: regions)
        }
        if probe == .compositeChanged {
            let stats = global(Self.base, document: before)
            var changed = stats
            let old = Dictionary(before.layers.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            for layer in after.layers where layer.isVisible && (old[layer.id] == nil || old[layer.id] != layer) {
                switch layer.content {
                case .fill(let color):
                    let lab = MaskMath.lab(color)
                    changed.meanL += (lab.l - stats.meanL) * 0.5 * layer.opacity
                    changed.meanA += (lab.a - stats.meanA) * 0.5 * layer.opacity
                    changed.meanB += (lab.b - stats.meanB) * 0.5 * layer.opacity
                case .gradientFill(let gradient):
                    for t in [0.0, 0.5, 1.0] {
                        let colour = gradient.color(at: t)
                        let lab = MaskMath.lab(colour), weight = 0.15 * colour.alpha * layer.opacity
                        changed.meanL += (lab.l - stats.meanL) * weight
                        changed.meanA += (lab.a - stats.meanA) * weight
                        changed.meanB += (lab.b - stats.meanB) * weight
                    }
                case .adjustment(let dials):
                    let recipe = layer.edits.operations.count
                    changed.meanL += 30 * (dials[.exposure] + dials[.brightness]) * layer.opacity + Double(min(recipe, 1)) * 2
                    changed.stdL += 15 * dials[.contrast] * layer.opacity
                    changed.meanChroma += 25 * (dials[.saturation] + dials[.vibrance]) * layer.opacity
                    changed.meanB += 25 * dials[.temperature] * layer.opacity
                    changed.meanA += 25 * dials[.tint] * layer.opacity
                case .image, .text, .shape, .group, .unsupported:
                    changed.meanL += 1
                }
            }
            return PixelProbeResult(request: request, before: PixelStats.Regions(inside: stats, outside: stats, coverage: 1),
                                    after: PixelStats.Regions(inside: changed, outside: changed, coverage: 1))
        }
        if probe == .layerMaskCoverageInRange {
            let old = Dictionary(before.layers.map { ($0.id, $0.maskStack) }, uniquingKeysWith: { first, _ in first })
            let touched = after.layers.filter { layer in layer.maskStack != nil && (old[layer.id] == nil || old[layer.id]! != layer.maskStack) }
            guard let layer = touched.first(where: { $0.id == after.selectedLayerID }) ?? touched.last, let stack = layer.maskStack else {
                return PixelProbeResult(request: request, before: nil, after: nil)
            }
            let stats = global(Self.base, document: after)
            let previous = old[layer.id].flatMap { $0 }.map { coverage(of: $0) }
            return PixelProbeResult(request: request, before: previous.map { PixelStats.Regions(inside: stats, outside: stats, coverage: $0) },
                                    after: PixelStats.Regions(inside: stats, outside: stats, coverage: coverage(of: stack)))
        }
        return nil
    }

    // MARK: Pixel probes

    /// The probe proxy's pixel count (256 × 256).
    static let pixels = 65_536.0
    /// The picture's statistics before any edit, inside a mask and outside it.
    static let base = PixelStats(meanL: 50, stdL: 18, meanChroma: 20, meanA: 4, meanB: 12, weight: 1)

    public func pixelProbes(_ requests: [PixelProbeRequest], before: PhotoDocument, after: PhotoDocument) -> [PixelProbeResult] {
        requests.map { request in
            // W3: the composite and layer-mask probes, from document facts (§8.7).
            if let layered = layerProbe(request, before: before, after: after) { return layered }
            let oneMask = request.probe == .maskedParameter || request.probe == .selectionUse
            switch request.region {
            case .localAdjustment(let id):
                // W3: the adjustment on whichever image layer owns it.
                let old = before.allLocalAdjustments.first { $0.adjustment.id == id }?.adjustment
                let new = after.allLocalAdjustments.first { $0.adjustment.id == id }?.adjustment
                let maskBefore = oneMask ? (new ?? old) : old
                let maskAfter = oneMask ? (new ?? old) : new
                return PixelProbeResult(request: request,
                                        before: maskBefore.map { regions(document: before, mask: $0, adjustment: old) },
                                        after: maskAfter.map { regions(document: after, mask: $0, adjustment: new) })
            case .selection:
                let old = before.selection, new = after.selection
                let maskBefore = oneMask ? (new ?? old) : old
                let maskAfter = oneMask ? (new ?? old) : new
                return PixelProbeResult(request: request,
                                        before: maskBefore.map { selectionRegions(document: before, coverage: $0.coverage, edited: nil) },
                                        after: maskAfter.map { selectionRegions(document: after, coverage: $0.coverage, edited: before) })
            case .box, .whole:
                let stats = global(Self.base, document: after)
                return PixelProbeResult(request: request, before: PixelStats.Regions(inside: global(Self.base, document: before), outside: Self.base, coverage: 1),
                                        after: PixelStats.Regions(inside: stats, outside: stats, coverage: 1))
            }
        }
    }

    /// The document's global dials, on any region.
    func global(_ stats: PixelStats, document: PhotoDocument) -> PixelStats {
        var result = stats
        let dials = document.activeAdjustments
        result.meanL += 30 * (dials[.exposure] + dials[.brightness])
        return result
    }

    /// Inside a local adjustment's mask (its dials applied) and outside it (untouched), with the stack's coverage
    /// and softness (feather shrinks the area at m < 0.05).
    func regions(document: PhotoDocument, mask: LocalAdjustment, adjustment: LocalAdjustment?) -> PixelStats.Regions {
        let coverage = coverage(of: mask.stack)
        var inside = global(Self.base, document: document)
        if let adjustment, adjustment.isVisible {
            let dials = adjustment.adjustments, amount = adjustment.amount
            inside.meanL += 30 * amount * (dials[.exposure] + dials[.brightness] + 0.5 * (dials[.shadows] + dials[.highlights]) + 0.4 * (dials[.whites] + dials[.blacks]))
            inside.stdL = max(0, inside.stdL + 15 * amount * (dials[.contrast] + dials[.clarity]))
            inside.meanChroma = max(0, inside.meanChroma + 25 * amount * (dials[.saturation] + dials[.vibrance]))
            inside.meanB += 25 * amount * dials[.temperature]
            inside.meanA += 25 * amount * dials[.tint]
        }
        inside.weight = coverage * Self.pixels
        var outside = global(Self.base, document: document)
        outside.weight = max(0, (1 - coverage - mask.stack.feather * 0.2 * (1 - coverage)) * Self.pixels)
        return PixelStats.Regions(inside: inside, outside: outside, coverage: coverage)
    }

    /// Inside the selection: what the last step painted there (a fill layer, a recolour, a blur).
    func selectionRegions(document: PhotoDocument, coverage: Double, edited: PhotoDocument?) -> PixelStats.Regions {
        var inside = global(Self.base, document: document)
        if let edited {
            let old = Set(edited.layers.flatMap { $0.edits.operations.map(\.id) })
            let added = document.layers.flatMap(\.edits.operations).filter { !old.contains($0.id) }.map(\.kind)
            for kind in added {
                switch kind {
                case .recolor(_, let color, _):
                    let lab = MaskMath.lab(color)
                    inside.meanA = lab.a
                    inside.meanB = lab.b
                case .blurRegion:
                    inside.stdL = max(0, inside.stdL - 6)
                default: break
                }
            }
            let fills = document.layers.filter { layer in !edited.layers.contains { $0.id == layer.id } }.compactMap { layer -> PSColor? in
                if case .fill(let color) = layer.content { return color }
                return nil
            }
            if let fill = fills.last {
                let lab = MaskMath.lab(fill)
                inside.meanL = lab.l
                inside.meanA = lab.a
                inside.meanB = lab.b
            }
        }
        inside.weight = coverage * Self.pixels
        var outside = global(Self.base, document: document)
        outside.weight = (1 - coverage) * Self.pixels
        return PixelStats.Regions(inside: inside, outside: outside, coverage: coverage)
    }
}
