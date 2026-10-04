#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import PicshopCore
import PicshopImaging

/// Masques (W2): Lightroom's masks on an iPhone. Empty, it offers what it found in the picture (« Détectés »),
/// gradients and ranges in one tap. With masks: « Nouveau masque », the list, the selected mask's parts (each in
/// add, subtract or intersect, inverted or not), its stack (feather, expand, density, invert), the canvas tool in
/// use (handles, brush, range editor, object pick) and what it does (MaskAdjustmentControls).
///
/// Masks act on the active image layer (W3: the selected image layer, else the background photo). Every control
/// carries its MaskPanelInventory id, and every change goes through the session's `applyLocalEdit` path, the one the
/// voice uses.
struct MasksPanel: View {
    @Bindable var session: PhotoEditorSession

    var body: some View {
        let state = session.maskState
        let masks = session.document.localAdjustments
        VStack(alignment: .leading, spacing: PSSpacing.medium) {
            // W3: masks act on the active image layer; on another layer than the photo the panel names it.
            if let target = session.masksTargetName {
                MaskCaption(text: String(format: L("On: %@"), target), symbol: "square.3.layers.3d")
            }
            if let working = state.aiWorking {
                AIMaskWorkingRow(session: session, region: working.region)
                    .transition(.opacity)
            }
            if let region = state.personPickerRegion {
                PersonPicker(session: session, region: region)
                    .transition(.opacity)
            }
            if masks.isEmpty, state.aiWorking == nil, state.editing == nil {
                MaskEmptyState(session: session)
            } else {
                HStack(spacing: PSSpacing.small) {
                    NewMaskMenu(session: session)
                    Spacer(minLength: PSSpacing.small)
                    if !masks.isEmpty {
                        Text(String(format: L("%d of 16"), masks.count))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(Color.psTextTertiary)
                    }
                }
                if !masks.isEmpty { MaskListView(session: session) }
                MaskEditingAccessory(session: session)
                if let caption = state.caption {
                    MaskCaption(text: caption, symbol: "sparkles")
                }
                if let adjustment = session.selectedMask {
                    MaskComponentsView(session: session, adjustment: adjustment)
                    if case .range(let componentID)? = state.editing,
                       let component = adjustment.stack.components.first(where: { $0.id == componentID }) {
                        RangeMaskControls(session: session, component: component)
                    }
                    MaskStackRows(session: session, adjustment: adjustment)
                    MaskAdjustmentControls(session: session, adjustment: adjustment)
                        .id(adjustment.id)
                }
            }
        }
        .animation(PSSpring.standard, value: state.aiWorking)
        .animation(PSSpring.standard, value: masks.count)
        .task(id: session.document.baseStateKey) { session.loadMaskSuggestions() }
    }
}

/// A one-line note under the list (approximate masks, the background photo).
struct MaskCaption: View {
    let text: String
    var symbol: String = "info.circle"

