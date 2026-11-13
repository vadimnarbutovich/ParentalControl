import Foundation

let family = UUID()
let pairing = UUID()
let now: Int64 = 1_792_576_800_000
var count = 0
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    precondition(condition(), message)
    count += 1
}
func lease(revision: Int = 1, issued: Int64 = now, end: Int64? = now + 86_400_000,
           state: FamilyAccessLease.State = .demo, familyID: UUID = family,
           pairingID: UUID = pairing) -> FamilyAccessLease {
    .init(protocolVersion: 1, familyID: familyID, pairingID: pairingID, revision: revision,
          issuedAtMs: issued, controlUntilMs: end, nextCheckAtMs: min(issued + 900_000, end ?? Int64.max), state: state)
}
let demo = lease()
check(demo.isValid(family: family, pairing: pairing), "Valid bounded trial")
check(!demo.isValid(family: UUID(), pairing: pairing), "Wrong family")
check(!demo.isValid(family: family, pairing: UUID()), "Wrong pairing")
check(!lease(end: nil, state: .paid).isValid(family: family, pairing: pairing), "Lifetime still requires lease")
check(!lease(end: now + 86_400_001).isValid(family: family, pairing: pairing), "No unbounded offline access")
check(!lease(revision: 0).isValid(family: family, pairing: pairing), "Invalid revision")
check(!lease(state: .expired).isValid(family: family, pairing: pairing), "Expired must not contain control deadline")
let renewed = lease(revision: 3, issued: now + 1000, end: now + 86_401_000, state: .paid)
let oldRelease = lease(revision: 2, issued: now + 500, end: nil, state: .expired)
check(!oldRelease.mayReplace(renewed, family: family, pairing: pairing), "Late release cannot override renewal")
check(renewed.mayReplace(demo, family: family, pairing: pairing), "New revision wins")
check(!demo.mayReplace(demo, family: family, pairing: pairing), "Replay preserves original clock anchor")
check(lease(issued: now + 1000).mayReplace(demo, family: family, pairing: pairing), "Fresh snapshot can re-anchor after reboot without extending expiry")
check(!lease(issued: now + 1000, end: now + 86_401_000).mayReplace(demo, family: family, pairing: pairing), "Same revision cannot extend lease")
check(!lease(revision: 4, issued: now - 1, end: now + 1000).mayReplace(renewed, family: family, pairing: pairing), "Server clock regression")
let receipt = ReceivedFamilyAccessLease(lease: demo, requestWallTime: 100000, requestContinuousTime: 100)
check(!receipt.needsRefresh(continuousTime: 999), "No premature refresh")
check(receipt.needsRefresh(continuousTime: 1000), "Honour server nextCheckAt at exact deadline")
check(receipt.needsRefresh(continuousTime: 10), "Reboot requests refresh")
let earlyLease = FamilyAccessLease(protocolVersion: 1, familyID: family, pairingID: pairing, revision: 5,
    issuedAtMs: now, controlUntilMs: now + 86_400_000, nextCheckAtMs: now + 30_000, state: .paid)
