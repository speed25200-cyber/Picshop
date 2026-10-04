#if canImport(SwiftUI) && canImport(CoreImage) && canImport(UIKit)
import SwiftUI
import UIKit
import PicshopCore
import PicshopImaging

// Exporter (W3, D16): the sheet opens on a preset (the `exportPreset:` effect a voice export or a recipe emits, decoded
// as Core's `ExportPreset`), the file is written off the main actor with a progress bar and « Annuler », and JPEG, HEIC,
// PNG and TIFF go to Photos as before while PDF and PSD, which Photos refuses, go to Files or the share sheet; their
// temporary file goes when the sheet closes or Files took it. The PSD's size is estimated before anything renders
// (`ExportBudget.psdBytesEstimate`), so a file over Photoshop's 2 GB limit is never started.
extension PhotoEditorSession {
    // MARK: - Opening the sheet

    /// The sheet with every field from `preset` (nil: the remembered choices).
    func presentExport(preset: ExportPreset?) {
        exportPreset = preset
        if !showsExport { showsExport = true }
    }

    /// The `exportPreset:<json>` effect; a preset that does not decode opens the sheet on the remembered choices.
    func presentExport(presetJSON json: String) {
        let preset = json.data(using: .utf8).flatMap { try? JSONDecoder().decode(ExportPreset.self, from: $0) }
        if preset == nil { PSLog.error("export preset did not decode", category: .ui) }
        presentExport(preset: preset)
    }

    /// The formats the sheet offers (D16, D24): the Photos formats, TIFF and PDF behind `proExport`, PSD behind
    /// `psdExport` as well.
    var exportFormats: [ExportOptions.Format] {
        var formats: [ExportOptions.Format] = [.jpeg, .heic, .png]
        if FeatureFlags.isOn(.proExport) {
            formats.append(.tiff)
            formats.append(.pdf)
            if FeatureFlags.isOn(.psdExport) { formats.append(.psd) }
        }
        return formats
    }

    /// The canvas an export writes (the base's size when the canvas is not set).
    var exportCanvas: PSSize {
        let canvas = document.canvasSize
        if canvas.width > 0, canvas.height > 0 { return canvas }
        return document.baseLayer?.imageAsset?.pixelSize ?? PSSize(width: 1, height: 1)
    }

    /// The output's pixel size (« 1080 × 1350 » for Instagram on a 4:5 photo).
    func exportPixelSize(_ options: ExportOptions) -> (width: Int, height: Int) {
        let output = options.outputSize(canvas: exportCanvas)
        return (max(1, Int(output.width.rounded())), max(1, Int(output.height.rounded())))
    }

    // MARK: - The PSD estimate (D16a)

    /// An upper bound of the PSD's size: the composite and every layer's bounds, at the output's depth.
    func psdEstimatedBytes(_ options: ExportOptions) -> Int {
        let size = exportPixelSize(options)
        let pixels = options.layered ? Self.psdLayerPixels(document, canvas: exportCanvas, width: size.width, height: size.height) : size.width * size.height
        return ExportBudget.psdBytesEstimate(width: size.width, height: size.height, depth: options.effectiveBitDepth, layerPixels: pixels)
    }

    /// Over Photoshop's limits (2 GB, 30,000 px a side): « Trop lourd pour un PSD ».
    func psdIsTooHeavy(_ options: ExportOptions) -> Bool {
        let size = exportPixelSize(options)
        return max(size.width, size.height) > PSDWriter.maxSide || psdEstimatedBytes(options) > PSDWriter.maxBytes
    }

    /// The pixels the layers' records hold, at most: each image or shape layer's placed bounds on the canvas, the whole
    /// canvas for the base, fills, adjustments, groups and text (whose size is known only once drawn).
    static func psdLayerPixels(_ document: PhotoDocument, canvas: PSSize, width: Int, height: Int) -> Int {
        let full = width * height
        var total = 0
        for layer in document.layers {
            guard layer.id != document.baseLayerID, let size = LayerPlacement.contentSize(of: layer, canvasSize: canvas) else {
                total += full
                continue
            }
            switch layer.content {
            case .image, .shape:
                let box = LayerPlacement.bounds(for: layer, contentSize: size, canvasSize: canvas, isBase: false).intersection(.unit)
                guard box.width > 0, box.height > 0 else { continue }
                total += Int((box.width * Double(width)).rounded(.up) * (box.height * Double(height)).rounded(.up))
            case .text, .fill, .gradientFill, .adjustment, .group, .unsupported:
                total += full
            }
        }
        return total
    }

