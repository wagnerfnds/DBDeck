import Foundation
import Security

public enum KeychainManager {
    private static let service = "DBDeck"

    public static func setPassword(_ password: String, for connectionID: UUID) {
        guard !password.isEmpty else {
            deletePassword(for: connectionID)
            return
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: connectionID.uuidString,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: Data(password.utf8)
        ]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = Data(password.utf8)
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    public static func password(for connectionID: UUID) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: connectionID.uuidString,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    public static func deletePassword(for connectionID: UUID) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: connectionID.uuidString,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
