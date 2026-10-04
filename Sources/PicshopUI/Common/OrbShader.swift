#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import Metal
import PicshopCore

/// The Metal orb (W2, D19): `psOrb` from App/Shaders/PSOrb.metal, compiled into the app's default library.
/// LiveOrb draws it with `.colorEffect` only when the `metalOrb` flag is on and the library holds the function;
/// otherwise it keeps the W1 mesh gradient.
enum OrbShader {
    /// Whether the app's default Metal library has `psOrb`, looked up once (a test host or a build without the
    /// shader has none).
    static let isAvailable: Bool = {
        guard let library = MTLCreateSystemDefaultDevice()?.makeDefaultLibrary() else { return false }
        return library.functionNames.contains("psOrb")
    }()

    /// The flag and the library, read when the orb draws.
    static var isEnabled: Bool { FeatureFlags.isOn(.metalOrb) && isAvailable }

    /// The colour effect for one frame: `time` in seconds, `level` 0…1 (the voice heard or spoken), four lobe
    /// colours (fewer are repeated), `size` the orb's frame.
    static func shader(time: Double, level: Double, colors: [Color], size: CGSize) -> Shader {
        let fallback = colors.last ?? Color.white
        let lobes = (0..<4).map { $0 < colors.count ? colors[$0] : fallback }
        // The time wraps every 10 minutes so the float keeps its precision in a long session.
        let wrapped = time.truncatingRemainder(dividingBy: 600)
        return ShaderLibrary.default.psOrb(.float2(size), .float(wrapped), .float(min(1, max(0, level))),
                                           .color(lobes[0]), .color(lobes[1]), .color(lobes[2]), .color(lobes[3]))
    }
}
#endif
