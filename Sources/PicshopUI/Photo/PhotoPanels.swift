#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import CoreImage
import PicshopCore
import PicshopIntent
import PicshopImaging

/// Contextual panel for the active tool.
extension PhotoEditorSession.Tool {
    /// Dock entries, grouped by purpose. Sub-modes appear as segments in the panel.
    static var groups: [ToolGroup<PhotoEditorSession.Tool>] {
        [
            ToolGroup(id: "retouch", title: L("Retouch"), symbol: "slider.horizontal.3", tools: [.adjust, .looks]),
            ToolGroup(id: "magic", title: L("Magic"), symbol: "wand.and.stars", tools: [.erase, .cutout, .precise]),
            ToolGroup(id: "crop", title: L("Crop"), symbol: "crop.rotate", tools: [.crop]),
            ToolGroup(id: "add", title: L("Add"), symbol: "plus.square.on.square", tools: [.text, .shapes]),
            ToolGroup(id: "layers", title: L("Layers"), symbol: "square.3.layers.3d", tools: [.layers]),
        ]
    }
}

struct PhotoToolPanel: View {
    @Bindable var session: PhotoEditorSession
    let tool: PhotoEditorSession.Tool

    private var group: ToolGroup<PhotoEditorSession.Tool>? {
        PhotoEditorSession.Tool.groups.first { $0.contains(tool) }
    }

    private var modes: AnyView? {
        guard let group, group.tools.count > 1 else { return nil }
        return AnyView(ModeSegments(modes: group.tools, selection: $session.activeTool, title: { $0.title }, symbol: { $0.symbol }))
    }