let earlyReceipt = ReceivedFamilyAccessLease(lease: earlyLease, requestWallTime: 100000, requestContinuousTime: 100)
check(earlyReceipt.needsRefresh(continuousTime: 130), "Early renewal refresh before continuity expires")
check(earlyReceipt.canControl(family: family, pairing: pairing, wallTime: 100180, continuousTime: 280), "Sandbox billing boundary does not interrupt continuity")
check(earlyReceipt.canControl(family: family, pairing: pairing, wallTime: 100000 + 86400 * 7, continuousTime: 604900), "Paid cache survives seven offline days")
check(earlyReceipt.canControl(family: family, pairing: pairing, wallTime: 200000, continuousTime: 10), "Paid cache survives reboot")
check(earlyReceipt.canControl(family: family, pairing: pairing, wallTime: 99990, continuousTime: 180), "Clock drift does not unlock paid child")
let revokedLease = lease(revision: 6, issued: now + 1000, end: nil, state: .expired)
check(revokedLease.mayReplace(earlyLease, family: family, pairing: pairing), "Canonical negative replaces paid cache")
let revokedReceipt = ReceivedFamilyAccessLease(lease: revokedLease, requestWallTime: 100001, requestContinuousTime: 101)
check(!revokedReceipt.canControl(family: family, pairing: pairing, wallTime: 100001, continuousTime: 101), "Canonical negative revokes immediately")
check(!earlyLease.mayReplace(revokedLease, family: family, pairing: pairing), "Late positive response cannot revive expired access")
check(receipt.canControl(family: family, pairing: pairing, wallTime: 100000, continuousTime: 100), "Initially active")
check(receipt.canControl(family: family, pairing: pairing, wallTime: 186399, continuousTime: 86499), "Before exact expiry")
check(!receipt.canControl(family: family, pairing: pairing, wallTime: 186400, continuousTime: 86500), "Exact expiry")
check(!receipt.canControl(family: family, pairing: pairing, wallTime: 100100, continuousTime: 10), "Reboot needs revalidation")
check(!receipt.canControl(family: family, pairing: pairing, wallTime: 95000, continuousTime: 200), "Clock rollback cannot extend")
check(!receipt.canControl(family: family, pairing: pairing, wallTime: .nan, continuousTime: 200), "Invalid clock")
check(!receipt.canControl(family: family, pairing: UUID(), wallTime: 100000, continuousTime: 100), "Old family lease not reused after re-pairing")
let roundTrip = try JSONDecoder().decode(ReceivedFamilyAccessLease.self, from: JSONEncoder().encode(receipt))
check(roundTrip == receipt, "Persisted receipt round trip")
// Demo clock regression: sleep advances both wall and continuous clocks, even
// when no process is running and the awake-only clock barely advances.
for slept in [149.076, 3600.0, 8 * 3600.0, 23 * 3600.0] {
    let wall = receipt.requestWallTime + slept
    let continuous = receipt.requestContinuousTime! + slept
    check(receipt.canControl(family: family, pairing: pairing, wallTime: wall, continuousTime: continuous),
          "Active demo survives \(slept) seconds including sleep")
    check(receipt.remainingDemoSeconds(wallTime: wall, continuousTime: continuous) == 86400 - slept,
          "Expiry monitor uses the same sleep-inclusive remainder")
}
check(receipt.needsRefresh(continuousTime: 100 + 8 * 3600), "Overnight sleep also advances refresh deadline")
check(receipt.remainingDemoSeconds(wallTime: 186400, continuousTime: 86500) == 0,
      "Demo expires exactly after 24 hours, including sleep")
check(!receipt.canControl(family: family, pairing: pairing, wallTime: 200000, continuousTime: 100100),
      "Waking after expiry does not grant a fresh demo")
check(receipt.remainingDemoSeconds(wallTime: 100120, continuousTime: 220) == 86280,
      "Slow request or sleep during network transit consumes the original interval")
check(receipt.remainingDemoSeconds(wallTime: 100469.743, continuousTime: 569.743)! < 85931,
      "Reproduced elapsed time no longer fails after 149 seconds of sleep")
check(receipt.remainingDemoSeconds(wallTime: 100469.743, continuousTime: 420.667) == nil,
      "Clock-domain mismatch remains rejected, not hidden by a larger tolerance")
check(receipt.remainingDemoSeconds(wallTime: 100000 + 8*3600, continuousTime: 10) == nil,
      "Reboot invalidates demo until authenticated refresh")
check(receipt.remainingDemoSeconds(wallTime: 100000 + 8*3600, continuousTime: 200) == nil,
      "Reboot with uptime past old anchor still fails the wall/clock comparison")
check(receipt.remainingDemoSeconds(wallTime: 99900, continuousTime: 200) == nil,
      "Clock rollback does not extend access")
check(receipt.remainingDemoSeconds(wallTime: 100200, continuousTime: 200) == nil,
      "Manual forward clock change still requires revalidation")
for invalid in [Double.nan, Double.infinity, -1] {
    check(receipt.remainingDemoSeconds(wallTime: 100000, continuousTime: invalid) == nil,
          "Invalid current clock fails closed")
    check(receipt.needsRefresh(continuousTime: invalid), "Invalid clock requests refresh")
}

