import Foundation

// Run with swiftc against the actual production models and gate (see README.txt).
if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--lock-probe" {
    let lease = RemoteControlGate.Lease(directory: URL(fileURLWithPath: CommandLine.arguments[2]))
    exit(lease == nil ? 42 : 0)
}

var assertions = 0
func check(_ condition: Bool, _ message: String) {
    precondition(condition, message)
    assertions += 1
}
let family = UUID()
let commandID = UUID()
let day = DailyBudgetState.dayKey()
func snapshot(type: String = "start_focus", revision: Int = 4, duration: Int? = nil,
              familyID: UUID? = nil, pending: Bool = true, limit: Int = 3600) throws -> NotificationControlSnapshot {
    let json: [String: Any] = [
        "desired": ["shouldFocusActive": type == "start_focus",
                    "revision": revision, "durationSeconds": duration as Any? ?? NSNull()],
        "budget": ["childReady": true, "appliedRevision": 2, "policy": [
            "familyID": (familyID ?? family).uuidString, "limitSeconds": limit,
            "revision": 3, "extraDay": day, "extraSeconds": 300
        ]],
        "pendingCommands": pending ? [["id": commandID.uuidString, "commandType": type]] : []
    ]
    return try JSONDecoder().decode(NotificationControlSnapshot.self, from: JSONSerialization.data(withJSONObject: json))
}

let valid = try snapshot()
check(valid.contains(id: commandID, type: "start_focus"), "Valid control must be found")
check(!valid.contains(id: UUID(), type: "start_focus"), "Unknown command must not run")
check(!valid.contains(id: commandID, type: "end_focus"), "Mismatched payload must not run")
check(!(try snapshot(pending: false)).contains(id: commandID, type: "start_focus"), "Expired/acked push must not replay")
check(!(try snapshot(type: "request_location")).contains(id: commandID, type: "request_location"), "LPSE must stay separate")
check(!(try snapshot(type: "add_earned_seconds")).contains(id: commandID, type: "add_earned_seconds"), "No legacy additive replay")
check((try snapshot(type: "tasks_updated")).contains(id: commandID, type: "tasks_updated"), "Budget wake signal")
for type in ScheduleControlPlan.commandTypes {
    check((try snapshot(type: type)).contains(id: commandID, type: type), "Schedule wake signal must reach NSE: \(type)")
    check(!(try snapshot(type: type, pending: false)).contains(id: commandID, type: type), "No replay of acknowledged schedule signal")
}
check(valid.policyForControl(family: family, minimumFocusRevision: 5) == nil, "Reject stale focus revision")
check(valid.policyForControl(family: family, minimumFocusRevision: 4) != nil, "Same revision can repair enforcement")
check((try snapshot(duration: 600)).policyForControl(family: family, minimumFocusRevision: 0) == nil, "Timed focus stays in host")
check((try snapshot(familyID: UUID())).policyForControl(family: family, minimumFocusRevision: 0) == nil, "Reject wrong family")
check((try snapshot(limit: -1)).policyForControl(family: family, minimumFocusRevision: 0) == nil, "Reject invalid budget")
check(valid.rejection(family: family, minimumFocusRevision: 4) == nil, "Valid snapshot has no rejection")
check(valid.rejection(family: family, minimumFocusRevision: 5) == .staleFocusRevision, "Distinguish stale revision")
check((try snapshot(duration: 600)).rejection(family: family, minimumFocusRevision: 0) == .timedFocus, "Distinguish timed session")
check((try snapshot(familyID: UUID())).rejection(family: family, minimumFocusRevision: 0) == .wrongFamily, "Distinguish wrong family")
check((try snapshot(limit: -1)).rejection(family: family, minimumFocusRevision: 0) == .invalidBudgetLimits, "Distinguish invalid limits")

var policy = valid.budget!.policy!
policy = DailyBudgetPolicy(familyID: policy.familyID, limitSeconds: 3600, revision: 3, extraDay: day,
    extraSeconds: 300, earnedSeconds: 0, grantedSeconds: 300, dayStartLimitSeconds: 3600,
    operations: [DailyBudgetOperation(revision: 3, kind: "adjustment", seconds: 300)])
var state = DailyBudgetState(policy: policy, day: day, usedSeconds: 3600, extraSeconds: 0)
state.initializeOperations()
check(state.availableSeconds == 300, "Reward unlocks exhausted allowance")
state.apply(policy)
check(state.availableSeconds == 300, "Duplicate push must not add minutes twice")
let older = DailyBudgetPolicy(familyID: family.uuidString, limitSeconds: 7200, revision: 2,
    extraDay: day, extraSeconds: 900, earnedSeconds: nil, grantedSeconds: nil,
    dayStartLimitSeconds: nil, operations: nil)
state.apply(older)
check(state.policy.revision == 3 && state.availableSeconds == 300, "Old snapshot cannot restore more time")
let noTime = DailyBudgetState(policy: policy, day: day, usedSeconds: 3900, extraSeconds: 300)
check(noTime.availableSeconds == 0, "Manual unblock must not manufacture allowance")
check(DailyBudgetStore.mayReport(revision: 3, pending: 0, confirmed: 0), "Pre-upgrade usage uploads remain compatible")
check(!DailyBudgetStore.mayReport(revision: 3, pending: 3, confirmed: 2), "Persisted desired policy is not an applied ACK")
check(DailyBudgetStore.mayReport(revision: 3, pending: 3, confirmed: 3), "Applied revision may be reported")
check(!DailyBudgetStore.mayReport(revision: 4, pending: 4, confirmed: 3), "A newer pending policy requires its own confirmation")