    var body: some View {
        ToolPanelContainer(title: group.map { $0.tools.count > 1 ? $0.title : tool.title } ?? tool.title,
                           symbol: group.map { $0.tools.count > 1 ? $0.symbol : tool.symbol } ?? tool.symbol,
                           onClose: { session.activeTool = nil }, trailing: trailing, modes: modes) {
            switch tool {
            case .adjust: AdjustPanel(session: session)
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

    private var trailing: AnyView? {
        switch tool {
        case .crop:
            return AnyView(HStack(spacing: 8) {
                Button { Haptics.tap(); session.cancelCrop(); session.activeTool = nil } label: {
                    Text(L("Cancel")).font(PSFont.caption(13)).padding(.horizontal, 12).padding(.vertical, 7)
                }
                .buttonStyle(.plain).foregroundStyle(PSTheme.textPrimary).psGlass(interactive: true)
                Button { session.commitCrop() } label: {
                    Text(L("Done")).font(PSFont.headline(13)).padding(.horizontal, 14).padding(.vertical, 7)
                }
                .buttonStyle(.plain).foregroundStyle(.white).psAccentFill(Capsule())
            })
        case .erase:
            return session.brushStrokes.isEmpty ? nil : AnyView(
                Button { Haptics.confirm(); session.commitBrushErase() } label: {
                    Label(L("Erase painted area"), systemImage: "sparkles").font(PSFont.headline(13)).padding(.horizontal, 12).padding(.vertical, 7)
                }
                .buttonStyle(.plain).foregroundStyle(.white).psAccentFill(Capsule())
            )
        default:
            return nil
        }
    }
}

private func localizedName(_ parameter: AdjustmentParameter) -> String {
    Locale.current.language.languageCode?.identifier == "fr" ? parameter.frenchName : parameter.englishName
}

private func localizedName(_ preset: FilterPreset) -> String {
    Locale.current.language.languageCode?.identifier == "fr" ? preset.frenchName : preset.englishName
}

private extension PhotoEditorSession {
    func perform(_ intent: EditIntent) {
        Task { await run(intent) }
    }
}

// MARK: - Adjust

struct AdjustPanel: View {
    @Bindable var session: PhotoEditorSession
    @State private var value: Double = 0
    @State private var group: Family = .light
    @Namespace private var groupIndicator

    /// Photos-style families of parameters; the segment slides between them.
    enum Family: String, CaseIterable, Identifiable {
        case light, color, detail, effects
        var id: String { rawValue }
        var title: String {
            switch self {
            case .light: return L("Light")
            case .color: return L("Colour")
            case .detail: return L("Detail")
            case .effects: return L("Effects")
            }
        }
        var symbol: String {
            switch self {
            case .light: return "sun.max"
            case .color: return "paintpalette"
            case .detail: return "circle.dotted.and.circle"
            case .effects: return "sparkles"
            }
        }
        var parameters: [AdjustmentParameter] {
            switch self {
            case .light: return AdjustmentParameter.lightGroup
            case .color: return AdjustmentParameter.colorGroup
            case .detail: return AdjustmentParameter.detailGroup
            case .effects: return AdjustmentParameter.effectsGroup
            }
        }
        static func containing(_ parameter: AdjustmentParameter) -> Family {
            allCases.first { $0.parameters.contains(parameter) } ?? .light
        }
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 2) {
                ForEach(Family.allCases) { item in
                    let isActive = group == item
                    let touched = item.parameters.contains { abs(session.adjustmentValue($0)) > 0.0005 }
                    Button {
                        Haptics.tick()
                        withAnimation(PSMotion.standard) {
                            group = item
                            if !item.parameters.contains(session.selectedParameter), let first = item.parameters.first {
                                session.selectedParameter = first
                            }
                        }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: item.symbol).font(.system(size: 11, weight: .bold))
                            Text(item.title).font(PSFont.caption(12)).lineLimit(1).minimumScaleFactor(0.8)
                            if touched && !isActive { Circle().fill(PSTheme.accent).frame(width: 5, height: 5) }
                        }
                        .padding(.horizontal, 10).padding(.vertical, 7)
                        .frame(maxWidth: .infinity)
                        .background {
                            if isActive {
                                Capsule().fill(PSTheme.accentGradient).overlay(Capsule().fill(PSTheme.accentHighlight))
                                    .matchedGeometryEffect(id: "group", in: groupIndicator)
                            }
                        }
                        .foregroundStyle(isActive ? Color.white : PSTheme.textSecondary)
                        .contentShape(Capsule())
                    }
                    .buttonStyle(PSPressStyle(scale: 0.97))
                    .accessibilityAddTraits(isActive ? [.isSelected] : [])
                }
            }
            .padding(3)
            .background(Color.black.opacity(0.28), in: Capsule())
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(group.parameters) { parameter in
                        let active = session.selectedParameter == parameter
                        let current = session.adjustmentValue(parameter)
                        Button {
                            Haptics.tick()
                            withAnimation(PSMotion.quick) { session.selectedParameter = parameter }
                            value = current
                        } label: {
                            VStack(spacing: 5) {
                                ZStack {
                                    Circle().stroke(PSTheme.hairline, lineWidth: 3)
                                    Circle()
                                        .trim(from: 0, to: CGFloat(min(1, abs(current))))
                                        .stroke(active ? Color.white : PSTheme.accent, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                                        .rotationEffect(.degrees(-90))
                                        .scaleEffect(x: current < 0 ? -1 : 1)
                                        .animation(PSMotion.numeric, value: current)
                                    Image(systemName: parameter.symbolName).font(.system(size: 15, weight: .semibold))
                                }
                                .frame(width: 40, height: 40)
                                Text(localizedName(parameter)).font(PSFont.caption(10)).lineLimit(1).minimumScaleFactor(0.8)
                            }
                            .foregroundStyle(active ? Color.white : PSTheme.textPrimary)
                            .frame(width: 66, height: 64)
                            .psActivePill(RoundedRectangle(cornerRadius: 16, style: .continuous), isActive: active, glow: false)
                            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        }
                        .buttonStyle(PSPressStyle())
                        .accessibilityLabel(localizedName(parameter))
                        .accessibilityValue(String(Int((current * 100).rounded())))
                    }
                }
                .padding(.horizontal, 2)
            }
            .scrollBounceBehavior(.basedOnSize)
            DialSlider(value: $value, range: session.selectedParameter.range, neutral: 0, label: localizedName(session.selectedParameter)) { editing in
                if editing { session.beginSliderInteraction(session.selectedParameter) } else { session.endSliderInteraction() }
            }
            .onChange(of: value) { _, newValue in
                if abs(newValue - session.adjustmentValue(session.selectedParameter)) > 0.0005 {
                    session.setAdjustment(session.selectedParameter, value: newValue)
                }
            }
            .onChange(of: session.selectedParameter) { _, parameter in
                value = session.adjustmentValue(parameter)
                let owner = Family.containing(parameter)
                if owner != group { withAnimation(PSMotion.standard) { group = owner } }
            }
            .onChange(of: session.history.present.modifiedAt) { _, _ in
                let current = session.adjustmentValue(session.selectedParameter)
                if abs(current - value) > 0.0005 { value = current }
            }
            HStack(spacing: 8) {
                PanelChip(title: L("Auto"), symbol: "wand.and.stars", tint: PSTheme.accent) { session.perform(EditIntent(action: .autoEnhance)) }
                PanelChip(title: L("Portrait light"), symbol: "person.and.background.dotted") { session.perform(EditIntent(action: .relight)) }
                Spacer()
                PanelChip(title: L("Reset"), symbol: "arrow.counterclockwise", isEnabled: !session.document.activeAdjustments.isNeutral) {
                    session.apply(.adjustments(.neutral), label: L("Reset"))
                    value = 0
                }
            }
        }
        .onAppear {
            value = session.adjustmentValue(session.selectedParameter)
            group = Family.containing(session.selectedParameter)
        }
    }
}

