#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import CoreImage
import PicshopCore
import PicshopIntent
import PicshopImaging

/// The open tool's panel: the controls inside a ToolPanel, with the
/// category's other panels as segments, the tool's own action in the header
/// (Annuler for Recadrer, Appliquer for painted strokes) and Done.
struct PhotoToolPanel: View {
    @Bindable var session: PhotoEditorSession
    let tool: PhotoEditorSession.Tool

    var body: some View {
        let siblings = PhotoToolCatalog.siblings(of: tool)
        ToolPanel(title: siblings.count > 1 ? PhotoToolCatalog.categoryTitle(of: tool) : PhotoToolCatalog.title(for: tool),
                  live: session.live, onDone: done) {
            accessory
        } content: {
            VStack(spacing: 12) {
                if siblings.count > 1 {
                    ModeSegments(modes: siblings, selection: $session.activeTool,
                                 title: { PhotoToolCatalog.title(for: $0) }, symbol: { PhotoToolCatalog.symbol(for: $0) })
                }
                PhotoToolContent(session: session, tool: tool)
            }
        }
    }

    @ViewBuilder
    private var accessory: some View {
        switch tool {
        case .crop:
            PanelChip(title: L("Cancel")) {
                session.cancelCrop()
                session.activeTool = nil
            }
        case .erase:
            if !session.brushStrokes.isEmpty {
                PanelActionButton(title: L("Apply"), symbol: "eraser") { session.commitBrushErase() }
                    .accessibilityLabel(L("Erase painted area"))
            }
        default:
            EmptyView()
        }
    }

    /// Done keeps the work: the crop is committed, painted strokes are erased on the way out.
    private func done() {
        if tool == .crop { session.commitCrop() }
        session.activeTool = nil
    }
}

/// The controls of one tool, built only when its panel is open.
private struct PhotoToolContent: View {
    @Bindable var session: PhotoEditorSession
    let tool: PhotoEditorSession.Tool

    var body: some View {
        switch tool {
        case .magic: MagicPanel(session: session)
        case .focus: FocusPanel(session: session)
        case .adjust: AdjustPanel(session: session)
        case .color:
            ColorControls(mixer: session.colorMixer, grade: session.colorGrade,
                          onMixer: { session.setColorMixer($0) }, onGrade: { session.setColorGrade($0) },
                          onBegin: { session.beginColorInteraction($0) }, onEnd: { session.endColorInteraction() },
                          lut: session.lut, onImportLUT: { session.importLUT(from: $0) },
                          onLUTIntensity: { session.setLUTIntensity($0) }, onRemoveLUT: { session.removeLUT() })
        case .looks: LooksPanel(session: session)
        case .erase: ErasePanel(session: session)
        case .precise: PrecisePanel(session: session)
        case .cutout: CutoutPanel(session: session)
        case .crop: CropPanel(session: session)
        case .text: TextPanel(session: session)
        case .shapes: ShapesPanel(session: session)
        case .layers: LayersPanel(session: session)
        }
    }
}

/// The action that finishes a panel's work (Apply, Erase): a white capsule
/// with a black label, flat because it sits on the panel's glass.
struct PanelActionButton: View {
    let title: String
    var symbol: String? = nil
    let action: () -> Void

    var body: some View {
        PSPanelPrimaryButton(title, systemImage: symbol, height: 36, action: action)
            .transition(.opacity.combined(with: .scale(scale: 0.9)))
    }
}

private func localizedName(_ parameter: AdjustmentParameter) -> String {
    Locale.current.language.languageCode?.identifier == "fr" ? parameter.frenchName : parameter.englishName
}

private func localizedName(_ preset: FilterPreset) -> String {
    Locale.current.language.languageCode?.identifier == "fr" ? preset.frenchName : preset.englishName
}

extension PhotoEditorSession {
    func perform(_ intent: EditIntent) {
        Task { await run(intent) }
    }
}

// MARK: - Adjust

// MARK: - Looks

struct LooksPanel: View {
    @Bindable var session: PhotoEditorSession
    @State private var thumbnails: [FilterPreset: UIImage] = [:]
    @State private var intensity: Double = 1
    /// The looks Vision's aesthetics model rates best for this photo.
    @State private var suggested: [FilterPreset] = []

