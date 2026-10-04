#if canImport(SwiftUI) && canImport(CoreImage) && canImport(UIKit)
import SwiftUI
import CoreImage
import PicshopCore
import PicshopIntent
import PicshopImaging

// Sélection (W2, M3): one selection per document (D7), undoable, remapped by geometry like the masks.
//
// Every way to select (subject, sky, object by tap or frame, Quick Selection strokes, the Lab wand, the lasso, Color
// Range, « Tout sélectionner ») makes a raster at the working size, which `combineSelection` folds into the current
// selection with the panel's mode (new, add, subtract, intersect). Modify and Select & Mask go through the services
// too. Each change is one history step, labelled with the English key "Selection" (« Sélection »).
// « Utiliser la sélection pour » calls the selectionApply handler (M4), the same path as the voice.
extension PhotoEditorSession {
    static let selectionLabel = "Selection"

    /// « Utiliser la sélection pour »: what `selectionApply` does with the selection.
    enum SelectionUse: Equatable {
        case adjust, mask, erase, cutout
        case fill(PSColor), recolor(PSColor), blur(Double), generate(String)
        /// W3 (D17): « Nouveau calque (copier) » and « Nouveau calque (couper) », the selection's pixels of the active
        /// image layer on a new layer above it.
        case copyToLayer, cutToLayer

        /// The `use` value of selectionApply.
        var use: String {
            switch self {
            case .adjust: return "adjust"
            case .mask: return "mask"
            case .erase: return "erase"
            case .cutout: return "cutout"
            case .copyToLayer: return "copyToLayer"
            case .cutToLayer: return "cutToLayer"
            case .fill: return "fill"
            case .recolor: return "recolor"
            case .blur: return "blur"
            case .generate: return "generate"
            }
        }

        /// The call's arguments.
        var arguments: [String: OpValue] {
            var args: [String: OpValue] = ["use": .string(use)]
            switch self {
            case .fill(let color), .recolor(let color): args["color"] = .string(color.hexString)
            case .blur(let amount): args["amount"] = .number((amount * 100).rounded().clamped(to: 0...100))
            case .generate(let prompt): args["prompt"] = .string(prompt)
            case .adjust, .mask, .erase, .cutout, .copyToLayer, .cutToLayer: break
            }
            return args
        }
    }

    var aiSelectionEnabled: Bool { FeatureFlags.isOn(.aiSelection) }

    /// How the next selection combines: the panel's mode (nil: a new selection).
    var selectionCombine: CombineMode? {
        document.selection == nil ? nil : selectionState.combine
    }

    // MARK: - Opening

    /// Sélection in one mode (Précis's wand and lasso, the lasso effect, a palette or grammar opening).
    func openSelect(mode: PhotoSelectionState.SelectMode) {
        guard aiSelectionEnabled else { return }
        if activeTool != .select { activeTool = .select }
        selectionState.mode = mode
    }

    func selectToolDidOpen() {
        guard aiSelectionEnabled else { return }
        selectionDidChange(document)
    }

    func selectToolDidClose() {
        selectionState.quickPrompts = []
        selectionState.boxDrag = nil
        selectionState.caption = nil
        lassoPoints = []
        if selectionState.colorRange?.target == .selection { selectionState.colorRange = nil }
    }

    /// `openTool:select.*`: the mode its gesture needs.
    func openSelectControl(_ id: String) {
        if id.hasPrefix("select.quick.") || id == "select.mode.quick" {
            openSelect(mode: .quick)
            selectionState.quickErase = id == "select.quick.erase"
        } else if id.hasPrefix("select.lasso.") || id == "select.mode.lasso" {
            openSelect(mode: .lasso)
        } else if id.hasPrefix("select.wand.") || id == "select.mode.wand" {
            openSelect(mode: .wand)
        } else if id.hasPrefix("select.object.") || id == "select.mode.object" {
            openSelect(mode: .object)
        } else if id.hasPrefix("select.colorRange.") || id == "select.mode.colorRange" {
            openSelect(mode: .colorRange)
            openColorRange(for: .selection)
        } else if id.hasPrefix("select.refine") {
            openSelectAndMask()
        } else {
            openSelect(mode: selectionState.mode)
        }
    }

    /// The combine row: an explicit pick stays for the session.
    func setSelectionCombine(_ mode: CombineMode?) {
        selectionState.combine = mode
        selectionState.combinePicked = true
        Haptics.tick()
    }

