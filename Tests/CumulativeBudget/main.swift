import Foundation

var checks = 0
func check(_ value: @autoclosure () -> Bool, _ label: String) {
    precondition(value(), label)
    checks += 1
}
let start = ISO8601DateFormatter().date(from: "2026-11-10T09:00:00Z")!
let day = DailyBudgetState.dayKey(start)
let family = UUID().uuidString
func make(_ available: Int = 360, used: Int = 120) -> DailyBudgetState {
    let policy = DailyBudgetPolicy(familyID: family, limitSeconds: available + used,
        revision: 1, extraDay: day, extraSeconds: 0, earnedSeconds: 0,
        grantedSeconds: 0, dayStartLimitSeconds: available + used, operations: nil)
    var state = DailyBudgetState(policy: policy, day: day, usedSeconds: used, extraSeconds: 0)
    state.armMonitor(event: "parentalcontrol.usageBudget.test", threshold: min(30, available),
                     cumulative: true, now: start)
    return state
}
func consume(_ state: inout DailyBudgetState, _ threshold: Int, elapsed: Double,
             generation: String = "parentalcontrol.usageBudget.test") {
    state.recordMonitorUsage(event: generation + "." + String(threshold), now: start.addingTimeInterval(elapsed))
}

// Regression: delivery is ~34 seconds late. The delay must not accumulate once
// per callback, and accounting must not depend on callback order or delivery gaps.
var state = make()
consume(&state, 30, elapsed: 64)
check(state.usedSeconds == 150 && state.monitorEvent != nil, "First callback retains the running monitor")
consume(&state, 60, elapsed: 94)
check(state.usedSeconds == 180 && state.monitorStartedAt == start.timeIntervalSince1970,
      "Second threshold shares the original start; no new 30-second waiting cycle")
consume(&state, 150, elapsed: 184)
check(state.usedSeconds == 270, "A later threshold includes missing 90/120 callbacks")
let saved = state
consume(&state, 60, elapsed: 190)
consume(&state, 150, elapsed: 200)
check(state == saved, "Out-of-order and duplicate callbacks do not double-charge")
consume(&state, 360, elapsed: 394)
check(state.availableSeconds == 0 && state.usedSeconds == 480 && state.monitorEvent == nil,
      "Six-minute allowance expires after the final cumulative event, not twelve restarted cycles")
consume(&state, 360, elapsed: 400)
check(state.usedSeconds == 480, "Final duplicate is ignored")

state = make()
consume(&state, 30, elapsed: 2)
check(state.usedSeconds == 120 && state.monitorEvent != nil, "Reject immediate iOS callbacks without resetting monitor")
consume(&state, 60, elapsed: 65)
check(state.usedSeconds == 180, "Later genuine threshold recovers a rejected early callback")
consume(&state, 90, elapsed: 3600)
check(state.usedSeconds == 210, "Long idle gap counts reported activity only, not elapsed wall time")
let beforeInvalid = state
consume(&state, 91, elapsed: 3700)
consume(&state, 120, elapsed: 3700, generation: "obsolete")
check(state == beforeInvalid, "Unknown thresholds and obsolete generations are ignored")

// Bounded registration, exact final threshold, short allowance and long budgets.
for available in [1, 6, 10, 29, 30, 59, 60, 61, 359, 360, 599, 600, 601, 86400, 604800] {
    let s = make(available)
    let plan = s.monitorPlan!
    check(plan.isValid && plan.thresholds.count <= 20, "Bounded valid registration for \(available)")
    check(plan.thresholds.last == min(available, 600), "Exact allowance or bounded-window endpoint")
}
state = make(1200)
consume(&state, 600, elapsed: 634)
check(state.usedSeconds == 720 && state.availableSeconds == 600 && state.monitorEvent == nil,
      "Only completed window rearms; no usage loss inside the window")
state.armMonitor(event: "new", threshold: 30, cumulative: true, now: start.addingTimeInterval(634))
consume(&state, 600, elapsed: 700)
check(state.usedSeconds == 720, "Previous window cannot spend the new allowance")
consume(&state, 600, elapsed: 1268, generation: "new")
check(state.availableSeconds == 0, "Next window continues from the accounted baseline")

// Parent additions/withdrawals: production enforcement rearms from current usage.
state = make()
consume(&state, 60, elapsed: 94)
state.extraSeconds = 600
state.armMonitor(event: "added", threshold: 30, cumulative: true, now: start.addingTimeInterval(100))
consume(&state, 360, elapsed: 400)
check(state.usedSeconds == 180 && state.availableSeconds == 900, "Adding minutes invalidates old events without resetting usage")
consume(&state, 60, elapsed: 170, generation: "added")
check(state.usedSeconds == 240 && state.availableSeconds == 840, "New generation charges against updated allowance")
state.extraSeconds = -210
state.armMonitor(event: "withdrawn", threshold: 30, cumulative: true, now: start.addingTimeInterval(180))
consume(&state, 30, elapsed: 220, generation: "withdrawn")
check(state.availableSeconds == 0 && state.usedSeconds == 270, "Withdrawal respects the remaining balance")

// Pause/block/resume replaces the generation through the existing enforcer.
state = make()
consume(&state, 30, elapsed: 64)
state.armMonitor(event: "resumed", threshold: 30, cumulative: true, now: start.addingTimeInterval(1000))
consume(&state, 360, elapsed: 1100)
consume(&state, 30, elapsed: 1064, generation: "resumed")
check(state.usedSeconds == 180, "Resume retains usage and ignores stopped monitor callbacks")

// Usage restored from the server must never be added again or strand a window.
state = make(1200)
state.usedSeconds = 750
consume(&state, 600, elapsed: 634)
check(state.usedSeconds == 750 && state.monitorEvent == nil, "Terminal event retires window even after higher usage reconciliation")

state = make()
let encoded = try JSONEncoder().encode(state)
let decoded = try JSONDecoder().decode(DailyBudgetState.self, from: encoded)
check(decoded == state, "Running generation survives process restart")
let restored = DailyBudgetState.restoring(state.policy, day: day, legacyUsedToday: 0, reported: state)
check(restored.monitorPlan == nil && restored.monitorEvent == nil && restored.usedSeconds == state.usedSeconds,
      "Reinstall recovery never restores server-side monitor ownership")
var oldJSON = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
oldJSON.removeValue(forKey: "monitorPlan")
var legacy = try JSONDecoder().decode(DailyBudgetState.self, from: JSONSerialization.data(withJSONObject: oldJSON))
legacy.recordMonitorUsage(event: "parentalcontrol.usageBudget.test", now: start.addingTimeInterval(64))
check(legacy.usedSeconds == 150 && legacy.monitorEvent == nil, "Pre-upgrade chunk is consumed once before migration")
state.advance(to: "2026-11-11")
consume(&state, 360, elapsed: 86400)
check(state.usedSeconds == 0 && state.monitorPlan == nil && state.monitorEvent == nil,
      "Old-day events cannot debit tomorrow")
print("Passed \(checks) cumulative usage checks")
