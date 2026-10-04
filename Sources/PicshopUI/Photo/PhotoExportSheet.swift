#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import CoreImage
import PicshopCore
import PicshopImaging

/// Export: format, depth, quality, size, colour space, and what the file keeps of the original (camera data and date
/// always, the place unless removed, HDR in HEIC).
///
/// W3 (D16, behind `proExport` / `psdExport`): JPEG, HEIC, PNG, TIFF, PDF and PSD in one strip; the depths the format
/// writes (« 8 bits », « 10 bits », « 16 bits »); sizes Originale, 4096, 2048, 1080; a preset (the `exportPreset:`
/// effect: Instagram, Impression, Web) sets every field, its `width(1080)` rule included (« 1080 × 1350 »). A PSD keeps
/// its layers and shows its estimated size, refused before anything renders past Photoshop's 2 GB. Photos takes
/// JPEG, HEIC, PNG and TIFF; PDF and PSD go to Files or the share sheet, and their temporary file goes once Files took
/// it or the sheet closes. A progress bar with « Annuler » while the file is written.
struct ExportSheet: View {
    @Bindable var session: PhotoEditorSession
    @Environment(\.dismiss) private var dismiss
    @Environment(\.picshop) private var app
    @State private var format: ExportOptions.Format = .heic
    @State private var quality: Double = 0.92
    @State private var bitDepth = 8
    @State private var size: ExportSizeRule = .full
    @State private var saveToPhotos = true
    @State private var colorSpace: ExportOptions.ColorSpaceChoice = .displayP3
    @State private var removesLocation = false
    @State private var keepsLayers = true
    @State private var resolution: Double?
    @State private var presetName: String?
    @State private var previewImage: UIImage?
    /// What the original carries, read once off the main thread.
    @State private var source = SourceFacts()
    /// A PDF or PSD written, waiting for Files (`fileMover`) or the share sheet.
    @State private var movesToFiles = false
    @State private var writtenFile: URL?
    @Namespace private var formatIndicator

    struct SourceFacts: Equatable {
        var hasLocation = false
        var hasGainMap = false
    }

    /// The sizes the menu offers (`PhotoPanelInventory.exportSizes`).
    private static let sizes: [ExportSizeRule] = PhotoPanelInventory.exportSizes.map { entry in entry.longSide.map { .longSide($0) } ?? .full }

    private var options: ExportOptions {
        ExportOptions(format: format, quality: quality, maxLongestSide: nil, saveToPhotos: format.canSaveToPhotos && saveToPhotos,
                      colorSpace: colorSpace, keepsLocation: !removesLocation, keepsHDR: true, bitDepth: bitDepth,
                      layered: keepsLayers, presetName: presetName, size: size, resolution: resolution)
    }

    private var exportSize: (width: Int, height: Int) { session.exportPixelSize(options) }

    /// Rough file size, so the choice between formats is informed: the PSD's upper bound from its layers (D16a).
    private var estimatedMegabytes: Double {
        if format == .psd { return Double(session.psdEstimatedBytes(options)) / 1_048_576 }
        let pixels = Double(exportSize.width * exportSize.height)
        let deep = Double(options.effectiveBitDepth) / 8
        let bitsPerPixel: Double
        switch format {
        case .png: bitsPerPixel = 12 * deep
        case .jpeg: bitsPerPixel = 1.2 + quality * 4
        case .heic: bitsPerPixel = (0.6 + quality * 2.2) * (options.effectiveBitDepth > 8 ? 1.3 : 1)
        case .tiff: bitsPerPixel = 14 * deep
        case .pdf: bitsPerPixel = 1.2 + 0.92 * 4
        case .psd: bitsPerPixel = 32
        }
        return pixels * bitsPerPixel / 8 / 1_048_576
    }

    private func subtitle(for format: ExportOptions.Format) -> String {
        switch format {
        case .heic: return L("Small, Apple")
        case .jpeg: return L("Universal")
        case .png: return L("Lossless")
        case .tiff: return L("Lossless, print")
        case .pdf: return L("One page")
        case .psd: return L("Layers")
        }
    }