    // MARK: - Canvas

    /// A tap in Sélection, by mode: subject or sky run at once, object and wand at the point, lasso corners.
    func handleSelectTap(at point: PSPoint) {
        guard aiSelectionEnabled else { return }
        switch selectionState.mode {
        case .subject: select(region: .subject)
        case .sky: select(region: .sky)
        case .object: selectObject(at: point)
        case .wand: wandSelect(at: point)
        case .lasso: lassoPoints.append(point)
        case .quick: break
        case .colorRange:
            openColorRange(for: .selection)
            sampleColorRange(at: point)
        }
    }

    // MARK: - Making selections

    /// A region (subject, sky, people, a parametric region) combined into the selection.
    func select(region: MaskRegion, person: Int? = nil) {
        guard aiSelectionEnabled else { return }
        let mode = selectionCombine
        let step = SelectionStep(Self.selectionSource(for: region), mode: mode, label: Self.label(for: region, person: person) ?? region.rawValue)
        let aspect = maskAspect
        runSelection(step, region: region) { document, services in
            if let request = Self.request(for: region, person: person) {
                let result = try await services.aiMask(request, in: document)
                return (result.raster, result.coverage, result.isApproximate || !result.usedModel && region == .object)
            }
            if region == .near || region == .far {
                let depth = try await services.depthMap(in: document)
                let spec = region == .far ? DepthRangeSpec(depth: depth, low: 0, high: 0.35) : DepthRangeSpec(depth: depth, low: 0.6, high: 1)
                let result = try await services.rasterize(.single(MaskComponent(.depthRange(spec))), in: document)
                return (result.raster, result.coverage, false)
            }
            guard let component = MaskStack.defaultComponent(for: region, aspect: aspect) else { throw PicshopError.objectNotFound(region.rawValue) }
            let result = try await services.rasterize(.single(component), in: document)
            return (result.raster, result.coverage, false)
        }
    }

    /// « Tout sélectionner »: the whole picture, a new selection.
    func selectAll() {
        guard aiSelectionEnabled else { return }
        runSelection(SelectionStep(.all), region: nil, combine: .some(nil)) { document, services in
            // A hard ellipse twice the longest side covers every pixel.
            let everything = MaskComponent(.radial(RadialGradientSpec(center: PSPoint(x: 0.5, y: 0.5), radiusX: 2, radiusY: 2, feather: 0)))
            let result = try await services.rasterize(.single(everything), in: document)
            return (result.raster, result.coverage, false)
        }
    }

    /// Object mode: a tap (SAM point; the Vision fallback without it).
    func selectObject(at point: PSPoint) {
        let mode = selectionCombine
        runSelection(SelectionStep(.object, mode: mode), region: .object) { document, services in
            let result = try await services.aiMask(.points([MaskPrompt(point)], label: nil), in: document)
            return (result.raster, result.coverage, result.isApproximate || !result.usedModel)
        }
    }

    /// Object mode: a frame dragged around it (SAM box; an overlapping instance without it).
    func selectObject(in box: PSRect) {
        guard box.width > 0.01, box.height > 0.01 else { return }
        let mode = selectionCombine
        let rect = box.clampedToUnit()
        runSelection(SelectionStep(.object, mode: mode), region: .object) { document, services in
            let result = try await services.aiMask(.box(rect, label: nil), in: document)
            return (result.raster, result.coverage, result.isApproximate || !result.usedModel)
        }
    }

    /// Quick Selection: one stroke (normalised points, `radius` a fraction of the longest side) adds what it paints
    /// over, or removes it when erasing; SAM point prompts, else the Lab-wand fallback with its caption.
    func quickSelectStroke(points: [PSPoint], radius: Double, erase: Bool) {
        guard aiSelectionEnabled, !points.isEmpty else { return }
        if erase, document.selection == nil { return }
        let mode: CombineMode? = erase ? .subtract : (document.selection == nil ? nil : .add)
        let aspect = maskAspect
        let prompts = SAMPrompting.prompts(along: points, radius: radius, aspect: aspect, erase: erase)
        selectionState.quickPrompts = Array((selectionState.quickPrompts + prompts).suffix(SAMPrompting.maxPrompts))
        runSelection(SelectionStep(.quick, mode: mode), region: .object, combine: .some(mode)) { document, services in
            let result = try await services.quickSelectRegion(along: points, radius: radius, in: document)
            return (result.raster, result.coverage, result.isApproximate || !result.usedModel)
        }
    }