// Synthesized decoding must recognize missing version/anchor as legacy, rather
// than using initializer defaults to reinterpret an old awake-time value.
func legacyReceipt(_ source: ReceivedFamilyAccessLease) throws -> ReceivedFamilyAccessLease {
    var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(source)) as! [String: Any]
    json.removeValue(forKey: "clockVersion")
    json.removeValue(forKey: "requestContinuousTime")
    json["requestUptime"] = 100
    return try JSONDecoder().decode(ReceivedFamilyAccessLease.self, from: JSONSerialization.data(withJSONObject: json))
}
let legacyDemo = try legacyReceipt(receipt)
check(legacyDemo.clockVersion == nil && legacyDemo.requestContinuousTime == nil, "Old receipts decode without clock conversion")
check(legacyDemo.needsRefresh(continuousTime: 100), "Old receipt forces existing authenticated refresh")
check(!legacyDemo.canControl(family: family, pairing: pairing, wallTime: 100000, continuousTime: 100),
      "Never grant demo from a legacy clock anchor")
let legacyPaid = try legacyReceipt(earlyReceipt)
check(legacyPaid.canControl(family: family, pairing: pairing, wallTime: 200000, continuousTime: 10),
      "Paid legacy receipt survives migration offline and reboot")
check(!legacyPaid.canControl(family: UUID(), pairing: pairing, wallTime: 200000, continuousTime: 10),
      "Legacy paid still bound to family")
check(!demo.mayReplace(legacyDemo.lease, family: family, pairing: pairing), "Migration never accepts replay as renewal")
let freshDemo = lease(issued: now + 1000)
check(freshDemo.mayReplace(legacyDemo.lease, family: family, pairing: pairing), "Fresh same-revision snapshot migrates clock")
let migrated = ReceivedFamilyAccessLease(lease: freshDemo, requestWallTime: 100001, requestContinuousTime: 500)
check(migrated.canControl(family: family, pairing: pairing, wallTime: 100001, continuousTime: 500), "Fresh authenticated demo works")
check(migrated.remainingDemoSeconds(wallTime: 100001, continuousTime: 500) == 86399, "Migration preserves original server deadline")
var unknownClock = try JSONSerialization.jsonObject(with: JSONEncoder().encode(receipt)) as! [String: Any]
unknownClock["clockVersion"] = 99
let futureReceipt = try JSONDecoder().decode(ReceivedFamilyAccessLease.self, from: JSONSerialization.data(withJSONObject: unknownClock))
check(futureReceipt.needsRefresh(continuousTime: 100), "Unknown clock version requires refresh")
check(!futureReceipt.canControl(family: family, pairing: pairing, wallTime: 100000, continuousTime: 100), "Unknown clock cannot grant demo")
check(roundTrip.clockVersion == 2 && roundTrip.requestContinuousTime == 100, "Modern anchor and version persist")
let clockSample = FamilyAccessClock.now
check(clockSample.isFinite && clockSample > 0 && FamilyAccessClock.now >= clockSample, "Real continuous clock is finite and monotonic")

var presentations = FamilyAccessPresentationStack()
let root = UUID(), editor = UUID(), nested = UUID()
check(presentations.presenter == nil, "No missing presenter assumed")
presentations.register(root, isRoot: true)
check(presentations.presenter == root, "Root handles dashboard access denial")
presentations.register(editor, isRoot: false)
check(presentations.presenter == editor, "Editor owns paywall without dismissing draft")
presentations.register(root, isRoot: true)
check(presentations.presenter == editor, "Root appearance cannot steal editor presentation")
presentations.register(nested, isRoot: false)
check(presentations.presenter == nested, "Nested modal is foremost")
presentations.unregister(nested)
check(presentations.presenter == editor, "Closing nested modal restores editor owner")
presentations.register(editor, isRoot: false)
presentations.unregister(editor)
check(presentations.presenter == root, "Repeated onAppear does not leave stale modal owner")
presentations.unregister(root)
check(presentations.presenter == nil, "No retained dismissed presenter")
print("PASS: \(count) subscription lease and presentation checks")
