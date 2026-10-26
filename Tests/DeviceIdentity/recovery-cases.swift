import Foundation

enum DeviceRole { case parent, child }
struct DevicePairingState: Equatable { let familyID: UUID }
struct Registration { let pairingState: DevicePairingState?; let deviceRole: DeviceRole? }
enum Failure: Error { case offline }
final class Credentials {
    var secret: String? = "retained-secret"
    func loadDeviceSecret() -> String? { secret }
}
@MainActor final class Remote {
    var result = Registration(pairingState: nil, deviceRole: nil)
    var failInspection = false
    var failUnlink = false
    var inspections = 0
    var unlinks: [UUID?] = []
    func inspectDeviceRegistration() async throws -> Registration {
        inspections += 1
        await Task.yield()
        if failInspection { throw Failure.offline }
        return result
    }
    func unlinkDevices(expectedFamilyID: UUID?) async throws {
        unlinks.append(expectedFamilyID)
        if failUnlink { throw Failure.offline }
    }
}
@MainActor final class RecoveryHarness {
    var deviceRole: DeviceRole?
    let storage = Credentials()
    let remoteSyncService = Remote()
    var recoveredFamily: DevicePairingState?
    var recoveredDeviceRole: DeviceRole?
    var isCheckingInstallationRecovery = false
    var installationRecoveryFailed = false
    var isResettingRecoveredFamily = false
    var didCheckInstallationRecovery = false
    var installationRecoveryCheckInFlight = false
    var recoveryPinFamilyID: UUID?
    var recoveryPinAuthorizedFamilyID: UUID?
    var isParentModeActive = false
    var remoteStatusMessage: String?
    var recoverySetupFamilyID: UUID?
    func setRecoverySetupFamily(_ familyID: UUID?) { recoverySetupFamilyID = familyID }
    var cleared = 0
    func chooseDeviceRole(_ role: DeviceRole) { deviceRole = role }
    func clearPairing() { cleared += 1; isParentModeActive = false }
    // ACTUAL_RECOVERY_METHODS
}

@MainActor func runRecoveryChecks() async {
    let family = DevicePairingState(familyID: UUID())
    let parent = RecoveryHarness()
    parent.remoteSyncService.result = Registration(pairingState: family, deviceRole: .parent)
    async let first: Void = parent.checkInstallationRecovery()
    async let duplicate: Void = parent.checkInstallationRecovery()
    _ = await (first, duplicate)
    precondition(parent.remoteSyncService.inspections == 1)
    precondition(parent.recoveredFamily == family && parent.deviceRole == nil)
    precondition(parent.remoteSyncService.unlinks.isEmpty)
    await parent.checkInstallationRecovery()
    precondition(parent.remoteSyncService.inspections == 1)
    parent.restoreRecoveredFamily()
    precondition(parent.deviceRole == .parent && parent.recoveredFamily == nil)
    precondition(parent.recoverySetupFamilyID == family.familyID)
    precondition(parent.cleared == 0 && parent.remoteSyncService.unlinks.isEmpty)
    await parent.checkInstallationRecovery(retry: true)
    precondition(parent.remoteSyncService.inspections == 1)

    let fresh = RecoveryHarness()
    fresh.storage.secret = nil
    await fresh.checkInstallationRecovery()
    precondition(fresh.remoteSyncService.inspections == 0)
    let clearedOnServer = RecoveryHarness()
    await clearedOnServer.checkInstallationRecovery()
    precondition(clearedOnServer.recoveredFamily == nil && !clearedOnServer.installationRecoveryFailed)
    precondition(clearedOnServer.deviceRole == nil)

    let offline = RecoveryHarness()
    offline.remoteSyncService.failInspection = true
    await offline.checkInstallationRecovery()
    precondition(offline.installationRecoveryFailed && !offline.isCheckingInstallationRecovery)
    offline.restoreRecoveredFamily()
    await offline.resetRecoveredFamily()
    precondition(offline.deviceRole == nil && offline.remoteSyncService.unlinks.isEmpty)
    await offline.checkInstallationRecovery()
    precondition(offline.remoteSyncService.inspections == 1)
    offline.remoteSyncService.failInspection = false
    offline.remoteSyncService.result = Registration(pairingState: family, deviceRole: .parent)
    await offline.checkInstallationRecovery(retry: true)
    precondition(!offline.installationRecoveryFailed && offline.recoveredFamily == family)
    offline.remoteSyncService.failUnlink = true
    await offline.resetRecoveredFamily()
    precondition(offline.recoveredFamily == family && offline.cleared == 0)
    precondition(offline.installationRecoveryFailed && !offline.isResettingRecoveredFamily)
    offline.remoteSyncService.failUnlink = false
    await offline.checkInstallationRecovery(retry: true)
    await offline.resetRecoveredFamily()
    precondition(offline.recoveredFamily == nil && offline.deviceRole == nil && offline.cleared == 1)
    precondition(offline.storage.secret == "retained-secret")
    precondition(offline.remoteSyncService.unlinks.allSatisfy { $0 == family.familyID })

    let child = RecoveryHarness()
    child.remoteSyncService.result = Registration(pairingState: family, deviceRole: .child)
    await child.checkInstallationRecovery()
    await child.resetRecoveredFamily()
    precondition(child.remoteSyncService.unlinks.isEmpty)
    child.recoveryPinAuthorizedFamilyID = UUID()
    await child.resetRecoveredFamily()
    precondition(child.remoteSyncService.unlinks.isEmpty)
    child.recoveryPinAuthorizedFamilyID = family.familyID
    await child.resetRecoveredFamily()
    precondition(child.remoteSyncService.unlinks == [family.familyID])
    precondition(child.recoveryPinAuthorizedFamilyID == nil)

    let malformed = RecoveryHarness()
    malformed.remoteSyncService.result = Registration(pairingState: family, deviceRole: nil)
    await malformed.checkInstallationRecovery()
    precondition(malformed.installationRecoveryFailed)
    print("Family recovery: single-flight, restore, offline, retry, reset and child authorization checks passed")
}
await runRecoveryChecks()