    /// The Lab wand (ΔE76 ≤ 2 + 48 × tolerance, the panel's sample size, contiguous or not) at a point, on the
    /// picture without its local adjustments.
    func wandSelect(at point: PSPoint) {
        guard aiSelectionEnabled, let renderer else { return }
        let tolerance = wandTolerance, contiguous = wandContiguous, sampleSize = selectionState.wandSampleSize
        let maskStore = MaskStore(store: app.store, projectID: projectID)
        let key = lookThumbnailKey
        let cached = selectionState.wandCache?.key == key ? selectionState.wandCache?.analysis : nil
        let stateKey = document.baseStateKey
        runSelection(SelectionStep(.wand, mode: selectionCombine), region: nil) { [weak self] document, _ in
            let analysis: VisionGrounding.WandAnalysis
            if let cached {
                analysis = cached
            } else {
                let options = PhotoRenderer.Options(targetLongestSide: Double(PhotoSelection.workingLongestSide), includeOverlays: false,
                                                    allowExpensiveWork: false, includesLocalAdjustments: false)
                let image = try await renderer.renderBase(document, options: options)
                guard let read = await Task.detached(priority: .userInitiated, operation: { () -> VisionGrounding.WandAnalysis? in
                    ImageSupport.cgImage(from: image).map(VisionGrounding.wandAnalysis(of:))
                }).value else { throw PicshopError.renderFailed("wand") }
                analysis = read
                self?.selectionState.wandCache = (key, read)
            }
            return try await Task.detached(priority: .userInitiated) { () -> (RasterRef, Double, Bool) in
                let bytes = PicshopImaging.Selection.magicWandLab(rgba: analysis.rgba, width: analysis.width, height: analysis.height, seed: (point.x, point.y),
                                                   tolerance: tolerance, contiguous: contiguous, sampleSize: sampleSize, antiAlias: true)
                let cleaned = PicshopImaging.Selection.despeckled(bytes, width: analysis.width, height: analysis.height,
                                                   minimumPixels: max(4, analysis.width * analysis.height / 20000))
                let raster = try maskStore.saveRaster(bytes: cleaned, width: analysis.width, height: analysis.height, origin: .selection,
                                                      stateKey: stateKey)
                return (raster, MaskStore.coverage(of: cleaned), false)
            }.value
        }
    }

    /// The lasso (a drawn outline or tapped corners), at the working size.
    func lassoSelect(points: [PSPoint]) {
        guard aiSelectionEnabled, points.count >= 3 else { return }
        lassoPoints = []
        let aspect = maskAspect
        let side = Double(PhotoSelection.workingLongestSide)
        let size = aspect >= 1 ? PSSize(width: side, height: (side / aspect).rounded()) : PSSize(width: (side * aspect).rounded(), height: side)
        let maskStore = MaskStore(store: app.store, projectID: projectID)
        runSelection(SelectionStep(.lasso, mode: selectionCombine), region: nil) { _, _ in
            try await Task.detached(priority: .userInitiated) { () -> (RasterRef, Double, Bool) in
                let result = try VisionGrounding.lassoSelection(imageSize: size, points: points, maskStore: maskStore)
                let raster = RasterRef(path: result.reference.relativePath, origin: .selection, pixelWidth: result.width, pixelHeight: result.height,
                                       boundingBox: result.reference.boundingBox)
                return (raster, MaskStore.coverage(of: result.bytes), false)
            }.value
        }
    }

    /// Color Range (or a tonal band) as a selection.
    func colorRangeSelect(_ kind: MaskComponent.Kind) {
        guard aiSelectionEnabled else { return }
        let source: SelectionStep.Source
        if case .luminanceRange = kind { source = .luminanceRange } else { source = .colorRange }
        runSelection(SelectionStep(source, mode: selectionCombine), region: .color) { document, services in
            let result = try await services.rasterize(.single(MaskComponent(kind)), in: document)
            return (result.raster, result.coverage, false)
        }
    }

