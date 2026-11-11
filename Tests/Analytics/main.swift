import Foundation

var checks = 0
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    precondition(condition(), message)
    checks += 1
}

let bundle = "mycompny.ParentalControl"
check(!AnalyticsSchema.isAllowedKey("", bundleID: bundle), "Missing key must fail closed")
check(!AnalyticsSchema.isAllowedKey("90679160-6625-4373-bd17-55564f521a13", bundleID: bundle), "Reject ScreenBlocker")
check(!AnalyticsSchema.isAllowedKey("90679160-6625-4373-BD17-55564F521A13", bundleID: bundle), "Reject uppercase old key")
check(!AnalyticsSchema.isAllowedKey("00000000-0000-0000-0000-000000000000", bundleID: bundle), "Reject placeholder")
check(!AnalyticsSchema.isAllowedKey("9edea000-9fd2-4da0-9b68-845eedb8bf86", bundleID: "mycompny.ScreenBlocker"), "Reject other bundle")
check(!AnalyticsSchema.isAllowedKey("9edea000-9fd2-4da0-9b68-845eedb8bf86", bundleID: nil), "Reject missing bundle")
check(AnalyticsSchema.isAllowedKey("9edea000-9fd2-4da0-9b68-845eedb8bf86", bundleID: bundle), "Accept separate project")
check(AnalyticsSchema.sanitized("unknown", parameters: nil) == nil, "Unregistered event rejected")
for oldEvent in ["dashboard_earn_card_tap", "conversion_save_tap", "conversion_apply_defaults_tap", "settings_pin_saved"] {
    check(AnalyticsSchema.sanitized(oldEvent, parameters: nil) == nil, "Legacy event rejected")
}
let unsafe: [String: Any] = [
    "pin": "1234", "pairing_code": "CODE", "family_id": UUID().uuidString,
    "device_id": UUID().uuidString, "latitude": 53.9, "longitude": 27.56,
    "title": "Private task", "details": "Private details", "day": "2026-10-20",
    "error": "Private server response", "token": "app-token", "email": "private@example.org"
]
for name in AnalyticsSchema.events.keys {
    check(AnalyticsSchema.sanitized(name, parameters: unsafe)?.isEmpty == true, "\(name): private fields excluded")
}
let task = AnalyticsSchema.sanitized("task_action", parameters: unsafe.merging([
    "action": "create", "result": "success"
]) { _, new in new })!
check(task.count == 3 && task["title"] as? String == "Private task", "Successful create keeps title but excludes unrelated fields")
check(task["action"] as? String == "create", "Preserve action")
for title in ["Уроки с Машей", "Read a book", "运动", "🏃‍♀️ Семейная прогулка"] {
    for action in ["create", "edit"] {
        check(AnalyticsSchema.sanitized("task_action", parameters: ["action": action, "result": "success", "title": title])?["title"] as? String == title,
              "Task title preserved verbatim, including Unicode")
    }
    check(AnalyticsSchema.sanitized("schedule_change", parameters: ["action": "save", "title": title])?["title"] as? String == title,
          "Schedule name preserved")
}
for action in ["delete", "submit", "approve", "invalid"] {
    check(AnalyticsSchema.sanitized("task_action", parameters: ["action": action, "result": "success", "title": "Homework"])?["title"] == nil,
          "No title on task lifecycle actions")
}
for action in ["create", "edit"] {
    check(AnalyticsSchema.sanitized("task_action", parameters: ["action": action, "result": "failed", "title": "Homework"])?["title"] == nil,
          "Failed saves do not export unsaved titles")
}
for action in ["toggle", "delete"] {
    check(AnalyticsSchema.sanitized("schedule_change", parameters: ["action": action, "title": "Bedtime"])?["title"] == nil,
          "No title on schedule toggle/delete")
}
check(AnalyticsSchema.sanitized("task_action", parameters: ["action": "create", "title": "Homework"])?["title"] == nil,
      "Success is required for task titles")
for invalidTitle: Any in [" \n\t", 123, true] {
    check(AnalyticsSchema.sanitized("schedule_change", parameters: ["action": "save", "title": invalidTitle])?["title"] == nil,
          "Reject empty and non-text titles")
}
check(AnalyticsSchema.sanitized("schedule_change", parameters: ["action": "save", "title": "  Время сна \n"])?["title"] as? String == "Время сна",
      "Trim surrounding whitespace only")
