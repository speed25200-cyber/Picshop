import Foundation

/// Framings worth trying for a photo, as a photographer would: a few shapes
/// and sizes, the subject on a third or in the middle, never cut. A judge
/// (Vision's aesthetics model) picks among them.
public enum CropCandidates {
    /// Normalised rectangles (top-left origin) inside the picture. `subject`
    /// is kept whole; `imageAspect` is width / height of the picture.
    public static func generate(subject: PSRect?, imageAspect: Double) -> [PSRect] {
        let aspect = max(0.1, imageAspect)
        // Shapes relative to the picture: its own, 4:5, 1:1, 3:2 (portrait pictures try 2:3).
        let shapes = [aspect, 4.0 / 5.0, 1, aspect >= 1 ? 3.0 / 2.0 : 2.0 / 3.0]
        let sizes = [0.92, 0.8, 0.68]
        let anchorsX = [1.0 / 3.0, 0.5, 2.0 / 3.0]
        let anchorsY = [1.0 / 3.0, 0.5]
        let target = subject.map { PSPoint(x: $0.midX, y: $0.midY) } ?? PSPoint(x: 0.5, y: 0.5)
        var result: [PSRect] = []
        for shape in shapes {
            // Width and height of the largest crop of this shape, in normalised units.
            let relative = shape / aspect
            let fullWidth = relative >= 1 ? 1 : relative
            let fullHeight = relative >= 1 ? 1 / relative : 1
            for size in sizes {
                let width = fullWidth * size, height = fullHeight * size
                for ax in anchorsX {
                    for ay in anchorsY {
                        // The subject lands on this point of the crop.
                        let x = (target.x - ax * width).clamped(to: 0...(1 - width))
                        let y = (target.y - ay * height).clamped(to: 0...(1 - height))
                        let rect = PSRect(x: x, y: y, width: width, height: height)
                        if let subject, !contains(rect, subject) { continue }
                        if !result.contains(where: { abs($0.minX - rect.minX) < 0.02 && abs($0.minY - rect.minY) < 0.02 && abs($0.width - rect.width) < 0.02 && abs($0.height - rect.height) < 0.02 }) {
                            result.append(rect)
                        }
                    }
                }
            }
        }
        return result
    }

    static func contains(_ outer: PSRect, _ inner: PSRect) -> Bool {
        inner.minX >= outer.minX - 0.005 && inner.maxX <= outer.maxX + 0.005 && inner.minY >= outer.minY - 0.005 && inner.maxY <= outer.maxY + 0.005
    }
}
