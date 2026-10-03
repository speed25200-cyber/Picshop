#if canImport(SwiftUI) && canImport(UIKit) && canImport(CoreImage)
import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins
import Observation
import PicshopCore
import PicshopImaging

/// What the Curves and Levels panels and the histogram card show: the histogram
/// of the last settled frame, the clipping overlay, the channel being edited.
///
/// Histograms are counted off the main thread (HistogramComputer on the
/// background context), the latest request winning, and only while something
/// shows one: the card, or a Curves or Levels panel.
@MainActor
@Observable
final class PhotoToneState {
    /// What the histogram card draws; a tap cycles through them, the last one hides the card.
    enum CardMode: Equatable { case rgb, luma }

    /// The last settled frame's histogram; nil until one is computed.
    private(set) var histogram: Histogram?
    /// Red where highlights clip (a channel ≥ 254), blue where shadows clip (≤ 1), at 50 %;
    /// E4's canvas composes it over the picture. Nil unless `showsClipping`.
    private(set) var clippingOverlay: CIImage?
    /// The active layer before its Levels and curves: behind the Curves and Levels graphs, and what Auto reads.
    private(set) var inputHistogram: Histogram?
    /// The curve or levels channel being edited.
    var channel: ToneCurve.Channel = .rgb
    /// 'Montrer l'écrêtage' in Levels.
    var showsClipping = false {
        didSet {
            guard showsClipping != oldValue else { return }
            clippingOverlay = showsClipping ? lastSettled.flatMap(Self.clippingOverlay(for:)) : nil
        }
    }
    /// The histogram card at the top left of the canvas.
    var showsHistogramCard = false {
        didSet { if showsHistogramCard, !oldValue { computeIfNeeded() } }
    }
    var cardMode: CardMode = .rgb

    private let computer = HistogramComputer()
    @ObservationIgnored private var lastSettled: CIImage?
    @ObservationIgnored private var settledGeneration = 0
    @ObservationIgnored private var computedGeneration = -1
    @ObservationIgnored private var histogramTask: Task<Void, Never>?
    @ObservationIgnored private var openPanels = 0
    @ObservationIgnored private var lastInput: PhotoDocument?
    /// The input `inputHistogram` was counted from.
    @ObservationIgnored private var countedInput: PhotoDocument?
    @ObservationIgnored private var inputTask: Task<Void, Never>?

    init() {}

    /// Whether anything on screen reads a histogram.
    private var needsHistogram: Bool { showsHistogramCard || openPanels > 0 }

    /// Called by the render loop after each settled frame.
    func didSettle(_ image: CIImage) {
        lastSettled = image
        settledGeneration += 1
        if showsClipping { clippingOverlay = Self.clippingOverlay(for: image) }
        computeIfNeeded()
    }

    /// The card's tap: RGB, then luma, then hidden.
    func cycleCard() {
        switch cardMode {
        case .rgb: cardMode = .luma
        case .luma:
            cardMode = .rgb
            showsHistogramCard = false
        }
    }

    /// A Curves or Levels panel opened (they show the histograms) or closed.
    func panelDidAppear() {
        openPanels += 1
        computeIfNeeded()
    }

    func panelDidDisappear() {
        openPanels = max(0, openPanels - 1)
        if openPanels == 0 { showsClipping = false }
    }

    /// The settled frame's histogram, counted once per frame and only while something shows it.
    private func computeIfNeeded() {
        guard needsHistogram, computedGeneration != settledGeneration, let image = lastSettled else { return }
        let generation = settledGeneration
        computedGeneration = generation
        histogramTask?.cancel()
        let computer = self.computer
        histogramTask = Task { [weak self] in
            let result = await computer.histogram(of: image)
            guard let self, !Task.isCancelled, generation == self.settledGeneration else { return }
            if result != self.histogram { self.histogram = result }
        }
    }

    /// Recounts the input histogram when the picture under the tone table changed (an edit
    /// other than Levels or curves, another layer): a curve or levels drag costs nothing here.
    func refreshInputHistogram(document: PhotoDocument, renderer: PhotoRenderer?) {
        guard let renderer else { return }
        let input = HistogramComputer.toneInput(of: document)
        guard input != lastInput else { return }
        lastInput = input
        inputTask?.cancel()
        let computer = self.computer
        inputTask = Task { [weak self] in
            let result = await computer.toneInputHistogram(of: input, renderer: renderer)
            guard let self, !Task.isCancelled, self.lastInput == input else { return }
            self.countedInput = input
            if result != self.inputHistogram { self.inputHistogram = result }
        }
    }

    /// The input histogram now, counted if it is not yet (Auto needs it before it acts).
    func currentInputHistogram(document: PhotoDocument, renderer: PhotoRenderer) async -> Histogram? {
        let input = HistogramComputer.toneInput(of: document)
        if input == countedInput, let inputHistogram { return inputHistogram }
        let result = await computer.toneInputHistogram(of: input, renderer: renderer)
        if result != nil, lastInput == nil || lastInput == input {
            lastInput = input
            countedInput = input
            inputHistogram = result
        }
        return result
    }

    /// Red over clipped highlights, blue over crushed shadows, at half strength (gamma-encoded tests).
    static func clippingOverlay(for image: CIImage) -> CIImage? {
        let extent = image.extent
        guard !extent.isEmpty, !extent.isInfinite else { return nil }
        let encoded = CIFilter.linearToSRGBToneCurve()
        encoded.inputImage = image
        guard let values = encoded.outputImage else { return nil }
        // Highlights: the brightest channel at 254 or more.
        let brightest = CIFilter.maximumComponent()
        brightest.inputImage = values
        let highs = CIFilter.colorThreshold()
        highs.inputImage = brightest.outputImage
        highs.threshold = Float(253.5 / 255)
        // Shadows: the darkest channel at 1 or less (inverted, so the test is "above").
        let darkest = CIFilter.minimumComponent()
        darkest.inputImage = values
        let inverted = CIFilter.colorInvert()
        inverted.inputImage = darkest.outputImage
        let lows = CIFilter.colorThreshold()
        lows.inputImage = inverted.outputImage
        lows.threshold = Float(1 - 1.5 / 255)
        guard let highMask = highs.outputImage, let lowMask = lows.outputImage else { return nil }
        let clear = CIImage(color: .clear).cropped(to: extent)
        func tint(_ color: CIColor, _ mask: CIImage) -> CIImage {
            let blend = CIFilter.blendWithMask()
            blend.inputImage = CIImage(color: color).cropped(to: extent)
            blend.backgroundImage = clear
            blend.maskImage = mask.cropped(to: extent)
            return blend.outputImage ?? clear
        }
        let red = tint(CIColor(red: 1, green: 0.1, blue: 0.1, alpha: 0.5), highMask)
        let blue = tint(CIColor(red: 0.1, green: 0.4, blue: 1, alpha: 0.5), lowMask)
        return red.composited(over: blue).cropped(to: extent)
    }
}
#endif
