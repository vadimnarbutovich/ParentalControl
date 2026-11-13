import Foundation
import Darwin

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

/// A boot-relative clock that continues advancing during device sleep.
/// All processes sharing access receipts must use this same clock domain.
nonisolated enum FamilyAccessClock {
    private static let secondsPerTick: Double = {
        var info = mach_timebase_info_data_t()
        guard mach_timebase_info(&info) == KERN_SUCCESS, info.denom != 0 else { return .nan }
        return Double(info.numer) / Double(info.denom) / 1_000_000_000
    }()

    static var now: TimeInterval { Double(mach_continuous_time()) * secondsPerTick }
}

/// Demo uses request-start clocks, not a mutable wall-clock deadline. Paid access
/// is the cached authenticated decision, including offline, sleep and reboot.
/// Neither clock changes nor a network failure can revive a confirmed revocation.
nonisolated struct ReceivedFamilyAccessLease: Codable, Equatable, Sendable {
    let lease: FamilyAccessLease
    let requestWallTime: TimeInterval
    // Optional only to decode pre-fix receipts. Never reinterpret their old
    // requestUptime (awake-only) as a continuous clock value.
    let requestContinuousTime: TimeInterval?
    let clockVersion: Int?

    init(lease: FamilyAccessLease, requestWallTime: TimeInterval, requestContinuousTime: TimeInterval) {
        self.lease = lease
        self.requestWallTime = requestWallTime
        self.requestContinuousTime = requestContinuousTime
        self.clockVersion = 2
    }

    /// Old anchors and a reboot require an authenticated refresh. Paid access
    /// remains valid while that refresh is unavailable.
    func needsRefresh(continuousTime: TimeInterval) -> Bool {
        guard clockVersion == 2, let requestContinuousTime,
              continuousTime.isFinite, requestContinuousTime.isFinite,
              requestContinuousTime >= 0, continuousTime >= requestContinuousTime else { return true }
        return continuousTime - requestContinuousTime >= Double(lease.nextCheckAtMs - lease.issuedAtMs) / 1000
    }

    /// Shared by the access gate and the expiry monitor, so sleep cannot make
    /// them disagree. Zero means actual expiry; nil means an untrusted anchor.
    func remainingDemoSeconds(wallTime: TimeInterval, continuousTime: TimeInterval) -> TimeInterval? {
        guard lease.state == .demo, lease.isValid(family: lease.familyID, pairing: lease.pairingID),
              clockVersion == 2, let requestContinuousTime, let deadline = lease.controlUntilMs,
              requestWallTime.isFinite, requestContinuousTime.isFinite,
              wallTime.isFinite, continuousTime.isFinite,
              requestContinuousTime >= 0, continuousTime >= requestContinuousTime else { return nil }
        // Anchored BEFORE the HTTP request: sleep/network transit cannot grant
        // extra demo time. Both clocks advance while the device is asleep.
        let elapsed = continuousTime - requestContinuousTime
        let wallElapsed = wallTime - requestWallTime
        // Preserve the existing protection against reboot/clock adjustment.
        guard abs(wallElapsed - elapsed) <= 5 else { return nil }
        return max(0, Double(deadline - lease.issuedAtMs) / 1000 - elapsed)
    }

    func canControl(family: UUID, pairing: UUID, wallTime: TimeInterval,
                    continuousTime: TimeInterval) -> Bool {
        guard lease.isValid(family: family, pairing: pairing) else { return false }
        // Paid access is still the last authenticated decision. In particular,
        // an old receipt or a reboot must not unlock a paid child's apps.
        if lease.state == .paid { return true }
        guard let remaining = remainingDemoSeconds(wallTime: wallTime, continuousTime: continuousTime) else { return false }
        return remaining > 0
    }
}