    var body: some View {
        VStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(FilterPreset.gallery) { preset in
                        let active = (session.document.baseLayer?.edits.resolvedLook?.preset ?? .original) == preset
                        Button {
                            Haptics.tick()
                            withAnimation(PSMotion.standard) { session.applyLook(preset, intensity: intensity) }
                        } label: {
                            VStack(spacing: 6) {
                                let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
                                ZStack {
                                    if let image = thumbnails[preset] {
                                        Image(uiImage: image).resizable().scaledToFill()
                                            .transition(.opacity)
                                    } else {
                                        PSTheme.surfaceElevated
                                        ProgressView().tint(PSTheme.textTertiary).controlSize(.mini)
                                    }
                                }
                                .frame(width: 68, height: 68)
                                .clipShape(shape)
                                .overlay {
                                    if active {
                                        shape.strokeBorder(PSTheme.accent, lineWidth: 2)
                                            .transition(.opacity)
                                    }
                                }
                                .overlay(alignment: .topLeading) {
                                    if suggested.contains(preset) {
                                        MagicGlyph(size: 10)
                                            .padding(4)
                                            .background(Circle().fill(Color.black.opacity(0.55)))
                                            .padding(4)
                                            .transition(.scale.combined(with: .opacity))
                                    }
                                }
                                Text(localizedName(preset)).font(.caption2.weight(active ? .semibold : .medium))
                                    .foregroundStyle(active ? PSTheme.textPrimary : PSTheme.textSecondary).lineLimit(1)
                            }
                            .frame(width: 72)
                            .animation(PSMotion.quick, value: active)
                        }
                        .buttonStyle(PSPressStyle())
                    }
                }
                .padding(.horizontal, 2)
            }
            if let best = suggested.first, session.document.baseLayer?.edits.resolvedLook == nil {
                Button {
                    Haptics.magic()
                    withAnimation(PSMotion.standard) { session.applyLook(best, intensity: intensity) }
                } label: {
                    Label(String(format: L("Best for this photo: %@"), localizedName(best)), systemImage: "sparkles")
                        .font(PSFont.headline(13))
                }
                .buttonStyle(MagicButtonStyle(compact: true))
                .transition(.opacity)
            }
            if session.document.baseLayer?.edits.resolvedLook != nil {
                LookIntensityDial(session: session, intensity: $intensity)
            }
        }
        .task {
            await renderThumbnails()
            await rankThumbnails()
        }
        .animation(PSMotion.standard, value: suggested)
    }

    /// Asks Vision which looks make this photo most beautiful; the top three get a sparkle.
    private func rankThumbnails() async {
        let candidates = FilterPreset.gallery.filter { $0 != .original && thumbnails[$0] != nil }
        let images = candidates.compactMap { thumbnails[$0]?.cgImage }
        guard images.count == candidates.count, !images.isEmpty else { return }
        let scores = await AestheticsRanker.scores(for: images)
        let ranked = zip(candidates, scores).compactMap { preset, score in score.map { (preset, $0) } }.sorted { $0.1 > $1.1 }
        suggested = Array(ranked.prefix(3).map(\.0))
    }

    /// Thumbnails are rendered once per photo state and kept on the session, so
    /// reopening the panel costs nothing and a hot phone renders them smaller.
    /// All twenty looks are laid out on one contact sheet, rendered once off
    /// the main thread and cut into tiles; the panel is updated once.
    private func renderThumbnails() async {
        if let cached = session.lookThumbnails, cached.key == session.lookThumbnailKey {
            thumbnails = cached.images
            return
        }
        let side = session.app.performance.thumbnailSide
        guard let renderer = session.renderer, let base = try? await renderer.renderBase(session.document, options: PhotoRenderer.Options(targetLongestSide: side, allowExpensiveWork: false)) else { return }
        let key = session.lookThumbnailKey
        let presets = FilterPreset.gallery
        let tiles = await Task.detached(priority: .userInitiated) { () -> [FilterPreset: CGImage] in
            LookContactSheet.render(presets, from: base)
        }.value
        guard !Task.isCancelled, !tiles.isEmpty else { return }
        var rendered: [FilterPreset: UIImage] = [:]
        for (preset, image) in tiles { rendered[preset] = UIImage(cgImage: image) }
        withAnimation(PSMotion.quick) { thumbnails = rendered }
        session.lookThumbnails = (key, rendered)
    }
}

/// The looks' intensity dial, in a leaf that owns the dragged value.
private struct LookIntensityDial: View {
    let session: PhotoEditorSession
    @Binding var intensity: Double

    var body: some View {
        DialSlider(value: $intensity, range: 0...1, neutral: 1, label: L("Intensity"), format: { "\(Int(($0 * 100).rounded()))%" }) { editing in
            if editing { session.beginSliderInteraction(.saturation) } else { session.endSliderInteraction() }
        }
        .onChange(of: intensity) { _, newValue in session.setLookIntensity(newValue) }
    }
}

/// Every look applied to one small render, laid out as a grid and rendered
/// in a single Core Image pass, then cropped into one image per look.
enum LookContactSheet {
    static let columns = 5

    static func render(_ presets: [FilterPreset], from base: CIImage) -> [FilterPreset: CGImage] {
        let extent = base.extent.integral
        guard extent.width >= 1, extent.height >= 1, !presets.isEmpty else { return [:] }
        let tileWidth = extent.width, tileHeight = extent.height
        let rows = (presets.count + columns - 1) / columns
        let sheetRect = CGRect(x: 0, y: 0, width: CGFloat(columns) * tileWidth, height: CGFloat(rows) * tileHeight)
        var sheet = CIImage.empty()
        for (index, preset) in presets.enumerated() {
            let adjusted = AdjustmentPipeline.apply(preset.recipe, toneCurve: preset.toneCurve, to: base, scale: 0.05).cropped(to: extent)
            let column = CGFloat(index % columns), row = CGFloat(index / columns)
            let placed = adjusted.transformed(by: CGAffineTransform(translationX: column * tileWidth - extent.minX, y: row * tileHeight - extent.minY))
            sheet = placed.composited(over: sheet)
        }
        guard let rendered = ImageSupport.cgImage(from: sheet, rect: sheetRect) else { return [:] }
        var tiles: [FilterPreset: CGImage] = [:]
        for (index, preset) in presets.enumerated() {
            // Core Image counts rows from the bottom, the bitmap from the top.
            let column = CGFloat(index % columns), row = CGFloat(index / columns)
            let crop = CGRect(x: column * tileWidth, y: sheetRect.height - (row + 1) * tileHeight, width: tileWidth, height: tileHeight)
            if let tile = rendered.cropping(to: crop) { tiles[preset] = tile }
        }
        return tiles
    }
}

// MARK: - Erase

