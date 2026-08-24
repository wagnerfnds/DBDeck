import Foundation
import Security

public enum KeychainManager {
    private static let service = "DBDeck"

    /// Que segredo de uma conexão está em jogo. O sufixo entra na conta do item — sem
    /// ele a senha do SSH sobrescreveria a do banco.
    public enum SecretKind: String {
        case database = ""
        case ssh = ".ssh"
    }

    private static func account(_ connectionID: UUID, _ kind: SecretKind) -> String {
        connectionID.uuidString + kind.rawValue
    }

    public static func setPassword(_ password: String, for connectionID: UUID, kind: SecretKind = .database) {
        guard !password.isEmpty else {
            deletePassword(for: connectionID, kind: kind)
            return
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(connectionID, kind),
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

    public static func password(for connectionID: UUID, kind: SecretKind = .database) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(connectionID, kind),
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

    public static func deletePassword(for connectionID: UUID, kind: SecretKind = .database) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(connectionID, kind),
        ]
        SecItemDelete(query as CFDictionary)
    }
}
