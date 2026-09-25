import Foundation
import MomoBrain
import Security

/// Stores provider API keys in the login Keychain.
struct KeychainStore: APIKeyStore {
    static let service = "io.github.uemrey0.Momo.api-keys"

    func key(for providerID: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: providerID,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
            let data = item as? Data
        else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// Saves a key, or deletes it when `key` is empty.
    @discardableResult
    func setKey(_ key: String, for providerID: String) -> Bool {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: providerID,
        ]
        SecItemDelete(base as CFDictionary)
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        var item = base
        item[kSecValueData as String] = Data(trimmed.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        item[kSecAttrLabel as String] = "Momo API key (\(providerID))"
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }
}
