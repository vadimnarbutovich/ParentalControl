import Foundation

nonisolated enum ParentFocusConfirmation {
    /// Optimism belongs only to the disabled control, never to the confirmed runtime.
    static func controlState(confirmed: Bool, pendingTarget: Bool?, isPending: Bool) -> Bool {
        isPending ? (pendingTarget ?? confirmed) : confirmed
    }

    /// A focus snapshot cannot confirm a budget, task, location or schedule command.
    static func matches(command: String, queuedAt: Date, runtimeUpdatedAt: Date,
                        isActive: Bool) -> Bool {
        guard runtimeUpdatedAt >= queuedAt else { return false }
        switch command {
        case "start_focus": return isActive
        case "end_focus": return !isActive
        default: return false
        }
    }
}
