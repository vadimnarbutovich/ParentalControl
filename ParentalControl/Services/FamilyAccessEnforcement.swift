import Foundation
import DeviceActivity
import ManagedSettings

/// System writes are outside the data lock. Each write rechecks current access
/// so a late expiry callback cannot undo a newer purchase/renewal.
nonisolated enum FamilyAccessEnforcement {
    static let activity = DeviceActivityName("parentalcontrol.accessExpiry")
    static func releaseIfNeeded() -> Bool {
        guard !FamilyAccessStore.allowed else { return false }
        guard RemoteControlGate.defaults?.string(forKey: "parentalcontrol.deviceRole") == "child" else { return true }
        RemoteControlGate.assertOutsideDataLock()
        func clear(_ store: ManagedSettingsStore) {
            if !FamilyAccessStore.allowed { store.clearAllSettings() }
        }
        clear(ManagedSettingsStore())
        let d = RemoteControlGate.defaults
        let schedules = d?.data(forKey: "parentalcontrol.blockSchedules")
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [[String: Any]] } ?? []
        var ids = Set(schedules.compactMap { ($0["id"] as? String).flatMap(UUID.init(uuidString:)) })
        let names = d?.data(forKey: "parentalcontrol.blockScheduleActivityNames")
            .flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? []
        for name in names {
            if let id = ScheduleControlPlan.scheduleID(activityName: name) { ids.insert(id) }
        }
        let center = DeviceActivityCenter()
        for name in center.activities {
            if let id = ScheduleControlPlan.scheduleID(activityName: name.rawValue) { ids.insert(id) }
        }
        for id in ids { clear(ManagedSettingsStore(named: .init("pcsched_store_\(id.uuidString)"))) }
        if !FamilyAccessStore.allowed {
            center.stopMonitoring(center.activities.filter {
                ["parentalcontrol.activity", "parentalcontrol.dailyBudget", activity.rawValue].contains($0.rawValue)
                    || ScheduleControlPlan.scheduleID(activityName: $0.rawValue) != nil
            })
            d?.removeObject(forKey: "parentalcontrol.accessMonitorRevision")
            d?.removeObject(forKey: "parentalcontrol.enforcementArmedSignature")
            d?.removeObject(forKey: "parentalcontrol.scheduleMonitorSignatures")
        }
        return !FamilyAccessStore.allowed
    }
    static func armExpiry() throws {
        guard RemoteControlGate.defaults?.string(forKey: "parentalcontrol.deviceRole") == "child" else { return }
        guard FamilyAccessStore.allowed, let receipt = FamilyAccessStore.receipt,
              let end = receipt.lease.controlUntilMs else { return }
        RemoteControlGate.assertOutsideDataLock()
        let d = RemoteControlGate.defaults
        if receipt.lease.state == .paid {
            // Only demo expires locally. A legacy access timer may still fire;
            // releaseIfNeeded rechecks the cached paid decision and does nothing.
            if d?.string(forKey: "parentalcontrol.accessMonitorRevision") != nil {
                DeviceActivityCenter().stopMonitoring([activity])
                d?.removeObject(forKey: "parentalcontrol.accessMonitorRevision")
            }
            return
        }
        let signature = "\(receipt.lease.revision):\(end)"
        if d?.string(forKey: "parentalcontrol.accessMonitorRevision") == signature { return }
        let elapsed = ProcessInfo.processInfo.systemUptime - receipt.requestUptime
        let remaining = Double(end - receipt.lease.issuedAtMs) / 1000 - elapsed
        guard remaining > 0, FamilyAccessStore.allowed else { _ = releaseIfNeeded(); return }
        let now = Date()
        let calendar = Calendar.current
        let fields: Set<Calendar.Component> = [.year, .month, .day, .hour, .minute, .second]
        // Apple's minimum interval is 15 min. A past start keeps short remaining
        // leases within that requirement without extending their actual end.
        let start = calendar.dateComponents(fields, from: now.addingTimeInterval(-16 * 60))
        let finish = calendar.dateComponents(fields, from: now.addingTimeInterval(ceil(remaining) + 1))
        try DeviceActivityCenter().startMonitoring(activity, during: .init(intervalStart: start, intervalEnd: finish, repeats: false))
        guard FamilyAccessStore.receipt == receipt, FamilyAccessStore.allowed else { return }
        d?.set(signature, forKey: "parentalcontrol.accessMonitorRevision")
    }
}