let root = FileManager.default.temporaryDirectory.appendingPathComponent("pc-nse-tests-" + UUID().uuidString)
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
func probe() throws -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
    process.arguments = ["--lock-probe", root.path]
    try process.run()
    process.waitUntilExit()
    return process.terminationStatus
}
var lease: RemoteControlGate.Lease? = RemoteControlGate.Lease(directory: root)
check(lease != nil, "First process owns gate")
check(RemoteControlGate.Lease(directory: root) == nil, "Second descriptor must not enter")
check(try probe() == 42, "Other process must defer without blocking")
lease = nil
check(try probe() == 0, "Lease release must allow next command")
// Only files created by this test, inside its unique temporary directory.
try FileManager.default.removeItem(at: root.appendingPathComponent("remote-control.lock"))
try FileManager.default.removeItem(at: root)

// Parent confirmation must come from a fresh focus snapshot, not desired state.
let queued = Date(timeIntervalSince1970: 100)
func confirms(_ command: String, _ active: Bool, _ timestamp: TimeInterval) -> Bool {
    ParentFocusConfirmation.matches(command: command, queuedAt: queued,
        runtimeUpdatedAt: Date(timeIntervalSince1970: timestamp), isActive: active)
}
check(!confirms("start_focus", true, 99), "Old matching block is not this command's confirmation")
check(!confirms("end_focus", false, 99), "Old matching unblock is not this command's confirmation")
check(confirms("start_focus", true, 101), "Fresh matching block confirms")
check(confirms("end_focus", false, 101), "Fresh matching unblock confirms")
check(!confirms("start_focus", false, 101), "Fresh unlocked runtime cannot confirm a block")
check(!confirms("end_focus", true, 101), "Fresh blocked runtime cannot confirm an unblock")
for command in ["add_earned_seconds", "subtract_earned_seconds", "reset_earned_balance",
                "tasks_updated", "schedules_updated", "request_location", "unknown"] {
    check(!confirms(command, false, 101), "Focus runtime must not ACK \(command)")
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}

let completions = Counter()
let cancellations = Counter()
let race = NotificationDeliveryLifetime(timeout: 60) { _ in completions.increment() }
race.onCancel { cancellations.increment() }
DispatchQueue.concurrentPerform(iterations: 100) { index in
    race.finish(reason: index.isMultiple(of: 2) ? "completed" : "system_expiry")
}
check(completions.value == 1, "Racing completion/expiry must call content handler exactly once")
check(cancellations.value == 1, "Registered cancellation runs once")
race.onCancel { cancellations.increment() }
check(cancellations.value == 2, "Work registered after expiry is cancelled immediately")
check(race.isFinished, "Expiry state is visible synchronously")
do {
    try race.checkCancellation()
    preconditionFailure("Expired processor must not continue")
} catch is CancellationError {
    check(true, "Processor observes expiry without an actor hop")
}

// Deliberately block the main thread: a MainActor Task timer cannot pass this test.
let notified = DispatchSemaphore(value: 0)
let expired = Counter()
let deadline = NotificationDeliveryLifetime(timeout: 0.05) { reason in
    if reason == "deadline" { expired.increment() }
    notified.signal()
}
check(notified.wait(timeout: .now() + 3) == .success, "Deadline returns notification while main thread is blocked")
check(deadline.isFinished && expired.value == 1, "Independent deadline closes delivery")
deadline.finish(reason: "late_worker")
check(expired.value == 1, "Late worker cannot complete delivery again")

let newerCompletions = Counter()
let newer = NotificationDeliveryLifetime(timeout: 60) { _ in newerCompletions.increment() }
deadline.finish(reason: "superseded_worker")
check(!newer.isFinished && newerCompletions.value == 0, "Old generation cannot finish a new delivery")
newer.finish(reason: "completed")
check(newerCompletions.value == 1, "New generation completes independently")

let cancellationStarted = DispatchSemaphore(value: 0)
let releaseCancellation = DispatchSemaphore(value: 0)
let originalReturned = DispatchSemaphore(value: 0)
let finishReturned = DispatchSemaphore(value: 0)
let slowCancel = NotificationDeliveryLifetime(timeout: 60) { _ in originalReturned.signal() }
slowCancel.onCancel {
    cancellationStarted.signal()
    _ = releaseCancellation.wait(timeout: .now() + 3)
}
DispatchQueue.global().async {
    slowCancel.finish(reason: "system_expiry")
    finishReturned.signal()
}
check(cancellationStarted.wait(timeout: .now() + 3) == .success, "Slow cleanup has started")
check(originalReturned.wait(timeout: .now()) == .success, "Notification is returned before slow cleanup")
check(slowCancel.isFinished, "Cleanup never holds delivery state lock")
releaseCancellation.signal()
check(finishReturned.wait(timeout: .now() + 3) == .success, "Cleanup finishes without deadlock")
print("Notification control: \(assertions) checks passed")