struct ErasePanel: View {
    @Bindable var session: PhotoEditorSession

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // One row: the categories, then what was found in this photo.
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    if !session.brushStrokes.isEmpty {
                        PanelChip(title: L("Clear strokes"), symbol: "xmark", tint: PSTheme.danger) { withAnimation(PSMotion.quick) { session.brushStrokes = [] } }
                            .transition(.opacity)
                    }
                    EraseTargetChip(title: L("People"), symbol: "person.2") { session.eraseAll(label: "person", phrase: L("people")) }
                    EraseTargetChip(title: L("Text & logos"), symbol: "textformat") { session.eraseAll(label: "text", phrase: L("text")) }
                    EraseTargetChip(title: L("Animals"), symbol: "pawprint") { session.eraseAll(label: "animal", phrase: L("animals")) }
                    EraseTargetChip(title: L("Vehicles"), symbol: "car") { session.eraseAll(label: "car", phrase: L("vehicles")) }
                    if session.isFindingObjects && session.sceneObjects.isEmpty {
                        ProgressView().controlSize(.small).tint(PSTheme.textTertiary)
                            .frame(width: 34, height: 34)
                            .accessibilityLabel(L("Looking for objects…"))
                            .transition(.opacity)
                    } else if !session.sceneObjects.isEmpty {
                        Capsule().fill(Color.white.opacity(0.14)).frame(width: 1, height: 20)
                            .accessibilityHidden(true)
                        ForEach(session.sceneObjects) { candidate in
                            SceneObjectChip(candidate: candidate, thumbnail: { await session.candidateThumbnail($0) }) {
                                session.erase(candidate)
                            }
                            .transition(.opacity)
                        }
                    }
                }
                .padding(.horizontal, 2)
            }
            .animation(PSMotion.standard, value: session.brushStrokes.isEmpty)
            DialSlider(value: $session.brushRadius, range: 0.006...0.09, neutral: 0.03, label: L("Brush size"), format: { "\(Int(($0 * 1000).rounded()))" }) { editing in
                session.showsBrushPreview = editing
            }
        }
        .animation(PSMotion.standard, value: session.sceneObjects.map(\.id))
        .task(id: session.lookThumbnailKey) { await session.loadSceneObjects() }
    }
}

/// A found object as a chip: its picture in a small disc, its name, one tap
/// to erase it.
struct SceneObjectChip: View {
    let candidate: ObjectCandidate
    let thumbnail: (ObjectCandidate) async -> UIImage?
    let action: () -> Void
    @State private var image: UIImage?

    var body: some View {
        Button { Haptics.confirm(); action() } label: {
            HStack(spacing: 8) {
                ZStack {
                    if let image {
                        Image(uiImage: image).resizable().scaledToFill()
                    } else {
                        Color.white.opacity(0.08)
                    }
                }
                .frame(width: 26, height: 26)
                .clipShape(Circle())
                Text(candidate.label.capitalized).font(.subheadline).foregroundStyle(PSTheme.textPrimary).lineLimit(1)
            }
            .padding(.leading, 4).padding(.trailing, 14)
            .frame(minHeight: PanelChipStyle.height)
            .background(Capsule().fill(PanelChipStyle.fill))
            .contentShape(Capsule())
        }
        .buttonStyle(PSPressStyle(scale: 0.97))
        .task(id: candidate.id) { image = await thumbnail(candidate) }
        .accessibilityLabel(String(format: L("Erase %@"), candidate.label))
    }
}

/// One-tap erase category: a monochrome glyph and a label in a panel chip.
struct EraseTargetChip: View {
    let title: String
    let symbol: String
    let action: () -> Void

    var body: some View {
        PanelChip(title: title, symbol: symbol, action: action)
            .accessibilityLabel(title)
    }
}

// MARK: - Precise