    /// Makes a raster, combines it into the selection (its mode, or `combine` when given) and commits one step.
    /// A raster that covers under 0.2 % changes nothing and says so.
    private func runSelection(_ step: SelectionStep, region: MaskRegion?, combine: CombineMode?? = nil,
                              make: @escaping @MainActor (PhotoDocument, VisionPhotoServices) async throws -> (RasterRef, Double, Bool)) {
        guard let services else { return }
        selectionState.task?.cancel()
        selectionState.isWorking = true
        selectionState.caption = nil
        let document = self.document
        let mode: CombineMode? = combine ?? step.mode
        selectionState.task = Task { [weak self] in
            do {
                let (raster, coverage, approximate) = try await make(document, services)
                guard let self, !Task.isCancelled else { return }
                guard coverage >= 0.002 else {
                    self.selectionState.isWorking = false
                    if mode == .subtract {
                        self.showToast(L("Nothing to remove there."))
                    } else {
                        self.tellMaskProblem(region.map { Self.notFoundMessage($0) } ?? L("Nothing to select there."))
                    }
                    return
                }
                let current = self.document
                let combined = try await services.combineSelection(current.selection, with: raster, mode: mode, in: current)
                guard !Task.isCancelled else { return }
                self.selectionState.isWorking = false
                var made = step
                made.mode = mode
                self.commitSelection(combined, appending: made)
                if approximate { self.selectionState.caption = L("Approximate selection (model not installed)") }
            } catch is CancellationError {
                self?.selectionState.isWorking = false
            } catch {
                guard let self else { return }
                self.selectionState.isWorking = false
                if case PicshopError.modelUnavailable(let id) = error {
                    self.maskState.modelOffer = id
                    self.selectionState.caption = L("Approximate selection (model not installed)")
                    return
                }
                self.handleMaskError(error, region: region ?? .selection)
            }
        }
    }

    /// One selection step: the new step appended (the last 12 kept), one undo step, the ants follow.
    func commitSelection(_ selection: PhotoSelection?, appending step: SelectionStep?) {
        var next = selection
        if var made = next, let step {
            made.steps = Array((made.steps + [step]).suffix(PhotoSelection.maxSteps))
            next = made
        }
        var updated = document
        updated.setSelection(next)
        guard updated.selection != document.selection else { return }
        commit(updated, label: Self.selectionLabel)
        // After the first selection the panel adds, unless the person picked a mode.
        if next != nil, !selectionState.combinePicked, selectionState.combine == nil { selectionState.combine = .add }
        Haptics.confirm()
    }

    // MARK: - Modify

    func invertSelection() {
        modifySelection(.invert)
    }

    /// Invert, grow, shrink, feather, smooth: pixels at full resolution, smoothness 0…1.
    func modifySelection(_ change: SelectionChange) {
        guard aiSelectionEnabled, let services, let selection = document.selection else { return }
        let document = self.document
        let step: SelectionStep
        if case .invert = change { step = SelectionStep(.invert) } else { step = SelectionStep(.modify) }
        selectionState.isWorking = true
        selectionState.task?.cancel()
        selectionState.task = Task { [weak self] in
            do {
                let modified = try await services.modifySelection(selection, change, in: document)
                guard let self, !Task.isCancelled else { return }
                self.selectionState.isWorking = false
                guard self.document.selection == selection else { return }
                self.commitSelection(modified, appending: step)
            } catch {
                guard let self else { return }
                self.selectionState.isWorking = false
                if !(error is CancellationError) { self.handleMaskError(error, region: .selection) }
            }
        }
    }

    /// The value sheet of « Étendre… », « Contracter… », « Contour progressif… », « Lisser… » was confirmed.
    func applyModify(_ request: PhotoSelectionState.ModifyRequest) {
        selectionState.modify = nil
        switch request.kind {
        case .grow: modifySelection(.grow(pixels: request.value))
        case .shrink: modifySelection(.shrink(pixels: request.value))
        case .feather: modifySelection(.feather(pixels: request.value))
        case .smooth: modifySelection(.smooth((request.value / 100).clamped(to: 0...1)))
        }
    }

    /// Désélectionner (one step).
    func deselect() {
        guard document.selection != nil else { return }
        selectionState.quickPrompts = []
        commitSelection(nil, appending: nil)
    }

    // MARK: - Use

    /// « Utiliser la sélection pour »: the selectionApply handler, exactly what the voice runs.
    func useSelection(for use: SelectionUse) {
        guard document.selection != nil else { return }
        if case .generate = use, !hasGenerativeEngine {
            showToast(L("Install Generative Fill in Settings › On-device models to use prompts."), isError: true)
            return
        }
        Haptics.confirm()
        perform(EditIntent(action: .operation, operation: OperationCall("selectionApply", args: use.arguments, source: .ui)))
    }

    // MARK: - Select & Mask

