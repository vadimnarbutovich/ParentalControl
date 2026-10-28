import Foundation

/// No locks across system IPC. A changed generation belongs to another updater,
/// not to a failed monitor: it must never trigger a fallback shield.
nonisolated enum BudgetMonitorRearm {
    enum Outcome {
        case started(DailyBudgetState)
        case superseded
        case failed(DailyBudgetState, code: Int)
    }

    static func run(
        expected initial: DailyBudgetState,
        read: () throws -> DailyBudgetState?,
        contextIsCurrent: () -> Bool,
        arm: () throws -> String,
        stop: () -> Void,
        start: (String) throws -> Void
    ) -> Outcome {
        var expected = initial
        func current() -> Bool {
            contextIsCurrent() && (try? read()) == expected
        }
        guard current() else { return .superseded }
        do {
            let event = try arm()
            guard let armed = try read(), armed.monitorEvent == event else { return .superseded }
            // arm may change ONLY the monitor generation, never the allowance,
            // usage, family, day or policy we used to calculate the threshold.
            var original = armed
            original.monitorEvent = initial.monitorEvent
            original.monitorThreshold = initial.monitorThreshold
            original.monitorStartedAt = initial.monitorStartedAt
            guard original == initial else { return .superseded }
            expected = armed
            guard current() else { return .superseded }
            stop()
            guard current() else { return .superseded }
            try start(event)
            guard current() else { return .superseded }
            return .started(expected)
        } catch {
            // Includes an arm conflict and a system error delivered after another
            // process changed the budget. Neither may shield the newer state.
            guard current() else { return .superseded }
            return .failed(expected, code: (error as NSError).code)
        }
    }
}
