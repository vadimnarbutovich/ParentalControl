import Foundation

enum DeviceRole { case parent, child }
struct DevicePairingState: Equatable { let familyID: UUID; var isLinked = true }
struct Registration { let pairingState: DevicePairingState?; let deviceRole: DeviceRole? }
enum Failure: Error { case offline }
final class Credentials {
    var secret: String? = "retained-secret"
    func loadDeviceSecret() -> String? { secret }
    var role: DeviceRole?
    func saveDeviceRole(_ role: DeviceRole?) { self.role = role }
}
@MainActor final class Remote {
    var result = Registration(pairingState: nil, deviceRole: nil)
    var failInspection = false
    var failUnlink = false
    var inspections = 0
    var unlinks: [UUID?] = []
    var resets: [UUID] = []
    var failReset = false
    var resetAllowed = true
    func resetPendingSetup(expectedFamilyID: UUID, role: DeviceRole) async throws -> Bool {
        resets.append(expectedFamilyID)
        await Task.yield()
        if failReset { throw Failure.offline }
        return resetAllowed
    }
    func invalidateRegistration() {}
    func inspectDeviceRegistration() async throws -> Registration {
        inspections += 1
        await Task.yield()
        try Task.checkCancellation()
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
    var pendingSetupFamilyID: UUID?
    var isChoosingDeviceRole = false
    var roleSelectionFailed = false
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
    var hasCompletedOnboarding = false
    var remotePollingTask: Task<Void, Never>?
    var parentPairingWaitTask: Task<Void, Never>?
    func setRecoverySetupFamily(_ familyID: UUID?) { recoverySetupFamilyID = familyID }
    var cleared = 0
    func chooseDeviceRole(_ role: DeviceRole) { deviceRole = role }
    func clearPairing() { cleared += 1; isParentModeActive = false }
    // ACTUAL_RECOVERY_METHODS
    // ACTUAL_RETURN_METHOD
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

    await parent.returnToFamilyRecovery()
    precondition(parent.deviceRole == nil && parent.storage.role == nil)
    precondition(parent.recoverySetupFamilyID == nil && parent.recoveredFamily == family)
    precondition(parent.remoteSyncService.unlinks.isEmpty && parent.storage.secret == "retained-secret")
    parent.restoreRecoveredFamily()
    precondition(parent.deviceRole == .parent && parent.recoverySetupFamilyID == family.familyID)
    parent.remoteSyncService.failInspection = true
    await parent.returnToFamilyRecovery()
    precondition(parent.installationRecoveryFailed && !parent.isCheckingInstallationRecovery)
    precondition(parent.deviceRole == nil && parent.remoteSyncService.unlinks.isEmpty)
    parent.remoteSyncService.failInspection = false
    await parent.checkInstallationRecovery(retry: true)
    precondition(parent.recoveredFamily == family && !parent.installationRecoveryFailed)
    parent.restoreRecoveredFamily()
    let leavingScreen = Task { await parent.returnToFamilyRecovery() }
    leavingScreen.cancel()
    await leavingScreen.value
    precondition(parent.recoveredFamily == family && !parent.installationRecoveryFailed)

    let pending = RecoveryHarness()
    pending.remoteSyncService.result = Registration(
        pairingState: DevicePairingState(familyID: UUID(), isLinked: false), deviceRole: .parent)
    await pending.checkInstallationRecovery()
    precondition(pending.deviceRole == nil && pending.recoveredFamily == nil)
    let pendingID = pending.pendingSetupFamilyID!
    precondition(pending.remoteSyncService.resets.isEmpty)
    pending.remoteSyncService.failReset = true
    await pending.selectInstallationRole(.child)
    precondition(pending.roleSelectionFailed && pending.deviceRole == nil && pending.pendingSetupFamilyID == pendingID)
    pending.remoteSyncService.failReset = false
    async let pick1: Void = pending.selectInstallationRole(.child)
    async let pick2: Void = pending.selectInstallationRole(.parent)
    _ = await (pick1, pick2)
    precondition(pending.remoteSyncService.resets.count == 2) // failed + single successful choice
    precondition(pending.deviceRole != nil && pending.pendingSetupFamilyID == nil && !pending.roleSelectionFailed)
    precondition(pending.recoverySetupFamilyID == nil && pending.cleared == 1)
    precondition(pending.remoteSyncService.unlinks.isEmpty)
    precondition(pending.storage.secret == "retained-secret")

    let joinedDuringSelection = RecoveryHarness()
    joinedDuringSelection.pendingSetupFamilyID = family.familyID
    joinedDuringSelection.remoteSyncService.resetAllowed = false
    joinedDuringSelection.remoteSyncService.result = Registration(pairingState: family, deviceRole: .parent)
    await joinedDuringSelection.selectInstallationRole(.child)
    precondition(joinedDuringSelection.deviceRole == nil && joinedDuringSelection.recoveredFamily == family)
    precondition(joinedDuringSelection.pendingSetupFamilyID == nil && joinedDuringSelection.cleared == 0)
    precondition(joinedDuringSelection.remoteSyncService.unlinks.isEmpty)

    let fresh = RecoveryHarness()
    fresh.storage.secret = nil
    await fresh.checkInstallationRecovery()
    precondition(fresh.remoteSyncService.inspections == 0)
    await fresh.selectInstallationRole(.parent)
    precondition(fresh.deviceRole == .parent && fresh.remoteSyncService.resets.isEmpty)
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