    var body: some View {
        Label(text, systemImage: symbol)
            .font(.footnote)
            .foregroundStyle(Color.psTextSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// While an AI mask computes: what it looks for, the working glyph, and ✕ to stop it. Shown at once.
private struct AIMaskWorkingRow: View {
    let session: PhotoEditorSession
    let region: MaskRegion

    var body: some View {
        HStack(spacing: PSSpacing.medium) {
            ProgressView().controlSize(.small).tint(Color.psTextSecondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(MaskAccessibility.regionName(region, language: psPrefersFrench ? .fr : .en))
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Color.psTextPrimary)
                Text(L("Making the mask…"))
                    .font(.caption2)
                    .foregroundStyle(Color.psTextTertiary)
            }
            Spacer(minLength: PSSpacing.small)
            MagicGlyph(size: PSGlyph.chip.rawValue)
            PanelRoundButton(symbol: "xmark", label: L("Stop")) { session.cancelAIMask() }
        }
        .padding(PSSpacing.small)
        .background(Color.psFillWell, in: RoundedRectangle(cornerRadius: PSRadius.tile, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// « Personne… »: the faces left to right; a tap makes the part of that person.
private struct PersonPicker: View {
    let session: PhotoEditorSession
    let region: MaskRegion

    var body: some View {
        let faces = session.maskState.personThumbnails
        let count = max(faces.count, session.maskState.suggestions.personCount)
        VStack(alignment: .leading, spacing: PSSpacing.small) {
            Text(L("Which person?"))
                .font(PSFontRole.inspectorLabel)
                .foregroundStyle(Color.psTextSecondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: PSSpacing.small) {
                    ForEach(0..<max(1, count), id: \.self) { index in
                        Button {
                            Haptics.tap()
                            session.choosePerson(index + 1)
                        } label: {
                            ZStack(alignment: .bottomTrailing) {
                                if index < faces.count {
                                    Image(decorative: faces[index], scale: 1).resizable().scaledToFill()
                                } else {
                                    Color.psFillControl
                                    Image(systemName: "person.fill").font(PSFont.glyph(.bar)).foregroundStyle(Color.psTextSecondary)
                                }
                                Text(verbatim: "\(index + 1)")
                                    .font(.caption2.weight(.bold))
                                    .foregroundStyle(Color.psOnAction)
                                    .padding(PSSpacing.xSmall)
                                    .background(Circle().fill(Color.psActionPrimary))
                                    .padding(PSSpacing.xSmall)
                            }
                            .frame(width: 56, height: 56)
                            .clipShape(RoundedRectangle(cornerRadius: PSRadius.thumb, style: .continuous))
                        }
                        .buttonStyle(PSPressStyle())
                        .accessibilityLabel(String(format: L("Person %d"), index + 1))
                        .accessibilityIdentifier("masks.new.person.index")
                    }
                    PanelChip(title: L("Cancel")) { session.maskState.personPickerRegion = nil }
                }
                .padding(.horizontal, 2)
            }
        }
    }
}

/// Empty Masques: « Détectés » (what the picture holds: Sujet, Ciel, Personnes with their faces, Arrière-plan),
/// « Dégradés » (Linéaire, Radial, Pinceau) and « Plages » (Couleur, Luminance, Profondeur), and every other kind
/// in « Nouveau masque ».
private struct MaskEmptyState: View {
    let session: PhotoEditorSession

    var body: some View {
        let suggestions = session.maskState.suggestions
        VStack(alignment: .leading, spacing: PSSpacing.medium) {
            group(L("Detected")) {
                MaskTile(title: L("Subject"), symbol: "person.crop.circle", controlID: "masks.new.subject") { session.addMask(.subject) }
                if suggestions.skyProbability > 0.3 {
                    MaskTile(title: L("Sky"), symbol: "cloud.sun", controlID: "masks.new.sky") { session.addMask(.sky) }
                }
                if suggestions.personCount > 0 {
                    MaskTile(title: L("People"), symbol: "person.2", faces: session.maskState.personThumbnails, controlID: "masks.new.people") {
                        session.addMask(.people)
                    }
                }
                MaskTile(title: L("Background"), symbol: "rectangle.dashed", controlID: "masks.new.background") { session.addMask(.background) }
            }
            group(L("Gradients")) {
                MaskTile(title: L("Linear"), symbol: "square.bottomhalf.filled", controlID: "masks.new.linear") { session.addMask(.top) }
                MaskTile(title: L("Radial"), symbol: "circle.circle", controlID: "masks.new.radial") { session.addMask(.center) }
                MaskTile(title: L("Brush"), symbol: "paintbrush.pointed", controlID: "masks.new.brush") { session.beginBrushMask() }
            }
            group(L("Ranges")) {
                MaskTile(title: L("Colour"), symbol: "eyedropper.halffull", controlID: "masks.new.colorRange") { session.addMask(.color) }
                MaskTile(title: L("Luminance"), symbol: "sun.max", controlID: "masks.new.luminanceRange") { session.addMask(.midtones) }
                MaskTile(title: L("Depth"), symbol: "square.3.layers.3d.down.right", controlID: "masks.new.depthRange") { session.addMask(.near) }
            }
            NewMaskMenu(session: session)
        }
    }

    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: PSSpacing.small) {
            Text(title)
                .font(PSFontRole.groupHeader)
                .textCase(.uppercase)
                .tracking(0.4)
                .foregroundStyle(Color.psTextSecondary)
                .accessibilityAddTraits(.isHeader)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: PSSpacing.small) { content() }
                    .padding(.horizontal, 2)
            }
        }
    }
}

/// A large tile of the empty state: a glyph (or up to four faces) and its name.
private struct MaskTile: View {
    let title: String
    let symbol: String
    var faces: [CGImage] = []
    let controlID: String
    let action: () -> Void