struct PrecisePanel: View {
    @Bindable var session: PhotoEditorSession
    private let colors: [PSColor] = [.white, .black, .red, .orange, .yellow, .green, .teal, .blue, .purple, .pink, .gray, .brown]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(PhotoEditorSession.PreciseMode.allCases) { mode in
                        IconChip(title: mode.title, symbol: mode.symbol, isActive: session.preciseMode == mode, tint: mode == .generate ? PSTheme.voice : nil) {
                            session.commitBrushErase()
                            session.brushStrokes = []
                            session.preciseMode = mode
                        }
                    }
                }
                .padding(.horizontal, 2)
            }
            switch session.preciseMode {
            case .wand:
                DialSlider(value: $session.wandTolerance, range: 0.02...0.8, neutral: 0.25, label: L("Tolerance"), format: { "\(Int(($0 * 100).rounded()))" })
                HStack {
                    Toggle(L("Contiguous"), isOn: $session.wandContiguous).font(PSFont.caption(13)).fixedSize()
                    Spacer()
                    selectionActions
                }
            case .lasso:
                HStack {
                    Text(L("Draw around the area, or tap corner by corner.")).font(PSFont.caption(12)).foregroundStyle(PSTheme.textSecondary)
                    Spacer()
                    if session.lassoPoints.count >= 3 {
                        PanelChip(title: L("Close"), symbol: "checkmark", tint: PSTheme.accent) { session.commitLasso() }
                    }
                    selectionActions
                }
            case .generate:
                HStack(spacing: 8) {
                    TextField(L("Describe what to generate…"), text: $session.generativePrompt)
                        .textFieldStyle(.plain).font(PSFont.body(15)).foregroundStyle(PSTheme.textPrimary)
                        .padding(.horizontal, 14).frame(minHeight: 36).psField(Capsule())
                        .submitLabel(.go).onSubmit { session.generateInSelection(session.generativePrompt) }
                    Button { session.generateInSelection(session.generativePrompt) } label: { Image(systemName: "sparkles").font(.system(size: 15, weight: .medium)).frame(width: 36, height: 36) }
                        .buttonStyle(.plain).foregroundStyle(PSTheme.onPrimary).background(Circle().fill(PSTheme.primary))
                        .disabled(session.generativePrompt.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                HStack {
                    Text(!session.hasGenerativeEngine ? L("Generative Fill model not installed — see Settings.") : (session.selectionMask == nil ? L("Select an area first (wand, lasso or tap), then describe the change.") : L("Selection ready. Say or type what should appear there.")))
                        .font(PSFont.caption(11)).foregroundStyle(session.hasGenerativeEngine ? PSTheme.textSecondary : PSTheme.warning).lineLimit(2)
                    Spacer()
                    selectionActions
                }
            case .pixelBrush:
                HStack(spacing: 8) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(colors, id: \.self) { color in
                                ColorSwatch(color: color, isSelected: session.paintColor == color, size: 24) { session.paintColor = color }
                            }
                        }
                        .padding(.horizontal, 2)
                    }
                    PanelChip(title: L("Apply paint"), symbol: "checkmark", tint: PSTheme.accent, isEnabled: !session.brushStrokes.isEmpty) { session.commitPixelPaint() }
                }
                DialSlider(value: $session.pixelBrushRadius, range: 0.0005...0.03, neutral: 0.004, label: L("Brush size"), format: { "\(Int(($0 * 10000).rounded()))" }) { editing in
                    session.showsBrushPreview = editing
                }
            case .clone:
                DialSlider(value: $session.pixelBrushRadius, range: 0.002...0.06, neutral: 0.02, label: L("Brush size"), format: { "\(Int(($0 * 1000).rounded()))" }) { editing in
                    session.showsBrushPreview = editing
                }
                HStack {
                    Text(session.cloneSource == nil ? L("Tap the source area, then paint the destination.") : L("Paint to clone from the marked source."))
                        .font(PSFont.caption(11)).foregroundStyle(PSTheme.textSecondary).lineLimit(2)
                    Spacer()
                    PanelChip(title: L("Reset"), symbol: "arrow.counterclockwise") { session.cloneSource = nil; session.cloneOffset = nil; session.brushStrokes = [] }
                    PanelChip(title: L("Apply"), symbol: "checkmark", tint: PSTheme.accent, isEnabled: !session.brushStrokes.isEmpty && session.cloneOffset != nil) { session.commitClone() }
                }
            }
        }
    }

    private var selectionActions: some View {
        HStack(spacing: 6) {
            if session.selectionMask != nil {
                PanelChip(title: L("Erase"), symbol: "eraser", tint: PSTheme.accent) { session.eraseSelection() }
                Menu {
                    ForEach(colors, id: \.self) { color in
                        Button(color.hexString) { session.recolorSelection(color) }
                    }
                } label: {
                    Label(L("Recolor"), systemImage: "paintpalette").font(.subheadline)
                        .padding(.horizontal, 14).frame(minHeight: PanelChipStyle.height)
                        .background(Capsule().fill(PanelChipStyle.fill))
                }
                .foregroundStyle(PSTheme.textPrimary)
                PanelRoundButton(symbol: "xmark", label: L("Clear")) { session.clearSelection() }
            }
        }
    }
}

// MARK: - Cutout

struct CutoutPanel: View {
    @Bindable var session: PhotoEditorSession
    @State private var blur: Double = 0.65
    private let colors: [PSColor] = [.white, .black, PSColor(hex: "#F2F2F7")!, PSColor(hex: "#1C1C1E")!, .blue, .teal, .green, .yellow, .orange, .pink, .purple, .gray]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    PanelChip(title: L("Remove background"), symbol: "person.crop.square.badge.minus", tint: PSTheme.voice) { session.perform(EditIntent(action: .removeBackground, background: .transparent)) }
                    PanelChip(title: L("Blur background"), symbol: "camera.aperture") { session.perform(EditIntent(action: .blurBackground, amount: .absolute(blur))) }
                    PanelChip(title: L("Gradient"), symbol: "circle.lefthalf.filled") {
                        session.perform(EditIntent(action: .replaceBackground, background: .gradient(PSColor(hex: "#1F2A4D")!, PSColor(hex: "#8A56C6")!)))
                    }
                }
                .padding(.horizontal, 2)
            }
            DialSlider(value: $blur, range: 0.1...1, neutral: 0.65, label: L("Blur amount"), format: { "\(Int(($0 * 100).rounded()))" })
            HStack(spacing: 10) {
                Text(L("Background colour")).font(PSFont.caption(12)).foregroundStyle(PSTheme.textSecondary)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(colors, id: \.self) { color in
                            ColorSwatch(color: color, isSelected: false, size: 26) {
                                session.perform(EditIntent(action: .replaceBackground, color: color, background: .color(color)))
                            }
                        }
                    }
                    .padding(.horizontal, 2)
                }
            }
        }
    }
}

// MARK: - Crop

struct CropPanel: View {
    @Bindable var session: PhotoEditorSession
    private enum Geometry { case straighten, vertical, horizontal }
    @State private var geometry: Geometry = .straighten
    private let presets: [AspectPreset] = [.free, .original, .square, .ratio4x5, .ratio9x16, .ratio3x4, .ratio4x3, .ratio16x9, .ratio3x2, .ratio21x9]

