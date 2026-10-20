import Foundation
import DeviceActivity
import FamilyControls
import ManagedSettings

nonisolated enum ScheduleControlEnforcer {
    private static let signaturesKey = "parentalcontrol.scheduleMonitorSignatures"
    private static let namesKey = "parentalcontrol.blockScheduleActivityNames"

    struct Receipt: Sendable {
        let snapshot: ScheduleControlStore.Snapshot
        let activeIDs: Set<UUID>
        func isCurrent() -> Bool {
            guard (try? ScheduleControlStore.snapshot()) == snapshot,
                  let plan = try? ScheduleControlPlan(data: snapshot.schedules) else { return false }
            return plan.activeIDs() == activeIDs
        }
    }

    static func apply(context: ControlSystemWorker.Context = .init(), verifyAccess: Bool = false) async throws -> Receipt {
        try await ControlSystemWorker.shared.run(context: context) { context in
            for _ in 0..<3 {
                do { return try applyCurrent(context, verifyAccess: verifyAccess) }
                catch ControlSystemWorker.Failure.stale { continue }
            }
            throw ControlSystemWorker.Failure.stale
        }
    }

    private static func applyCurrent(_ context: ControlSystemWorker.Context, verifyAccess: Bool) throws -> Receipt {
        let snapshot = try ScheduleControlStore.snapshot()
        guard snapshot.role == "child", snapshot.pairing != nil else { throw ControlSystemWorker.Failure.stale }
        let plan = try ScheduleControlPlan(data: snapshot.schedules)
        let active = plan.activeIDs()
        let selection = try snapshot.selection.map { try JSONDecoder().decode(FamilyActivitySelection.self, from: $0) }
            ?? FamilyActivitySelection()
        if !plan.enabledEntries.isEmpty,
           selection.applicationTokens.isEmpty && selection.categoryTokens.isEmpty && selection.webDomainTokens.isEmpty {
            throw ControlSystemWorker.Failure.busy
        }
        func validate() throws {
            try context.check()
            guard (try ScheduleControlStore.snapshot()) == snapshot, plan.activeIDs() == active
            else { throw ControlSystemWorker.Failure.stale }
        }
        func system(_ action: () throws -> Void) throws {
            RemoteControlGate.assertOutsideDataLock()
            try context.perform(validate: validate, action)
        }
        let center = DeviceActivityCenter()
        let defaults = RemoteControlGate.defaults!
        var registered: [String] = []
        try system { registered = center.activities.map(\.rawValue) }
        let previous = defaults.data(forKey: namesKey).flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? []
        let known = Set(registered + previous)
        let enabled = plan.enabledEntries
        let wanted = Set(enabled.map(\.activityName))
        // Only obsolete schedule monitors, never daily budget / usage monitors.
        for name in known where ScheduleControlPlan.scheduleID(activityName: name) != nil && !wanted.contains(name) {
            try system { center.stopMonitoring([DeviceActivityName(name)]) }
        }
        var signatures = defaults.data(forKey: signaturesKey)
            .flatMap { try? JSONDecoder().decode([String: Data].self, from: $0) } ?? [:]
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        struct Signature: Encodable {
            let entry: ScheduleControlPlan.Entry
            let selection: Data?
            let pairing: Data?
            let timeZone: String
        }
        for entry in enabled {
            let signature = try encoder.encode(Signature(entry: entry, selection: snapshot.selection,
                pairing: snapshot.pairing, timeZone: snapshot.timeZone))
            if (verifyAccess && entry.id == enabled.first?.id) ||
                !registered.contains(entry.activityName) || signatures[entry.activityName] != signature {
                let schedule = DeviceActivitySchedule(
                    intervalStart: DateComponents(hour: entry.startTime.hour, minute: entry.startTime.minute),
                    intervalEnd: DateComponents(hour: entry.monitoredEnd.hour, minute: entry.monitoredEnd.minute),
                    repeats: true, warningTime: entry.warningMinutes.map { DateComponents(minute: $0) })
                do {
                    try system { try center.startMonitoring(DeviceActivityName(entry.activityName), during: schedule) }
                } catch {
                    signatures.removeValue(forKey: entry.activityName)
                    defaults.set(try? encoder.encode(signatures), forKey: signaturesKey)
                    throw error
                }
                signatures[entry.activityName] = signature
            }
        }
        let ids = Set(known.compactMap { ScheduleControlPlan.scheduleID(activityName: $0) } + plan.entries.map(\.id))
        for id in ids {
            let store = ManagedSettingsStore(named: .init("pcsched_store_\(id.uuidString)"))
            if active.contains(id) {
                try system { store.shield.applications = selection.applicationTokens.isEmpty ? nil : selection.applicationTokens }
                try system { store.shield.applicationCategories = selection.categoryTokens.isEmpty ? nil : .specific(selection.categoryTokens) }
                try system { store.shield.webDomains = selection.webDomainTokens.isEmpty ? nil : selection.webDomainTokens }
            } else {
                // Never clear manual / budget / other schedule shields.
                try system { store.clearAllSettings() }
            }
        }
        try ScheduleControlStore.transaction { d in
            try validate()
            d.set(try encoder.encode(signatures.filter { wanted.contains($0.key) }), forKey: signaturesKey)
            d.set(try encoder.encode(wanted.sorted()), forKey: namesKey)
            d.synchronize()
        }
        return Receipt(snapshot: snapshot, activeIDs: active)
    }
}