// MARK: - Looks

struct LooksPanel: View {
    @Bindable var session: PhotoEditorSession
    @State private var thumbnails: [FilterPreset: UIImage] = [:]
    @State private var intensity: Double = 1

    var body: some View {
        VStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(FilterPreset.gallery) { preset in
                        let active = (session.document.baseLayer?.edits.resolvedLook?.preset ?? .original) == preset
                        Button {
                            Haptics.tick()
                            session.applyLook(preset, intensity: intensity)
                        } label: {
                            VStack(spacing: 5) {
                                ZStack {
                                    if let image = thumbnails[preset] {
                                        Image(uiImage: image).resizable().scaledToFill()
                                    } else {
                                        PSTheme.surfaceElevated
                                    }
                                }
                                .frame(width: 60, height: 60)
                                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(active ? PSTheme.accent : .clear, lineWidth: 2.5))
                                Text(localizedName(preset)).font(PSFont.caption(10)).foregroundStyle(active ? PSTheme.accent : PSTheme.textSecondary).lineLimit(1)
                            }
                            .frame(width: 64)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 2)
            }
            if session.document.baseLayer?.edits.resolvedLook != nil {
                DialSlider(value: $intensity, range: 0...1, neutral: 1, label: L("Intensity"), format: { "\(Int(($0 * 100).rounded()))%" }) { editing in
                    if editing { session.beginSliderInteraction(.saturation) } else { session.endSliderInteraction() }
                }
                .onChange(of: intensity) { _, newValue in session.setLookIntensity(newValue) }
            } else {
                Text(L("Pick a look, then tune its intensity.")).font(PSFont.caption(12)).foregroundStyle(PSTheme.textSecondary)
            }
        }
        .task { await renderThumbnails() }
    }

    /// Thumbnails are rendered once per photo state and kept on the session, so
    /// reopening the panel costs nothing and a hot phone renders them smaller.
    private func renderThumbnails() async {
        if let cached = session.lookThumbnails, cached.key == session.lookThumbnailKey {
            thumbnails = cached.images
            return
        }
        let side = session.app.performance.thumbnailSide
        guard let renderer = session.renderer, let base = try? await renderer.renderBase(session.document, options: PhotoRenderer.Options(targetLongestSide: side, allowExpensiveWork: false)) else { return }
        let key = session.lookThumbnailKey
        var rendered: [FilterPreset: UIImage] = [:]
        for preset in FilterPreset.gallery {
            let adjusted = AdjustmentPipeline.apply(preset.recipe, toneCurve: preset.toneCurve, to: base, scale: 0.05)
            if let cg = ImageSupport.cgImage(from: adjusted) {
                rendered[preset] = UIImage(cgImage: cg)
                thumbnails[preset] = rendered[preset]
            }
            await Task.yield()
        }
        session.lookThumbnails = (key, rendered)
    }
}

// MARK: - Erase

