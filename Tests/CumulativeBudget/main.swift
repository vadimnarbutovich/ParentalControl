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
// Replay the Nov 13 failure: all thresholds delivered within 0.335 seconds.
// The terminal event is eighth, so queued obsolete callbacks follow the repair.
let earlyEvents: [(Int, Double)] = [
    (30, 0.266696), (480, 0.270837), (150, 0.274414), (390, 0.277924),
    (210, 0.281426), (180, 0.284937), (120, 0.288391), (600, 0.291815),
    (270, 0.295276), (90, 0.298699), (450, 0.302072), (330, 0.305466),
    (240, 0.308649), (570, 0.313162), (360, 0.316550), (510, 0.320171),
    (60, 0.323501), (420, 0.327008), (540, 0.331161), (300, 0.334625)
]
state = make(4170, used: 630)
var repairs = 0
for (threshold, elapsed) in earlyEvents {
    consume(&state, threshold, elapsed: elapsed)
    check(state.usedSeconds == 630 && state.availableSeconds == 4170, "Early burst cannot charge minutes")
    if state.monitorEvent == nil {
        repairs += 1
        check(state.monitorRecoveryAttempts == 1, "Terminal retires the stranded generation")
        state.armMonitor(event: "recovered", threshold: 30, cumulative: true,
                         now: start.addingTimeInterval(elapsed))
    }
}
check(repairs == 1 && state.monitorEvent == "recovered", "Queued obsolete events cannot restart the replacement")
consume(&state, 30, elapsed: 31, generation: "recovered")
check(state.usedSeconds == 660 && state.monitorRecoveryAttempts == nil, "Real usage continues after repair, without opening host")
consume(&state, 600, elapsed: 601, generation: "recovered")
check(state.usedSeconds == 1230 && state.monitorEvent == nil, "Repaired cumulative window completes normally")

// Persistent OS failure cannot create an infinite start/stop loop or free usage.
state = make(4170, used: 630)
for attempt in 1...3 {
    if attempt > 1 { state.armMonitor(event: "parentalcontrol.usageBudget.test", threshold: 30, cumulative: true, now: start) }
    consume(&state, 600, elapsed: 0.3)
    check(state.monitorRecoveryAttempts == attempt && state.monitorRecoveryExhausted == (attempt == 3), "Bounded automatic recovery")
    state = try JSONDecoder().decode(DailyBudgetState.self, from: JSONEncoder().encode(state))
    check(state.monitorRecoveryAttempts == attempt && state.usedSeconds == 630, "Retry state survives process restart without debiting")
}
let failed = state
state.apply(state.policy)
check(state == failed, "Same-policy refresh does not replenish retries")
consume(&state, 600, elapsed: 900)
check(state == failed, "Late event cannot revive a retired generation")
let nextPolicy = DailyBudgetPolicy(familyID: state.policy.familyID, limitSeconds: state.policy.limitSeconds,
    revision: state.policy.revision + 1, extraDay: day, extraSeconds: 0,
    earnedSeconds: 0, grantedSeconds: 0, dayStartLimitSeconds: state.policy.limitSeconds, operations: nil)
state.apply(nextPolicy)
check(!state.monitorRecoveryExhausted && state.usedSeconds == 630, "New parent policy permits recovery without resetting usage")
state = failed
state.advance(to: "2026-11-11")
check(!state.monitorRecoveryExhausted && state.usedSeconds == 0, "Next day clears recovery state")
let recoveredInstall = DailyBudgetState.restoring(failed.policy, day: day, legacyUsedToday: 0, reported: failed)
check(!recoveredInstall.monitorRecoveryExhausted && recoveredInstall.usedSeconds == 630, "Server snapshot never transfers monitor failure ownership")
oldJSON.removeValue(forKey: "monitorRecoveryAttempts")
let oldState = try JSONDecoder().decode(DailyBudgetState.self, from: JSONSerialization.data(withJSONObject: oldJSON))
check(oldState.monitorRecoveryAttempts == nil, "Snapshots from previous builds remain readable")

// Production reuse decision: only growing allowance, same selection/day/restart.
func signature(_ s: DailyBudgetState, selection: Data = Data([1]), restart: String = "stable") -> BudgetMonitoringSignature {
    BudgetMonitoringSignature(selection: selection, day: s.day, seconds: s.budgetSeconds, restart: restart)
}
state = make(300, used: 600)
let originalSignature = signature(state)
consume(&state, 30, elapsed: 31)
state.extraSeconds += 300
var latestSignature = signature(state)
check(originalSignature.canReuse(for: latestSignature, state: state, registered: true), "Adding time preserves running window")
consume(&state, 60, elapsed: 61)
state.extraSeconds += 300
check(latestSignature.canReuse(for: signature(state), state: state, registered: true), "Repeated additions also preserve in-flight usage")
latestSignature = signature(state)
consume(&state, 300, elapsed: 301)
check(state.usedSeconds == 900 && state.availableSeconds == 600, "Original terminal retains all added time and charges original window once")
check(!latestSignature.canReuse(for: signature(state), state: state, registered: true), "Finished generation must restart")
state.armMonitor(event: "extra", threshold: 30, cumulative: true, now: start.addingTimeInterval(301))
consume(&state, 600, elapsed: 902, generation: "extra")
check(state.availableSeconds == 0 && state.usedSeconds == 1500, "Added time is consumed to exhaustion without host launch")

state = make(1200)
latestSignature = signature(state)
check(latestSignature.canReuse(for: latestSignature, state: state, registered: true), "Ordinary refresh preserves healthy window")
check(!latestSignature.canReuse(for: latestSignature, state: state, registered: false), "Manual block or pause stopped the registration: resume must restart")
check(!latestSignature.canReuse(for: signature(state, selection: Data([2])), state: state, registered: true), "Selection changes restart")
check(!latestSignature.canReuse(for: signature(state, restart: "changed"), state: state, registered: true), "Explicit restart invalidates monitor")
var oldSignature = latestSignature
oldSignature.accountingVersion = 2
let decodedSignature = try JSONDecoder().decode(BudgetMonitoringSignature.self, from: JSONEncoder().encode(oldSignature))
check(!decodedSignature.canReuse(for: latestSignature, state: state, registered: true), "Upgrade does not preserve a potentially stranded old generation")
state.extraSeconds -= 1
check(!latestSignature.canReuse(for: signature(state), state: state, registered: true), "Even a small withdrawal recalculates exact endpoint")
state = make(1200)
state.monitorPlan = nil
check(!latestSignature.canReuse(for: latestSignature, state: state, registered: true), "Legacy single-event monitor migrates")
state = failed
check(!signature(state).canReuse(for: signature(state), state: state, registered: true), "Failed window cannot be acknowledged as working")
state = make(1200)
state.advance(to: "2026-11-11")
state.armMonitor(event: "tomorrow", threshold: 30, cumulative: true, now: start.addingTimeInterval(86400))
check(!latestSignature.canReuse(for: signature(state), state: state, registered: true), "Different day invalidates signature")
print("Passed \(checks) cumulative usage checks")
