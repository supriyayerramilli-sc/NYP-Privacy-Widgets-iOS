//
//  DeviceIdentity.swift
//  NYPMobile
//
//  Device-level identity for cross-device consent WITHOUT a backend:
//  a UUID generated once and persisted in the Keychain. Unlike UserDefaults,
//  Keychain entries survive app deletion/reinstall, so consent tied to this
//  ID persists across reinstalls via Didomi's sync backend.
//
//  This is DEVICE-level identity, not USER-level: it follows the phone,
//  not the person. Logging in (email) upgrades to a user-level identity.
//

import Foundation
import Security

enum DeviceIdentity {

    private static let service = "com.didomi.NYPMobile"
    private static let account = "didomi-device-id"

    /// Stable per-device ID. Created on first access, then read from Keychain.
    static var id: String {
        if let existing = read() {
            return existing
        }
        let newId = "device-" + UUID().uuidString.lowercased()
        save(newId)
        return newId
    }

    private static func read() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8) else {
            return nil
        }
        return value
    }

    private static func save(_ value: String) {
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(value.utf8)
        ]
        SecItemDelete(attributes as CFDictionary)
        SecItemAdd(attributes as CFDictionary, nil)
    }
}