    var body: some View {
        VStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(presets) { preset in
                        AspectChip(preset: preset, isActive: session.cropAspect == preset, originalAspect: session.document.baseLayer?.imageAsset?.pixelSize.aspectRatio ?? 1) {
                            withAnimation(PSMotion.standard) {
                                if preset == .free { session.cropAspect = .free } else { session.setCropAspect(preset) }
                            }
                        }
                    }
                }
                .padding(.horizontal, 2)
            }
            HStack(spacing: 6) {
                PanelChip(title: L("Straighten"), symbol: "level", isActive: geometry == .straighten) { geometry = .straighten }
                PanelChip(title: L("Vertical"), symbol: "perspective", isActive: geometry == .vertical) { geometry = .vertical }
                PanelChip(title: L("Horizontal"), symbol: "trapezoid.and.line.horizontal", isActive: geometry == .horizontal) { geometry = .horizontal }
                Spacer()
            }
            switch geometry {
            case .straighten:
                DialSlider(value: $session.straightenPreview, range: -20...20, neutral: 0, label: L("Straighten"), units: 80, format: { String(format: "%.1f°", $0) })
            case .vertical:
                DialSlider(value: $session.perspectiveVertical, range: -1...1, neutral: 0, label: L("Vertical"), units: 60, format: { String(format: "%.0f", $0 * 100) })
            case .horizontal:
                DialSlider(value: $session.perspectiveHorizontal, range: -1...1, neutral: 0, label: L("Horizontal"), units: 60, format: { String(format: "%.0f", $0 * 100) })
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    IconChip(title: L("Best crop"), symbol: "crop", isEnabled: !session.isProcessing, tint: PSTheme.voice) { session.autoCrop() }
                    IconChip(title: L("Expand"), symbol: "arrow.up.left.and.arrow.down.right", isEnabled: !session.isProcessing, tint: PSTheme.voice) { session.expandCanvas() }
                    IconChip(title: L("Rotate"), symbol: "rotate.right") { session.rotateQuarterTurn() }
                    if session.isTurnedOrMirrored {
                        IconChip(title: L("Right way up"), symbol: "arrow.uturn.up", tint: PSTheme.accent) { session.putRightWayUp() }
                    }
                    IconChip(title: L("Flip"), symbol: "arrow.left.and.right.righttriangle.left.righttriangle.right") { session.flipHorizontally() }
                    IconChip(title: L("Flip vertical"), symbol: "arrow.up.and.down.righttriangle.up.righttriangle.down") { session.flipVertically() }
                    IconChip(title: L("Auto level"), symbol: "level") { session.autoLevel() }
                    IconChip(title: L("Reset"), symbol: "arrow.counterclockwise", isEnabled: session.hasPendingGeometry) { session.beginCrop(); geometry = .straighten }
                }
                .padding(.horizontal, 2)
            }
        }
    }
}

/// Aspect-ratio chip: a little frame drawn at the preset's proportion, like the
/// Photos app, with the label underneath.
struct AspectChip: View {
    let preset: AspectPreset
    let isActive: Bool
    var originalAspect: Double = 1
    let action: () -> Void

    private var frameSize: CGSize {
        let ratio: Double
        switch preset {
        case .free: ratio = 1.25
        case .original: ratio = max(0.4, min(2.5, originalAspect))
        default: ratio = preset.value ?? 1
        }
        let box = 22.0
        return ratio >= 1 ? CGSize(width: box, height: box / ratio) : CGSize(width: box * ratio, height: box)
    }

    var body: some View {
        Button { Haptics.tick(); action() } label: {
            VStack(spacing: 5) {
                ZStack {
                    let shape = RoundedRectangle(cornerRadius: 3, style: .continuous)
                    shape.strokeBorder(isActive ? Color.black : PSTheme.textSecondary, style: StrokeStyle(lineWidth: 1.6, dash: preset == .free ? [3, 2] : []))
                        .frame(width: frameSize.width, height: frameSize.height)
                    if preset == .original {
                        Image(systemName: "photo").font(.system(size: 8, weight: .semibold)).foregroundStyle(isActive ? Color.black : PSTheme.textSecondary)
                    }
                }
                .frame(width: 24, height: 24)
                Text(preset.displayName).font(.caption2.weight(.medium)).lineLimit(1).minimumScaleFactor(0.8)
            }
            .foregroundStyle(isActive ? Color.black : PSTheme.textSecondary)
            .frame(width: 52, height: 48)
            .background(isActive ? Color.white : PanelChipStyle.fill, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .animation(PSMotion.quick, value: isActive)
        }
        .buttonStyle(PSPressStyle())
        .accessibilityLabel(preset.displayName)
        .accessibilityAddTraits(isActive ? [.isSelected] : [])
    }
}

// MARK: - Text

struct TextPanel: View {
    @Bindable var session: PhotoEditorSession
    @State private var draft = ""
    @FocusState private var focused: Bool
    private let colors: [PSColor] = [.white, .black, .yellow, .orange, .red, .pink, .purple, .blue, .teal, .green]