    var body: some View {
        let exporting = session.exportProgress != nil
        NavigationStack {
            ScrollView {
                VStack(spacing: PSSpacing.large) {
                    preview
                    if let title = PhotoEditorSession.presetTitle(presetName) {
                        Label(String(format: L("Preset: %@"), title), systemImage: "wand.and.stars")
                            .font(PSFont.caption(13))
                            .foregroundStyle(PSTheme.textSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    formatPicker
                    settingsCard
                    destinationCard
                    if source.hasGainMap {
                        Label(format == .heic && bitDepth == 8 ? L("HDR kept: as bright as the original in Photos.") : L("Choose HEIC to keep the HDR."),
                              systemImage: "sun.max")
                            .font(PSFont.caption(12))
                            .foregroundStyle(PSTheme.textSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, PSSpacing.xSmall)
                    }
                    if let url = writtenFile ?? session.exportedURL {
                        ShareLink(item: url) { Label(L("Share"), systemImage: "square.and.arrow.up").frame(maxWidth: .infinity) }
                            .buttonStyle(SecondaryButtonStyle())
                            .accessibilityIdentifier("export.share")
                    }
                }
                .padding(.horizontal, PSSpacing.page)
                .padding(.top, PSSpacing.small)
                .padding(.bottom, 96)
                .animation(PSMotion.standard, value: format)
                .animation(PSMotion.quick, value: size)
            }
            .scrollIndicators(.hidden)
            .background(AmbientBackground().ignoresSafeArea())
            .safeAreaInset(edge: .bottom) { actionBar(exporting: exporting) }
            .navigationTitle(L("Export"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(L("Done")) { dismiss() }.disabled(exporting) } }
            .onAppear(perform: start)
            .onDisappear(perform: finish)
            .onChange(of: format) { _, new in
                // A depth the new format does not write falls back to 8 bits.
                if !new.supportedBitDepths.contains(bitDepth) { bitDepth = 8 }
                writtenFile = nil
            }
            .task { await readSource() }
            .interactiveDismissDisabled(exporting)
            .fileMover(isPresented: $movesToFiles, file: writtenFile) { result in
                session.exportedFileWasMoved(result)
                if case .success = result {
                    writtenFile = nil
                    dismiss()
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    // MARK: Settings

    /// Quality, depth, size, colour space, layers, background.
    private var settingsCard: some View {
        VStack(spacing: 0) {
            if format == .jpeg || format == .heic {
                VStack(spacing: PSSpacing.xSmall) {
                    HStack {
                        Text(L("Quality")).font(PSFont.caption(13)).foregroundStyle(PSTheme.textSecondary)
                        Spacer()
                        Text(verbatim: "\(Int(quality * 100))").font(PSFont.mono(12)).contentTransition(.numericText())
                    }
                    Slider(value: $quality, in: 0.5...1).tint(PSTheme.primary)
                }
                .padding(.horizontal, PSSpacing.large).padding(.vertical, PSSpacing.medium)
                .accessibilityIdentifier("export.quality")
                Divider().overlay(PSTheme.hairline).padding(.leading, PSSpacing.large)
            }
            if format.supportedBitDepths.count > 1 {
                VStack(alignment: .leading, spacing: PSSpacing.small) {
                    Text(L("Depth")).font(PSFont.headline(15))
                    Picker(L("Depth"), selection: $bitDepth) {
                        ForEach(format.supportedBitDepths, id: \.self) { depth in
                            Text(String(format: L("%d bits"), depth)).tag(depth)
                        }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("export.bitDepth")
                }
                .padding(.horizontal, PSSpacing.large).padding(.vertical, PSSpacing.medium)
                Divider().overlay(PSTheme.hairline).padding(.leading, PSSpacing.large)
            }
            sizeRow
            Divider().overlay(PSTheme.hairline).padding(.leading, PSSpacing.large)
            colorSpaceRow
            if format == .psd {
                Divider().overlay(PSTheme.hairline).padding(.leading, PSSpacing.large)
                Toggle(isOn: $keepsLayers) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L("Keep the layers")).font(PSFont.headline(15))
                        Text(L("Each layer stays editable in Photoshop.")).font(PSFont.caption(12)).foregroundStyle(PSTheme.textSecondary)
                    }
                }
                .padding(.horizontal, PSSpacing.large).padding(.vertical, PSSpacing.medium)
                .accessibilityIdentifier("export.layers")
            }
            Divider().overlay(PSTheme.hairline).padding(.leading, PSSpacing.large)
            Label(Self.keepsAlpha(format) ? L("Transparent background") : L("White background"),
                  systemImage: Self.keepsAlpha(format) ? "checkerboard.rectangle" : "rectangle.fill")
                .font(PSFont.caption(13))
                .foregroundStyle(PSTheme.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, PSSpacing.large).padding(.vertical, PSSpacing.medium)
        }
        .psCard(cornerRadius: PSRadius.card, shadow: false)
    }

    /// PNG, TIFF and PSD keep transparency; JPEG, HEIC and PDF are flattened on white (D14, D16).
    static func keepsAlpha(_ format: ExportOptions.Format) -> Bool {
        switch format {
        case .png, .tiff, .psd: return true
        case .jpeg, .heic, .pdf: return false
        }
    }

    /// Originale, 4096, 2048, 1080 (long side), or a preset's « 1080 px de large »; the pixel size and the estimate.
    private var sizeRow: some View {
        HStack(spacing: PSSpacing.small) {
            VStack(alignment: .leading, spacing: 2) {
                Text(L("Size")).font(PSFont.headline(15))
                Text(verbatim: "\(exportSize.width) × \(exportSize.height) · ~\(Self.megabytes(estimatedMegabytes))")
                    .font(PSFont.caption(12))
                    .foregroundStyle(PSTheme.textSecondary)
                    .contentTransition(.numericText())
            }
            Spacer(minLength: PSSpacing.small)
            Menu {
                ForEach(Self.sizes, id: \.self) { rule in
                    Button {
                        Haptics.tick()
                        size = rule
                    } label: {
                        if rule == size {
                            Label(Self.sizeTitle(rule), systemImage: "checkmark")
                        } else {
                            Text(Self.sizeTitle(rule))
                        }
                    }
                }
            } label: {
                HStack(spacing: PSSpacing.xSmall) {
                    Text(Self.sizeTitle(size)).font(PSFontRole.inspectorValue)
                    Image(systemName: "chevron.up.chevron.down").font(.caption2.weight(.semibold))
                }
                .foregroundStyle(Color.psTextPrimary)
                .padding(.horizontal, PSSpacing.medium)
                .frame(minHeight: PSMetrics.chip)
                .background(Capsule().fill(Color.psFillControl))
            }
            .accessibilityIdentifier("export.size")
        }
        .padding(.horizontal, PSSpacing.large).padding(.vertical, PSSpacing.medium)
    }

    static func sizeTitle(_ rule: ExportSizeRule) -> String {
        switch rule {
        case .full: return L("Original")
        case .longSide(let side): return "\(side) px"
        case .width(let width): return String(format: L("%d px wide"), width)
        }
    }

    static func megabytes(_ value: Double) -> String {
        value >= 1024 ? String(format: "%.1f GB", value / 1024) : String(format: "%.1f MB", value)
    }

    /// Display P3 or sRGB, with what each is for.
    private var colorSpaceRow: some View {
        VStack(alignment: .leading, spacing: PSSpacing.small) {
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
            .accessibilityIdentifier("export.colorSpace")
        }
        .padding(.horizontal, PSSpacing.large).padding(.vertical, PSSpacing.medium)
    }

    // MARK: Destination (D16)

    /// Photos for JPEG, HEIC, PNG and TIFF; PDF and PSD go to Files or the share sheet. The place and HDR as before.
    private var destinationCard: some View {
        VStack(spacing: 0) {
            if source.hasLocation {
                Toggle(isOn: $removesLocation) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L("Remove location")).font(PSFont.headline(15))
                        Text(L("The place the photo was taken stays out of the file and of Photos."))
                            .font(PSFont.caption(12)).foregroundStyle(PSTheme.textSecondary)
                    }
                }
                .padding(.horizontal, PSSpacing.large).padding(.vertical, PSSpacing.medium)
                .accessibilityIdentifier("export.location")
                Divider().overlay(PSTheme.hairline).padding(.leading, PSSpacing.large)
            }
            Toggle(isOn: Binding(get: { format.canSaveToPhotos && saveToPhotos }, set: { saveToPhotos = $0 })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("Save to Photos")).font(PSFont.headline(15))
                    if !format.canSaveToPhotos {
                        Text(L("Photos doesn't accept this format: save it to Files or share it."))
                            .font(PSFont.caption(12)).foregroundStyle(PSTheme.textSecondary)
                    }
                }
            }
            .disabled(!format.canSaveToPhotos)
            .padding(.horizontal, PSSpacing.large).padding(.vertical, PSSpacing.medium)
            .accessibilityIdentifier("export.save.photos")
        }
        .psCard(cornerRadius: PSRadius.card, shadow: false)
    }

    // MARK: Action

    @ViewBuilder
    private func actionBar(exporting: Bool) -> some View {
        VStack(spacing: PSSpacing.small) {
            if let progress = session.exportProgress {
                HStack(spacing: PSSpacing.medium) {
                    ProgressView(value: progress)
                        .tint(Color.psActionPrimary)
                        .animation(PSSpring.quick, value: progress)
                    Button(L("Cancel")) { session.cancelExport() }
                        .font(PSFont.headline(15))
                        .foregroundStyle(Color.psTextPrimary)
                        .accessibilityIdentifier("export.cancel")
                }
                .frame(minHeight: PSMetrics.control)
            } else if format == .psd, session.psdIsTooHeavy(options) {
                tooHeavy
            } else {
                Button(action: export) {
                    Label(actionTitle, systemImage: actionSymbol).frame(maxWidth: .infinity)
                }
                .buttonStyle(PrimaryButtonStyle())
                .accessibilityIdentifier(format.canSaveToPhotos ? "export.save.photos" : "export.save.files")
            }
        }
        .padding(.horizontal, PSSpacing.page)
        .padding(.vertical, PSSpacing.small)
        .background(LinearGradient(colors: [PSTheme.ink.opacity(0), PSTheme.ink.opacity(0.9)], startPoint: .top, endPoint: .bottom).ignoresSafeArea())
    }

    /// « Trop lourd pour un PSD », with the two ways out: 4096 on the long side, or 8 bits.
    private var tooHeavy: some View {
        VStack(spacing: PSSpacing.small) {
            Label(L("Too heavy for a PSD."), systemImage: "exclamationmark.triangle")
                .font(PSFont.headline(15))
                .foregroundStyle(Color.psWarning)
            HStack(spacing: PSSpacing.small) {
                Button(L("Size 4096")) {
                    Haptics.tick()
                    size = .longSide(4096)
                }
                .buttonStyle(SecondaryButtonStyle())
                if bitDepth > 8 {
                    Button(L("8 bits")) {
                        Haptics.tick()
                        bitDepth = 8
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }
            }
        }
    }

    private var actionTitle: String {
        if !format.canSaveToPhotos { return L("Save to Files") }
        return saveToPhotos ? L("Save to Photos") : L("Export")
    }

    private var actionSymbol: String {
        if !format.canSaveToPhotos { return "folder" }
        return saveToPhotos ? "photo.badge.arrow.down" : "square.and.arrow.down"
    }

    private func export() {
        Haptics.confirm()
        let options = self.options
        rememberChoices()
        Task {
            guard await session.export(options: options) else { return }
            if options.format.canSaveToPhotos {
                // Done: the sheet goes, and « Enregistré dans Photos » shows over the photo.
                dismiss()
            } else if let url = session.exportedURL {
                // PDF and PSD: Files takes the file (moved, never copied in memory); the share sheet stays offered.
                writtenFile = url
                movesToFiles = true
            }
        }
    }

    // MARK: Lifecycle

    /// The preset's every field, else the remembered choices.
    private func start() {
        if let preset = session.exportPreset {
            let options = ExportOptions(preset: preset)
            format = session.exportFormats.contains(options.format) ? options.format : .jpeg
            quality = options.quality
            bitDepth = options.effectiveBitDepth
            size = options.size ?? .full
            colorSpace = options.colorSpace
            removesLocation = !options.keepsLocation
            keepsLayers = options.layered
            resolution = options.resolution
            presetName = options.presetName
        } else {
            let remembered = app?.settings.photoExportFormat ?? .heic
            format = session.exportFormats.contains(remembered) ? remembered : .heic
            colorSpace = app?.settings.photoExportColorSpace ?? .displayP3
            removesLocation = app?.settings.photoExportRemovesLocation ?? false
        }
    }

    /// A PDF or PSD Files did not take goes with the sheet (D16).
    private func finish() {
        guard session.exportProgress == nil else { return }
        if let url = session.exportedURL, ["pdf", "psd"].contains(url.pathExtension.lowercased()) {
            session.discardExportedFile()
        }
        writtenFile = nil
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
        let shape = RoundedRectangle(cornerRadius: PSRadius.card, style: .continuous)
        return ZStack {
            if let previewImage {
                Image(uiImage: previewImage).resizable().scaledToFit()
            } else {
                PSTheme.surfaceElevated
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 180)
        .task {
            // Rasterised once for the sheet, off the main thread.
            guard previewImage == nil, let image = session.preview else { return }
            let rendered = await Task.detached(priority: .userInitiated) { () -> CGImage? in
                ImageSupport.cgImage(from: image.transformed(by: CGAffineTransform(scaleX: 0.5, y: 0.5)))
            }.value
            if let rendered { previewImage = UIImage(cgImage: rendered) }
        }
        .clipShape(shape)
        .overlay(shape.strokeBorder(PSTheme.strokeGradient, lineWidth: 1))
        .shadow(color: Color.psScrim, radius: 18, y: 10)
    }

    /// The six formats (the ones the flags allow), the selected one white with a black label.
    private var formatPicker: some View {
        let inner = RoundedRectangle(cornerRadius: PSRadius.thumb, style: .continuous)
        let outer = RoundedRectangle(cornerRadius: PSRadius.tile, style: .continuous)
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: PSSpacing.xSmall) {
                ForEach(session.exportFormats) { item in
                    let isActive = format == item
                    Button {
                        Haptics.tick()
                        withAnimation(PSMotion.standard) { format = item }
                    } label: {
                        VStack(spacing: 2) {
                            Text(item.displayName).font(PSFont.headline(14))
                            Text(subtitle(for: item)).font(PSFont.caption(10)).lineLimit(1)
                        }
                        .frame(minWidth: 64)
                        .padding(.horizontal, PSSpacing.small)
                        .padding(.vertical, 9)
                        .foregroundStyle(isActive ? Color.psOnAction : PSTheme.textSecondary)
                        .background {
                            if isActive {
                                inner.fill(Color.psActionPrimary)
                                    .matchedGeometryEffect(id: "format", in: formatIndicator)
                            }
                        }
                        .contentShape(inner)
                    }
                    .buttonStyle(PSPressStyle(scale: 0.97))
                    .accessibilityAddTraits(isActive ? [.isSelected] : [])
                    .accessibilityIdentifier("export.format.\(item.fileFormat.rawValue)")
                }
            }
            .padding(PSSpacing.xSmall)
        }
        .background(Color.psFillWell, in: outer)
        .overlay(outer.strokeBorder(Color.psHairline, lineWidth: 1))
    }
}
#endif