    // MARK: - Writing the file

    /// Writes the file off the main actor with its progress (0…1), then saves it to Photos when asked and the format
    /// allows it. PDF and PSD stay as `exportedURL` for Files or the share sheet. True once written.
    @discardableResult
    func runExport(options: ExportOptions) async -> Bool {
        guard let renderer, exportProgress == nil else { return false }
        if interaction != nil { endInteraction() }
        exportProgress = 0.02
        defer {
            exportProgress = nil
            exportTask = nil
        }
        let document = self.document
        let source = exportSourceURL
        let progress: @Sendable (Double) -> Void = { [weak self] value in
            Task { @MainActor in self?.noteExportProgress(value) }
        }
        let task = Task.detached(priority: .userInitiated) {
            try await PhotoExporter.export(document, renderer: renderer, options: options, source: source, progress: progress)
        }
        exportTask = task
        do {
            let url = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            discardExportedFile()
            exportedURL = url
            Haptics.success()
            if options.format.canSaveToPhotos {
                showToast(options.saveToPhotos ? L("Saved to Photos") : L("Exported"))
            }
            return true
        } catch {
            if error is CancellationError || task.isCancelled {
                Haptics.tick()
                showToast(L("Export cancelled."))
                return false
            }
            Haptics.error()
            showToast(Self.exportMessage(for: error), isError: true)
            return false
        }
    }

    /// The bar moves forward only, by whole percents (the strips report far more often than it needs).
    private func noteExportProgress(_ value: Double) {
        guard let current = exportProgress, value.isFinite else { return }
        let next = min(0.99, max(current, value))
        if next - current >= 0.01 { exportProgress = next }
    }

    /// « Annuler » under the progress bar: the strips stop and the partial file is removed.
    func cancelExport() {
        exportTask?.cancel()
    }

    /// The temporary PDF or PSD goes when the sheet closes or Files took it (D16).
    func discardExportedFile() {
        guard let url = exportedURL else { return }
        exportedURL = nil
        let path = url.path
        guard path.hasPrefix(FileManager.default.temporaryDirectory.path) else { return }
        Task.detached(priority: .utility) { try? FileManager.default.removeItem(atPath: path) }
    }

    /// Files moved the file away (`fileMover`): nothing left to delete.
    func exportedFileWasMoved(_ result: Result<URL, Error>) {
        switch result {
        case .success:
            exportedURL = nil
            Haptics.success()
            showToast(L("Saved to Files"))
        case .failure(let error):
            // The person cancelled the picker: the file stays for the share sheet until the sheet closes.
            if (error as NSError).code != NSUserCancelledError {
                showToast(error.localizedDescription, isError: true)
            }
        }
    }

    /// The export's failure in words (the PSD limits read like the sheet's own lines).
    static func exportMessage(for error: Error) -> String {
        if let psd = error as? PSDError {
            switch psd {
            case .tooLarge: return L("Too large for a PSD.")
            case .tooHeavy: return L("Too heavy for a PSD.")
            case .io(let reason) where reason == "space": return L("Not enough free space for this PSD.")
            case .unsupportedDepth, .badRow, .io: return L("The PSD couldn't be written.")
            }
        }
        return (error as? PicshopError)?.message ?? error.localizedDescription
    }

    /// The preset's name as the sheet shows it (« Instagram »).
    static func presetTitle(_ name: String?) -> String? {
        switch name {
        case "instagram"?: return "Instagram"
        case "print"?: return L("Print")
        case "web"?: return L("Web")
        case let other?: return other.isEmpty ? nil : other
        case nil: return nil
        }
    }
}
#endif
