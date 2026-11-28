import Foundation
import Security

enum NavigationKey {
    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "org.personal.watchlink.navigation",
         kSecAttrAccount as String: "google"]
    }

    static func load() -> String {
        var request = query
        request[kSecReturnData as String] = true
        var result: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    static func save(_ key: String) -> Bool {
        let values: [String: Any] = [kSecValueData as String: Data(key.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemUpdate(query as CFDictionary, values as CFDictionary)
        if status == errSecItemNotFound {
            return SecItemAdd(query.merging(values) { _, new in new } as CFDictionary, nil) == errSecSuccess
        }
        return status == errSecSuccess
    }
}
