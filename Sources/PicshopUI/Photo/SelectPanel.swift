#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import PicshopCore
import PicshopIntent
import PicshopImaging

/// Sélection (W2): one selection per document, made by subject, sky, object (tap or frame), Quick Selection, the
/// magic wand, the lasso or Color Range, combined as Nouvelle / Ajouter / Soustraire / Intersecter; then modified
/// (Inverser, Étendre…, Contracter…, Contour progressif…, Lisser…, Sélectionner et masquer…), used (« Utiliser la
/// sélection pour ») or dropped (Désélectionner). The marching ants show it in every tool.
struct SelectPanel: View {
    @Bindable var session: PhotoEditorSession

    var body: some View {
        let state = session.selectionState
        let hasSelection = session.document.selection != nil
        VStack(alignment: .leading, spacing: PSSpacing.medium) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: PSSpacing.small) {
                    ForEach(PhotoSelectionState.SelectMode.allCases) { mode in
                        IconChip(title: mode.title, symbol: mode.symbol, isActive: state.mode == mode,
                                 tint: mode == .subject || mode == .sky || mode == .object || mode == .quick ? PSTheme.voice : nil) {
                            choose(mode)
                        }
                        .accessibilityIdentifier(mode.controlID)
                    }
                    IconChip(title: L("Select all"), symbol: "rectangle.dashed") { session.selectAll() }
                        .accessibilityIdentifier("select.all")
                }
                .padding(.horizontal, 2)
            }
            modeAccessory(state)
            combineRow(state, hasSelection: hasSelection)
            if let request = state.modify {
                ModifyValueRow(session: session, request: request)
            } else if hasSelection {
                modifyRow
                HStack(spacing: PSSpacing.small) {
                    SelectionUseMenu(session: session)
                    Spacer(minLength: PSSpacing.small)
                    PanelChip(title: L("Deselect"), symbol: "xmark") { session.deselect() }
                        .accessibilityIdentifier("select.deselect")
                }
            }
            if state.isWorking {
                HStack(spacing: PSSpacing.small) {
                    ProgressView().controlSize(.small).tint(Color.psTextSecondary)
                    Text(L("Selecting…")).font(.footnote).foregroundStyle(Color.psTextSecondary)
                }
                .transition(.opacity)
            }
            if let caption = state.caption {
                MaskCaption(text: caption, symbol: "exclamationmark.triangle")
            }
        }
        .animation(PSSpring.quick, value: state.isWorking)
        .animation(PSSpring.quick, value: state.mode)
    }

    private func choose(_ mode: PhotoSelectionState.SelectMode) {
        let state = session.selectionState
        let again = state.mode == mode
        state.mode = mode
        state.boxDrag = nil
        session.lassoPoints = []
        // Subject and sky select on the tap of their button; Color Range opens its sheet.
        switch mode {
        case .subject: session.select(region: .subject)
        case .sky: session.select(region: .sky)
        case .colorRange: session.openColorRange(for: .selection)
        case .object, .quick, .wand, .lasso: if !again { Haptics.tick() }
        }
    }

    @ViewBuilder
    private func modeAccessory(_ state: PhotoSelectionState) -> some View {
        switch state.mode {
        case .subject, .sky:
            MaskCaption(text: L("Tap the button again, or the picture, to select it once more."), symbol: "hand.tap")
        case .object:
            MaskCaption(text: L("Tap the object, or draw a frame around it."), symbol: "hand.tap")
        case .quick:
            VStack(spacing: PSSpacing.small) {
                HStack(spacing: PSSpacing.small) {
                    PanelChip(title: L("Add"), symbol: "plus", isActive: !state.quickErase) { state.quickErase = false }
                    PanelChip(title: L("Erase strokes"), symbol: "eraser", isActive: state.quickErase) { state.quickErase = true }
                        .accessibilityIdentifier("select.quick.erase")
                    Spacer(minLength: 0)
                }
                DialSlider(value: Binding(get: { state.quickRadius }, set: { state.quickRadius = $0 }), range: 0.008...0.12, neutral: 0.035,
                           label: L("Size"), format: { "\(Int(($0 * 1000).rounded()))" }) { editing in
                    session.showsBrushPreview = editing
                }
                .accessibilityIdentifier("select.quick.size")
                MaskCaption(text: L("Paint over what to select."), symbol: "paintbrush.pointed")
            }
        case .wand:
            VStack(spacing: PSSpacing.small) {
                DialSlider(value: $session.wandTolerance, range: 0.02...0.8, neutral: 0.25, label: L("Tolerance"), format: { "\(Int(($0 * 100).rounded()))" })
                    .accessibilityIdentifier("select.wand.tolerance")
                HStack(spacing: PSSpacing.small) {
                    Picker(selection: Binding(get: { state.wandSampleSize }, set: { state.wandSampleSize = $0 })) {
                        Text(verbatim: "1 px").tag(1)
                        Text(verbatim: "3 × 3").tag(3)
                        Text(verbatim: "5 × 5").tag(5)
                    } label: {
                        Text(L("Sample size"))
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 200)
                    .accessibilityIdentifier("select.wand.sampleSize")
                    Toggle(L("Contiguous"), isOn: $session.wandContiguous)
                        .font(PSFont.caption(13))
                        .fixedSize()
                        .accessibilityIdentifier("select.wand.contiguous")
                }
            }
        case .lasso:
            HStack(spacing: PSSpacing.small) {
                MaskCaption(text: L("Draw around the area, or tap corner by corner."), symbol: "lasso")
                if session.lassoPoints.count >= 3 {
                    PanelChip(title: L("Close"), symbol: "checkmark", tint: PSTheme.accent) { session.lassoSelect(points: session.lassoPoints) }
                }
            }
        case .colorRange:
            HStack(spacing: PSSpacing.small) {
                PanelChip(title: L("Colour range…"), symbol: "eyedropper.halffull") { session.openColorRange(for: .selection) }
                    .accessibilityIdentifier("select.mode.colorRange")
                Spacer(minLength: 0)
            }
        }
    }

    /// Nouvelle / Ajouter / Soustraire / Intersecter.
    private func combineRow(_ state: PhotoSelectionState, hasSelection: Bool) -> some View {
        Picker(selection: Binding(get: { hasSelection ? (state.combine.map(Self.tag) ?? "new") : "new" },
                                  set: { value in session.setSelectionCombine(CombineMode(rawValue: value)) })) {
            Text(L("New")).tag("new")
            Text(L("Add")).tag("add")
            Text(L("Subtract")).tag("subtract")
            Text(L("Intersect")).tag("intersect")
        } label: {
            Text(L("Combine"))
        }
        .pickerStyle(.segmented)
        .disabled(!hasSelection)
        .accessibilityIdentifier("select.combine")
    }

    private static func tag(_ mode: CombineMode) -> String { mode.rawValue }

    private var modifyRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: PSSpacing.small) {
                PanelChip(title: L("Invert"), symbol: "circle.lefthalf.filled") { session.invertSelection() }
                    .accessibilityIdentifier("select.modify.invert")
                PanelChip(title: L("Expand…"), symbol: "arrow.up.left.and.arrow.down.right") {
                    session.selectionState.modify = .init(kind: .grow, value: 20)
                }
                .accessibilityIdentifier("select.modify.grow")
                PanelChip(title: L("Contract…"), symbol: "arrow.down.right.and.arrow.up.left") {
                    session.selectionState.modify = .init(kind: .shrink, value: 20)
                }
                .accessibilityIdentifier("select.modify.shrink")
                PanelChip(title: L("Feather…"), symbol: "circle.dotted") {
                    session.selectionState.modify = .init(kind: .feather, value: 10)
                }
                .accessibilityIdentifier("select.modify.feather")
                PanelChip(title: L("Smooth…"), symbol: "scribble") {
                    session.selectionState.modify = .init(kind: .smooth, value: 30)
                }
                .accessibilityIdentifier("select.modify.smooth")
                PanelChip(title: L("Select and mask…"), symbol: "wand.and.stars", tint: PSTheme.voice) { session.openSelectAndMask() }
                    .accessibilityIdentifier("select.refine")
            }
            .padding(.horizontal, 2)
        }
    }
}

