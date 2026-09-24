#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import PicshopIntent

/// The Live orb's colours: four keys per state, spread over a 3 × 3 mesh.
///
/// The spectrum belongs to the orb (and MagicGlyph, WorkingShimmer and the
/// Premium badge) and nowhere else. `.connecting` shares the listening keys,
/// `.dictating` the hearing ones; a muted orb uses a grey set whatever its state.
public enum OrbPalette {
    /// The four key colours k0…k3 for `state`.
    public static func keys(for state: LiveState) -> [Color] {
        hexKeys(for: state).map { OrbRGB($0).color }
    }

    /// The keys of a muted orb.
    static var mutedKeys: [Color] { mutedHex.map { OrbRGB($0).color } }

    /// The nine colours of the orb's 3 × 3 mesh, row by row:
    /// - row 0: k0 darkened 30 %, k1, k2 darkened 30 %;
    /// - row 1: k3, k1 lightened 25 % (the centre), k2;
    /// - row 2: k2 darkened 30 %, k0, k3 darkened 30 %.
    static func mesh(for state: LiveState, isMuted: Bool = false) -> [Color] {
        let hex = isMuted ? mutedHex : hexKeys(for: state)
        let k = hex.map { OrbRGB($0) }
        return [
            k[0].darkened(0.30), k[1], k[2].darkened(0.30),
            k[3], k[1].lightened(0.25), k[2],
            k[2].darkened(0.30), k[0], k[3].darkened(0.30),
        ].map(\.color)
    }

    static func hexKeys(for state: LiveState) -> [UInt32] {
        switch state {
        case .off: return [0x4A5BA0, 0x6A5BB0, 0x8F5A9E, 0x5A7FD6]
        case .connecting, .listening: return [0x2F6BFF, 0x5AA2FF, 0x7B61FF, 0x9FD0FF]
        case .hearing, .dictating: return [0x3D8BFF, 0x7CC0FF, 0x8E6BFF, 0xC6E4FF]
        case .thinking: return [0x6D4AFF, 0x9B6BFF, 0x3D8BFF, 0xC9A7FF]
        case .speaking: return [0xF2609E, 0xFF9A4D, 0x9B6BFF, 0xFFC48A]
        case .acting: return [0x3D8BFF, 0x9B6BFF, 0xF2609E, 0xFF9A4D]
        case .problem: return [0xFF9F0A, 0xFF6B3D, 0xB8860B, 0xFFD27A]
        }
    }

    static let mutedHex: [UInt32] = [0x5C5C66, 0x3A3A40, 0x77777F, 0x2A2A2E]
}

/// An sRGB colour as components, so the mesh can darken and lighten keys.
struct OrbRGB: Equatable {
    var red: Double
    var green: Double
    var blue: Double

    init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// From 0xRRGGBB.
    init(_ hex: UInt32) {
        red = Double((hex >> 16) & 0xFF) / 255
        green = Double((hex >> 8) & 0xFF) / 255
        blue = Double(hex & 0xFF) / 255
    }

    /// Towards black by `fraction`.
    func darkened(_ fraction: Double) -> OrbRGB {
        OrbRGB(red: red * (1 - fraction), green: green * (1 - fraction), blue: blue * (1 - fraction))
    }

    /// Towards white by `fraction`.
    func lightened(_ fraction: Double) -> OrbRGB {
        OrbRGB(red: red + (1 - red) * fraction, green: green + (1 - green) * fraction, blue: blue + (1 - blue) * fraction)
    }

    var color: Color { Color(red: red, green: green, blue: blue) }
}
#endif
