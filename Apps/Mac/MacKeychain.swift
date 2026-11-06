import Foundation
import IKeyCore
import Security

/// Outcome of loading the pairing key. `.unavailable` carries the Keychain status; the caller
/// must not invent a key then, or every paired iPad would be locked out.
enum PSKLoad: Equatable {
    case loaded(PairingSecret)
    case created(PairingSecret)
    case unavailable(OSStatus)
}

/// The Mac's persistent pairing key and identity. Main-thread confined.
///
/// The key is a device-only generic password (never synced). The data-protection keychain is
/// tried first; a build without the keychain entitlement (errSecMissingEntitlement) uses the
/// login keychain for the rest of the process.
enum MacKeychain {
    private static let service = "com.ikey.pairing"
    private static let account = "psk"
    private static let macIDKey = "iKey.macID"
    private static let portKey = "iKey.listenerPort"

    private static var cached: PairingSecret?
    private static var useDataProtection = true

    /// Loads the stored key, or creates one only when none exists (errSecItemNotFound).
    /// Any other status (locked keychain, denied access, cancelled prompt) is `.unavailable`,
    /// as is a readable item that does not decode as a key (errSecDecode).
    static func loadOrCreatePSK() -> PSKLoad {
        if let cached { return .loaded(cached) }
        var item: CFTypeRef?
        let status = perform { query in
            var query = query
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            return SecItemCopyMatching(query as CFDictionary, &item)
        }
        switch status {
        case errSecSuccess:
            guard let data = item as? Data,
                  let secret = try? PairingSecret(hex: String(decoding: data, as: UTF8.self)) else {
                // Readable but not a key (corrupt, or another build's encoding): never re-key
                // silently, which would lock out every paired iPad. Report it; Reset pairing
                // (rotatePSK) is the only path that replaces the item.
                return .unavailable(errSecDecode)
            }
            cached = secret
            return .loaded(secret)
        case errSecItemNotFound:
            return store(PairingSecret.generate(), replacing: false)
        default:
            return .unavailable(status)
        }
    }

    /// Replaces the stored key with a new one (adding it if missing). On failure the old key
    /// stays in effect.
    static func rotatePSK() -> PSKLoad {
        store(PairingSecret.generate(), replacing: true)
    }

    /// This Mac's stable identity, advertised in the Bonjour TXT record and the welcome.
    static var macID: UUID {
        let defaults = UserDefaults.standard
        if let text = defaults.string(forKey: macIDKey), let id = UUID(uuidString: text) { return id }
        let id = UUID()
        defaults.set(id.uuidString, forKey: macIDKey)
        return id
    }

    /// The last port the listener was ready on, so the iPad can reconnect without browsing.
    static var savedPort: UInt16? {
        get {
            guard let value = UserDefaults.standard.object(forKey: portKey) as? Int,
                  let port = UInt16(exactly: value), port != 0 else { return nil }
            return port
        }
        set {
            if let newValue, newValue != 0 {
                UserDefaults.standard.set(Int(newValue), forKey: portKey)
            } else {
                UserDefaults.standard.removeObject(forKey: portKey)
            }
        }
    }

    // MARK: Keychain access

    private static func store(_ secret: PairingSecret, replacing: Bool) -> PSKLoad {
        let data = Data(secret.hex.utf8)
        var status = errSecItemNotFound
        if replacing {
            status = perform { query in
                SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
            }
        }
        if status == errSecItemNotFound {
            status = perform { query in
                var attributes = query
                attributes[kSecValueData as String] = data
                attributes[kSecAttrLabel as String] = "iKey pairing key"
                if useDataProtection {
                    attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
                }
                return SecItemAdd(attributes as CFDictionary, nil)
            }
        }
        guard status == errSecSuccess else { return .unavailable(status) }
        cached = secret
        return .created(secret)
    }

    /// Runs `operation` with the item's base query; on errSecMissingEntitlement switches to the
    /// login keychain and runs it again.
    private static func perform(_ operation: ([String: Any]) -> OSStatus) -> OSStatus {
        let status = operation(baseQuery())
        guard status == errSecMissingEntitlement, useDataProtection else { return status }
        useDataProtection = false
        return operation(baseQuery())
    }

    private static func baseQuery() -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if useDataProtection { query[kSecUseDataProtectionKeychain as String] = true }
        return query
    }
}
