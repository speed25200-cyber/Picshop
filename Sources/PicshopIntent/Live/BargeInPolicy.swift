import Foundation
import PicshopCore

/// When speech over the assistant's voice counts as an interruption: echo
/// guard, stop words, backchannels and thresholds.
public struct BargeInPolicy: Sendable {
    public struct Parameters: Sendable {
        public init() {}
    }

    let parameters: Parameters

    public init(parameters: Parameters = .init()) {
        self.parameters = parameters
    }
}
