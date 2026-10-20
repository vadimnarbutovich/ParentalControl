import Foundation

/// Wire contract of the existing authenticated child_poll endpoint.
nonisolated struct NotificationControlSnapshot: Decodable {
    struct Desired: Decodable {
        let shouldFocusActive: Bool
        let durationSeconds: Int?
        let revision: Int
    }
    struct Command: Decodable {
        let id: UUID
        let commandType: String
    }
    let desired: Desired
    let budget: DailyBudgetStatus?
    let pendingCommands: [Command]

    enum Rejection: String {
        case timedFocus = "timed_focus"
        case staleFocusRevision = "stale_focus_revision"
        case missingBudgetPolicy = "missing_budget_policy"
        case wrongFamily = "wrong_family"
        case invalidBudgetLimits = "invalid_budget_limits"
        case invalidBudgetRevision = "invalid_budget_revision"
    }

    func contains(id: UUID, type: String) -> Bool {
        ["start_focus", "end_focus", "tasks_updated"].contains(type)
            && pendingCommands.contains { $0.id == id && $0.commandType == type }
    }

    func policyForControl(family: UUID, minimumFocusRevision: Int) -> DailyBudgetPolicy? {
        guard rejection(family: family, minimumFocusRevision: minimumFocusRevision) == nil else { return nil }
        return budget?.policy
    }

    func rejection(family: UUID, minimumFocusRevision: Int) -> Rejection? {
        guard (desired.durationSeconds ?? 0) <= 0 else { return .timedFocus }
        guard desired.revision >= minimumFocusRevision else { return .staleFocusRevision }
        guard let policy = budget?.policy else { return .missingBudgetPolicy }
        guard UUID(uuidString: policy.familyID) == family else { return .wrongFamily }
        guard policy.hasValidLimits else { return .invalidBudgetLimits }
        guard policy.revision > 0 else { return .invalidBudgetRevision }
        return nil
    }
}
