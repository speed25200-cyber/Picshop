#if canImport(Vision) && canImport(CoreImage)
import Foundation
import CoreGraphics
import Vision

/// Scores how good a picture looks with Vision's aesthetics model — the
/// same judgement Photos uses to pick highlights — so PicShop can point at
/// the looks that suit this photo best.
public enum AestheticsRanker {
    /// One score per image (higher is better); nil where the model is unavailable.
    public static func scores(for images: [CGImage]) async -> [Double?] {
        guard #available(iOS 18.0, macOS 15.0, *) else { return images.map { _ in nil } }
        var results: [Double?] = []
        for image in images {
            do {
                let request = CalculateImageAestheticsScoresRequest()
                let observation = try await request.perform(on: image)
                results.append(Double(observation.overallScore))
            } catch {
                results.append(nil)
            }
        }
        return results
    }
}
#endif
