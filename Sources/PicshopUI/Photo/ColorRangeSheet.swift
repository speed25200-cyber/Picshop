#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import PicshopCore
import PicshopImaging

/// Color Range (W2), for a selection or a local mask: the eyedropper (+ adds the tapped colour, − removes the
/// nearest sample) builds a list of up to 8 samples, « Tolérance » widens them, presets pick a colour family, skin
/// tones or a tonal band. The preview shows on the canvas while the sheet is open (the sheet stays half height so
/// the picture can be tapped). OK makes the selection or the mask.
struct ColorRangeSheet: View {
    @Bindable var session: PhotoEditorSession

    var body: some View {
        if let editing = session.selectionState.colorRange {
            let tool = editing.target == .selection ? "select" : "masks"
            VStack(alignment: .leading, spacing: PSSpacing.medium) {
                HStack(spacing: PSSpacing.small) {
                    PanelChip(title: L("Cancel")) { session.closeColorRange() }
                    Spacer(minLength: PSSpacing.small)
                    Text(L("Colour range"))
                        .font(.headline)
                        .foregroundStyle(Color.psTextPrimary)
                        .accessibilityAddTraits(.isHeader)
                    Spacer(minLength: PSSpacing.small)
                    PanelActionButton(title: L("OK"), symbol: "checkmark") { session.applyColorRange() }
                        .disabled(editing.component == nil)
                }
                HStack(spacing: PSSpacing.small) {
                    PanelChip(title: L("Add colour"), symbol: "eyedropper.full", isActive: editing.addsSamples) {
                        session.updateColorRange { $0.addsSamples = true }
                    }
                    .accessibilityIdentifier("\(tool).colorRange.sample.add")
                    PanelChip(title: L("Remove colour"), symbol: "eyedropper", isActive: !editing.addsSamples, isEnabled: !editing.samples.isEmpty) {
                        session.updateColorRange { $0.addsSamples = false }
                    }
                    .accessibilityIdentifier("\(tool).colorRange.sample.subtract")
                    Spacer(minLength: 0)
                }
                samples(editing, tool: tool)
                InspectorSliderRow(label: L("Tolerance"), value: editing.fuzziness, range: ColorRangeEditing.minimumFuzziness...1, neutral: 0.4,
                                   controlID: "\(tool).colorRange.fuzziness",
                                   format: { "\(Int(($0 * 100).rounded()))" },
                                   onChange: { value in session.updateColorRange({ $0.fuzziness = value }, interactive: true) },
                                   onEnd: { session.requestPreview() })
                presets(editing, tool: tool)
                HStack(spacing: PSSpacing.small) {
                    Text(L("Preview")).font(PSFontRole.inspectorLabel).foregroundStyle(Color.psTextSecondary)
                    Spacer(minLength: PSSpacing.small)
                    Menu {
                        ForEach(ColorRangeEditing.PreviewMode.allCases) { mode in
                            Button {
                                session.updateColorRange { $0.preview = mode }
                            } label: {
                                if mode == editing.preview { Label(mode.title, systemImage: "checkmark") } else { Text(mode.title) }
                            }
                            .accessibilityIdentifier("\(tool).\(mode.controlID)")
                        }
                    } label: {
                        Label(editing.preview.title, systemImage: "eye")
                            .font(.subheadline)
                            .foregroundStyle(Color.psTextPrimary)
                    }
                }
                Picker(selection: Binding(get: { editing.output }, set: { output in session.updateColorRange { $0.output = output } })) {
                    ForEach(ColorRangeEditing.Output.allCases) { output in
                        Text(output.title).tag(output)
                    }
                } label: {
                    Text(L("Output"))
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("\(tool).colorRange.output.\(editing.output.rawValue)")
                Text(editing.addsSamples ? L("Tap the picture to add its colour.") : L("Tap the picture to remove the closest colour."))
                    .font(.footnote)
                    .foregroundStyle(Color.psTextSecondary)
            }
            .padding(PSSpacing.panel)
            .presentationDetents([.fraction(0.5), .large])
            .presentationBackgroundInteraction(.enabled(upThrough: .fraction(0.5)))
            .presentationDragIndicator(.visible)
            .presentationBackground(Color.psElevated)
        }
    }

    /// The samples, each removable.
    @ViewBuilder
    private func samples(_ editing: ColorRangeEditing, tool: String) -> some View {
        if editing.samples.isEmpty {
            Text(L("No colour picked yet: tap the picture, or choose a preset."))
                .font(.footnote)
                .foregroundStyle(Color.psTextTertiary)
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: PSSpacing.small) {
                    ForEach(Array(editing.samples.enumerated()), id: \.offset) { index, sample in
                        let rgb = PhotoEditorSession.sRGB(of: sample)
                        Button {
                            Haptics.tap()
                            session.updateColorRange { if $0.samples.indices.contains(index) { $0.samples.remove(at: index) } }
                        } label: {
                            ZStack(alignment: .topTrailing) {
                                Circle()
                                    .fill(Color(.sRGB, red: rgb.r, green: rgb.g, blue: rgb.b, opacity: 1))
                                    .frame(width: 32, height: 32)
                                    .overlay(Circle().strokeBorder(Color.psStrokeStrong, lineWidth: 1))
                                Image(systemName: "xmark.circle.fill")
                                    .font(PSFont.glyph(.micro))
                                    .foregroundStyle(Color.psTextPrimary, Color.psOverlay)
                                    .offset(x: 4, y: -4)
                            }
                        }
                        .buttonStyle(PSPressStyle(scale: 0.9))
                        .accessibilityLabel(String(format: L("Remove colour %d"), index + 1))
                        .accessibilityIdentifier("\(tool).colorRange.sample.remove")
                    }
                    Text(String(format: L("%d of 8"), editing.samples.count))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(Color.psTextTertiary)
                }
                .padding(.horizontal, 2)
                .padding(.vertical, PSSpacing.xSmall)
            }
        }
    }

    private func presets(_ editing: ColorRangeEditing, tool: String) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: PSSpacing.small) {
                ForEach(ColorRangeEditing.Preset.allCases) { preset in
                    PanelChip(title: preset.title, isActive: editing.preset == preset) {
                        session.updateColorRange { editing in
                            editing.preset = editing.preset == preset ? nil : preset
                            // A tonal band stands alone: the colour samples do not mix with it.
                            if preset.luminance != nil, editing.preset != nil { editing.samples = [] }
                        }
                    }
                    .accessibilityIdentifier("\(tool).colorRange.preset.\(preset.rawValue)")
                }
            }
            .padding(.horizontal, 2)
        }
    }
}
#endif
