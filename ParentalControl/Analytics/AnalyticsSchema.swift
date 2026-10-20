import Foundation

/// Closed, low-cardinality event contract. Unknown events/fields never leave the app.
/// No identifiers, user text, coordinates, app tokens, exact dates or raw errors.
enum AnalyticsSchema {
    enum Rule {
        case choice(Set<String>)
        case integer(ClosedRange<Int>)
        case boolean

        func accepts(_ value: Any) -> Bool {
            switch self {
            case .choice(let options): return (value as? String).map(options.contains) ?? false
            case .integer(let range):
                guard type(of: value) == Int.self, let number = value as? Int else { return false }
                return range.contains(number)
            case .boolean: return type(of: value) == Bool.self
            }
        }
    }

    static let result: Rule = .choice(["success", "failed", "cancelled", "timeout", "unavailable"])
    static let role: Rule = .choice(["parent", "child", "unselected"])
    static let mode: Rule = .choice(["first_launch", "replay"])
    static let permission: Rule = .choice(["notifications", "screenTime", "location"])
    static let step: Rule = .choice([
        "parentIntro", "childIntro", "install", "notifications", "screenTime", "location",
        "pairing", "pin", "apps", "protection", "limit", "finish"
    ])
    static let taskAction: Rule = .choice(["create", "edit", "delete", "submit", "approve"])
    static let scheduleAction: Rule = .choice(["save", "toggle", "delete"])

    static let events: [String: [String: Rule]] = [
        "role_selected": ["role": role],
        "onboarding_flow_shown": ["mode": mode, "role": role],
        "onboarding_step_shown": ["mode": mode, "step": step],
        "onboarding_step_continue": ["step": step, "ready": .boolean],
        "onboarding_closed": ["mode": mode, "role": role],
        "onboarding_share_app": [:],
        "onboarding_permission_request": ["permission": permission, "role": role],
        "permission_request_result": ["permission": permission, "granted": .boolean],
        "pairing_code_request": ["result": result],
        "pairing_join": ["result": result],
        "devices_unlink": ["result": result],
        "parent_mode_enter": ["result": .choice(["success", "wrong_pin", "locked_out", "not_configured"])],
        "parent_mode_exit_tap": [:],
        "parent_pin_change": ["action": .choice(["set", "clear"]), "result": result],
        "main_tab_select": ["tab": .choice(["home", "tasks", "schedule", "map", "statistics", "blocklist", "settings", "parentEntry"])],
        "dashboard_pairing_connect_tap": [:],
        "dashboard_pro_badge_tap": [:],
        "blocklist_pick_apps_tap": [:],
        "blocklist_picker_dismissed": [
            "action": .choice(["blocked_limit"]), "apps_count": .integer(0...10000),
            "categories_count": .integer(0...10000), "domains_count": .integer(0...10000)
        ],
        "blocklist_manual_block": ["action": .choice(["block", "unblock"])],
        "remote_block_request": ["action": .choice(["block", "unblock"])],
        "remote_block_result": ["action": .choice(["block", "unblock"]), "result": result],
        "daily_budget_saved": ["kind": .choice(["limit", "adjustment"]),
            "seconds": .integer(-86400...86400), "limit_mode": .choice(["every_day", "weekdays"])],
        "daily_budget_save_failed": ["kind": .choice(["limit", "adjustment"])],
        "schedule_change": ["action": scheduleAction, "enabled": .boolean, "is_new": .boolean],
        "schedule_sync_result": ["action": .choice(["save", "delete"]), "result": result],
        "task_action": ["action": taskAction, "result": result],
        "location_request": [:],
        "location_request_result": ["result": result],
        "statistics_calendar_open": [:],
        "statistics_day_select": [:],
        "statistics_summary_open": [:],
        "removal_protection_open": ["source": .choice(["settings", "onboarding"])],
        "removal_protection_enable": ["result": result],
        "removal_protection_disable": [:],
        "settings_premium_tap": [:],
        "settings_language_tap": [:],
        "settings_permissions_open": [:],
        "settings_pin_change_tap": [:],
        "settings_pin_clear_tap": [:],
        "settings_pin_set_tap": [:],
        "settings_onboarding_replay_tap": [:],
        "settings_rate_app_tap": [:],
        "settings_share_app_tap": [:],
        "settings_feedback_tap": [:],
        "paywall_open": ["source": .choice(["settings", "dashboard_badge", "limited_feature"])],
        "paywall_cta_tap": ["cta_type": .choice(["continue", "start_trial"])],
        "purchase_started": ["plan": .choice(["weekly", "annual", "other"])],
        "purchase_result": ["plan": .choice(["weekly", "annual", "other"]), "result": result],
        "restore_started": [:],
        "restore_result": ["result": .choice(["restored", "no_active_subscription", "failed"])]
    ]

    static func sanitized(_ name: String, parameters: [String: Any]?) -> [String: Any]? {
        guard let rules = events[name] else { return nil }
        return (parameters ?? [:]).filter { key, value in rules[key]?.accepts(value) == true }
    }

    static func isAllowedKey(_ key: String, bundleID: String?) -> Bool {
        guard bundleID == "mycompny.ParentalControl", UUID(uuidString: key) != nil else { return false }
        // Never route this app back to the inherited ScreenBlocker project.
        return key.lowercased() != "90679160-6625-4373-bd17-55564f521a13"
            && key != "00000000-0000-0000-0000-000000000000"
    }
}
