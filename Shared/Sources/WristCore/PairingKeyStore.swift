import Foundation
import Security
import LocalAuthentication

/// Uses the data-protection keychain, never the user's old login keychain.
/// Import is a development-install step from an app-owned file, not a BLE action.
public enum PairingKeyStore {
    public static let bootstrapName = "WristControl-Pairing.json"
    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "dev.wristcontrol.device-pair.v2",
         kSecAttrAccount as String: "single-pair",
         kSecUseDataProtectionKeychain as String: true,
         kSecAttrSynchronizable as String: false]
    }

    /// Actually requests the protected data. Attribute-only queries are not a lock probe.
    public static func read() -> (data: Data?, status: OSStatus) {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecReturnAttributes as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        let context = LAContext(); context.interactionNotAllowed = true
        q[kSecUseAuthenticationContext as String] = context
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        guard status == errSecSuccess else { return (nil, status) }
        guard let item = result as? [String: Any], let data = item[kSecValueData as String] as? Data,
              data.count == 32,
              (item[kSecAttrAccessible as String] as? String) == (kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
        else { return (nil, errSecDecode) }
        return (data, errSecSuccess)
    }

    public static var bootstrapURL: URL? {
#if os(macOS)
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("WristControl", isDirectory: true).appendingPathComponent(bootstrapName)
#else
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent(bootstrapName)
#endif
    }

    /// Never replaces or deletes an existing key on a read error. A conflicting
    /// bootstrap is an error, not permission to silently change the trusted pair.
    @discardableResult public static func importBootstrapIfPresent() -> OSStatus {
        guard let url = bootstrapURL, FileManager.default.fileExists(atPath: url.path) else { return read().status }
        guard let bytes = try? Data(contentsOf: url), bytes.count < 1024,
              let object = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any],
              object["version"] as? Int == 1, let encoded = object["secret"] as? String,
              let secret = Data(base64Encoded: encoded), secret.count == 32 else { return errSecDecode }
        let existing = read()
        if existing.status == errSecItemNotFound {
            var item = query
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            item[kSecValueData as String] = secret
            let status = SecItemAdd(item as CFDictionary, nil)
            guard status == errSecSuccess else { return status }
        } else if existing.status != errSecSuccess { return existing.status }
        guard let stored = read().data, stored == secret else { return errSecDuplicateItem }
        do { try FileManager.default.removeItem(at: url) } catch { return errSecIO }
        return errSecSuccess
    }
}