    var body: some View {
        Button {
            Haptics.tap()
            action()
        } label: {
            VStack(spacing: PSSpacing.xSmall) {
                if faces.isEmpty {
                    Image(systemName: symbol).font(PSFont.glyph(.tile)).foregroundStyle(Color.psTextPrimary)
                        .frame(height: 30)
                } else {
                    HStack(spacing: -8) {
                        ForEach(Array(faces.prefix(4).enumerated()), id: \.offset) { _, face in
                            Image(decorative: face, scale: 1).resizable().scaledToFill()
                                .frame(width: 24, height: 24)
                                .clipShape(Circle())
                                .overlay(Circle().strokeBorder(Color.psElevated, lineWidth: 1.5))
                        }
                    }
                    .frame(height: 30)
                }
                Text(title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Color.psTextSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(width: PSMetrics.toolTile, height: PSMetrics.toolTile)
            .background(Color.psFillControl, in: RoundedRectangle(cornerRadius: PSRadius.tile, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: PSRadius.tile, style: .continuous))
        }
        .buttonStyle(PSPressStyle())
        .accessibilityLabel(title)
        .accessibilityIdentifier(controlID)
    }
}

/// « Nouveau masque »: every source, in the inventory's order.
struct NewMaskMenu: View {
    let session: PhotoEditorSession

    var body: some View {
        Menu {
            MaskSourceMenuItems(session: session, idPrefix: "masks.new.") { region in
                if let region { session.addMask(region) } else { session.beginBrushMask() }
            } part: { region in
                session.choosePart(region, mode: nil)
            }
        } label: {
            Label(L("New mask"), systemImage: "plus")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.psOnAction)
                .padding(.horizontal, PSSpacing.large)
                .frame(minHeight: PanelChipStyle.height)
                .background(Capsule().fill(Color.psActionPrimary))
        }
        .disabled(!session.canAddMask)
        .accessibilityIdentifier("masks.new")
    }
}

/// The sources of a new mask or a new part. `choose(nil)` is the brush; people parts go through `part` (the face
/// picker when there are several people).
struct MaskSourceMenuItems: View {
    let session: PhotoEditorSession
    let idPrefix: String
    let choose: (MaskRegion?) -> Void
    let part: (MaskRegion) -> Void

    var body: some View {
        let suggestions = session.maskState.suggestions
        Button { choose(.subject) } label: { Label(L("Subject"), systemImage: "person.crop.circle") }
            .accessibilityIdentifier(idPrefix + "subject")
        Button { choose(.background) } label: { Label(L("Background"), systemImage: "rectangle.dashed") }
            .accessibilityIdentifier(idPrefix + "background")
        Button { choose(.sky) } label: { Label(L("Sky"), systemImage: "cloud.sun") }
            .accessibilityIdentifier(idPrefix + "sky")
        Button { choose(.people) } label: { Label(L("People"), systemImage: "person.2") }
            .accessibilityIdentifier(idPrefix + "people")
        Menu {
            Button { part(.person) } label: { Label(L("Whole person"), systemImage: "person") }
                .accessibilityIdentifier(idPrefix + "person")
            Button { part(.face) } label: { Label(L("Face"), systemImage: "face.smiling") }
                .accessibilityIdentifier(idPrefix + "face")
            Button { part(.faceSkin) } label: { Label(L("Face skin"), systemImage: "hand.raised") }
                .accessibilityIdentifier(idPrefix + "faceSkin")
            Button { part(.eyes) } label: { Label(L("Eyes"), systemImage: "eye") }
                .accessibilityIdentifier(idPrefix + "eyes")
            Button { part(.lips) } label: { Label(L("Lips"), systemImage: "mouth") }
                .accessibilityIdentifier(idPrefix + "lips")
            Button { part(.teeth) } label: { Label(L("Teeth"), systemImage: "mouth.fill") }
                .accessibilityIdentifier(idPrefix + "teeth")
            if suggestions.mattes.contains(.hair) {
                Button { part(.hair) } label: { Label(L("Hair"), systemImage: "comb") }
                    .accessibilityIdentifier(idPrefix + "hair")
            }
            if suggestions.mattes.contains(.bodySkin) {
                Button { part(.bodySkin) } label: { Label(L("Skin"), systemImage: "hand.wave") }
                    .accessibilityIdentifier(idPrefix + "bodySkin")
            }
        } label: {
            Label(L("Person"), systemImage: "person.crop.square")
        }
        Button { choose(.object) } label: { Label(L("Object (tap or frame)"), systemImage: "cube") }
            .accessibilityIdentifier(idPrefix + "object")
        Button { choose(.vegetation) } label: { Label(L("Vegetation"), systemImage: "leaf") }
            .accessibilityIdentifier(idPrefix + "vegetation")
        Button { choose(.water) } label: { Label(L("Water"), systemImage: "drop") }
            .accessibilityIdentifier(idPrefix + "water")
        Divider()
        Button { choose(.top) } label: { Label(L("Linear gradient"), systemImage: "square.bottomhalf.filled") }
            .accessibilityIdentifier(idPrefix + "linear")
        Button { choose(.center) } label: { Label(L("Radial gradient"), systemImage: "circle.circle") }
            .accessibilityIdentifier(idPrefix + "radial")
        Button { choose(nil) } label: { Label(L("Brush"), systemImage: "paintbrush.pointed") }
            .accessibilityIdentifier(idPrefix + "brush")
        Divider()
        Button { choose(.color) } label: { Label(L("Colour range…"), systemImage: "eyedropper.halffull") }
            .accessibilityIdentifier(idPrefix + "colorRange")
        Button { choose(.midtones) } label: { Label(L("Luminance range…"), systemImage: "sun.max") }
            .accessibilityIdentifier(idPrefix + "luminanceRange")
        Button { choose(.near) } label: { Label(L("Depth range…"), systemImage: "square.3.layers.3d.down.right") }
            .accessibilityIdentifier(idPrefix + "depthRange")
        Divider()
        Button { choose(.selection) } label: { Label(L("From the selection"), systemImage: "lasso") }
            .disabled(session.document.selection == nil)
            .accessibilityIdentifier(idPrefix + "selection")
    }
}

/// The canvas tool in use for the selected mask: the brush's settings, the object pick, the handles' hint.
private struct MaskEditingAccessory: View {
    let session: PhotoEditorSession

