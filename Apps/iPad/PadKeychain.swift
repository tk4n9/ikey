import Foundation
import Security
import IKeyCore

/// The pairing key for each paired Mac, kept in this device's Keychain only: readable after the
/// first unlock (so a relaunch reconnects without the key being pasted again), never synced to
/// iCloud and never restored to another device.
enum PadKeychain {
    private static let service = "com.ikey.pairing.v2"

    static func load(macID: UUID) -> PairingSecret? {
        var query = baseQuery(macID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return try? PairingSecret(hex: data.map { String(format: "%02x", $0) }.joined())
    }

    /// Adds or replaces the key; false when the Keychain refused it.
    static func save(_ s: PairingSecret, macID: UUID) -> Bool {
        let attributes: [String: Any] = [
            kSecValueData as String: s.bytes,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemUpdate(baseQuery(macID) as CFDictionary, attributes as CFDictionary)
        if status == errSecSuccess { return true }
        guard status == errSecItemNotFound else { return false }
        let item = baseQuery(macID).merging(attributes) { _, new in new }
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    static func delete(macID: UUID) {
        _ = SecItemDelete(baseQuery(macID) as CFDictionary)
    }

    private static func baseQuery(_ macID: UUID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: macID.uuidString,
            kSecAttrSynchronizable as String: false,
        ]
    }
}
