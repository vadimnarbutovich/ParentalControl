import Foundation

var checks = 0
func check(_ value: @autoclosure () -> Bool, _ label: String) {
    precondition(value(), label)
    checks += 1
}
let family = UUID().uuidString
let day = "2026-10-27"
func policy(_ revision: Int = 10, familyID: String = family, limit: Int = 3600,
            extra: Int = 1500, operations: [DailyBudgetOperation]? = nil) -> DailyBudgetPolicy {
    .init(familyID: familyID, limitSeconds: limit, revision: revision, extraDay: day,
          extraSeconds: extra, earnedSeconds: 0, grantedSeconds: max(0, extra),
          dayStartLimitSeconds: limit, operations: operations)
}
let currentPolicy = policy()
var reported = DailyBudgetState(policy: currentPolicy, day: day, usedSeconds: 120,
    extraSeconds: 1500, lastConsumptionAt: 123, monitorEvent: "old-installation",
    monitorThreshold: 30, monitorStartedAt: 111, cappedAdjustmentsVersion: 1)
let recovered = DailyBudgetState.restoring(currentPolicy, day: day, legacyUsedToday: 0, reported: reported)
check(recovered.usedSeconds == 120, "Restore the two minutes retained by the server")
check(recovered.availableSeconds == 4980, "Child and parent both have 83 minutes remaining")
check(recovered.extraSeconds == 1500, "Previously added time is retained")
check(recovered.monitorEvent == nil && recovered.monitorThreshold == 0 && recovered.monitorStartedAt == 0,
      "Do not restore old DeviceActivity event ownership")
check(recovered.lastConsumptionAt == 0, "Do not restore old installation clock anchors")
check(DailyBudgetState.restoring(currentPolicy, day: day, legacyUsedToday: 180, reported: reported).usedSeconds == 180,
      "A higher migration baseline is not reduced")

var local = DailyBudgetState(policy: currentPolicy, day: day, usedSeconds: 0,
    extraSeconds: 1500, monitorEvent: "current-installation", monitorThreshold: 30, monitorStartedAt: 200)
local.restoreReportedUsage(reported, throughRevision: currentPolicy.revision)
check(local.usedSeconds == 120, "Repair devices already restored by the old build")
for _ in 0..<10 { local.restoreReportedUsage(reported, throughRevision: currentPolicy.revision) }
check(local.usedSeconds == 120, "Repeated responses do not add the same usage again")
check(local.monitorEvent == "current-installation" && local.monitorStartedAt == 200,
      "Usage reconciliation does not copy server monitoring state")
local.usedSeconds = 180
local.extraSeconds = 1800
local.restoreReportedUsage(reported, throughRevision: currentPolicy.revision)
check(local.usedSeconds == 180 && local.extraSeconds == 1800, "Stale reports cannot reduce usage or overwrite local adjustments")

// Reject unrelated days/families, future revisions and malformed counters in
// both the missing-storage path and reconciliation of an existing store.
var invalid: [DailyBudgetState] = []
var bad = reported; bad.day = "2026-10-26"; invalid.append(bad)
bad = reported; bad.day = "2026-10-28"; invalid.append(bad)
bad = reported; bad.policy = policy(familyID: UUID().uuidString); invalid.append(bad)
bad = reported; bad.policy = policy(11); invalid.append(bad)
bad = reported; bad.policy = policy(0); invalid.append(bad)
bad = reported; bad.usedSeconds = -1; invalid.append(bad)
bad = reported; bad.usedSeconds = Int.max; invalid.append(bad)
bad = reported; bad.extraSeconds = Int.max; invalid.append(bad)
bad = reported; bad.policy = policy(limit: -1); invalid.append(bad)
bad = reported; bad.policy.weeklyLimitsSeconds = [1]; invalid.append(bad)
bad = reported; bad.cappedAdjustmentsVersion = 99; invalid.append(bad)
for snapshot in invalid {
    let fresh = DailyBudgetState.restoring(currentPolicy, day: day, legacyUsedToday: 30, reported: snapshot)
    check(fresh.usedSeconds == 30 && fresh.extraSeconds == 1500, "Invalid snapshot retains the existing initialization fallback")
    var existing = recovered
    existing.restoreReportedUsage(snapshot, throughRevision: currentPolicy.revision)
    check(existing == recovered, "Invalid snapshot does not change an existing budget")
}
let noSnapshot = DailyBudgetState.restoring(currentPolicy, day: day, legacyUsedToday: 30, reported: nil)
check(noSnapshot.usedSeconds == 30, "Old servers and first setup keep the legacy baseline")
var rollover = recovered
rollover.advance(to: "2026-10-28")
rollover.restoreReportedUsage(reported, throughRevision: currentPolicy.revision)
check(rollover.usedSeconds == 0 && rollover.extraSeconds == 0, "Yesterday's snapshot cannot consume today's time")

// Original limit 100, usage 90: withdrawing 50 actually withdraws only 10.
// Later granting 50 leaves 50 available. Replaying against zero would lose 40.
let operations = [DailyBudgetOperation(revision: 2, kind: "adjustment", seconds: -50),
                  DailyBudgetOperation(revision: 3, kind: "adjustment", seconds: 50)]
let cappedPolicy = policy(3, limit: 100, extra: 0, operations: operations)
let cappedReport = DailyBudgetState(policy: cappedPolicy, day: day, usedSeconds: 90,
                                   extraSeconds: 40, cappedAdjustmentsVersion: 1)
let cappedRecovery = DailyBudgetState.restoring(cappedPolicy, day: day, legacyUsedToday: 0, reported: cappedReport)
check(cappedRecovery.availableSeconds == 50 && cappedRecovery.extraSeconds == 40, "Restore actual capped adjustments without replay")
let newer = policy(4, limit: 100, extra: 20,
    operations: operations + [.init(revision: 4, kind: "reward", seconds: 20)])
let withNewReward = DailyBudgetState.restoring(newer, day: day, legacyUsedToday: 0, reported: cappedReport)
check(withNewReward.policy.revision == 4 && withNewReward.availableSeconds == 70, "Apply only operations newer than the restored snapshot")
var repeated = withNewReward
repeated.restoreReportedUsage(cappedReport, throughRevision: newer.revision)
repeated.apply(newer)
check(repeated == withNewReward, "Reward and recovery are idempotent")

// On already-reset devices, merge usage BEFORE applying a new withdrawal.
let base = policy(1, limit: 100, extra: 0, operations: [])
let used = DailyBudgetState(policy: base, day: day, usedSeconds: 90, extraSeconds: 0, cappedAdjustmentsVersion: 1)
var reset = DailyBudgetState(policy: base, day: day, usedSeconds: 0, extraSeconds: 0, cappedAdjustmentsVersion: 1)
let withdrawal = policy(2, limit: 100, extra: -50, operations: [operations[0]])
reset.restoreReportedUsage(used, throughRevision: withdrawal.revision)
reset.apply(withdrawal)
check(reset.extraSeconds == -10 && reset.usedSeconds == 90, "New withdrawal uses reconciled usage, not the reset balance")
check(reset.availableSeconds == 0, "Recovered exhaustion stays exhausted")

print("Passed \(checks) budget recovery checks")