/// The value of a Modify step (pixels at full resolution, or smoothness), then Appliquer or Annuler.
private struct ModifyValueRow: View {
    let session: PhotoEditorSession
    let request: PhotoSelectionState.ModifyRequest
    @State private var value: Double = 0

    var body: some View {
        let isSmooth = request.kind == .smooth
        VStack(spacing: PSSpacing.small) {
            DialSlider(value: $value, range: isSmooth ? 0...100 : 1...200, neutral: isSmooth ? 30 : 20, label: title,
                       units: 100, format: { isSmooth ? "\(Int($0.rounded()))" : "\(Int($0.rounded())) px" })
            HStack(spacing: PSSpacing.small) {
                Spacer(minLength: 0)
                PanelChip(title: L("Cancel")) { session.selectionState.modify = nil }
                PanelActionButton(title: L("Apply"), symbol: "checkmark") {
                    var applied = request
                    applied.value = value
                    session.applyModify(applied)
                }
            }
        }
        .onAppear { value = request.value }
    }

    private var title: String {
        switch request.kind {
        case .grow: return L("Expand by")
        case .shrink: return L("Contract by")
        case .feather: return L("Feather radius")
        case .smooth: return L("Smoothness")
        }
    }
}

/// The overlay inside Sélection (the panel's header): the ants with a 20 % tint, or another style.
struct SelectionOverlayMenu: View {
    let session: PhotoEditorSession

    var body: some View {
        let state = session.selectionState
        Menu {
            ForEach(MaskOverlayStyle.allCases, id: \.self) { style in
                Button {
                    state.overlay = style
                    session.requestPreview()
                } label: {
                    if state.overlay == style {
                        Label(style == .outline ? L("Marching ants") : MaskOverlayMenu.title(style), systemImage: "checkmark")
                    } else {
                        Text(style == .outline ? L("Marching ants") : MaskOverlayMenu.title(style))
                    }
                }
                .accessibilityIdentifier("select.overlay.\(style.rawValue)")
            }
        } label: {
            Image(systemName: "circle.dashed")
                .font(PSFont.glyph(.chip))
                .foregroundStyle(Color.psTextPrimary)
                .frame(width: PanelChipStyle.height, height: PanelChipStyle.height)
                .background(Circle().fill(Color.psFillControl))
        }
        .accessibilityLabel(L("Selection overlay"))
    }
}
#endif
