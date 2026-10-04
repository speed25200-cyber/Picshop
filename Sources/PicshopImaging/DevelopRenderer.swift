#if canImport(CoreImage)
import Foundation
import CoreImage
import PicshopCore

/// The develop step shared by image layers and adjustment layers (W3, D9), moved out of `renderImageLayer` verbatim:
/// the adjustments with the look's curve, the tone table (Levels and the person's curves), colour match, the mixer and
/// grade cube, then an imported LUT. Static and free of actor state, so a snapshot frame runs it on the calling thread
/// (D13) with cube lookups that never bake there.
public enum DevelopRenderer {
    /// What the develop step draws, resolved once from an edit stack. An adjustment layer adds its own dials under
    /// the stack's (its content `Adjustments`, D9).
    public struct Recipe: Hashable, Sendable {
        public var adjustments: Adjustments
        /// The look's built-in 5-point curve, drawn with the adjustments through Core Image's tone curve.
        public var lookCurve: ToneCurve
        public var tone: ToneLUT?
        public var match: ColorMatch?
        public var mixer: ColorMixer?
        public var grade: ColorGrade?
        public var lut: LUTReference?

        public init(adjustments: Adjustments = .neutral, lookCurve: ToneCurve = .identity, tone: ToneLUT? = nil, match: ColorMatch? = nil,
                    mixer: ColorMixer? = nil, grade: ColorGrade? = nil, lut: LUTReference? = nil) {
            self.adjustments = adjustments
            self.lookCurve = lookCurve
            self.tone = tone
            self.match = match
            self.mixer = mixer
            self.grade = grade
            self.lut = lut
        }

        /// The stack's recipe. `extra` (an adjustment layer's own dials) sits under the stack's resolved
        /// adjustments: a parameter the stack sets wins. `tone` passes a table the caller already holds (the renderer
        /// keeps them by their inputs); nil computes it from the edits (256 entries, microseconds).
        public init(edits: EditStack, extra: Adjustments? = nil, tone: ToneLUT?? = nil) {
            let resolved = edits.resolvedAdjustments
            var manual = resolved
            if let extra, !extra.isNeutral {
                // The layer's own dials under the stack's: what an operation of the stack sets wins, even back to 0;
                // a whole set (`.adjustments`) replaces them.
                let replacesAll = edits.operations.contains { if case .adjustments = $0.kind { return true } else { return false } }
                if !replacesAll {
                    manual = extra
                    for parameter in resolved.activeParameters { manual[parameter] = resolved[parameter] }
                    for operation in edits.operations {
                        if case .adjust(let parameter, _) = operation.kind { manual[parameter] = resolved[parameter] }
                    }
                }
            }
            self.init(adjustments: AdjustmentPipeline.effectiveAdjustments(manual: manual, look: edits.resolvedLook),
                      lookCurve: edits.resolvedLookToneCurve,
                      tone: tone ?? edits.resolvedToneLUT,
                      match: edits.resolvedColorMatch,
                      mixer: edits.resolvedColorMixer,
                      grade: edits.resolvedColorGrade,
                      lut: edits.resolvedLUT)
        }

        /// Draws nothing.
        public var isNeutral: Bool {
            adjustments.isNeutral && lookCurve.isIdentity && tone == nil && match == nil && mixer == nil && grade == nil && lut == nil
        }
    }

    /// How the mixer and grade cube is found.
    public enum Cubes: Sendable {
        /// The settled frame: the 33³ cube, baked here when missing.
        case settled
        /// A drag frame on the renderer actor: the 17³ scratch cube, baked here when missing (W1).
        case interactive
        /// A snapshot frame (D13): never baked on the calling thread; the latest drag cube stands in.
        case nonBlocking
    }

    /// `image` developed by `recipe`. `scale` is the image's ratio to the full-resolution original (radius-based
    /// dials); `lutURL` turns a LUT's project path into its file.
    public static func apply(_ recipe: Recipe, to image: CIImage, scale: Double, cubes: Cubes, colorCube: ColorCube = .shared,
                             lutURL: (String) -> URL) -> CIImage {
        var image = image
        if !recipe.adjustments.isNeutral || !recipe.lookCurve.isIdentity {
            image = AdjustmentPipeline.apply(recipe.adjustments, toneCurve: recipe.lookCurve, to: image, scale: scale)
        }
        // Levels and the person's curves: one table, in a gamma-encoded space, after the look and before colour.
        if let tone = recipe.tone {
            image = ToneRenderer.apply(tone, to: image)
        }
        // Colour work after tone, as in a grading suite: match, then mixer and wheels in one LUT.
        if let match = recipe.match {
            image = cubes == .nonBlocking ? colorCube.applyNonBlocking(match, to: image) : colorCube.apply(match, to: image)
        }
        if recipe.mixer != nil || recipe.grade != nil {
            switch cubes {
            case .settled: image = colorCube.apply(mixer: recipe.mixer, grade: recipe.grade, to: image, interactive: false)
            case .interactive: image = colorCube.apply(mixer: recipe.mixer, grade: recipe.grade, to: image, interactive: true)
            case .nonBlocking: image = colorCube.applyNonBlocking(mixer: recipe.mixer, grade: recipe.grade, to: image)
            }
        }
        // An imported look sits on top, as the last node of a grade (its file is parsed once per path and kept).
        if let lut = recipe.lut {
            image = colorCube.apply(lutAt: lutURL(lut.relativePath), intensity: lut.intensity, to: image)
        }
        return image
    }

    /// D9's form: the edits' recipe with an adjustment layer's dials under it, applied to `image`.
    public static func apply(edits: EditStack, extra: Adjustments?, to image: CIImage, scale: Double = 1, interactive: Bool = false,
                             lutURL: (String) -> URL) -> CIImage {
        apply(Recipe(edits: edits, extra: extra), to: image, scale: scale, cubes: interactive ? .interactive : .settled, lutURL: lutURL)
    }

    /// Bakes the recipe's cubes and parses its LUT now (a snapshot's capture, on the renderer actor), so its frames
    /// find them.
    static func warm(_ recipe: Recipe, colorCube: ColorCube = .shared, lutURL: (String) -> URL) {
        if let match = recipe.match { colorCube.warm(match) }
        colorCube.warm(mixer: recipe.mixer, grade: recipe.grade)
        if let lut = recipe.lut {
            _ = colorCube.apply(lutAt: lutURL(lut.relativePath), intensity: lut.intensity, to: CIImage(color: .black).cropped(to: CGRect(x: 0, y: 0, width: 1, height: 1)))
        }
    }
}
#endif
