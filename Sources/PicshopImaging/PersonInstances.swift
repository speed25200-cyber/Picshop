#if canImport(Vision) && canImport(CoreImage)
import Foundation
import Vision
import CoreGraphics
import PicshopCore

/// People one by one (W2, D8): `VNGeneratePersonInstanceMaskRequest` gives up to four people, each with its own
/// mask; they are numbered left to right by the left edge of their mask's box, from 1, as « Personne 2 » and the
/// face thumbnails count them.
enum PersonInstances {
    struct Instance: Sendable {
        /// 8-bit at the image's size, row 0 at the top.
        let bytes: [UInt8]
        /// Normalised, top-left origin.
        let box: PSRect
        /// Fraction of the picture above 127.
        let area: Double
    }

    /// The people in `image`, left to right; empty when Vision finds nobody.
    static func instances(in image: CGImage) throws -> [Instance] {
        let handler = VNImageRequestHandler(cgImage: image, orientation: .up, options: [:])
        let request = VNGeneratePersonInstanceMaskRequest()
        try handler.perform([request])
        guard let observation = request.results?.first else { return [] }
        let width = image.width, height = image.height
        var found: [Instance] = []
        for index in observation.allInstances {
            let buffer = try observation.generateScaledMaskForImage(forInstances: IndexSet(integer: index), from: handler)
            let bytes = MaskStore.bytes(from: buffer, width: width, height: height)
            let area = MaskStore.coverage(of: bytes)
            guard area > 0.0005 else { continue }
            found.append(Instance(bytes: bytes, box: MaskStore.boundingBox(of: bytes, width: width, height: height), area: area))
        }
        return found.sorted { $0.box.minX < $1.box.minX }
    }
}
#endif
