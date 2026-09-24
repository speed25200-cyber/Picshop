#if canImport(SwiftUI) && canImport(UIKit)
import Foundation
import Observation
import Security
import PicshopIntent

/// The user's Anthropic API key, kept in this iPhone's Keychain only (D7). Views
/// see `maskedKey` and `status`; the key itself is never published or logged.
@MainActor
@Observable
public final class ClaudeKeyStore {
    /// Keychain item (D7): kSecAttrAccessibleWhenUnlockedThisDeviceOnly, not synchronizable.
    nonisolated static let service = KeychainItem.service
    nonisolated static let account = KeychainItem.account

    public private(set) var hasKey = false
    /// sk-ant-...A1b2
    public private(set) var maskedKey: String?
    public private(set) var status: ClaudeKeyStatus = .unchecked

    @ObservationIgnored private let transport: any ClaudeTransport
    /// The last `check`: saving that same key keeps its result.
    @ObservationIgnored private var lastCheck: (key: String, status: ClaudeKeyStatus)?
    /// The first Keychain read, started at init.
    @ObservationIgnored private var loading: Task<Void, Never>?
    /// save or delete ran before the first read landed: its result is stale.
    @ObservationIgnored private var changedWhileLoading = false

    init(transport: any ClaudeTransport) {
        self.transport = transport
        loading = Task { await self.loadSavedKey() }
    }

    /// `hasKey` and `maskedKey` reflect the Keychain once this returns.
    func waitUntilLoaded() async {
        await loading?.value
    }

    /// The local format check, then GET modelURL.
    public func check(_ key: String) async -> ClaudeKeyStatus {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard APIKeyFormat.looksValid(trimmed) else {
            lastCheck = (trimmed, .malformed)
            return .malformed
        }
        let result = await Self.verify(trimmed, transport: transport)
        lastCheck = (trimmed, result)
        return result
    }

    /// Stores the key in the Keychain. Call after `.valid` or `.offline` (an offline save stays unverified).
    public func save(_ key: String) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard APIKeyFormat.looksValid(trimmed) else { throw KeychainError.malformedKey }
        try KeychainItem.write(Data(trimmed.utf8))
        changedWhileLoading = true
        hasKey = true
        maskedKey = APIKeyFormat.mask(trimmed)
        status = lastCheck?.key == trimmed ? (lastCheck?.status ?? .unchecked) : .unchecked
        lastCheck = nil
    }

    public func delete() throws {
        try KeychainItem.delete()
        changedWhileLoading = true
        hasKey = false
        maskedKey = nil
        status = .unchecked
        lastCheck = nil
    }

    /// Checks the saved key again and updates `status`.
    public func recheck() async {
        guard let key = await readKey() else {
            if hasKey { hasKey = false; maskedKey = nil }
            status = .unchecked
            return
        }
        status = await Self.verify(key, transport: transport)
    }

    // MARK: Live

    /// Read once at Live start, off the main thread. Never logged.
    func readKey() async -> String? {
        await Task.detached(priority: .userInitiated) {
            (try? KeychainItem.read()).flatMap { String(data: $0, encoding: .utf8) }
        }.value
    }

    /// Claude refused the saved key during Live: the status Settings shows.
    func noteRejected(_ rejected: ClaudeKeyStatus) {
        if status != rejected { status = rejected }
    }

    private func loadSavedKey() async {
        let key = await readKey()
        guard !changedWhileLoading else { return }
        hasKey = key != nil
        maskedKey = key.map(APIKeyFormat.mask)
    }

    private static func verify(_ key: String, transport: any ClaudeTransport) async -> ClaudeKeyStatus {
        do {
            let response = try await transport.send(ClaudeRequestBuilder.keyCheckRequest(apiKey: key))
            return ClaudeRequestBuilder.keyStatus(httpStatus: response.status, offline: false)
        } catch let error as LiveBrainError {
            switch error {
            case .network: return ClaudeRequestBuilder.keyStatus(httpStatus: nil, offline: true)
            case .timeout: return .server(0)
            default: return .server(0)
            }
        } catch let error as ClaudeAPIError {
            return ClaudeRequestBuilder.keyStatus(httpStatus: error.status, offline: false)
        } catch {
            return ClaudeRequestBuilder.keyStatus(httpStatus: nil, offline: true)
        }
    }

    #if DEBUG
    /// The saved item's attributes are exactly D7's: this device only, not synchronizable.
    func verifyKeychainAttributes() -> Bool {
        KeychainItem.hasExpectedAttributes()
    }
    #endif
}

enum KeychainError: Error, Equatable {
    case malformedKey
    case status(OSStatus)
}

/// The one generic-password item (D7).
enum KeychainItem {
    static let service = "com.picshopio.picshop.anthropic"
    static let account = "api-key"

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
        ]
    }

    /// SecItemUpdate, then SecItemAdd when the item does not exist yet.
    static func write(_ data: Data) throws {
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        let updated = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
        if updated == errSecSuccess { return }
        guard updated == errSecItemNotFound else { throw KeychainError.status(updated) }
        var item = baseQuery
        for (name, value) in attributes { item[name] = value }
        let added = SecItemAdd(item as CFDictionary, nil)
        guard added == errSecSuccess else { throw KeychainError.status(added) }
    }

    static func read() throws -> Data? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError.status(status) }
        return result as? Data
    }

    static func delete() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError.status(status) }
    }

    static func hasExpectedAttributes() -> Bool {
        var query = baseQuery
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let attributes = result as? [String: Any] else { return false }
        let accessible = attributes[kSecAttrAccessible as String] as? String
        let synchronizable = (attributes[kSecAttrSynchronizable as String] as? Bool) ?? false
        return accessible == (kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String) && !synchronizable
    }
}
#endif
