import Foundation
import PicshopCore

/// Decides when the user has finished speaking: 0.55 s of silence after a
/// complete sentence, 0.80 s when likely complete, 1.60 s when incomplete.
public struct EndOfTurnDetector: Sendable {
    public struct Parameters: Sendable {
        public init() {}
    }

    public var parameters: Parameters

    public init(parameters: Parameters = .init()) {
        self.parameters = parameters
    }
}
