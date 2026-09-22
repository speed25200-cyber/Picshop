import XCTest
@testable import PicshopCore

final class SceneDetectionTests: XCTestCase {
    /// A 32×18 frame: a horizontal gradient in `base`, slid by `pan` pixels (camera move), with a little noise.
    private func frame(base: (Double, Double, Double), pan: Int, seed: Int, time: Double) -> FrameSignature {
        let width = 32, height = 18
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        var generator = seed
        for y in 0..<height {
            for x in 0..<width {
                generator = (generator &* 1103515245 &+ 12345) & 0x7fffffff
                let noise = Double(generator % 11) - 5
                let shade = 0.55 + 0.45 * Double((x + pan) % width) / Double(width)
                let index = (y * width + x) * 4
                bytes[index] = UInt8((base.0 * shade + noise).clamped(to: 0...255))
                bytes[index + 1] = UInt8((base.1 * shade + noise).clamped(to: 0...255))
                bytes[index + 2] = UInt8((base.2 * shade + noise).clamped(to: 0...255))
            }
        }
        return FrameSignature.measure(rgba: bytes, width: width, height: height, time: time)
    }

    func testFindsTheCutsAndIgnoresCameraMoves() {
        var frames: [FrameSignature] = []
        let shots: [(Double, Double, Double)] = [(220, 90, 60), (40, 90, 210), (60, 200, 80)]
        var time = 0.0
        for (shot, colour) in shots.enumerated() {
            for step in 0..<24 {
                frames.append(frame(base: colour, pan: step, seed: shot * 100 + step, time: time))
                time += 0.125
            }
        }
        let cuts = SceneDetector.cuts(in: frames)
        XCTAssertEqual(cuts.count, 2)
        XCTAssertEqual(cuts.first ?? 0, 3, accuracy: 0.001)
        XCTAssertEqual(cuts.last ?? 0, 6, accuracy: 0.001)
    }

    func testOneShotHasNoCuts() {
        let frames = (0..<40).map { frame(base: (180, 150, 120), pan: $0, seed: $0, time: Double($0) * 0.125) }
        XCTAssertTrue(SceneDetector.cuts(in: frames).isEmpty)
    }

    func testDistanceIsZeroForTheSameFrame() {
        let a = frame(base: (100, 100, 100), pan: 0, seed: 1, time: 0)
        XCTAssertEqual(a.distance(to: a), 0, accuracy: 1e-9)
    }
}
