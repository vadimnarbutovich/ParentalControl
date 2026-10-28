let installID = "23F53D83-5726-443B-A397-F3E772E61D8D"
for oldRole in ["parent", "child"] {
    // Real Codable model must accept old backups but ignore their saved role.
    let json = """
    {"installID":"\(installID)","secret":"test-secret","role":"\(oldRole)"}
    """
    let legacy = try JSONDecoder().decode(DeviceIdentityKeychain.Identity.self, from: Data(json.utf8))
    DeviceIdentityKeychain.saved = legacy
    let reinstalled = CredentialStore()
    precondition(reinstalled.loadDeviceInstallID() == installID)
    precondition(reinstalled.loadDeviceSecret() == "test-secret")
    precondition(reinstalled.loadDeviceRole() == nil)
    reinstalled.saveDeviceRole(.child)
    precondition(reinstalled.loadDeviceInstallID() == installID)
    precondition(reinstalled.loadDeviceRole() == .child)
    reinstalled.saveDeviceSecret("new-secret")
    let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(DeviceIdentityKeychain.saved!)) as! [String: Any]
    precondition(encoded["role"] == nil)
    precondition(encoded["installID"] as? String == installID)
}

// An update cannot replace the established identity, role, pairing or setup.
let updated = CredentialStore()
updated.saveDeviceInstallID("existing-id")
updated.store.set("existing-secret", forKey: StorageKey.deviceSecret)
updated.saveDeviceRole(.parent)
updated.store.set("existing-family", forKey: "pairing")
updated.store.set("true", forKey: "onboarding")
precondition(updated.loadDeviceInstallID() == "existing-id")
precondition(updated.loadDeviceSecret() == "existing-secret")
precondition(updated.loadDeviceRole() == .parent)
precondition(updated.store.string(forKey: "pairing") == "existing-family")
precondition(updated.store.string(forKey: "onboarding") == "true")

// Never combine one identity with another identity's secret.
let partial = CredentialStore()
partial.saveDeviceInstallID("partial-id")
precondition(partial.loadDeviceInstallID() == "partial-id")
precondition(partial.loadDeviceSecret() == nil)
let partialSecret = CredentialStore()
partialSecret.store.set("partial-secret", forKey: StorageKey.deviceSecret)
precondition(partialSecret.loadDeviceInstallID() == nil)
precondition(partialSecret.loadDeviceSecret() == "partial-secret")

// First installation / unavailable Keychain still starts without a role.
DeviceIdentityKeychain.saved = nil
let fresh = CredentialStore()
precondition(fresh.loadDeviceInstallID() == nil)
precondition(fresh.loadDeviceRole() == nil)
print("Device identity: reinstall, upgrade, legacy Codable and partial-state checks passed")
