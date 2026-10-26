import Foundation

enum Role { case parent, child }
enum Location { case authorizedAlways, denied }
struct Pair { let familyID: UUID; var isLinked = true }
struct Pin { var hashBase64 = "hash"; var saltBase64 = "salt"; var updatedAt = Date() }
struct Budget { var policy: Int? = 3600 }
struct Poll { var budget: Budget? = Budget() }
struct Selection {
    var applicationTokens = [1]
    var categoryTokens: [Int] = []
    var webDomainTokens: [Int] = []
}
final class Screen { var isAuthorized = true; var selection = Selection() }
@MainActor enum FamilyAccessStore { static var allowed = true; static var isSettingUp = false }
@MainActor final class Remote {
    var pin: Pin? = Pin()
    var poll = Poll()
    var failPin = false
    var failAccess = false
    var failBudget = false
    var pinCalls = 0
    var budgetCalls = 0
    var readyValues: [Bool] = []
    var afterPin: (() -> Void)?
    func fetchParentPin() async throws -> Pin? {
        pinCalls += 1
        if failPin { throw CancellationError() }
        afterPin?()
        return pin
    }
    func accessStatus(ready: Bool) async throws {
        readyValues.append(ready)
        if failAccess { throw CancellationError() }
    }
    func parentPoll() async throws -> Poll {
        budgetCalls += 1
        if failBudget { throw CancellationError() }
        return poll
    }
}
@MainActor final class Harness {
    var recoverySetupFamilyID: UUID? = UUID()
    var deviceRole: Role? = .parent
    var pairingState: Pair?
    let remoteSyncService = Remote()
    let screenTimeService = Screen()
    var parentPinNeedsRefresh = false
    var parentPinUnavailable = false
    var parentPinIsSet = false
    var isNotificationAuthorized = true
    var childLocationAuthorizationStatus: Location = .authorizedAlways
    var parentBudgetStatus: Budget?
    var appliedPins = 0
    var failPinStorage = false
    init() { pairingState = Pair(familyID: recoverySetupFamilyID!) }
    func bootstrapRemoteIfNeeded() async { }
    func refreshPermissionStatuses() async { }
    func adoptFamilyAccess() { }
    func receiveParentBudget(_ budget: Budget) { parentBudgetStatus = budget }
    func applyParentPinFromBackend(hashBase64: String?, saltBase64: String?, updatedAt: Date?) {
        appliedPins += 1
        parentPinIsSet = hashBase64 != nil
        parentPinNeedsRefresh = failPinStorage
    }
    // ACTUAL_PREPARATION
}

@MainActor func run() async throws {
    for mask in 0..<256 {
        func flag(_ bit: Int) -> Bool { mask & (1 << bit) != 0 }
        let parent = flag(0), notification = flag(1), screen = flag(2), location = flag(3)
        let pin = flag(4), apps = flag(5), allowed = flag(6), budget = flag(7)
        let plan = RecoverySetupPlan.steps(isParent: parent, notifications: notification,
            screenTime: screen, location: location, pinConfigured: pin, appsSelected: apps,
            configurationAllowed: allowed, budgetExists: budget)
        precondition(plan.contains(.notifications) == !notification)
        precondition(plan.contains(.install) == parent)
        if parent { precondition(plan.first == .install) }
        precondition(plan.contains(.screenTime) == (!parent && !screen))
        precondition(plan.contains(.location) == (!parent && !location))
        precondition(plan.contains(.apps) == (!parent && allowed && (!screen || !apps)))
        precondition(plan.contains(.pin) == (!pin || plan.contains(.apps)))
        precondition(plan.contains(.limit) == (parent && allowed && !budget))
        precondition(!plan.contains(.pairing) && !plan.contains(.protection) && !plan.contains(.finish))
        if let apps = plan.firstIndex(of: .apps) { precondition(plan.firstIndex(of: .pin)! < apps) }
    }
    let ready = Harness()
    let readyPlan = try await ready.prepareRecoveredSetup()
    precondition(readyPlan == [.install] && ready.parentPinIsSet)
    precondition(ready.parentBudgetStatus?.policy == 3600)
    precondition(ready.remoteSyncService.pinCalls == 1 && ready.remoteSyncService.budgetCalls == 1)
    precondition(ready.remoteSyncService.readyValues == [false])

    let missing = Harness()
    missing.remoteSyncService.pin = nil
    missing.remoteSyncService.poll.budget = Budget(policy: nil)
    let missingPlan = try await missing.prepareRecoveredSetup()
    precondition(missingPlan == [.install, .pin, .limit])

    for kind in 0..<5 {
        let failure = Harness()
        failure.remoteSyncService.failPin = kind == 0
        failure.remoteSyncService.failAccess = kind == 1
        failure.remoteSyncService.failBudget = kind == 2
        if kind == 3 { failure.remoteSyncService.poll.budget = nil }
        failure.failPinStorage = kind == 4
        do { _ = try await failure.prepareRecoveredSetup(); fatalError("Failure must not produce editable defaults") }
        catch { }
    }
    let switched = Harness()
    switched.remoteSyncService.afterPin = { switched.pairingState = Pair(familyID: UUID()) }
    do { _ = try await switched.prepareRecoveredSetup(); fatalError("Changed family must be rejected") }
    catch { precondition(switched.appliedPins == 0) }

    FamilyAccessStore.allowed = false
    let expired = Harness()
    let expiredPlan = try await expired.prepareRecoveredSetup()
    precondition(expiredPlan == [.install])
    precondition(expired.remoteSyncService.budgetCalls == 0 && expired.parentPinIsSet)
    let child = Harness()
    child.deviceRole = .child
    child.screenTimeService.selection.applicationTokens = []
    let childPlan = try await child.prepareRecoveredSetup()
    precondition(childPlan.isEmpty)
    precondition(child.remoteSyncService.budgetCalls == 0)

    FamilyAccessStore.isSettingUp = true
    let setupPlan = try await child.prepareRecoveredSetup()
    precondition(setupPlan == [.pin, .apps])
    print("Recovery setup: 256 step combinations and actual preparation success/failure/scope/expiry checks passed")
}
try await run()
