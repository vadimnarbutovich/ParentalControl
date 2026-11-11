import Foundation

// Isolated defaults: never touch a real family or the application group.
nonisolated enum RemoteControlGate {
    static let suite = "ParentalControl.ClockTests.\(UUID().uuidString)"
    static let defaults = UserDefaults(suiteName: suite)
    static func withLock(_ body: () -> Void) -> Bool { body(); return true }
}

@main
struct ClockStoreTests {
    static func main() throws {
        let d = RemoteControlGate.defaults!
        defer { d.removePersistentDomain(forName: RemoteControlGate.suite) }
        let family = UUID(), child = UUID()
        let pairing = try JSONSerialization.data(withJSONObject: [
            "familyID": family.uuidString, "childDeviceID": child.uuidString
        ])
        d.set(pairing, forKey: "parentalcontrol.pairingState")
        d.set(pairing, forKey: "parentalcontrol.accessPairing.v1")
        let key = "parentalcontrol.accessReceipt.v1"
        let issued = Int64(Date().timeIntervalSince1970 * 1000)
        func lease(_ state: String = "demo", revision: Int = 28, offset: Int64 = 0) -> [String: Any] {
            ["protocolVersion": 1, "familyID": family.uuidString,
             "pairingID": child.uuidString, "revision": revision,
             "issuedAtMs": issued + offset, "controlUntilMs": issued + 3600_000,
             "nextCheckAtMs": issued + 900_000, "state": state, "enforced": true]
        }
        func legacy(_ state: String = "demo") throws {
            d.set(try JSONSerialization.data(withJSONObject: ["lease": lease(state),
                "requestWallTime": Date().timeIntervalSince1970,
                "requestUptime": ProcessInfo.processInfo.systemUptime]), forKey: key)
        }
        func accept(_ object: [String: Any], scope: Data? = nil) throws {
            FamilyAccessStore.accept(try JSONSerialization.data(withJSONObject: object),
                pairing: scope ?? pairing, requestWall: Date().timeIntervalSince1970,
                requestContinuousTime: FamilyAccessClock.now)
        }
        var checks = 0
        func check(_ value: Bool, _ message: String) {
            precondition(value, message); checks += 1
        }
        try legacy()
        check(FamilyAccessStore.receipt != nil, "Old receipt must decode")
        check(!FamilyAccessStore.allowed, "Old demo needs authenticated clock migration")
        try accept(lease())
        check(FamilyAccessStore.receipt?.clockVersion == nil, "Exact replay cannot migrate clock")
        try accept(lease(offset: 1))
        check(FamilyAccessStore.receipt?.clockVersion == 2, "Fresh same-revision receipt migrates")
        check(FamilyAccessStore.allowed, "Migrated demo allows management")
        let migrated = d.data(forKey: key)
        try accept(lease(offset: 2))
        check(d.data(forKey: key) == migrated, "Ordinary polling preserves anchor and active operations")
        try accept(lease(revision: 27, offset: 3))
        check(d.data(forKey: key) == migrated, "Older revision cannot replace receipt")
        var extended = lease(offset: 4)
        extended["controlUntilMs"] = issued + 7200_000
        try accept(extended)
        check(d.data(forKey: key) == migrated, "Same revision cannot extend demo")
        var revoked = lease("expired", revision: 29, offset: 5)
        revoked.removeValue(forKey: "controlUntilMs")
        try accept(revoked)
        check(!FamilyAccessStore.allowed, "Confirmed expiry still revokes access")
        try accept(lease(offset: 6))
        check(!FamilyAccessStore.allowed, "Stale demo cannot revive revoked access")
        try legacy("paid")
        check(FamilyAccessStore.allowed, "Legacy paid receipt remains available offline")
        try accept(lease("paid", offset: 1))
        check(FamilyAccessStore.allowed && FamilyAccessStore.receipt?.clockVersion == 2,
              "Paid receipt migrates without losing access")
        let otherPair = try JSONSerialization.data(withJSONObject: [
            "familyID": UUID().uuidString, "childDeviceID": UUID().uuidString
        ])
        d.set(otherPair, forKey: "parentalcontrol.pairingState")
        check(!FamilyAccessStore.allowed, "A changed family cannot inherit access")
        try accept(lease("paid", revision: 30, offset: 7))
        check(!FamilyAccessStore.allowed, "Delayed response for old family cannot grant access")
        print("PASS \(checks) access-store clock migration checks")
    }
}
