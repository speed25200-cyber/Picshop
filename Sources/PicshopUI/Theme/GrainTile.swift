#if canImport(SwiftUI) && canImport(UIKit) && canImport(CoreImage)
import SwiftUI
import CoreImage
import CoreImage.CIFilterBuiltins
import PicshopImaging

/// The backdrop's film grain: a 256-pixel tile of luminance noise made once
/// (CIRandomGenerator, desaturated) on the background context, then tiled as
/// a plain image. Static: nothing redraws it, so it is safe under glass and
/// costs nothing per frame. No shader in W1.
@MainActor
enum GrainTile {
    static let side = 256
    private static var cached: CGImage?
    private static var pending: Task<CGImage?, Never>?

    /// The tile, made on first use off the main thread and kept for the app's life.
    static func image() async -> CGImage? {
        if let cached { return cached }
        if let pending { return await pending.value }
        let side = Self.side
        let task = Task.detached(priority: .utility) { () -> CGImage? in
            Self.make(side: side)
        }
        pending = task
        let image = await task.value
        cached = image
        pending = nil
        return image
    }

    /// Already made (the view draws it straight away), else nil.
    static var ready: CGImage? { cached }

    /// Grey noise, one random value per pixel. Not main-actor: it runs detached.
    nonisolated static func make(side: Int) -> CGImage? {
        guard let noise = CIFilter.randomGenerator().outputImage else { return nil }
        let rect = CGRect(x: 0, y: 0, width: side, height: side)
        let mono = CIFilter.colorControls()
        mono.inputImage = noise.cropped(to: rect)
        mono.saturation = 0
        mono.contrast = 1
        guard let output = mono.outputImage?.cropped(to: rect) else { return nil }
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        return RenderContext.background.createCGImage(output, from: rect, format: .RGBA8, colorSpace: space)
    }
}

/// The grain tile over a view, at `amount` (3 % on the backdrop, 2.5 % on the calm style).
struct GrainLayer: View {
    var amount: Double = 0.03
    @State private var tile: CGImage? = GrainTile.ready

    var body: some View {
        ZStack {
            if let tile {
                // Scale 2: a grain pixel is half a point, fine but visible on every iPhone.
                Image(decorative: tile, scale: 2)
                    .resizable(resizingMode: .tile)
                    .opacity(amount)
                    .transition(.opacity)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .task {
            guard tile == nil else { return }
            tile = await GrainTile.image()
        }
    }
}
#endif
