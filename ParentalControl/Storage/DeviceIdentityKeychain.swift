import Foundation
import Security

/// Host-only backup of the existing device credentials. Extensions continue to
/// use App Group data; no new Keychain sharing entitlement is required.
enum DeviceIdentityKeychain {
    struct Identity: Codable, Equatable {
        let installID: String
        let secret: String
        // Role belongs to this installation, not the persistent credentials.
        // Codable ignores the legacy "role" field when reading older backups.
    }
    private static let service = "mycompny.ParentalControl.deviceIdentity"
    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service, kSecAttrAccount as String: "identity-v1"]
    }
    static func read() -> Identity? {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &value) == errSecSuccess,
              let data = value as? Data,
              let identity = try? JSONDecoder().decode(Identity.self, from: data),
              UUID(uuidString: identity.installID) != nil, !identity.secret.isEmpty else { return nil }
        return identity
    }
    @discardableResult static func save(_ identity: Identity) -> Bool {
        guard UUID(uuidString: identity.installID) != nil, !identity.secret.isEmpty,
              let data = try? JSONEncoder().encode(identity) else { return false }
        let attributes: [String: Any] = [kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecSuccess { return true }
        // Do not delete an existing item to update it, or overwrite on transient
        // Keychain errors (e.g. device has not been unlocked since boot).
        guard status == errSecItemNotFound else { return false }
        return SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil) == errSecSuccess
    }
}
