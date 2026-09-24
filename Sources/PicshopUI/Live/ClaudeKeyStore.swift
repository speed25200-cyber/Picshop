#if canImport(SwiftUI) && canImport(UIKit)
import Foundation
import Observation
import PicshopIntent

/// The user's Anthropic API key, kept in this iPhone's Keychain only (D7). Views
/// see `maskedKey` and `status`; the key itself is never published or logged.
@MainActor
@Observable
public final class ClaudeKeyStore {
    /// Keychain item (D7): kSecAttrAccessibleWhenUnlockedThisDeviceOnly, not synchronizable.
    static let service = "com.picshopio.picshop.anthropic"
    static let account = "api-key"

    public private(set) var hasKey = false
    /// sk-ant-...A1b2
    public private(set) var maskedKey: String?
    public private(set) var status: ClaudeKeyStatus = .unchecked

    init() {}

    /// The local format check, then GET modelURL.
    public func check(_ key: String) async -> ClaudeKeyStatus {
        // Phase 0 stub: the format check only, nothing goes over the network yet.
        APIKeyFormat.looksValid(key) ? .unchecked : .malformed
    }

    /// Stores the key in the Keychain. Call after `.valid` or `.offline`.
    public func save(_ key: String) throws {
        // Phase 0 stub.
    }

    public func delete() throws {
        // Phase 0 stub.
    }

    /// Checks the saved key again and updates `status`.
    public func recheck() async {
        // Phase 0 stub.
    }
}
#endif