    var body: some View {
        switch session.maskState.editing {
        case .brush?:
            MaskBrushSettings(session: session)
        case .object?:
            HStack(spacing: PSSpacing.small) {
                MaskCaption(text: L("Tap the object, or draw a frame around it."), symbol: "hand.tap")
                PanelChip(title: L("Cancel")) {
                    session.maskState.editing = nil
                    session.maskState.caption = nil
                }
            }
        case .handles?:
            MaskCaption(text: L("Drag the handles on the photo. Two fingers pan."), symbol: "hand.draw")
        default:
            EmptyView()
        }
    }
}

/// The mask brush: size, feather and flow (per stroke), « Effacer », and Terminé to stop painting.
private struct MaskBrushSettings: View {
    let session: PhotoEditorSession

    var body: some View {
        let brush = session.maskState.brush
        VStack(spacing: PSSpacing.small) {
            HStack(spacing: PSSpacing.small) {
                PanelChip(title: L("Paint"), symbol: "paintbrush.pointed", isActive: !brush.erase) { session.maskState.brush.erase = false }
                    .accessibilityIdentifier("masks.brush.paint")
                PanelChip(title: L("Erase strokes"), symbol: "eraser", isActive: brush.erase) { session.maskState.brush.erase = true }
                    .accessibilityIdentifier("masks.brush.erase")
                Spacer(minLength: PSSpacing.small)
                PanelChip(title: L("Done"), symbol: "checkmark") { session.maskState.editing = nil }
            }
            DialSlider(value: Binding(get: { session.maskState.brush.size }, set: { session.maskState.brush.size = $0 }),
                       range: 0.005...0.2, neutral: 0.04, label: L("Size"), format: { "\(Int(($0 * 1000).rounded()))" }) { editing in
                session.showsBrushPreview = editing
            }
            .accessibilityIdentifier("masks.brush.size")
            InspectorSliderRow(label: L("Feather"), value: brush.feather, range: 0...1, neutral: 0.5, controlID: "masks.brush.feather",
                               format: { "\(Int(($0 * 100).rounded()))" },
                               onChange: { session.maskState.brush.feather = $0 })
            InspectorSliderRow(label: L("Flow"), value: brush.flow, range: 0.05...1, neutral: 1, controlID: "masks.brush.flow",
                               format: { "\(Int(($0 * 100).rounded())) %" },
                               onChange: { session.maskState.brush.flow = $0 })
        }
    }
}

/// The selected mask's parts: each with its kind, its mode (add, subtract, intersect), inverted or not, and a
/// bin; a tap opens it on the canvas (handles, brush, range editor, colour range). Then « + Ajouter »,
/// « − Soustraire », « ∩ Intersecter » with every source.
private struct MaskComponentsView: View {
    let session: PhotoEditorSession
    let adjustment: LocalAdjustment