    private var selectedTextLayer: Layer? {
        if let layer = session.document.selectedLayer, layer.isText { return layer }
        return session.document.textLayers.last
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                TextField(L("Type or say “add text …”"), text: $draft)
                    .textFieldStyle(.plain)
                    .font(PSFont.body(15))
                    .foregroundStyle(PSTheme.textPrimary)
                    .padding(.horizontal, 14).frame(minHeight: 36)
                    .psField(Capsule())
                    .focused($focused)
                    .submitLabel(.done)
                    .onSubmit(commit)
                Button(action: commit) { Image(systemName: "plus").font(.system(size: 15, weight: .semibold)).frame(width: 36, height: 36) }
                    .buttonStyle(.plain).foregroundStyle(PSTheme.onPrimary).background(Circle().fill(PSTheme.primary))
                    .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
                    .accessibilityLabel(L("Add Text"))
            }
            if let layer = selectedTextLayer, let element = layer.textElement {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(TextRasterizer.fontChoices, id: \.name) { font in
                            FontChip(name: font.name, display: font.display, isActive: element.fontName == font.name) {
                                session.updateText(layerID: layer.id) { $0.fontName = font.name }
                            }
                        }
                        Capsule().fill(Color.white.opacity(0.14)).frame(width: 1, height: 20)
                        ForEach(TextElement.Style.allCases, id: \.self) { style in
                            PanelChip(title: styleName(style), isActive: element.style == style) {
                                session.updateText(layerID: layer.id) { $0.style = style }
                            }
                        }
                    }
                    .padding(.horizontal, 2)
                }
                HStack(spacing: 8) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(colors, id: \.self) { color in
                                ColorSwatch(color: color, isSelected: element.color == color, size: 24) {
                                    session.updateText(layerID: layer.id) { $0.color = color }
                                }
                            }
                        }
                        .padding(.horizontal, 2)
                    }
                    PanelRoundButton(symbol: "trash", label: L("Delete"), tint: PSTheme.danger) { Haptics.warning(); session.removeLayer(layer.id) }
                }
            }
        }
    }

    private func styleName(_ style: TextElement.Style) -> String {
        switch style {
        case .plain: return L("Plain")
        case .outlined: return L("Outline")
        case .shadowed: return L("Shadow")
        case .pill: return L("Pill")
        case .banner: return L("Banner")
        case .neon: return L("Neon")
        }
    }

    private func commit() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        session.addText(text)
        draft = ""
        focused = false
    }
}

// MARK: - Layers

struct ShapesPanel: View {
    @Bindable var session: PhotoEditorSession
    private let colors: [PSColor] = [.white, .black, .yellow, .orange, .red, .pink, .purple, .blue, .teal, .green]

    private var selectedShapeLayer: Layer? {
        if let layer = session.document.selectedLayer, layer.isShape { return layer }
        return session.document.shapeLayers.last
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(ShapeElement.Kind.allCases, id: \.self) { kind in
                        PanelChip(title: kindName(kind), symbol: symbol(kind), isActive: session.shapeKindToAdd == kind) {
                            session.shapeKindToAdd = kind
                            session.addShape(kind)
                        }
                    }
                }
                .padding(.horizontal, 2)
            }
            if let layer = selectedShapeLayer, let shape = layer.shapeElement {
                HStack(spacing: 8) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(colors, id: \.self) { color in
                                ColorSwatch(color: color, isSelected: (shape.stroke != nil && shape.kind != .line && shape.kind != .arrow ? shape.stroke : shape.fill) == color, size: 24) {
                                    session.updateShape(layerID: layer.id) { element in
                                        if element.stroke != nil, element.kind != .line, element.kind != .arrow { element.stroke = color } else { element.fill = color }
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, 2)
                    }
                    if shape.kind != .line, shape.kind != .arrow {
                        PanelChip(title: shape.stroke == nil ? L("Filled") : L("Outline"), symbol: shape.stroke == nil ? "square.fill" : "square", isActive: shape.stroke != nil) {
                            session.updateShape(layerID: layer.id) { element in
                                if element.stroke == nil {
                                    element.stroke = element.fill
                                    element.fill = .clear
                                    element.strokeWidth = max(element.strokeWidth, 0.008)
                                } else {
                                    element.fill = element.stroke ?? .white
                                    element.stroke = nil
                                }
                            }
                        }
                    }
                    PanelRoundButton(symbol: "trash", label: L("Delete"), tint: PSTheme.danger) { Haptics.warning(); session.removeLayer(layer.id) }
                }
                if shape.stroke != nil || shape.kind == .line || shape.kind == .arrow {
                    DialSlider(value: Binding(get: { shape.strokeWidth * 1000 }, set: { value in session.updateShape(layerID: layer.id) { $0.strokeWidth = value / 1000 } }),
                               range: 2...40, neutral: 8, label: L("Thickness"), units: 38, format: { String(format: "%.0f", $0) })
                }
                DialSlider(value: Binding(get: { layer.opacity * 100 }, set: { value in session.updateLayer(layer.id) { $0.opacity = value / 100 } }),
                           range: 0...100, neutral: 100, label: L("Opacity"), units: 50, format: { String(format: "%.0f%%", $0) })
            }
        }
    }

    private func kindName(_ kind: ShapeElement.Kind) -> String {
        switch kind {
        case .rectangle: return L("Rectangle")
        case .roundedRectangle: return L("Rounded")
        case .ellipse: return L("Ellipse")
        case .line: return L("Line")
        case .arrow: return L("Arrow")
        }
    }

    private func symbol(_ kind: ShapeElement.Kind) -> String {
        switch kind {
        case .rectangle: return "rectangle"
        case .roundedRectangle: return "rectangle.roundedtop"
        case .ellipse: return "oval"
        case .line: return "line.diagonal"
        case .arrow: return "arrow.up.right"
        }
    }
}

struct LayersPanel: View {
    @Bindable var session: PhotoEditorSession

