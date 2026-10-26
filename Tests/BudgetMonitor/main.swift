import Foundation

var checks = 0
func check(_ condition: @autoclosure () -> Bool, _ label: String) {
    precondition(condition(), label)
    checks += 1
}
let policy = DailyBudgetPolicy(familyID: UUID().uuidString, limitSeconds: 3600,
    revision: 2, extraDay: "2026-10-26", extraSeconds: 300, earnedSeconds: 0,
    grantedSeconds: 300, dayStartLimitSeconds: 3600, operations: nil)
let initial = DailyBudgetState(policy: policy, day: "2026-10-26", usedSeconds: 0,
    extraSeconds: 300, monitorEvent: "old", monitorThreshold: 30, monitorStartedAt: 1)

final class Harness {
    var state: DailyBudgetState? = initial
    var contextCurrent = true
    var stops = 0
    var starts = 0
    var armHook: ((Harness) throws -> Void)?
    var stopHook: ((Harness) -> Void)?
    var startHook: ((Harness) throws -> Void)?
    func run() -> BudgetMonitorRearm.Outcome {
        BudgetMonitorRearm.run(expected: initial, read: { self.state },
            contextIsCurrent: { self.contextCurrent }, arm: {
                try self.armHook?(self)
                self.state?.monitorEvent = "owned"
                self.state?.monitorThreshold = 30
                self.state?.monitorStartedAt = 2
                return "owned"
            }, stop: {
                self.stops += 1
                self.stopHook?(self)
            }, start: { event in
                check(event == "owned", "Register the generation actually armed")
                self.starts += 1
                try self.startHook?(self)
            })
    }
}
func isSuperseded(_ result: BudgetMonitorRearm.Outcome) -> Bool {
    if case .superseded = result { return true }; return false
}

let success = Harness()
if case .started(let state) = success.run() {
    check(state.monitorEvent == "owned" && state.availableSeconds == 3900, "Successful monitor retains allowance")
} else { preconditionFailure("Expected a successful registration") }
check(success.stops == 1 && success.starts == 1, "Normal path registers once")

let obsolete = Harness()
obsolete.state?.monitorEvent = "newer"
check(isSuperseded(obsolete.run()), "Already obsolete snapshot does nothing")
check(obsolete.stops == 0 && obsolete.starts == 0, "Do not stop another updater's monitor")

let armConflict = Harness()
armConflict.armHook = { h in
    h.state?.monitorEvent = "newer"
    throw NSError(domain: "armConflict", code: 1)
}
check(isSuperseded(armConflict.run()), "Atomic arm conflict is not a monitoring failure")
check(armConflict.stops == 0 && armConflict.starts == 0, "Arm conflict cannot perform system writes")

let changedDuringArm = Harness()
changedDuringArm.armHook = { $0.state?.extraSeconds = 900 }
check(isSuperseded(changedDuringArm.run()), "Same-revision balance change invalidates threshold")
check(changedDuringArm.stops == 0, "Validate allowance before stopping")

let duringStop = Harness()
duringStop.stopHook = { $0.state?.monitorEvent = "newer" }
check(isSuperseded(duringStop.run()), "New generation during stop belongs to its updater")
check(duringStop.starts == 0, "Do not overwrite a newer registration")

let duringStart = Harness()
duringStart.startHook = { $0.state?.monitorEvent = "newer" }
check(isSuperseded(duringStart.run()), "Late start return cannot clear or shield a newer generation")

let lateFailure = Harness()
lateFailure.startHook = { h in
    h.state?.monitorEvent = "newer"
    throw NSError(domain: "system", code: 99)
}
check(isSuperseded(lateFailure.run()), "Regression: failed old registration with unchanged policy must not shield")

for mutation: (Harness) -> Void in [
    { $0.contextCurrent = false }, // manual block/unblock, pause, selection, pairing or access
    { $0.state?.usedSeconds = 30 },
    { $0.state?.day = "2026-10-27" },
    { $0.state?.policy.limitSeconds = 0 },
    { $0.state = nil }
] {
    let h = Harness()
    h.startHook = { h in mutation(h) }
    check(isSuperseded(h.run()), "Concurrent authoritative change invalidates a successful system return")
    let failed = Harness()
    failed.startHook = { h in mutation(h); throw NSError(domain: "system", code: 99) }
    check(isSuperseded(failed.run()), "Concurrent change invalidates the error fallback too")
}

let realFailure = Harness()
realFailure.startHook = { _ in throw NSError(domain: "system", code: 42) }
if case .failed(let expected, let code) = realFailure.run() {
    check(code == 42 && expected == realFailure.state, "Real current failure retains fail-closed behavior and diagnostic code")
} else { preconditionFailure("Real failure must not be mistaken for a successful monitor") }
let armFailure = Harness()
armFailure.armHook = { _ in throw NSError(domain: "disk", code: 13) }
if case .failed(let expected, let code) = armFailure.run() {
    check(expected == initial && code == 13, "Current storage failure remains distinguishable")
} else { preconditionFailure("Expected current arm failure") }
print("Passed \(checks) budget monitor generation checks")
