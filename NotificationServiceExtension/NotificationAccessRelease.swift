import Foundation

/// Only an authenticated denial consistent with the local receipt can complete a release wake.
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
              lease.state == .expired || lease.state == .verificationRequired,
              let current,
              lease.isValid(family: family, pairing: current.pairingID),
              current.isValid(family: family, pairing: current.pairingID) else { return nil }
        if lease == current { return lease.revision }
        // Natural demo expiry does not increment the purchase revision. The
        // store intentionally rejects a same-revision change of lease state.
        // Acknowledge the release without replacing that receipt, but only if
        // the server's denial is at/after the SAME demo's original deadline.
        // A cached paid receipt or a newer purchase must never enter this path.
        guard current.state == .demo, lease.revision == current.revision,
              let deadline = current.controlUntilMs,
              lease.issuedAtMs >= deadline else { return nil }
        return lease.revision
    }
}
