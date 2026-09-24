import Foundation
import PicshopCore

/// Energy voice activity detection on 20 ms frames, with an adaptive noise floor.
public struct VoiceActivityDetector: Sendable {
    public struct Parameters: Sendable {
        public init() {}
    }

    let parameters: Parameters
    public private(set) var noiseFloorDB: Float = -60

    public init(parameters: Parameters = .init()) {
        self.parameters = parameters
    }
}
