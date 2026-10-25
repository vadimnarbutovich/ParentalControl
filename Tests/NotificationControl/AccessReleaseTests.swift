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
                   familyID: UUID? = nil, pairingID: UUID? = nil) -> FamilyAccessLease {
            .init(protocolVersion: 1, familyID: familyID ?? family, pairingID: pairingID ?? child,
                  revision: revision, issuedAtMs: 1_000_000,
                  controlUntilMs: state == .paid || state == .demo ? 1_100_000 : nil,
                  nextCheckAtMs: 1_050_000, state: state)
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
        for state in [FamilyAccessLease.State.paid, .demo, .setup, .verificationRequired] {
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
        print("PASS: \(checks) access release acknowledgement checks")
    }
}
