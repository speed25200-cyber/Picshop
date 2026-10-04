import Foundation
import PicshopCore

/// The colours Color Range and the eyedropper sample (W2, §6 item 11): the mean of a (2r + 1)² window of the
/// pre-local picture in gamma sRGB, converted to CIE Lab with Core's `MaskMath.lab`, the same function the mask cube
/// is built from, so a sampled colour is exactly what a colour range tests. Pure Swift, Linux-compiled.
public enum ColorRangeSampler {
    /// The mean gamma sRGB colour (0…1) of the window centred on `point` (normalised, top-left), clipped at the
    /// picture's edges.
    public static func meanColor(rgba: [UInt8], width: Int, height: Int, at point: PSPoint, radius: Int) -> (r: Double, g: Double, b: Double)? {
        guard width > 0, height > 0, rgba.count >= width * height * 4 else { return nil }
        let cx = min(width - 1, max(0, Int(point.x * Double(width))))
        let cy = min(height - 1, max(0, Int(point.y * Double(height))))
        let r = max(0, radius)
        var sum = (0.0, 0.0, 0.0), count = 0.0
        for y in max(0, cy - r)...min(height - 1, cy + r) {
            for x in max(0, cx - r)...min(width - 1, cx + r) {
                let i = (y * width + x) * 4
                sum.0 += Double(rgba[i])
                sum.1 += Double(rgba[i + 1])
                sum.2 += Double(rgba[i + 2])
                count += 1
            }
        }
        guard count > 0 else { return nil }
        return (sum.0 / count / 255, sum.1 / count / 255, sum.2 / count / 255)
    }

    /// The Lab colour of each point's window.
    public static func labColors(rgba: [UInt8], width: Int, height: Int, at points: [PSPoint], radius: Int) -> [LabColor] {
        points.compactMap { point in
            meanColor(rgba: rgba, width: width, height: height, at: point, radius: radius).map { MaskMath.lab(r: $0.r, g: $0.g, b: $0.b) }
        }
    }

    /// The luma (Rec. 709 on gamma values) of the window: the eyedropper of the luminance range editor.
    public static func luma(rgba: [UInt8], width: Int, height: Int, at point: PSPoint, radius: Int) -> Double? {
        meanColor(rgba: rgba, width: width, height: height, at: point, radius: radius).map { MaskMath.luma(r: $0.r, g: $0.g, b: $0.b) }
    }
}
