import Foundation
import Security

var checks = 0
func check(_ value: @autoclosure () -> Bool, _ message: String) {
    precondition(value(), message)
    checks += 1
}
final class FakeKeychain {
    var values: [String: Data] = [:]
    var readError: OSStatus?
    var writeError: OSStatus?
    var deleteError: OSStatus?
    var writes = 0
    var deletes = 0
    var adapter: ParentPinKeychain {
        ParentPinKeychain(read: { key in
            if let error = self.readError { return (error, nil) }
            return self.values[key].map { (errSecSuccess, $0) } ?? (errSecItemNotFound, nil)
        }, write: { key, data in
            self.writes += 1
            if let error = self.writeError { return error }
            self.values[key] = data
            return errSecSuccess
        }, delete: { key in
            self.deletes += 1
            if let error = self.deleteError { return error }
            self.values.removeValue(forKey: key)
            return errSecSuccess
        })
    }
}
let fake = FakeKeychain()
let service = ParentPinService(keychain: fake.adapter)
let salt = Data(repeating: 7, count: 16)
let first = ParentPinMetadata(hash: service.hashPin("1234", salt: salt), salt: salt,
                              updatedAt: Date(timeIntervalSince1970: 1000))
let next = ParentPinMetadata(hash: service.hashPin("5678", salt: salt), salt: salt,
                             updatedAt: Date(timeIntervalSince1970: 2000))
check(service.storageState() == .missing, "Initially missing")
check(service.saveMetadata(first), "Save atomic record")
check(fake.values["parent_pin_record_v1"] != nil, "Single record exists")
check(fake.values["parent_pin_hash"] == nil, "No separate hash")
check(service.loadMetadata() == first, "Roundtrip")
check(service.verifyPin("1234") == .success, "Offline PIN succeeds")
fake.readError = errSecInteractionNotAllowed
check(service.storageState() == .unavailable, "Locked is not missing")
check(service.verifyPin("1234") == .unavailable, "Locked fails closed")
fake.readError = nil
check(service.loadMetadata() == first, "Unlock restores local PIN without server")
let deletesBeforeFailure = fake.deletes
fake.writeError = errSecInteractionNotAllowed
check(!service.saveMetadata(next), "Write failure reported")
check(fake.deletes == deletesBeforeFailure, "Failed update never deletes old record")
check(service.loadMetadata() == first, "Failed replacement preserves old data")
check(!service.clearMetadata(), "Failed clear reported")
check(service.loadMetadata() == first, "Failed clear preserves data")
fake.writeError = nil
check(service.saveMetadata(next), "Successful replacement")
check(service.verifyPin("1234") == .wrongPin(remainingAttempts: 4), "Old PIN rejected")
check(service.verifyPin("5678") == .success, "New PIN accepted")
for _ in 0..<4 { _ = service.verifyPin("0000") }
if case .lockedOut = service.verifyPin("0000") { checks += 1 } else { fatalError("Lockout required") }
check(service.saveMetadata(next), "Repeated sync succeeds")
if case .lockedOut = service.verifyPin("5678") { checks += 1 } else { fatalError("Same PIN sync must not reset lockout") }
check(service.clearMetadata(), "Clear creates tombstone")
check(service.storageState() == .missing, "Tombstone means no PIN")
fake.values["parent_pin_hash"] = first.hash
fake.values["parent_pin_salt"] = first.salt
fake.values["parent_pin_updated_at"] = Data("1970-01-01T00:16:40Z".utf8)
check(service.storageState() == .missing, "Tombstone cannot revive leftover legacy PIN")
fake.values.removeValue(forKey: "parent_pin_record_v1")
fake.writeError = errSecNotAvailable
check(service.loadMetadata() == first, "Failed migration preserves usable legacy PIN")
check(fake.values["parent_pin_hash"] == first.hash, "Failed migration retains legacy data")
fake.writeError = nil
check(service.loadMetadata() == first, "Legacy migration succeeds")
check(fake.values["parent_pin_record_v1"] != nil, "Migrated record persisted")
check(fake.values["parent_pin_hash"] == nil, "Legacy removed only after success")
fake.values["parent_pin_record_v1"] = Data("invalid".utf8)
check(service.storageState() == .corrupted, "Corrupted differs from missing")
check(service.verifyPin("1234") == .unavailable, "Corrupted cannot authorize")
fake.values.removeAll()
fake.values["parent_pin_hash"] = first.hash
check(service.storageState() == .corrupted, "Partial legacy is corrupted")
check(service.saveMetadata(first), "Repair partial legacy from authenticated metadata")
check(service.verifyPin("1234") == .success, "Repaired PIN works offline")
check(ParentPinMetadata.fromBackend(hashBase64: "", saltBase64: "", updatedAt: Date()) == nil,
      "Empty decoded data rejected")
let now = Date(timeIntervalSince1970: 10000)
check(!ParentPinRecoveryPolicy.shouldAttempt(state: .available(first), requiresRefresh: false,
    lastAttempt: nil, now: now), "Valid local PIN costs zero requests")
check(!ParentPinRecoveryPolicy.shouldAttempt(state: .unavailable, requiresRefresh: true,
    lastAttempt: nil, now: now), "Locked Keychain cannot trigger futile network recovery")
check(ParentPinRecoveryPolicy.shouldAttempt(state: .missing, requiresRefresh: false,
    lastAttempt: nil, now: now), "Missing PIN can recover independently of subscription")
check(ParentPinRecoveryPolicy.shouldAttempt(state: .corrupted, requiresRefresh: false,
    lastAttempt: nil, now: now), "Corrupted PIN can recover")
check(ParentPinRecoveryPolicy.shouldAttempt(state: .available(first), requiresRefresh: true,
    lastAttempt: nil, now: now), "Observed but unsaved remote change requires refresh")
check(!ParentPinRecoveryPolicy.shouldAttempt(state: .missing, requiresRefresh: false,
    lastAttempt: now.addingTimeInterval(-299), now: now), "Repeated taps cannot retry early")
check(ParentPinRecoveryPolicy.shouldAttempt(state: .missing, requiresRefresh: false,
    lastAttempt: now.addingTimeInterval(-300), now: now), "Retry allowed after cooldown")
check(!ParentPinRecoveryPolicy.shouldAttempt(state: .missing, requiresRefresh: false,
    lastAttempt: now.addingTimeInterval(10), now: now), "Clock rollback cannot bypass cooldown")
print("Parent PIN: \(checks) checks passed")