struct ErasePanel: View {
    @Bindable var session: PhotoEditorSession

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    PanelChip(title: L("People"), symbol: "person.2") { session.eraseAll(label: "person", phrase: L("people")) }
                    PanelChip(title: L("Text & logos"), symbol: "textformat.abc") { session.eraseAll(label: "text", phrase: L("text")) }
                    PanelChip(title: L("Animals"), symbol: "pawprint") { session.eraseAll(label: "animal", phrase: L("animals")) }
                    PanelChip(title: L("Vehicles"), symbol: "car") { session.eraseAll(label: "car", phrase: L("vehicles")) }
                    PanelChip(title: L("Clear strokes"), symbol: "xmark", isEnabled: !session.brushStrokes.isEmpty) { session.brushStrokes = [] }
                }
                .padding(.horizontal, 2)
            }
            DialSlider(value: $session.brushRadius, range: 0.006...0.09, neutral: 0.03, label: L("Brush size"), format: { "\(Int(($0 * 1000).rounded()))" }) { editing in
                session.showsBrushPreview = editing
            }
            Text(L("Tap an object to erase it, paint over it, or say “efface le poteau à droite”."))
                .font(PSFont.caption(11)).foregroundStyle(PSTheme.textSecondary).lineLimit(2)
        }
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
                        IconChip(title: mode.title, symbol: mode.symbol, isActive: session.preciseMode == mode) {
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
                    Toggle(L("Contiguous"), isOn: $session.wandContiguous).font(PSFont.caption(13)).tint(PSTheme.accent).fixedSize()
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
                        .padding(.horizontal, 14).padding(.vertical, 9).psField(Capsule())
                        .submitLabel(.go).onSubmit { session.generateInSelection(session.generativePrompt) }
                    Button { session.generateInSelection(session.generativePrompt) } label: { Image(systemName: "sparkles").font(.system(size: 15, weight: .bold)).frame(width: 38, height: 38) }
                        .buttonStyle(.plain).foregroundStyle(.white).psAccentFill(Circle())
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
                    Label(L("Recolor"), systemImage: "paintpalette").font(PSFont.caption(13)).padding(.horizontal, 12).padding(.vertical, 9)
                }
                .foregroundStyle(PSTheme.textPrimary).psGlass(interactive: true)
                Button { session.clearSelection() } label: { Image(systemName: "xmark").font(PSFont.caption(13)).padding(8) }
                    .buttonStyle(.plain).psGlass(interactive: true, shape: AnyShape(Circle()))
                    .accessibilityLabel(L("Clear"))
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
                    PanelChip(title: L("Remove background"), symbol: "person.crop.square.badge.minus", tint: PSTheme.accent) { session.perform(EditIntent(action: .removeBackground, background: .transparent)) }
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
                        PanelChip(title: preset.displayName, isActive: session.cropAspect == preset) {
                            if preset == .free { session.cropAspect = .free } else { session.setCropAspect(preset) }
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
            HStack(spacing: 8) {
                IconChip(title: L("Rotate"), symbol: "rotate.right") { session.rotateQuarterTurn() }
                IconChip(title: L("Flip"), symbol: "arrow.left.and.right.righttriangle.left.righttriangle.right") { session.flipHorizontally() }
                IconChip(title: L("Auto level"), symbol: "level") { session.autoLevel() }
                IconChip(title: L("Reset"), symbol: "arrow.counterclockwise", isEnabled: session.hasPendingGeometry) { session.beginCrop(); geometry = .straighten }
                Spacer()
            }
        }
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
                    .padding(.horizontal, 14).padding(.vertical, 9)
                    .psField(Capsule())
                    .focused($focused)
                    .submitLabel(.done)
                    .onSubmit(commit)
                Button(action: commit) { Image(systemName: "plus").font(.system(size: 15, weight: .bold)).frame(width: 38, height: 38) }
                    .buttonStyle(.plain).foregroundStyle(.white).psAccentFill(Circle())
                    .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
                    .accessibilityLabel(L("Add Text"))
            }
            if let layer = selectedTextLayer, let element = layer.textElement {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(TextRasterizer.fontChoices, id: \.name) { font in
                            PanelChip(title: font.display, isActive: element.fontName == font.name) {
                                session.updateText(layerID: layer.id) { $0.fontName = font.name }
                            }
                        }
                        Divider().frame(height: 22).overlay(PSTheme.hairline)
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
                    Button(role: .destructive) { Haptics.warning(); session.removeLayer(layer.id) } label: { Image(systemName: "trash").font(.system(size: 14, weight: .semibold)).frame(width: 34, height: 34) }
                        .buttonStyle(.plain).foregroundStyle(PSTheme.danger).psGlass(interactive: true, shape: AnyShape(Circle()))
                        .accessibilityLabel(L("Delete"))
                }
                Text(L("Drag the text to move it, pinch to resize, twist to rotate."))
                    .font(PSFont.caption(11)).foregroundStyle(PSTheme.textSecondary)
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
                    Button(role: .destructive) { Haptics.warning(); session.removeLayer(layer.id) } label: { Image(systemName: "trash").font(.system(size: 14, weight: .semibold)).frame(width: 34, height: 34) }
                        .buttonStyle(.plain).foregroundStyle(PSTheme.danger).psGlass(interactive: true, shape: AnyShape(Circle()))
                        .accessibilityLabel(L("Delete"))
                }
                if shape.stroke != nil || shape.kind == .line || shape.kind == .arrow {
                    DialSlider(value: Binding(get: { shape.strokeWidth * 1000 }, set: { value in session.updateShape(layerID: layer.id) { $0.strokeWidth = value / 1000 } }),
                               range: 2...40, neutral: 8, label: L("Thickness"), units: 38, format: { String(format: "%.0f", $0) })
                }
                DialSlider(value: Binding(get: { layer.opacity * 100 }, set: { value in session.updateLayer(layer.id) { $0.opacity = value / 100 } }),
                           range: 0...100, neutral: 100, label: L("Opacity"), units: 50, format: { String(format: "%.0f%%", $0) })
                Text(L("Tap the canvas to place a shape. Drag to move, pinch to resize, twist to rotate."))
                    .font(PSFont.caption(11)).foregroundStyle(PSTheme.textSecondary)
            } else {
                Text(L("Pick a shape, then tap the canvas to place it."))
                    .font(PSFont.caption(11)).foregroundStyle(PSTheme.textSecondary)
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
                        HStack(spacing: 10) {
                            Image(systemName: layer.symbolName).frame(width: 22)
                            Text(layer.name).font(PSFont.body(14)).lineLimit(1)
                            Spacer()
                            if index > 0 {
                                Button { session.moveLayer(layer.id, to: min(session.document.layers.count - 1, index + 1)) } label: { Image(systemName: "chevron.up") }
                                    .buttonStyle(.plain).disabled(index == session.document.layers.count - 1).opacity(index == session.document.layers.count - 1 ? 0.3 : 1)
                                Button { session.moveLayer(layer.id, to: max(1, index - 1)) } label: { Image(systemName: "chevron.down") }
                                    .buttonStyle(.plain).disabled(index <= 1).opacity(index <= 1 ? 0.3 : 1)
                            }
                            Button { session.updateLayer(layer.id) { $0.isVisible.toggle() } } label: { Image(systemName: layer.isVisible ? "eye" : "eye.slash") }
                                .buttonStyle(.plain)
                            if index > 0 {
                                Button(role: .destructive) { session.removeLayer(layer.id) } label: { Image(systemName: "trash") }
                                    .buttonStyle(.plain).foregroundStyle(PSTheme.danger)
                            }
                        }
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(selected ? Color.black : PSTheme.textPrimary)
                        .padding(.horizontal, 12).padding(.vertical, 9)
                        .background(selected ? PSTheme.accent : PSTheme.hairline, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .contentShape(Rectangle())
                        .onTapGesture { Haptics.tick(); session.selectLayer(layer.id) }
                    }
                }
            }
            .frame(maxHeight: 150)
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