let emoji = "👨‍👩‍👧‍👦"
let longTitle = AnalyticsSchema.sanitized("schedule_change", parameters: ["action": "save", "title": String(repeating: emoji, count: 205)])?["title"] as? String
check(longTitle == String(repeating: emoji, count: 200), "Bound titles without splitting graphemes")
check(AnalyticsSchema.sanitized("task_action", parameters: ["action": "Private user text"])?.isEmpty == true,
      "Arbitrary string rejected even for allowed field")
check(AnalyticsSchema.sanitized("daily_budget_saved", parameters: ["minutes": Int.max])?.isEmpty == true, "Bound counts")
check(AnalyticsSchema.sanitized("daily_budget_saved", parameters: ["minutes": 5])?["minutes"] as? Int == 5, "Keep minutes")
check(AnalyticsSchema.sanitized("daily_budget_saved", parameters: ["minutes": -5])?["minutes"] as? Int == -5, "Keep negative adjustment")
check(AnalyticsSchema.sanitized("daily_budget_saved", parameters: ["minutes": true])?.isEmpty == true, "Bool not integer")
check(AnalyticsSchema.sanitized("daily_budget_saved", parameters: ["seconds": 300])?.isEmpty == true, "Legacy seconds cannot mix with minutes")
check(AnalyticsSchema.sanitized("schedule_change", parameters: ["enabled": "true"])?.isEmpty == true, "String not bool")
check(AnalyticsSchema.sanitized("schedule_change", parameters: ["enabled": false])?["enabled"] as? Bool == false, "Preserve false")
check(AnalyticsSchema.sanitized("statistics_day_select", parameters: ["day": "2026-10-20"])?.isEmpty == true, "No date export")
check(AnalyticsSchema.sanitized("main_tab_select", parameters: ["tab": "schedule"])?["tab"] as? String == "schedule", "Actual tab ID")
for plan in ["annual", "monthly", "lifetime"] {
    check(AnalyticsSchema.sanitized("purchase_started", parameters: ["plan": plan])?["plan"] as? String == plan,
          "Preserve current purchase plan")
    check(AnalyticsSchema.sanitized("purchase_result", parameters: ["plan": plan, "result": "cancelled"])?["result"] as? String == "cancelled",
          "Preserve cancellation")
}
check(AnalyticsSchema.sanitized("purchase_started", parameters: ["plan": "weekly"])?.isEmpty == true,
      "Reject removed weekly plan")
let context: [String: Any] = ["app": "parental_control", "schema_version": 5,
    "distribution": "release", "role": "child", "parent_mode": true]
let roleEvents: Set<String> = ["role_selected", "onboarding_flow_shown", "onboarding_step_shown",
    "onboarding_step_continue", "onboarding_closed", "onboarding_permission_request"]
for name in AnalyticsSchema.events.keys {
    let payload = AnalyticsSchema.sanitized(name, parameters: context)!
    check(payload.count == (roleEvents.contains(name) ? 1 : 0), "\(name): no unrelated context")
}
check(AnalyticsSchema.sanitized("settings_rate_app_tap", parameters: nil)?.isEmpty == true,
      "Simple taps need no payload")
let tab = AnalyticsSchema.sanitized("main_tab_select", parameters: context.merging(["tab": "map"]) { _, new in new })!
check(tab.count == 1 && tab["tab"] as? String == "map", "Navigation contains only the destination")
check(AnalyticsSchema.sanitized("onboarding_step_shown", parameters: ["role": "parent"])?["role"] as? String == "parent",
      "Onboarding keeps the explicitly supplied role")
for name in ["purchase_result", "restore_result"] {
    check(AnalyticsSchema.sanitized(name, parameters: ["result": "pending_verification"])?["result"] as? String == "pending_verification",
          "\(name): retain pending verification")
}
check(AnalyticsSchema.sanitized("parent_mode_enter", parameters: ["result": "unavailable"])?["result"] as? String == "unavailable",
      "Retain unavailable PIN outcome")
check(AnalyticsSchema.sanitized("remote_block_result", parameters: ["result": "pending_verification"])?.isEmpty == true,
      "Purchase-only outcome cannot leak into command results")
print("PASS: \(checks) analytics configuration and privacy checks")
