import Foundation
import PicshopCore

/// Tool results in the shapes each brain reads.
public enum ToolResultEncoder {
    /// At most 300 characters, for the on-device model.
    public static func compactText(_ result: LiveToolResult) -> String {
        // Phase 0 stub.
        String(result.payload.serialized().prefix(300))
    }
}
