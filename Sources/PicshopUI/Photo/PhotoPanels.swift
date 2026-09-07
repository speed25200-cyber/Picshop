#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import CoreImage
import PicshopCore
import PicshopIntent
import PicshopImaging

/// Contextual panel for the active tool.
struct PhotoToolPanel: View {
    @Bindable var session: PhotoEditorSession
    let tool: PhotoEditorSession.Tool

    var body: some View {
        Group {
            switch tool {
            case .adjust: AdjustPanel(session: session)
            case .looks: LooksPanel(session: session)
            case .erase: ErasePanel(session: session)
            case .precise: PrecisePanel(session: session)
            case .cutout: CutoutPanel(session: session)
            case .crop: CropPanel(session: session)
            case .text: TextPanel(session: session)
            case .layers: LayersPanel(session: session)
            }
        }
        .padding(14)
        .psGlassPanel()
        .padding(.horizontal, 16)
    }
}

// MARK: - Adjust

struct AdjustPanel: View {
    @Bindable var session: PhotoEditorSession
    @State private var value: Double = 0

    private let groups: [(String, [AdjustmentParameter])] = [
        (L("Light"), AdjustmentParameter.lightGroup), (L("Colour"), AdjustmentParameter.colorGroup),
        (L("Detail"), AdjustmentParameter.detailGroup), (L("Effects"), AdjustmentParameter.effectsGroup),
    ]

    var body: some View {
        VStack(spacing: 12) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(groups, id: \.0) { group in
                        ForEach(group.1) { parameter in
                            let active = session.selectedParameter == parameter
                            let touched = session.adjustmentValue(parameter) != 0
                            Button {
                                Haptics.tick()
                                session.selectedParameter = parameter
                                value = session.adjustmentValue(parameter)
                            } label: {
                                VStack(spacing: 5) {
                                    Image(systemName: parameter.symbolName).font(.system(size: 16, weight: .semibold))
                                    Text(localizedName(parameter)).font(PSFont.caption(10)).lineLimit(1)
                                }
                                .foregroundStyle(active ? Color.black : (touched ? PSTheme.accent : PSTheme.textPrimary))
                                .frame(width: 68, height: 52)
                                .background(active ? PSTheme.accent : PSTheme.hairline, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            }
                            .buttonStyle(.plain)
                        }
                        Divider().frame(height: 30).overlay(PSTheme.hairline)
                    }
                }
            }
            ParameterSlider(title: localizedName(session.selectedParameter), value: $value, range: session.selectedParameter.range, bipolar: session.selectedParameter.isBipolar) { editing in
                if editing { session.beginSliderInteraction(session.selectedParameter) } else { session.endSliderInteraction() }
            }
            .onChange(of: value) { _, newValue in
                if abs(newValue - session.adjustmentValue(session.selectedParameter)) > 0.0005 {
                    session.setAdjustment(session.selectedParameter, value: newValue)
                }
            }
            .onChange(of: session.selectedParameter) { _, parameter in value = session.adjustmentValue(parameter) }
            .onChange(of: session.history.present.modifiedAt) { _, _ in
                let current = session.adjustmentValue(session.selectedParameter)
                if abs(current - value) > 0.0005 { value = current }
            }
            HStack {
                Button { session.perform(EditIntent(action: .autoEnhance)) } label: { Label(L("Auto"), systemImage: "wand.and.stars") }
                    .buttonStyle(.plain).font(PSFont.caption(13)).padding(.horizontal, 12).padding(.vertical, 8).psGlass(tint: PSTheme.accent, interactive: true).foregroundStyle(.black)
                Spacer()
                Button {
                    session.beginSliderInteraction(session.selectedParameter)
                    session.setAdjustment(session.selectedParameter, value: 0)
                    session.endSliderInteraction()
                    value = 0
                } label: { Text(L("Reset")).font(PSFont.caption(13)) }
                    .buttonStyle(.plain).foregroundStyle(PSTheme.textSecondary)
            }
        }
        .onAppear { value = session.adjustmentValue(session.selectedParameter) }
    }

    private func localizedName(_ parameter: AdjustmentParameter) -> String {
        Locale.current.language.languageCode?.identifier == "fr" ? parameter.frenchName : parameter.englishName
    }
}

