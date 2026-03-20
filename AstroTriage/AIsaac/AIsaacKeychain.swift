// AIsaac — Secure API key storage via macOS Keychain
import Foundation
import Security

enum AIsaacKeychain {
    private static let service = "com.joergsflow.AstroBlinkV2.aisaac"
    private static let account = "anthropic-api-key"

    // Store the user's own Anthropic API key
    static func saveAPIKey(_ key: String) -> Bool {
        // Delete existing first
        deleteAPIKey()

        guard let data = key.data(using: .utf8) else { return false }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        return status == errSecSuccess
    }

    // Retrieve the stored API key (nil if not set)
    static func loadAPIKey() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // Delete the stored API key
    @discardableResult
    static func deleteAPIKey() -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        return SecItemDelete(query as CFDictionary) == errSecSuccess
    }

    // Check if a key is stored
    static var hasAPIKey: Bool {
        loadAPIKey() != nil
    }
}
