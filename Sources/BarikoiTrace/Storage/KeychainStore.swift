import Foundation
import Security

/// Minimal Keychain wrapper for string values. Used for identity/credential
/// data (API key, MQTT credentials, user identity) — a deliberate step up from
/// the Kotlin SDK's plain DataStore Preferences for the same fields (see the
/// work plan's Phase 0 note on not carrying the hardcoded-credential pattern
/// forward; this at least keeps whatever credentials are configured out of
/// plain UserDefaults).
final class KeychainStore {
    private let service: String

    init(service: String = "com.barikoi.trace") {
        self.service = service
    }

    func set(_ value: String, forKey key: String) {
        let data = Data(value.utf8)
        var query = baseQuery(for: key)
        SecItemDelete(query as CFDictionary)
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(query as CFDictionary, nil)
    }

    func get(_ key: String) -> String? {
        var query = baseQuery(for: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func remove(_ key: String) {
        SecItemDelete(baseQuery(for: key) as CFDictionary)
    }

    private func baseQuery(for key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
    }
}