// MARK: - Export

struct ExportSheet: View {
    @Bindable var session: PhotoEditorSession
    @Environment(\.dismiss) private var dismiss
    @Environment(\.picshop) private var app
    @State private var format: ExportOptions.Format = .heic
    @State private var quality: Double = 0.92
    @State private var fullResolution = true
    @State private var saveToPhotos = true

    var body: some View {
        NavigationStack {
            Form {
                Section(L("Format")) {
                    Picker(L("Format"), selection: $format) {
                        ForEach(ExportOptions.Format.allCases) { Text($0.displayName).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    if format != .png {
                        HStack { Text(L("Quality")); Slider(value: $quality, in: 0.5...1); Text("\(Int(quality * 100))").font(PSFont.mono()) }
                    }
                    Toggle(L("Full resolution"), isOn: $fullResolution)
                    Text(fullResolution ? "\(Int(session.document.canvasSize.width)) × \(Int(session.document.canvasSize.height))" : L("Longest side 2048 px"))
                        .font(PSFont.caption()).foregroundStyle(PSTheme.textSecondary)
                }
                Section {
                    Toggle(L("Save to Photos"), isOn: $saveToPhotos)
                }
                Section {
                    Button {
                        Task {
                            await session.export(options: ExportOptions(format: format, quality: quality, maxLongestSide: fullResolution ? nil : 2048, saveToPhotos: saveToPhotos))
                        }
                    } label: {
                        Label(L("Export"), systemImage: "square.and.arrow.down").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .listRowBackground(Color.clear)
                    if let url = session.exportedURL {
                        ShareLink(item: url) { Label(L("Share last export"), systemImage: "square.and.arrow.up").frame(maxWidth: .infinity) }
                            .buttonStyle(SecondaryButtonStyle())
                            .listRowBackground(Color.clear)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(AmbientBackground().ignoresSafeArea())
            .navigationTitle(L("Export"))
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(L("Done")) { dismiss() } } }
            .onAppear { format = app?.settings.photoExportFormat ?? .heic }
        }
        .preferredColorScheme(.dark)
        .presentationDetents([.medium, .large])
    }
}
#endif