private extension PhotoEditorSession {
    func perform(_ intent: EditIntent) {
        Task { await run(intent) }
    }
}

// MARK: - Looks

struct LooksPanel: View {
    @Bindable var session: PhotoEditorSession
    @State private var thumbnails: [FilterPreset: UIImage] = [:]
    @State private var intensity: Double = 1

    var body: some View {
        VStack(spacing: 12) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(FilterPreset.gallery) { preset in
                        let active = (session.document.baseLayer?.edits.resolvedLook?.preset ?? .original) == preset
                        Button {
                            Haptics.tick()
                            session.applyLook(preset, intensity: intensity)
                        } label: {
                            VStack(spacing: 6) {
                                ZStack {
                                    if let image = thumbnails[preset] {
                                        Image(uiImage: image).resizable().scaledToFill()
                                    } else {
                                        PSTheme.surfaceElevated
                                    }
                                }
                                .frame(width: 64, height: 64)
                                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(active ? PSTheme.accent : .clear, lineWidth: 2.5))
                                Text(localizedName(preset)).font(PSFont.caption(10)).foregroundStyle(active ? PSTheme.accent : PSTheme.textSecondary).lineLimit(1)
                            }
                            .frame(width: 70)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            if session.document.baseLayer?.edits.resolvedLook != nil {
                ParameterSlider(title: L("Intensity"), value: $intensity, range: 0...1, bipolar: false) { editing in
                    if editing { session.beginSliderInteraction(.saturation) } else { session.endSliderInteraction() }
                }
                .onChange(of: intensity) { _, newValue in session.setLookIntensity(newValue) }
            }
        }
        .task { await renderThumbnails() }
    }

    private func localizedName(_ preset: FilterPreset) -> String {
        Locale.current.language.languageCode?.identifier == "fr" ? preset.frenchName : preset.englishName
    }

    private func renderThumbnails() async {
        guard let renderer = session.renderer, let base = try? await renderer.renderBase(session.document, options: PhotoRenderer.Options(targetLongestSide: 160, allowExpensiveWork: false)) else { return }
        for preset in FilterPreset.gallery {
            let adjusted = AdjustmentPipeline.apply(preset.recipe, toneCurve: preset.toneCurve, to: base, scale: 0.05)
            if let cg = ImageSupport.cgImage(from: adjusted) {
                thumbnails[preset] = UIImage(cgImage: cg)
            }
        }
    }
}

// MARK: - Erase

struct ErasePanel: View {
    @Bindable var session: PhotoEditorSession

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "waveform.and.mic").foregroundStyle(PSTheme.voice)
                Text(L("Say what to erase (“the pole on the right”), tap it, or paint over it."))
                    .font(PSFont.caption(12)).foregroundStyle(PSTheme.textSecondary).fixedSize(horizontal: false, vertical: true)
            }
            ParameterSlider(title: L("Brush size"), value: $session.brushRadius, range: 0.008...0.09, bipolar: false)
            HStack {
                Button { session.brushStrokes = [] } label: { Text(L("Clear")).font(PSFont.caption(13)) }
                    .buttonStyle(.plain).foregroundStyle(PSTheme.textSecondary)
                    .disabled(session.brushStrokes.isEmpty)
                Spacer()
                Button {
                    Haptics.confirm()
                    session.commitBrushErase()
                } label: {
                    Label(L("Erase painted area"), systemImage: "sparkles").font(PSFont.caption(13)).padding(.horizontal, 12).padding(.vertical, 8)
                }
                .buttonStyle(.plain).foregroundStyle(.black).psGlass(tint: PSTheme.accent, interactive: true)
                .disabled(session.brushStrokes.isEmpty)
                .opacity(session.brushStrokes.isEmpty ? 0.5 : 1)
            }
        }
    }
}

// MARK: - Precise