    var body: some View {
        VStack(spacing: 8) {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 6) {
                    ForEach(Array(session.document.layers.enumerated().reversed()), id: \.element.id) { index, layer in
                        let selected = session.document.selectedLayerID == layer.id
                        let isBase = index == 0
                        HStack(spacing: 10) {
                            Image(systemName: layer.symbolName)
                                .font(.system(size: 15, weight: .medium))
                                .foregroundStyle(PSTheme.textSecondary)
                                .frame(width: 28, height: 28)
                                .background(Circle().fill(Color.white.opacity(0.08)))
                            VStack(alignment: .leading, spacing: 1) {
                                Text(layer.name).font(.subheadline.weight(.medium)).lineLimit(1)
                                Text(isBase ? L("Photo") : (layer.isText ? L("Text") : (layer.isShape ? L("Shapes") : L("Layers"))))
                                    .font(.caption2).foregroundStyle(PSTheme.textTertiary)
                            }
                            Spacer(minLength: 4)
                            if !isBase {
                                LayerRowButton(symbol: "chevron.up", enabled: index < session.document.layers.count - 1) { session.moveLayer(layer.id, to: min(session.document.layers.count - 1, index + 1)) }
                                LayerRowButton(symbol: "chevron.down", enabled: index > 1) { session.moveLayer(layer.id, to: max(1, index - 1)) }
                            }
                            LayerRowButton(symbol: layer.isVisible ? "eye" : "eye.slash", enabled: true) { session.updateLayer(layer.id) { $0.isVisible.toggle() } }
                            if !isBase {
                                LayerRowButton(symbol: "trash", enabled: true, tint: PSTheme.danger) { Haptics.warning(); session.removeLayer(layer.id) }
                            }
                        }
                        .foregroundStyle(PSTheme.textPrimary)
                        .padding(.horizontal, 10).padding(.vertical, 8)
                        .background(Color.white.opacity(selected ? 0.16 : 0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .opacity(layer.isVisible ? 1 : 0.55)
                        .contentShape(Rectangle())
                        .animation(PSMotion.quick, value: selected)
                        .onTapGesture { Haptics.tick(); session.selectLayer(layer.id) }
                    }
                }
            }
            .frame(maxHeight: 148)
            if let selected = session.document.selectedLayer, session.document.index(of: selected.id) != 0 {
                HStack(spacing: 10) {
                    DialSlider(value: Binding(get: { selected.opacity }, set: { value in session.updateLayer(selected.id) { $0.opacity = value } }), range: 0...1, neutral: 1, label: L("Opacity"), format: { "\(Int(($0 * 100).rounded()))%" })
                    Picker(L("Blend"), selection: Binding(get: { selected.blendMode }, set: { mode in session.updateLayer(selected.id) { $0.blendMode = mode } })) {
                        ForEach(BlendMode.allCases) { Text($0.displayName).tag($0) }
                    }
                    .pickerStyle(.menu).tint(PSTheme.textPrimary).fixedSize()
                }
            }
        }
    }
}

/// Small round action inside a layer row.
struct LayerRowButton: View {
    let symbol: String
    let enabled: Bool
    var tint: Color? = nil
    let action: () -> Void

    var body: some View {
        Button { Haptics.tap(); action() } label: {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(tint ?? PSTheme.textPrimary)
                .frame(width: 30, height: 30)
                .background(PanelChipStyle.fill, in: Circle())
        }
        .buttonStyle(PSPressStyle(scale: 0.88))
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.3)
    }
}

/// Font choice rendered in its own face, so the row is a live specimen sheet.
struct FontChip: View {
    let name: String
    let display: String
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button { Haptics.tick(); action() } label: {
            VStack(spacing: 3) {
                Text("Aa").font(Font(UIFont(name: name, size: 20) ?? UIFont.systemFont(ofSize: 20, weight: .bold)))
                    .frame(height: 24)
                Text(display).font(.caption2).lineLimit(1).minimumScaleFactor(0.8)
            }
            .foregroundStyle(isActive ? Color.black : PSTheme.textPrimary)
            .frame(width: 60, height: 50)
            .background(isActive ? Color.white : PanelChipStyle.fill, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .animation(PSMotion.quick, value: isActive)
        }
        .buttonStyle(PSPressStyle())
        .accessibilityLabel(display)
        .accessibilityAddTraits(isActive ? [.isSelected] : [])
    }
}

/// A round, icon-only control inside a panel (clear, delete): the chip fill, no glass.
struct PanelRoundButton: View {
    let symbol: String
    let label: String
    var tint: Color? = nil
    let action: () -> Void

    var body: some View {
        Button { Haptics.tap(); action() } label: {
            Image(systemName: symbol).font(.system(size: 15, weight: .medium))
                .foregroundStyle(tint ?? PSTheme.textPrimary)
                .frame(width: PanelChipStyle.height, height: PanelChipStyle.height)
                .background(Circle().fill(PanelChipStyle.fill))
                .contentShape(Circle())
        }
        .buttonStyle(PSPressStyle(scale: 0.92))
        .accessibilityLabel(label)
    }
}

// MARK: - Export

struct ExportSheet: View {
    @Bindable var session: PhotoEditorSession
    @Environment(\.dismiss) private var dismiss
    @Environment(\.picshop) private var app
    @State private var format: ExportOptions.Format = .heic
    @State private var quality: Double = 0.92
    @State private var fullResolution = true
    @State private var saveToPhotos = true
    @State private var previewImage: UIImage?
    @Namespace private var formatIndicator

    private var exportSize: (width: Int, height: Int) {
        let size = session.document.canvasSize
        guard !fullResolution, max(size.width, size.height) > 2048 else { return (Int(size.width), Int(size.height)) }
        let scale = 2048 / max(1, max(size.width, size.height))
        return (Int((size.width * scale).rounded()), Int((size.height * scale).rounded()))
    }

