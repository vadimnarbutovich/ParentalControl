import Foundation
var checks = 0
func check(_ condition: @autoclosure () -> Bool, _ name: String) {
    precondition(condition(), name); checks += 1
}
let calendar = Calendar.current
let todayDate = calendar.date(from: DateComponents(year: 2026, month: 11, day: 11, hour: 9))!
let yesterdayDate = calendar.date(byAdding: .day, value: -1, to: todayDate)!
let today = DailyBudgetState.dayKey(todayDate)
let yesterday = DailyBudgetState.dayKey(yesterdayDate)
let policy = DailyBudgetPolicy(familyID: UUID().uuidString, limitSeconds: 600, revision: 14,
    extraDay: yesterday, extraSeconds: 10200, earnedSeconds: 0, grantedSeconds: 16500,
    dayStartLimitSeconds: 3600, operations: nil)
func priorDay(used: Int, extra: Int, running: Bool) -> DailyBudgetState {
    var s = DailyBudgetState(policy: policy, day: yesterday, usedSeconds: used, extraSeconds: extra,
                            cappedAdjustmentsVersion: 1)
    if running { s.armMonitor(event: "old", threshold: 30, cumulative: true, now: yesterdayDate) }
    return s
}
// The same production state transitions used by the monitor, with no app launch/server fetch.
for previous in [priorDay(used: 2820, extra: 10200, running: true),
                 priorDay(used: 600, extra: 0, running: false)] {
    var state = previous
    state.advance(to: today)
    check(state.usedSeconds == 0 && state.availableSeconds == 600, "Fresh ten-minute allowance")
    check(state.extraSeconds == 0 && state.earnedSeconds == 0 && state.grantedSeconds == 0,
          "Yesterday's extras do not roll over")
    check(state.monitorEvent == nil && state.monitorPlan == nil, "New generation required")
    state.recordMonitorUsage(event: "old.600", now: todayDate)
    check(state.usedSeconds == 0, "Old-day callback cannot charge new day")
    state.armMonitor(event: "new", threshold: 30, cumulative: true, now: todayDate)
    check(state.monitorPlan!.thresholds == Array(stride(from: 30, through: 600, by: 30)), "20 cumulative thresholds")
    for threshold in state.monitorPlan!.thresholds {
        // Extension process restarts between callbacks: serialized state must retain progress.
        state = try! JSONDecoder().decode(DailyBudgetState.self, from: JSONEncoder().encode(state))
        state.recordMonitorUsage(event: "new.\(threshold)", now: todayDate.addingTimeInterval(Double(threshold)))
        check(state.usedSeconds == threshold && state.availableSeconds == 600-threshold, "Cumulative debit \(threshold)")
    }
    check(state.availableSeconds == 0 && state.monitorEvent == nil, "Exhaustion enters shield branch")
    let exhausted = state
    state.advance(to: today)
    state.recordMonitorUsage(event: "new.600", now: todayDate.addingTimeInterval(630))
    check(state == exhausted, "Repeated same-day reads/callbacks cannot reset allowance")
    state.advance(to: yesterday)
    check(state == exhausted, "Backward day cannot grant another allowance")
}
var weekly = priorDay(used: 600, extra: 0, running: false)
weekly.policy.weeklyLimitsSeconds = [60,120,600,240,300,360,420]
weekly.advance(to: today)
check(weekly.availableSeconds == 600, "Wednesday resolves offline from persisted weekly policy")
weekly.advance(to: "2026-11-12")
check(weekly.availableSeconds == 240, "Thursday resolves without yesterday's scalar")
var zero = priorDay(used: 600, extra: 0, running: false)
zero.policy.weeklyLimitsSeconds = Array(repeating: 0, count: 7)
zero.advance(to: today)
check(zero.availableSeconds == 0, "Zero-day allowance remains restricted")
var idle = priorDay(used: 100, extra: 0, running: true)
idle.advance(to: today)
idle.armMonitor(event: "idle", threshold: 30, cumulative: true, now: todayDate)
idle.recordMonitorUsage(event: "idle.30", now: todayDate.addingTimeInterval(3600))
check(idle.usedSeconds == 30, "An hour of elapsed time does not charge an hour")
idle.advance(to: "2026-11-15")
check(idle.usedSeconds == 0 && idle.availableSeconds == 600, "Skipped days do not accumulate allowances")
print("Passed \(checks) new-day accounting checks; system callbacks/shields require device verification")
