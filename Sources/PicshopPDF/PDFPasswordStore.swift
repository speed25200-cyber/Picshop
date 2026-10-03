#if canImport(PDFKit) && canImport(Security)
import Foundation
import Security
import PicshopCore

/// The passwords of protected PDFs, in the Keychain of this device only (never synced):
/// a project opened once with its password opens again without asking. Keyed by
/// project and by the file inside the package (a merged PDF has its own).
public enum PDFPasswordStore {
    static let service = "picshop.pdf.password"

    static func account(_ projectID: UUID, _ path: String) -> String {
        "\(projectID.uuidString)|\(path)"
    }

    public static func password(projectID: UUID, path: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(projectID, path),
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public static func save(_ password: String, projectID: UUID, path: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(projectID, path),
        ]
        SecItemDelete(base as CFDictionary)
        var item = base
        item[kSecValueData as String] = Data(password.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        if status != errSecSuccess { PSLog.error("PDF password not kept in the Keychain: \(status)", category: .core) }
    }

    /// Every password of a project (the project was deleted).
    public static func removeAll(projectID: UUID) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var items: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &items) == errSecSuccess, let list = items as? [[String: Any]] else { return }
        for attributes in list {
            guard let account = attributes[kSecAttrAccount as String] as? String, account.hasPrefix(projectID.uuidString) else { continue }
            let delete: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
            SecItemDelete(delete as CFDictionary)
        }
    }
}
#endif