    var body: some View {
        let components = adjustment.stack.components
        let editingID = session.maskState.editing.flatMap(PhotoEditorSession.editedComponent)
        VStack(alignment: .leading, spacing: PSSpacing.xSmall) {
            ForEach(Array(components.enumerated()), id: \.element.id) { index, component in
                row(component, isFirst: index == 0, isEditing: component.id == editingID)
            }
            HStack(spacing: PSSpacing.small) {
                addMenu(.add, title: L("Add"), symbol: "plus")
                addMenu(.subtract, title: L("Subtract"), symbol: "minus")
                addMenu(.intersect, title: L("Intersect"), symbol: "circle.circle")
            }
            .disabled(components.count >= MaskStack.maxComponents)
        }
    }

    private func row(_ component: MaskComponent, isFirst: Bool, isEditing: Bool) -> some View {
        HStack(spacing: PSSpacing.small) {
            Image(systemName: Self.symbol(component.kind))
                .font(PSFont.glyph(.micro))
                .foregroundStyle(isEditing ? Color.psValueAccent : Color.psTextSecondary)
                .frame(width: 24)
            Text(MaskAccessibility.componentName(component.kind, language: psPrefersFrench ? .fr : .en))
                .font(.subheadline)
                .foregroundStyle(Color.psTextPrimary)
                .lineLimit(1)
            Spacer(minLength: PSSpacing.xSmall)
            if !isFirst {
                Picker(selection: Binding(get: { component.mode }, set: { session.setComponentMode(component.id, $0) })) {
                    Image(systemName: "plus").tag(CombineMode.add).accessibilityLabel(L("Add"))
                    Image(systemName: "minus").tag(CombineMode.subtract).accessibilityLabel(L("Subtract"))
                    Image(systemName: "circle.circle").tag(CombineMode.intersect).accessibilityLabel(L("Intersect"))
                } label: {
                    EmptyView()
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 112)
                .accessibilityIdentifier("masks.component.mode.\(component.mode.rawValue)")
            }
            LayerRowButton(symbol: "circle.lefthalf.filled", enabled: true, tint: component.isInverted ? Color.psValueAccent : nil) {
                session.invertComponent(component.id, !component.isInverted)
            }
            .accessibilityLabel(component.isInverted ? L("Inverted") : L("Invert"))
            .accessibilityIdentifier("masks.component.invert")
            LayerRowButton(symbol: "trash", enabled: true, tint: Color.psDanger) { session.removeComponent(component.id) }
                .accessibilityLabel(L("Delete"))
                .accessibilityIdentifier("masks.component.delete")
        }
        .padding(.horizontal, PSSpacing.small)
        .frame(minHeight: PSMetrics.control)
        .background(isEditing ? Color.psFillPressed : Color.clear, in: RoundedRectangle(cornerRadius: PSRadius.thumb, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture { session.editComponent(component) }
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: Text(L("Edit part"))) { session.editComponent(component) }
    }

    private func addMenu(_ mode: CombineMode, title: String, symbol: String) -> some View {
        Menu {
            MaskSourceMenuItems(session: session, idPrefix: "masks.component.source.") { region in
                if let region { session.addComponent(region, mode: mode) } else { session.addBrushComponent(mode: mode) }
            } part: { region in
                session.choosePart(region, mode: mode)
            }
        } label: {
            Label(title, systemImage: symbol)
                .font(.subheadline)
                .foregroundStyle(Color.psTextPrimary)
                .padding(.horizontal, PSSpacing.medium)
                .frame(minHeight: PanelChipStyle.height)
                .background(Capsule().fill(Color.psFillControl))
        }
        .accessibilityIdentifier("masks.component.\(mode.rawValue)")
    }

    static func symbol(_ kind: MaskComponent.Kind) -> String {
        switch kind {
        case .raster(let raster):
            switch raster.origin {
            case .sky: return "cloud.sun"
            case .person, .people, .facePart, .matte: return "person.crop.circle"
            case .subject: return "person.crop.circle.badge.checkmark"
            case .object: return "cube"
            case .vegetation: return "leaf"
            case .water: return "drop"
            case .selection: return "lasso"
            case .brush: return "paintbrush.pointed"
            case .background: return "rectangle.dashed"
            case .depth, .imported: return "square.dashed"
            }
        case .brush: return "paintbrush.pointed"
        case .linear: return "square.bottomhalf.filled"
        case .radial: return "circle.circle"
        case .colorRange: return "eyedropper.halffull"
        case .luminanceRange: return "sun.max"
        case .depthRange: return "square.3.layers.3d.down.right"
        case .unsupported: return "questionmark.square.dashed"
        }
    }
}

/// The stack: Contour progressif, Étendre / Contracter, Densité, and Inverser.
private struct MaskStackRows: View {
    let session: PhotoEditorSession
    let adjustment: LocalAdjustment

