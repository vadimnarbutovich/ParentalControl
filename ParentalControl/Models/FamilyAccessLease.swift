import Foundation

/// Protocol model for staged, server-verified access. Not an SDK entitlement:
/// a receipt is bound to the current family AND pairing. Demo has a hard
/// deadline; paid status is cached until an authenticated newer decision.
/// Shared by host/NSE/monitor. Rollout remains server-controlled and disabled
/// until hardware acceptance of expiry, release and renewal is complete.
nonisolated struct FamilyAccessLease: Codable, Equatable, Sendable {
    enum State: String, Codable, Sendable {
        case setup, demo, paid, expired
        case verificationRequired = "verification_required"
    }
    let protocolVersion: Int
    let familyID: UUID
    let pairingID: UUID
    let revision: Int
    let issuedAtMs: Int64
    let controlUntilMs: Int64?
    let nextCheckAtMs: Int64
    let state: State

    func isValid(family: UUID, pairing: UUID) -> Bool {
        guard protocolVersion == 1, familyID == family, pairingID == pairing,
              revision > 0, issuedAtMs > 0,
              issuedAtMs < Int64.max - 86_400_000,
              nextCheckAtMs >= issuedAtMs,
              nextCheckAtMs <= issuedAtMs + 900_000 else { return false }
        switch state {
        case .demo, .paid:
            guard let controlUntilMs else { return false }
            return controlUntilMs > issuedAtMs && controlUntilMs <= issuedAtMs + 86_400_000
                && nextCheckAtMs <= controlUntilMs
        case .setup, .expired, .verificationRequired:
            return controlUntilMs == nil
        }
    }

    /// Older responses cannot replace a newer decision. Same-revision paid
    /// snapshots may refresh the wire horizon; demo cannot extend its deadline.
    func mayReplace(_ previous: Self?, family: UUID, pairing: UUID) -> Bool {
        guard isValid(family: family, pairing: pairing) else { return false }
        guard let previous else { return true }
        guard previous.familyID == family, previous.pairingID == pairing else { return true }
        // Ignore even identical replays: replacing the receipt would reset its
        // monotonic anchor and incorrectly grant another full lease interval.
        if revision == previous.revision {
            if state == .paid && previous.state == .paid {
                return issuedAtMs > previous.issuedAtMs
            }
            // A new authenticated snapshot may re-anchor after a reboot, but
            // never replay the same response or extend its absolute deadline.
            return issuedAtMs > previous.issuedAtMs
                && controlUntilMs == previous.controlUntilMs && state == previous.state
        }
        return revision > previous.revision && issuedAtMs >= previous.issuedAtMs
    }
}

/// Demo uses request-start clocks, not a mutable wall-clock deadline. Paid access
/// is the cached authenticated decision, including offline, sleep and reboot.
/// Neither clock changes nor a network failure can revive a confirmed revocation.
nonisolated struct ReceivedFamilyAccessLease: Codable, Equatable, Sendable {
    let lease: FamilyAccessLease
    let requestWallTime: TimeInterval
    let requestUptime: TimeInterval

    /// Honour the server's renewal check independently of the longer continuity
    /// lease. Reboot/invalid clock requests revalidation, never extra access.
    func needsRefresh(uptime: TimeInterval) -> Bool {
        guard uptime.isFinite, requestUptime.isFinite, uptime >= requestUptime else { return true }
        return uptime - requestUptime >= Double(lease.nextCheckAtMs - lease.issuedAtMs) / 1000
    }

    func canControl(family: UUID, pairing: UUID, wallTime: TimeInterval,
                    uptime: TimeInterval) -> Bool {
        guard lease.isValid(family: family, pairing: pairing) else { return false }
        // Paid offline access is the last authenticated decision, not a device
        // clock inference. Sleep/reboot/period boundaries must not remove a
        // parent's shield. A newer expired/released receipt revokes immediately.
        if lease.state == .paid { return true }
        guard
              let deadline = lease.controlUntilMs,
              requestWallTime.isFinite, requestUptime.isFinite,
              wallTime.isFinite, uptime.isFinite,
              requestUptime >= 0, uptime >= requestUptime else { return false }
        // Anchor before the HTTP request, not on receipt. A slow response must
        // not extend the server's deadline by its network transit time.
        let elapsed = uptime - requestUptime
        let wallElapsed = wallTime - requestWallTime
        // Time-zone changes do not affect Unix time. A changed boot epoch,
        // manual clock adjustment, or corrupt persisted clock fails safely.
        guard abs(wallElapsed - elapsed) <= 5 else { return false }
        return elapsed >= 0 && elapsed < Double(deadline - lease.issuedAtMs) / 1000
    }
}