    func openSelectAndMask() {
        guard let selection = document.selection else { return }
        if activeTool != .select { activeTool = .select }
        selectionState.refine = RefineEditing(refinement: selection.refinement ?? SelectionRefinement())
        requestPreview()
    }

    /// A slider or a view mode changed: the live preview follows (lazy GPU, interactive while dragging).
    func updateRefine(_ change: (inout RefineEditing) -> Void, interactive: Bool = false) {
        guard var refine = selectionState.refine else { return }
        change(&refine)
        guard refine != selectionState.refine else { return }
        selectionState.refine = refine
        requestPreview(interactive: interactive)
    }

    /// OK: the refined selection (one step), or a local mask made of it.
    func applySelectAndMask() {
        guard let refine = selectionState.refine, let services, let selection = document.selection else { return }
        selectionState.refine = nil
        let document = self.document
        selectionState.isWorking = true
        selectionState.task?.cancel()
        selectionState.task = Task { [weak self] in
            do {
                let refined = try await services.refineSelection(selection, refine.refinement, in: document)
                guard let self, !Task.isCancelled else { return }
                self.selectionState.isWorking = false
                guard self.document.selection == selection else { return }
                var withRefinement = refined
                withRefinement.refinement = refine.refinement
                self.commitSelection(withRefinement, appending: SelectionStep(.refine))
                if refine.output == .mask { self.useSelection(for: .mask) }
            } catch {
                guard let self else { return }
                self.selectionState.isWorking = false
                self.requestPreview()
                if !(error is CancellationError) { self.handleMaskError(error, region: .selection) }
            }
        }
    }

    func closeSelectAndMask() {
        selectionState.refine = nil
        requestPreview()
    }

    // MARK: - Color Range (selections and masks)

    /// Opens ColorRangeSheet for a selection, a new mask, a new component or an existing colour range component.
    func openColorRange(for target: ColorRangeEditing.Target, spec: ColorRangeSpec? = nil) {
        var editing = ColorRangeEditing(target: target, output: target == .selection ? .selection : .mask)
        if let spec {
            editing.samples = spec.samples
            editing.fuzziness = max(ColorRangeEditing.minimumFuzziness, spec.fuzziness)
            editing.preset = spec.preset.flatMap { ColorRangeEditing.Preset(rawValue: $0.rawValue) }
        }
        if selectionState.colorRange?.target != target { selectionState.colorRange = editing }
        requestPreview()
    }

    func updateColorRange(_ change: (inout ColorRangeEditing) -> Void, interactive: Bool = false) {
        guard var editing = selectionState.colorRange else { return }
        change(&editing)
        editing.fuzziness = editing.fuzziness.clamped(to: ColorRangeEditing.minimumFuzziness...1)
        guard editing != selectionState.colorRange else { return }
        selectionState.colorRange = editing
        requestPreview(interactive: interactive)
    }

    /// The sheet's eyedropper on the canvas: adds the tapped colour (a 5 × 5 average of the picture without its
    /// local adjustments), or removes the sample closest to it.
    func sampleColorRange(at point: PSPoint) {
        guard let services, selectionState.colorRange != nil else { return }
        let document = self.document
        Task { [weak self] in
            let lab = (try? await services.sampleColors(at: [point], radius: 2, in: document))?.first
            guard let self else { return }
            guard let lab else {
                self.tellMaskProblem(L("That colour couldn't be read."))
                return
            }
            self.updateColorRange { editing in
                // A colour picked replaces a preset that is a tonal band.
                if editing.preset?.luminance != nil { editing.preset = nil }
                if editing.addsSamples {
                    editing.samples = Array((editing.samples + [lab]).suffix(ColorRangeEditing.maxSamples))
                } else if let nearest = editing.samples.indices.min(by: { Self.labDistance(editing.samples[$0], lab) < Self.labDistance(editing.samples[$1], lab) }) {
                    editing.samples.remove(at: nearest)
                }
            }
            Haptics.tick()
        }
    }