    /// Rough file size, so the choice between formats is informed.
    private var estimatedMegabytes: Double {
        let pixels = Double(exportSize.width * exportSize.height)
        let bitsPerPixel: Double
        switch format {
        case .png: bitsPerPixel = 12
        case .jpeg: bitsPerPixel = 1.2 + quality * 4
        case .heic: bitsPerPixel = 0.6 + quality * 2.2
        }
        return pixels * bitsPerPixel / 8 / 1_048_576
    }

    private func subtitle(for format: ExportOptions.Format) -> String {
        switch format {
        case .heic: return L("Small, Apple")
        case .jpeg: return L("Universal")
        case .png: return L("Lossless")
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: PSSpacing.large) {
                    preview
                    formatPicker
                    if format != .png {
                        VStack(spacing: 6) {
                            HStack {
                                Text(L("Quality")).font(PSFont.caption(13)).foregroundStyle(PSTheme.textSecondary)
                                Spacer()
                                Text("\(Int(quality * 100))").font(PSFont.mono(12)).contentTransition(.numericText())
                            }
                            Slider(value: $quality, in: 0.5...1).tint(PSTheme.primary)
                        }
                        .padding(.horizontal, 16).padding(.vertical, 12)
                        .psCard(cornerRadius: 18, shadow: false)
                    }
                    VStack(spacing: 0) {
                        Toggle(isOn: $fullResolution) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(L("Full resolution")).font(PSFont.headline(15))
                                Text("\(exportSize.width) × \(exportSize.height) · ~\(String(format: "%.1f", estimatedMegabytes)) MB").font(PSFont.caption(12)).foregroundStyle(PSTheme.textSecondary).contentTransition(.numericText())
                            }
                        }
                        .padding(.horizontal, 16).padding(.vertical, 12)
                        Divider().overlay(PSTheme.hairline).padding(.leading, 16)
                        Toggle(isOn: $saveToPhotos) {
                            Text(L("Save to Photos")).font(PSFont.headline(15))
                        }
                        .padding(.horizontal, 16).padding(.vertical, 12)
                    }
                    .psCard(cornerRadius: 18, shadow: false)
                    if let url = session.exportedURL {
                        ShareLink(item: url) { Label(L("Share last export"), systemImage: "square.and.arrow.up").frame(maxWidth: .infinity) }
                            .buttonStyle(SecondaryButtonStyle())
                    }
                }
                .padding(.horizontal, PSSpacing.page)
                .padding(.top, 8)
                .padding(.bottom, 96)
                .animation(PSMotion.standard, value: format)
                .animation(PSMotion.quick, value: fullResolution)
            }
            .scrollIndicators(.hidden)
            .background(AmbientBackground().ignoresSafeArea())
            .safeAreaInset(edge: .bottom) {
                Button {
                    Haptics.confirm()
                    Task {
                        await session.export(options: ExportOptions(format: format, quality: quality, maxLongestSide: fullResolution ? nil : 2048, saveToPhotos: saveToPhotos))
                    }
                } label: {
                    Label(saveToPhotos ? L("Save to Photos") : L("Export"), systemImage: saveToPhotos ? "photo.badge.arrow.down" : "square.and.arrow.down").frame(maxWidth: .infinity)
                }
                .buttonStyle(PrimaryButtonStyle())
                .padding(.horizontal, PSSpacing.page)
                .padding(.vertical, 10)
                .background(LinearGradient(colors: [PSTheme.ink.opacity(0), PSTheme.ink.opacity(0.9)], startPoint: .top, endPoint: .bottom).ignoresSafeArea())
            }
            .navigationTitle(L("Export"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(L("Done")) { dismiss() } } }
            .onAppear { format = app?.settings.photoExportFormat ?? .heic }
        }
        .preferredColorScheme(.dark)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    /// The picture itself, so the sheet feels like handing over the result.
    private var preview: some View {
        ZStack {
            if let previewImage {
                Image(uiImage: previewImage).resizable().scaledToFit()
            } else {
                PSTheme.surfaceElevated
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 180)
        .task {
            // Rasterised once for the sheet, off the body path.
            guard previewImage == nil, let image = session.preview else { return }
            let scaled = image.transformed(by: CGAffineTransform(scaleX: 0.5, y: 0.5))
            if let cg = ImageSupport.cgImage(from: scaled) { previewImage = UIImage(cgImage: cg) }
        }
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(PSTheme.strokeGradient, lineWidth: 1))
        .shadow(color: .black.opacity(0.4), radius: 18, y: 10)
    }

    private var formatPicker: some View {
        HStack(spacing: 4) {
            ForEach(ExportOptions.Format.allCases) { item in
                let isActive = format == item
                Button {
                    Haptics.tick()
                    withAnimation(PSMotion.standard) { format = item }
                } label: {
                    VStack(spacing: 2) {
                        Text(item.displayName).font(PSFont.headline(14))
                        Text(subtitle(for: item)).font(PSFont.caption(10)).opacity(0.8)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
                    .foregroundStyle(isActive ? Color.white : PSTheme.textSecondary)
                    .background {
                        if isActive {
                            RoundedRectangle(cornerRadius: 12, style: .continuous).fill(PSTheme.selection)
                                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.white.opacity(0.12), lineWidth: 0.75))
                                .matchedGeometryEffect(id: "format", in: formatIndicator)
                        }
                    }
                    .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(PSPressStyle(scale: 0.97))
                .accessibilityAddTraits(isActive ? [.isSelected] : [])
            }
        }
        .padding(4)
        .background(Color.black.opacity(0.28), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
    }
}
#endif