struct PrecisePanel: View {
    @Bindable var session: PhotoEditorSession
    private let colors: [PSColor] = [.white, .black, .red, .orange, .yellow, .green, .teal, .blue, .purple, .pink, .gray, .brown]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(PhotoEditorSession.PreciseMode.allCases) { mode in
                        let active = session.preciseMode == mode
                        Button {
                            Haptics.tick()
                            session.commitBrushErase()
                            session.brushStrokes = []
                            session.preciseMode = mode
                        } label: {
                            VStack(spacing: 4) {
                                Image(systemName: mode.symbol).font(.system(size: 16, weight: .semibold))
                                Text(mode.title).font(PSFont.caption(10)).lineLimit(1)
                            }
                            .foregroundStyle(active ? Color.black : PSTheme.textPrimary)
                            .frame(width: 74, height: 50)
                            .background(active ? PSTheme.accent : PSTheme.hairline, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            switch session.preciseMode {
            case .wand:
                ParameterSlider(title: L("Tolerance"), value: $session.wandTolerance, range: 0.02...0.8, bipolar: false)
                HStack {
                    Toggle(L("Contiguous"), isOn: $session.wandContiguous).font(PSFont.caption(13)).tint(PSTheme.accent)
                    Spacer()
                    selectionActions
                }
                Text(L("Tap a colour to select it. Pinch in for the pixel grid.")).font(PSFont.caption(12)).foregroundStyle(PSTheme.textSecondary)
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
                        .padding(.horizontal, 14).padding(.vertical, 10).background(PSTheme.hairline, in: Capsule())
                        .submitLabel(.go).onSubmit { session.generateInSelection(session.generativePrompt) }
                    Button { session.generateInSelection(session.generativePrompt) } label: { Image(systemName: "sparkles").font(.system(size: 15, weight: .bold)).frame(width: 38, height: 38) }
                        .buttonStyle(.plain).foregroundStyle(.black).psGlass(tint: PSTheme.accent, interactive: true, shape: AnyShape(Circle()))
                        .disabled(session.generativePrompt.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                HStack {
                    Text(session.selectionMask == nil ? L("Select an area first (wand, lasso or tap), then describe the change.") : L("Selection ready. Say or type what should appear there."))
                        .font(PSFont.caption(12)).foregroundStyle(session.hasGenerativeEngine ? PSTheme.textSecondary : PSTheme.warning)
                    Spacer()
                    selectionActions
                }
                if !session.hasGenerativeEngine {
                    Text(L("Generative Fill model not installed — see Settings.")).font(PSFont.caption(11)).foregroundStyle(PSTheme.warning)
                }
            case .pixelBrush:
                HStack(spacing: 8) {
                    ForEach(colors, id: \.self) { color in
                        Button { session.paintColor = color } label: {
                            Circle().fill(Color(cgColor: color.cgColor)).frame(width: 24, height: 24)
                                .overlay(Circle().stroke(session.paintColor == color ? PSTheme.accent : PSTheme.hairline, lineWidth: 2))
                        }.buttonStyle(.plain)
                    }
                }
                ParameterSlider(title: L("Brush size"), value: $session.pixelBrushRadius, range: 0.0005...0.03, bipolar: false)
                HStack {
                    Button { session.brushStrokes = [] } label: { Text(L("Clear")).font(PSFont.caption(13)) }.buttonStyle(.plain).foregroundStyle(PSTheme.textSecondary)
                    Spacer()
                    PanelChip(title: L("Apply paint"), symbol: "checkmark", tint: PSTheme.accent) { session.commitPixelPaint() }.disabled(session.brushStrokes.isEmpty)
                }
            case .clone:
                ParameterSlider(title: L("Brush size"), value: $session.pixelBrushRadius, range: 0.002...0.06, bipolar: false)
                HStack {
                    Text(session.cloneSource == nil ? L("Tap the source area, then paint the destination.") : L("Paint to clone from the marked source."))
                        .font(PSFont.caption(12)).foregroundStyle(PSTheme.textSecondary)
                    Spacer()
                    Button { session.cloneSource = nil; session.cloneOffset = nil; session.brushStrokes = [] } label: { Text(L("Reset")).font(PSFont.caption(13)) }.buttonStyle(.plain).foregroundStyle(PSTheme.textSecondary)
                    PanelChip(title: L("Apply"), symbol: "checkmark", tint: PSTheme.accent) { session.commitClone() }.disabled(session.brushStrokes.isEmpty || session.cloneOffset == nil)
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
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                actionChip(L("Remove background"), symbol: "person.crop.square.badge.minus") { session.perform(EditIntent(action: .removeBackground, background: .transparent)) }
                actionChip(L("Blur background"), symbol: "camera.aperture") { session.perform(EditIntent(action: .blurBackground, amount: .absolute(blur))) }
            }
            ParameterSlider(title: L("Blur amount"), value: $blur, range: 0.1...1, bipolar: false)
            Text(L("Background colour")).font(PSFont.caption(12)).foregroundStyle(PSTheme.textSecondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(colors, id: \.self) { color in
                        Button {
                            Haptics.tick()
                            session.perform(EditIntent(action: .replaceBackground, color: color, background: .color(color)))
                        } label: {
                            Circle().fill(Color(cgColor: color.cgColor)).frame(width: 34, height: 34)
                                .overlay(Circle().stroke(PSTheme.hairline, lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(color.hexString)
                    }
                    Button {
                        session.perform(EditIntent(action: .replaceBackground, background: .gradient(PSColor(hex: "#1F2A4D")!, PSColor(hex: "#8A56C6")!)))
                    } label: {
                        Circle().fill(LinearGradient(colors: [Color(red: 0.12, green: 0.16, blue: 0.3), Color(red: 0.54, green: 0.34, blue: 0.78)], startPoint: .top, endPoint: .bottom)).frame(width: 34, height: 34)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L("Gradient"))
                }
            }
        }
    }

    private func actionChip(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button { Haptics.tap(); action() } label: {
            Label(title, systemImage: symbol).font(PSFont.caption(13)).padding(.horizontal, 12).padding(.vertical, 9).frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain).foregroundStyle(PSTheme.textPrimary).psGlass(interactive: true)
    }
}

// MARK: - Crop

struct CropPanel: View {
    @Bindable var session: PhotoEditorSession
    @State private var straighten: Double = 0
    private let presets: [AspectPreset] = [.original, .square, .ratio4x5, .ratio9x16, .ratio3x4, .ratio4x3, .ratio16x9, .ratio3x2, .ratio21x9]

    var body: some View {
        VStack(spacing: 12) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(presets) { preset in
                        Button { session.crop(to: preset) } label: {
                            Text(preset.displayName).font(PSFont.caption(13)).padding(.horizontal, 12).padding(.vertical, 8)
                        }
                        .buttonStyle(.plain).foregroundStyle(PSTheme.textPrimary).psGlass(interactive: true)
                    }
                }
            }
            ParameterSlider(title: L("Straighten"), value: $straighten, range: -15...15, bipolar: true) { editing in
                if !editing, straighten != 0 {
                    session.apply(.straighten(degrees: straighten), label: L("Straighten"))
                    straighten = 0
                }
            }
            HStack(spacing: 8) {
                actionChip(L("Rotate"), symbol: "rotate.right") { session.apply(.rotate(degrees: 90)) }
                actionChip(L("Flip"), symbol: "arrow.left.and.right.righttriangle.left.righttriangle.right") { session.apply(.flip(.horizontal)) }
                actionChip(L("Auto level"), symbol: "level") { session.perform(EditIntent(action: .straighten)) }
            }
        }
    }

    private func actionChip(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button { Haptics.tap(); action() } label: {
            Label(title, systemImage: symbol).font(PSFont.caption(12)).padding(.horizontal, 10).padding(.vertical, 9).frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain).foregroundStyle(PSTheme.textPrimary).psGlass(interactive: true)
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
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                TextField(L("Type or say “add text …”"), text: $draft)
                    .textFieldStyle(.plain)
                    .font(PSFont.body(15))
                    .foregroundStyle(PSTheme.textPrimary)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(PSTheme.hairline, in: Capsule())
                    .focused($focused)
                    .submitLabel(.done)
                    .onSubmit(commit)
                Button(action: commit) { Image(systemName: "plus").font(.system(size: 15, weight: .bold)).frame(width: 38, height: 38) }
                    .buttonStyle(.plain).foregroundStyle(.black).psGlass(tint: PSTheme.accent, interactive: true, shape: AnyShape(Circle()))
                    .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if let layer = selectedTextLayer, let element = layer.textElement {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(TextRasterizer.fontChoices, id: \.name) { font in
                            Button { session.updateText(layerID: layer.id) { $0.fontName = font.name } } label: {
                                Text(font.display).font(PSFont.caption(12)).padding(.horizontal, 10).padding(.vertical, 7)
                            }
                            .buttonStyle(.plain).foregroundStyle(element.fontName == font.name ? .black : PSTheme.textPrimary)
                            .psGlass(tint: element.fontName == font.name ? PSTheme.accent : nil, interactive: true)
                        }
                    }
                }
                HStack(spacing: 10) {
                    ForEach(colors, id: \.self) { color in
                        Button { session.updateText(layerID: layer.id) { $0.color = color } } label: {
                            Circle().fill(Color(cgColor: color.cgColor)).frame(width: 26, height: 26)
                                .overlay(Circle().stroke(element.color == color ? PSTheme.accent : PSTheme.hairline, lineWidth: 2))
                        }.buttonStyle(.plain)
                    }
                    Spacer()
                    Picker(L("Style"), selection: Binding(get: { element.style }, set: { style in session.updateText(layerID: layer.id) { $0.style = style } })) {
                        ForEach(TextElement.Style.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                    }
                    .pickerStyle(.menu).tint(PSTheme.textPrimary)
                }
                HStack {
                    ParameterSlider(title: L("Size"), value: Binding(get: { element.relativeSize }, set: { size in session.updateText(layerID: layer.id) { $0.relativeSize = size } }), range: 0.02...0.25, bipolar: false)
                    Button(role: .destructive) { session.removeLayer(layer.id) } label: { Image(systemName: "trash").frame(width: 38, height: 38) }
                        .buttonStyle(.plain).foregroundStyle(PSTheme.danger).psGlass(interactive: true, shape: AnyShape(Circle()))
                }
                Text(L("Drag the text on the canvas to move it, or say “put the text at the top”."))
                    .font(PSFont.caption(11)).foregroundStyle(PSTheme.textSecondary)
            }
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

struct LayersPanel: View {
    @Bindable var session: PhotoEditorSession

    var body: some View {
        VStack(spacing: 8) {
            ForEach(Array(session.document.layers.enumerated().reversed()), id: \.element.id) { index, layer in
                let selected = session.document.selectedLayerID == layer.id
                HStack(spacing: 10) {
                    Image(systemName: layer.symbolName).frame(width: 24)
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
                .padding(.horizontal, 12).padding(.vertical, 10)
                .background(selected ? PSTheme.accent : PSTheme.hairline, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .contentShape(Rectangle())
                .onTapGesture { Haptics.tick(); session.selectLayer(layer.id) }
            }
            if let selected = session.document.selectedLayer, session.document.index(of: selected.id) != 0 {
                HStack {
                    ParameterSlider(title: L("Opacity"), value: Binding(get: { selected.opacity }, set: { value in session.updateLayer(selected.id) { $0.opacity = value } }), range: 0...1, bipolar: false)
                    Picker(L("Blend"), selection: Binding(get: { selected.blendMode }, set: { mode in session.updateLayer(selected.id) { $0.blendMode = mode } })) {
                        ForEach(BlendMode.allCases) { Text($0.displayName).tag($0) }
                    }
                    .pickerStyle(.menu).tint(PSTheme.textPrimary)
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
            .navigationTitle(L("Export"))
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(L("Done")) { dismiss() } } }
            .onAppear { format = app?.settings.photoExportFormat ?? .heic }
        }
        .preferredColorScheme(.dark)
        .presentationDetents([.medium, .large])
    }
}
#endif