    /// OK: a selection (combined with the panel's mode), a new local mask, a new component, or the edited component.
    func applyColorRange() {
        guard let editing = selectionState.colorRange else { return }
        selectionState.colorRange = nil
        requestPreview()
        guard let kind = editing.component else { return }
        switch editing.output {
        case .selection:
            colorRangeSelect(kind)
        case .mask:
            switch editing.target {
            case .component(let adjustmentID, let componentID):
                editMask(.setComponentKind(componentID, kind), on: adjustmentID)
                flashMask(adjustmentID)
            case .addToMask(let adjustmentID, let mode):
                editMask(.addComponent(MaskComponent(kind, mode: mode)), on: adjustmentID)
                flashMask(adjustmentID)
            case .newMask, .selection:
                let region: MaskRegion
                switch editing.preset {
                case .skinTones?: region = .skinTones
                case .shadows?: region = .shadows
                case .midtones?: region = .midtones
                case .highlights?: region = .highlights
                default: region = .color
                }
                if activeTool != .masks { activeTool = .masks }
                createMask(LocalAdjustment(region: region, stack: .single(MaskComponent(kind))), editing: nil)
            }
        }
        Haptics.confirm()
    }

    func closeColorRange() {
        selectionState.colorRange = nil
        requestPreview()
    }

    // MARK: - The ants, and the selection for the legacy executors

    /// After every document change: the ants' outline follows the selection (traced off the main thread, through
    /// its corners), and a baked copy for another selection is dropped.
    func selectionDidChange(_ document: PhotoDocument) {
        guard aiSelectionEnabled, let selection = document.selection else {
            if !selectionState.contour.isEmpty {
                selectionState.contour = []
                selectionState.contourPath = Path()
            }
            selectionState.contourKey = nil
            bakedSelection = nil
            return
        }
        if let baked = bakedSelection, baked.selection != selection { bakedSelection = nil }
        let raster = selection.raster
        let key = raster.path + "|" + raster.corners.map { "\($0.x),\($0.y)" }.joined(separator: ";")
        guard selectionState.contourKey != key else { return }
        selectionState.contourKey = key
        let maskStore = MaskStore(store: app.store, projectID: projectID)
        let budget = PhotoSelectionState.contourPointBudget
        selectionState.contourTask?.cancel()
        selectionState.contourTask = Task { [weak self] in
            let paths = await Task.detached(priority: .userInitiated) { () -> [[PSPoint]] in
                guard let raw = maskStore.rawBytes(raster) else { return [] }
                let gray = GrayRaster(width: raw.width, height: raw.height, bytes: raw.bytes)
                // Bounded: the ants restroke this every frame, on the main thread (specks under 3 px go, ≤ 6,000 points).
                let traced = SelectionContour.paths(gray, minimumExtent: 3, maximumPoints: budget)
                let normalized = SelectionContour.normalized(traced, width: raw.width, height: raw.height)
                guard raster.corners != RasterRef.unitCorners, let map = PSHomography.quad(from: RasterRef.unitCorners, to: raster.corners) else {
                    return normalized
                }
                return normalized.map { path in path.map { map.apply($0) } }
            }.value
            guard let self, !Task.isCancelled, self.selectionState.contourKey == key else { return }
            self.selectionState.contour = paths
            // Built once per outline in unit space; the overlay only scales it to the canvas frame.
            self.selectionState.contourPath = SelectionAntsOverlay.path(paths, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
    }

    /// Before a command runs: a selection a crop or a turn moved is baked into an aligned raster for the executors
    /// that take a mask (D7). The document keeps the corners form.
    func prepareCommandSelection() async {
        guard aiSelectionEnabled, let services, let selection = document.selection, !selection.isAligned else { return }
        if let baked = bakedSelection, baked.selection == selection { return }
        let document = self.document
        guard let result = try? await services.rasterize(.single(MaskComponent(.raster(selection.raster))), in: document) else { return }
        guard self.document.selection == selection else { return }
        bakedSelection = (selection, result.raster.maskReference)
    }

    /// ΔE76 between two Lab colours.
    static func labDistance(_ a: LabColor, _ b: LabColor) -> Double {
        let dl = a.l - b.l, da = a.a - b.a, db = a.b - b.b
        return (dl * dl + da * da + db * db).squareRoot()
    }

    /// How the selection was made, as a step source.
    static func selectionSource(for region: MaskRegion) -> SelectionStep.Source {
        switch region {
        case .subject: return .subject
        case .background: return .background
        case .sky: return .sky
        case .people: return .people
        case .person: return .person
        case .face, .faceSkin, .eyes, .lips, .teeth, .hair, .bodySkin: return .facePart
        case .object: return .object
        case .color, .skinTones: return .colorRange
        case .shadows, .midtones, .highlights: return .luminanceRange
        case .selection: return .mask
        default: return .region
        }
    }
}
#endif
