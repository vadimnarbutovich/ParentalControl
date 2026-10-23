import Foundation
import DeviceActivity
import FamilyControls
import ManagedSettings

/// Shared host/NSE implementation. No DeviceActivity / ManagedSettings call is
/// made inside a file-lock scope. Named bedtime stores are never touched.
nonisolated enum ScreenTimeEnforcer {
    static let restartKey = "parentalcontrol.enforcementRestart"
    private static let armedKey = "parentalcontrol.enforcementArmedSignature"
    private static let usage = DeviceActivityName("parentalcontrol.activity")
    private static let daily = DeviceActivityName("parentalcontrol.dailyBudget")

    struct Stamp: Equatable, Sendable {
        let role: String?
        let pairing: Data?
        let selection: Data?
        let focus: Data?
        let paused: Bool
        let restart: String?
        let focusRevision: Int
        let budgetRevision: Int?
        let day: String?
        let budgetSeconds: Int
        let usedSeconds: Int
        let budgetEnabled: Bool
        let focusActive: Bool
        var available: Int { max(0, budgetSeconds - usedSeconds) }
    }

    struct Receipt: Sendable {
        let stamp: Stamp
        let monitoring: Bool
        let event: String?
        let signature: Data?
        func isCurrent() -> Bool {
            guard FamilyAccessStore.allowed else { return false }
            guard let current = try? ScreenTimeEnforcer.snapshot(), current.stamp == stamp else { return false }
            return !monitoring || (current.budget?.monitorEvent == event &&
                RemoteControlGate.defaults?.data(forKey: armedKey) == signature)
        }
    }

    private struct State {
        let stamp: Stamp
        let budget: DailyBudgetState?
        let selection: FamilyActivitySelection
    }

    /// Short data transaction only. The same lock protects host/NSE focus writes.
    private static func snapshot() throws -> State {
        var result: Result<State, Error>?
        guard RemoteControlGate.withLock({
            result = Result {
                guard let d = RemoteControlGate.defaults else { throw ControlSystemWorker.Failure.busy }
                d.synchronize()
                let selectionData = d.data(forKey: "parentalcontrol.familySelection")
                let selection = try selectionData.map { try JSONDecoder().decode(FamilyActivitySelection.self, from: $0) }
                    ?? FamilyActivitySelection()
                let enabled = DailyBudgetStore.shared.isEnabled
                let budget = enabled ? try? DailyBudgetStore.shared.current() : nil
                let pairing = d.data(forKey: "parentalcontrol.pairingState")
                let pair = pairing.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                let family = (pair?["familyID"] as? String).flatMap(UUID.init(uuidString:))
                let focus = d.data(forKey: RemoteControlGate.snapshotKey)
                let object = focus.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                let end = (object?["endsAt"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
                let active = focus != nil && (end == nil || end! > Date())
                // An unreadable active budget must never fall back to an older allowance.
                var earned = enabled ? (budget?.budgetSeconds ?? 0) :
                    d.integer(forKey: "parentalcontrol.deviceActivityMirrorEarnedSeconds")
                var spent = enabled ? (budget?.usedSeconds ?? 0) :
                    d.integer(forKey: "parentalcontrol.deviceActivityMirrorSpentSeconds")
                if !enabled, earned == 0, spent == 0,
                   let data = d.data(forKey: "parentalcontrol.balance"),
                   let balance = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    earned = max(0, balance["totalEarnedSeconds"] as? Int ?? 0)
                    spent = max(0, balance["totalSpentSeconds"] as? Int ?? 0)
                }
                return State(stamp: Stamp(role: d.string(forKey: "parentalcontrol.deviceRole"),
                    pairing: pairing, selection: selectionData, focus: focus,
                    paused: d.bool(forKey: "parentalcontrol.isDeviceActivityMonitoringPaused"),
                    restart: d.string(forKey: restartKey),
                    focusRevision: family.map { d.integer(forKey: RemoteControlGate.revisionKey($0)) } ?? 0,
                    budgetRevision: budget?.policy.revision, day: budget?.day,
                    budgetSeconds: earned, usedSeconds: spent, budgetEnabled: enabled,
                    focusActive: active), budget: budget, selection: selection)
            }
        }), let result else { throw ControlSystemWorker.Failure.busy }
        return try result.get()
    }

    static func verifyMonitoringAccess(context: ControlSystemWorker.Context) async throws {
        try await ControlSystemWorker.shared.run(context: context) { context in
            try context.check()
            RemoteControlGate.assertOutsideDataLock()
            try DeviceActivityCenter().startMonitoring(daily, during: dailySchedule)
            try context.check()
        }
    }

    static func apply(context: ControlSystemWorker.Context = .init()) async throws -> Receipt {
        try await ControlSystemWorker.shared.run(context: context) { context in
            // Concurrent consumption / a newer focus revision can invalidate a plan.
            // Re-read it rather than replaying the obsolete payload.
            for _ in 0..<3 {
                do { return try applyCurrent(context: context) }
                catch ControlSystemWorker.Failure.stale { continue }
            }
            throw ControlSystemWorker.Failure.stale
        }
    }

    private static var dailySchedule: DeviceActivitySchedule {
        DeviceActivitySchedule(intervalStart: DateComponents(hour: 0, minute: 0),
            intervalEnd: DateComponents(hour: 23, minute: 59, second: 59), repeats: true)
    }

    private static func applyCurrent(context: ControlSystemWorker.Context) throws -> Receipt {
        precondition(!Thread.isMainThread)
        try context.check()
        if FamilyAccessEnforcement.releaseIfNeeded() { throw ControlSystemWorker.Failure.stale }
        try FamilyAccessEnforcement.armExpiry()
        let accessReceipt = FamilyAccessStore.receipt
        let state = try snapshot()
        let stamp = state.stamp
        let center = DeviceActivityCenter()
        let store = ManagedSettingsStore()
        var expectedEvent = state.budget?.monitorEvent
        func validate() throws {
            try context.check()
            guard FamilyAccessStore.allowed, FamilyAccessStore.receipt == accessReceipt else {
                throw ControlSystemWorker.Failure.stale
            }
            let current = try snapshot()
            guard current.stamp == stamp, current.budget?.monitorEvent == expectedEvent
            else { throw ControlSystemWorker.Failure.stale }
        }
        func system(_ action: () throws -> Void) throws {
            RemoteControlGate.assertOutsideDataLock()
            try context.perform(validate: validate, action)
        }
        func shield() throws {
            try system { store.shield.applications = state.selection.applicationTokens.isEmpty ? nil : state.selection.applicationTokens }
            try system { store.shield.applicationCategories = state.selection.categoryTokens.isEmpty ? nil : .specific(state.selection.categoryTokens) }
            try system { store.shield.webDomains = state.selection.webDomainTokens.isEmpty ? nil : state.selection.webDomainTokens }
        }
        func complete(monitoring: Bool, signature: Data? = nil) throws -> Receipt {
            var result: Result<Receipt, Error>?
            guard RemoteControlGate.withLock({
                result = Result {
                    try validate()
                    if let budget = state.budget {
                        let key = DailyBudgetStore.confirmedEnforcementKey(budget.policy.familyID)
                        RemoteControlGate.defaults?.set(budget.policy.revision, forKey: key)
                        RemoteControlGate.defaults?.synchronize()
                    }
                    return Receipt(stamp: stamp, monitoring: monitoring, event: expectedEvent, signature: signature)
                }
            }), let result else { throw ControlSystemWorker.Failure.busy }
            return try result.get()
        }
        guard stamp.role == "child" else { throw ControlSystemWorker.Failure.stale }
        let hasSelection = !state.selection.applicationTokens.isEmpty ||
            !state.selection.categoryTokens.isEmpty || !state.selection.webDomainTokens.isEmpty
        func ensureDaily() throws {
            if stamp.budgetEnabled {
                var registered = false
                try system { registered = center.activities.contains(daily) }
                if !registered { try system { try center.startMonitoring(daily, during: dailySchedule) } }
            } else {
                try system { center.stopMonitoring([daily]) }
            }
        }

        // Apply restrictive state before a potentially slow monitoring operation.
        if stamp.budgetEnabled && state.budget == nil {
            try shield()
            throw ControlSystemWorker.Failure.busy
        }
        if stamp.focusActive || (!stamp.paused && stamp.available <= 0) {
            try shield()
            try ensureDaily()
            try system { center.stopMonitoring([usage]) }
            return try complete(monitoring: false)
        }
        if stamp.paused {
            try ensureDaily()
            try system { center.stopMonitoring([usage]) }
            try system { store.clearAllSettings() }
            return try complete(monitoring: false)
        }
        try ensureDaily()
        guard hasSelection && stamp.available > 0 else {
            try system { center.stopMonitoring([usage]) }
            try system { store.clearAllSettings() }
            return try complete(monitoring: false)
        }

        struct Signature: Codable {
            let selection: Data?
            let day: String?
            let seconds: Int
            let restart: String?
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let signature = try encoder.encode(Signature(selection: stamp.selection, day: stamp.day,
            seconds: stamp.budgetSeconds, restart: stamp.restart))
        let defaults = RemoteControlGate.defaults!
        var registered = false
        try system { registered = center.activities.contains(usage) }
        let needsRestart = !registered || (stamp.budgetEnabled && state.budget?.monitorEvent == nil) ||
            defaults.data(forKey: armedKey) != signature
        if needsRestart {
            let threshold = max(1, min(stamp.available, stamp.available < 60 ? 10 : 30))
            // arm() holds only its own short data lock, never over startMonitoring.
            try validate()
            let event = stamp.budgetEnabled
                ? try DailyBudgetStore.shared.arm(threshold: threshold, matching: state.budget) : "parentalcontrol.usageBudget"
            if stamp.budgetEnabled { expectedEvent = event }
            try system { center.stopMonitoring([usage]) }
            do {
                try system {
                    try center.startMonitoring(usage, during: dailySchedule, events: [
                        DeviceActivityEvent.Name(event): DeviceActivityEvent(applications: state.selection.applicationTokens,
                            categories: state.selection.categoryTokens, webDomains: state.selection.webDomainTokens,
                            threshold: DateComponents(second: threshold), includesPastActivity: false)
                    ])
                }
            } catch {
                // A late / failed registration cannot be treated as a healthy monitor.
                defaults.removeObject(forKey: armedKey)
                // Do not turn an expired/stale operation into another system write.
                try validate()
                try shield()
                throw error
            }
            defaults.set(signature, forKey: armedKey)
            defaults.set(threshold, forKey: "parentalcontrol.deviceActivityThresholdSeconds")
            defaults.set(threshold, forKey: "parentalcontrol.deviceActivityLastThresholdValue")
            defaults.set(Int(Date().timeIntervalSince1970), forKey: "parentalcontrol.deviceActivityLastStartMonitoringTimestamp")
        }
        // A late startMonitoring return must never unlock using the old command.
        try system { store.clearAllSettings() }
        return try complete(monitoring: true, signature: signature)
    }
}