    var body: some View {
        let stack = adjustment.stack
        VStack(spacing: 0) {
            InspectorSliderRow(label: L("Feather"), value: stack.feather, range: 0...1, neutral: 0, controlID: "masks.stack.feather",
                               format: { "\(Int(($0 * 100).rounded()))" },
                               onBegin: { session.beginMaskInteraction() }, onChange: { session.setMaskFeather($0) },
                               onEnd: { session.endMaskInteraction() })
            InspectorSliderRow(label: L("Expand / contract"), value: stack.expand, range: -1...1, neutral: 0, controlID: "masks.stack.expand",
                               format: { ValueRing.formatted($0) },
                               onBegin: { session.beginMaskInteraction() }, onChange: { session.setMaskExpand($0) },
                               onEnd: { session.endMaskInteraction() })
            InspectorSliderRow(label: L("Density"), value: stack.density, range: 0...1, neutral: 1, controlID: "masks.stack.density",
                               format: { "\(Int(($0 * 100).rounded())) %" },
                               onBegin: { session.beginMaskInteraction() }, onChange: { session.setMaskDensity($0) },
                               onEnd: { session.endMaskInteraction() })
            HStack {
                PanelChip(title: L("Invert"), symbol: "circle.lefthalf.filled", isActive: stack.isInverted) {
                    session.invertMask(adjustment.id)
                }
                .accessibilityIdentifier("masks.stack.invert")
                Spacer()
            }
            .padding(.top, PSSpacing.small)
        }
    }
}

/// The overlay menu (the panel's header): the six styles, « Aucune », the colour, and whether a drag shows it.
struct MaskOverlayMenu: View {
    let session: PhotoEditorSession

    private static let colors: [PSColor] = [PSColor(red: 1, green: 0.23, blue: 0.19), PSColor(red: 0.2, green: 0.85, blue: 0.4),
                                            PSColor(red: 0.25, green: 0.55, blue: 1), .white]

    var body: some View {
        let state = session.maskState
        Menu {
            ForEach(MaskOverlayStyle.allCases, id: \.self) { style in
                Button {
                    session.setMaskOverlay(style)
                } label: {
                    if state.isOverlayPinned, state.overlay == style {
                        Label(Self.title(style), systemImage: "checkmark")
                    } else {
                        Text(Self.title(style))
                    }
                }
                .accessibilityIdentifier("masks.overlay.\(style.rawValue)")
            }
            Button {
                session.setMaskOverlay(nil)
            } label: {
                if state.isOverlayPinned { Text(L("No overlay")) } else { Label(L("No overlay"), systemImage: "checkmark") }
            }
            .accessibilityIdentifier("masks.overlay.none")
            Divider()
            Menu {
                ForEach(Array(Self.colors.enumerated()), id: \.offset) { index, color in
                    Button {
                        session.setMaskOverlayColor(color)
                    } label: {
                        Text(Self.colorName(index))
                    }
                }
            } label: {
                Label(L("Overlay colour"), systemImage: "paintpalette")
            }
            .accessibilityIdentifier("masks.overlay.color")
            Toggle(L("Show while dragging"), isOn: Binding(get: { state.showsOverlayWhileDragging }, set: { state.showsOverlayWhileDragging = $0 }))
                .accessibilityIdentifier("masks.overlay.whileDragging")
        } label: {
            Image(systemName: state.isOverlayPinned ? "circle.lefthalf.striped.horizontal" : "circle.dashed")
                .font(PSFont.glyph(.chip))
                .foregroundStyle(Color.psTextPrimary)
                .frame(width: PanelChipStyle.height, height: PanelChipStyle.height)
                .background(Circle().fill(Color.psFillControl))
        }
        .accessibilityLabel(L("Mask overlay"))
    }

    static func title(_ style: MaskOverlayStyle) -> String {
        switch style {
        case .tint: return L("Colour")
        case .rubylith: return L("Rubylith")
        case .outline: return L("Outline")
        case .onBlack: return L("On black")
        case .onWhite: return L("On white")
        case .blackAndWhite: return L("Black & white")
        }
    }

    static func colorName(_ index: Int) -> String {
        switch index {
        case 0: return L("Red")
        case 1: return L("Green")
        case 2: return L("Blue")
        default: return L("White")
        }
    }
}
#endif
