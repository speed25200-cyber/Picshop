#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import PicshopCore
import PicshopImaging

/// Sélectionner et masquer (W2, v1): the selection's edge refined by « Rayon » (the guided filter), « Lisser »,
/// « Contour progressif », « Contraste », « Décaler le contour » and « Décontaminer les couleurs », seen live on the
/// canvas (`renderer.refinePreview`) in one of five views. OK keeps the refined selection (one step) or makes a
/// local mask of it. The sheet stays half height so the picture stays in view.
struct SelectAndMaskSheet: View {
    @Bindable var session: PhotoEditorSession

    var body: some View {
        if let refine = session.selectionState.refine {
            ScrollView {
                VStack(alignment: .leading, spacing: PSSpacing.medium) {
                    header
                    views(refine)
                    sliders(refine)
                    Picker(selection: Binding(get: { refine.output }, set: { output in session.updateRefine { $0.output = output } })) {
                        ForEach(RefineEditing.Output.allCases) { output in
                            Text(output.title).tag(output)
                        }
                    } label: {
                        Text(L("Output"))
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("select.refine.output.\(refine.output.rawValue)")
                    if refine.refinement != SelectionRefinement() {
                        HStack {
                            Spacer(minLength: 0)
                            PanelChip(title: L("Reset"), symbol: "arrow.counterclockwise") {
                                session.updateRefine { $0.refinement = SelectionRefinement() }
                            }
                        }
                    }
                }
                .padding(PSSpacing.panel)
            }
            .scrollBounceBehavior(.basedOnSize)
            .presentationDetents([.fraction(0.5), .large])
            .presentationBackgroundInteraction(.enabled(upThrough: .fraction(0.5)))
            .presentationDragIndicator(.visible)
            .presentationBackground(Color.psElevated)
        }
    }

    private var header: some View {
        HStack(spacing: PSSpacing.small) {
            PanelChip(title: L("Cancel")) { session.closeSelectAndMask() }
            Spacer(minLength: PSSpacing.small)
            Text(L("Select and mask"))
                .font(.headline)
                .foregroundStyle(Color.psTextPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: PSSpacing.small)
            PanelActionButton(title: L("OK"), symbol: "checkmark") { session.applySelectAndMask() }
                .disabled(session.document.selection == nil)
        }
    }

    /// Superposition, Sur noir, Sur blanc, Noir et blanc, Contour.
    private func views(_ refine: RefineEditing) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: PSSpacing.small) {
                ForEach(RefineEditing.ViewMode.allCases) { mode in
                    PanelChip(title: mode.title, isActive: refine.view == mode) {
                        session.updateRefine { $0.view = mode }
                    }
                    .accessibilityIdentifier("select.refine.view.\(mode.rawValue)")
                }
            }
            .padding(.horizontal, 2)
        }
    }

    @ViewBuilder
    private func sliders(_ refine: RefineEditing) -> some View {
        let r = refine.refinement
        VStack(spacing: PSSpacing.xSmall) {
            row(L("Radius"), r.radius, 0...1, neutral: 0.25, id: "radius") { $0.radius = $1 }
            row(L("Smooth"), r.smooth, 0...1, id: "smooth") { $0.smooth = $1 }
            row(L("Feather"), r.feather, 0...1, id: "feather") { $0.feather = $1 }
            row(L("Contrast"), r.contrast, 0...1, id: "contrast") { $0.contrast = $1 }
            row(L("Shift edge"), r.shiftEdge, -1...1, id: "shiftEdge", signed: true) { $0.shiftEdge = $1 }
            row(L("Decontaminate colours"), r.decontaminate, 0...1, id: "decontaminate") { $0.decontaminate = $1 }
        }
    }

    /// One slider: the preview follows the finger at the interactive rate, then settles once on release.
    private func row(_ label: String, _ value: Double, _ range: ClosedRange<Double>, neutral: Double = 0, id: String,
                     signed: Bool = false, set: @escaping (inout SelectionRefinement, Double) -> Void) -> some View {
        InspectorSliderRow(label: label, value: value, range: range, neutral: neutral,
                           controlID: "select.refine.\(id)",
                           format: { value in
                               let percent = Int((value * 100).rounded())
                               return signed && percent > 0 ? "+\(percent)" : "\(percent)"
                           },
                           onChange: { next in session.updateRefine({ set(&$0.refinement, next) }, interactive: true) },
                           onEnd: { session.requestPreview() })
    }
}
#endif
