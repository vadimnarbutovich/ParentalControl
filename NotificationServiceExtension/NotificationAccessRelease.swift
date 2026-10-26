import Foundation

/// Only an authenticated, accepted expiry response can complete a release wake.
/// A generic HTTP error or a missing local receipt is not an acknowledgement.
enum NotificationAccessRelease {
    private struct Denial: Decodable {
        let error: String
        let access: Access
        struct Access: Decodable {
            let enforced: Bool
        }
    }
    private struct Envelope: Decodable { let access: FamilyAccessLease }

    static func revision(status: Int, data: Data, current: FamilyAccessLease?, family: UUID) -> Int? {
        guard status == 402,
              let denial = try? JSONDecoder().decode(Denial.self, from: data),
              denial.error == "access_required", denial.access.enforced,
              let lease = try? JSONDecoder().decode(Envelope.self, from: data).access,
              lease.state == .expired, lease == current,
              lease.isValid(family: family, pairing: lease.pairingID) else { return nil }
        return lease.revision
    }
}
