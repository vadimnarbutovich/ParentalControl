import Foundation

@main
struct AccessReleaseTests {
    static func main() throws {
        let family = UUID(), child = UUID()
        var checks = 0
        func check(_ value: Bool, _ message: String) {
            precondition(value, message); checks += 1
        }
        func lease(_ state: FamilyAccessLease.State = .expired, revision: Int = 4,
                   familyID: UUID? = nil, pairingID: UUID? = nil, issuedAt: Int64 = 1_000_000) -> FamilyAccessLease {
            .init(protocolVersion: 1, familyID: familyID ?? family, pairingID: pairingID ?? child,
                  revision: revision, issuedAtMs: issuedAt,
                  controlUntilMs: state == .paid || state == .demo ? issuedAt + 100_000 : nil,
                  nextCheckAtMs: issuedAt + 50_000, state: state)
        }
        func body(_ value: FamilyAccessLease, enforced: Bool = true, error: String = "access_required") throws -> Data {
            var access = try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as! [String: Any]
            access["enforced"] = enforced
            return try JSONSerialization.data(withJSONObject: ["error": error, "access": access])
        }
        let expired = lease(), data = try body(lease())
        func revision(_ status: Int = 402, _ input: Data? = nil, _ current: FamilyAccessLease? = nil) -> Int? {
            NotificationAccessRelease.revision(status: status, data: input ?? data,
                current: current ?? expired, family: family)
        }
        check(revision() == 4, "Accepted authenticated expiry can acknowledge release")
        for status in [200, 401, 403, 409, 500] {
            check(revision(status) == nil, "Only access denial authorizes release ACK")
        }
        check(revision(402, Data("{}".utf8)) == nil, "Malformed response must retry")
        check(revision(402, try body(expired, enforced: false)) == nil, "Legacy access is not expired")
        check(revision(402, try body(expired, error: "other")) == nil, "Unrelated error must retry")
        check(NotificationAccessRelease.revision(status: 402, data: data, current: nil, family: family) == nil,
              "Missing receipt never acknowledges")
        for state in [FamilyAccessLease.State.paid, .demo, .setup] {
            let value = lease(state)
            check(revision(402, try body(value), value) == nil, "Only confirmed expiry, not uncertainty")
        }
        check(revision(402, nil, lease(.paid, revision: 5)) == nil, "Renewal wins over delayed expiry")
        check(revision(402, nil, lease(revision: 5)) == nil, "Different revision requires a new wake")
        check(revision(402, nil, lease(pairingID: UUID())) == nil, "Changed pairing cannot acknowledge")
        let other = lease(familyID: UUID())
        check(revision(402, try body(other), other) == nil, "Wrong family cannot acknowledge")
        let invalid = lease(revision: 0)
        check(revision(402, try body(invalid), invalid) == nil, "Invalid receipt cannot acknowledge")
        for state in [FamilyAccessLease.State.expired, .verificationRequired] {
            let denied = lease(state)
            check(revision(402, try body(denied), denied) == 4, "Accepted server denial acknowledges release")
            let demo = lease(.demo)
            let atDeadline = lease(state, issuedAt: 1_100_000)
            check(!atDeadline.mayReplace(demo, family: family, pairing: child), "Receipt replacement policy is unchanged")
            check(revision(402, try body(atDeadline), demo) == 4, "Same-revision demo expiry can acknowledge without replacing receipt")
            let afterDeadline = lease(state, issuedAt: 1_100_001)
            check(revision(402, try body(afterDeadline), demo) == 4, "Later denial also acknowledges")
            check(revision(402, try body(lease(state, issuedAt: 1_099_999)), demo) == nil, "Cannot acknowledge before original demo deadline")
            check(revision(402, try body(atDeadline), lease(.paid)) == nil, "Same-revision paid cache is never treated as expired demo")
            check(revision(402, try body(atDeadline), lease(.demo, revision: 5)) == nil, "Newer demo receipt wins")
            check(revision(402, try body(atDeadline), lease(.paid, revision: 5)) == nil, "Newer purchase wins")
            check(revision(402, try body(atDeadline), lease(.demo, pairingID: UUID())) == nil, "Demo denial cannot cross pairing")
            check(revision(402, try body(atDeadline), lease(.demo, familyID: UUID())) == nil, "Demo denial cannot cross family")
            check(revision(402, try body(atDeadline, enforced: false), demo) == nil, "Unenforced response cannot complete demo release")
            check(revision(500, try body(atDeadline), demo) == nil, "Server failure cannot complete demo release")
        }
        print("PASS: \(checks) access release acknowledgement checks")
    }
}
