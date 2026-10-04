#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import CoreImage
import PicshopCore
import PicshopImaging

/// Export: format, quality, size, colour space, and what the file keeps of the
/// original (camera data and date always, the place unless removed, HDR in HEIC).
struct ExportSheet: View {
    @Bindable var session: PhotoEditorSession
    @Environment(\.dismiss) private var dismiss
    @Environment(\.picshop) private var app
    @State private var format: ExportOptions.Format = .heic
    @State private var quality: Double = 0.92
    @State private var fullResolution = true
    @State private var saveToPhotos = true
    @State private var colorSpace: ExportOptions.ColorSpaceChoice = .displayP3
    @State private var removesLocation = false
    @State private var previewImage: UIImage?
    /// What the original carries, read once off the main thread.
    @State private var source = SourceFacts()
    @Namespace private var formatIndicator

    struct SourceFacts: Equatable {
        var hasLocation = false
        var hasGainMap = false
    }

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

    private var options: ExportOptions {
        ExportOptions(format: format, quality: quality, maxLongestSide: fullResolution ? nil : 2048, saveToPhotos: saveToPhotos,
                      colorSpace: colorSpace, keepsLocation: !removesLocation, keepsHDR: true)
    }

    var body: some View {
        let exporting = session.exportProgress != nil
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
                        colorSpaceRow
                        if source.hasLocation {
                            Divider().overlay(PSTheme.hairline).padding(.leading, 16)
                            Toggle(isOn: $removesLocation) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(L("Remove location")).font(PSFont.headline(15))
                                    Text(L("The place the photo was taken stays out of the file and of Photos."))
                                        .font(PSFont.caption(12)).foregroundStyle(PSTheme.textSecondary)
                                }
                            }
                            .padding(.horizontal, 16).padding(.vertical, 12)
                        }
                        Divider().overlay(PSTheme.hairline).padding(.leading, 16)
                        Toggle(isOn: $saveToPhotos) {
                            Text(L("Save to Photos")).font(PSFont.headline(15))
                        }
                        .padding(.horizontal, 16).padding(.vertical, 12)
                    }
                    .psCard(cornerRadius: 18, shadow: false)
                    if source.hasGainMap {
                        Label(format == .heic ? L("HDR kept: as bright as the original in Photos.") : L("Choose HEIC to keep the HDR."), systemImage: "sun.max")
                            .font(PSFont.caption(12))
                            .foregroundStyle(PSTheme.textSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 4)
                    }
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
                    let options = self.options
                    rememberChoices()
                    Task {
                        // Done: the sheet goes, and 'Saved to Photos' shows over the photo.
                        if await session.export(options: options) {
                            dismiss()
                        }
                    }
                } label: {
                    if exporting {
                        HStack(spacing: 10) {
                            ProgressView().tint(.black)
                            Text(L("Exporting…"))
                        }
                        .frame(maxWidth: .infinity)
                    } else {
                        Label(saveToPhotos ? L("Save to Photos") : L("Export"), systemImage: saveToPhotos ? "photo.badge.arrow.down" : "square.and.arrow.down").frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(exporting)
                .padding(.horizontal, PSSpacing.page)
                .padding(.vertical, 10)
                .background(LinearGradient(colors: [PSTheme.ink.opacity(0), PSTheme.ink.opacity(0.9)], startPoint: .top, endPoint: .bottom).ignoresSafeArea())
            }
            .navigationTitle(L("Export"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(L("Done")) { dismiss() }.disabled(exporting) } }
            .onAppear {
                format = app?.settings.photoExportFormat ?? .heic
                colorSpace = app?.settings.photoExportColorSpace ?? .displayP3
                removesLocation = app?.settings.photoExportRemovesLocation ?? false
            }
            .task { await readSource() }
            .interactiveDismissDisabled(exporting)
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    /// Display P3 or sRGB, with what each is for.
    private var colorSpaceRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(L("Colour space")).font(PSFont.headline(15))
                Spacer()
                Text(colorSpace == .sRGB ? L("For the web") : L("Widest on iPhone")).font(PSFont.caption(12)).foregroundStyle(PSTheme.textSecondary)
            }
            Picker(L("Colour space"), selection: $colorSpace) {
                ForEach(ExportOptions.ColorSpaceChoice.allCases) { choice in
                    Text(verbatim: choice.displayName).tag(choice)
                }
            }
            .pickerStyle(.segmented)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    /// The next export starts from the same choices.
    private func rememberChoices() {
        guard let settings = app?.settings else { return }
        if settings.photoExportColorSpace != colorSpace { settings.photoExportColorSpace = colorSpace }
        if settings.photoExportRemovesLocation != removesLocation { settings.photoExportRemovesLocation = removesLocation }
    }

    /// Whether the original has a place and an HDR gain map, read off the main thread.
    private func readSource() async {
        guard let url = session.exportSourceURL else { return }
        let facts = await Task.detached(priority: .utility) { () -> SourceFacts in
            let metadata = PhotoMetadata.read(from: url)
            return SourceFacts(hasLocation: metadata.location != nil, hasGainMap: ImageSupport.hasHDRGainMap(at: url))
        }.value
        if source != facts { source = facts }
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
