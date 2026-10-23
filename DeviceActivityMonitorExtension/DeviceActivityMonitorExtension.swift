//
//  DeviceActivityMonitorExtension.swift
//  DeviceActivityMonitorExtension
//
//  Created by Vadzim Narbutovich on 04.03.2026.
//

import DeviceActivity
import FamilyControls
import Foundation
import ManagedSettings

final class DeviceActivityMonitorExtension: DeviceActivityMonitor {
    private let appGroupId = "group.mycompny.parentalcontrol"
    private let balanceKey = "parentalcontrol.balance"
    private let lastBalanceResetDayStartKey = "parentalcontrol.lastBalanceResetDayStart"
    private let midnightResetDisabledKey = "parentalcontrol.midnightResetDisabled"
    private let spentBaselineDayStartKey = "parentalcontrol.spentBaselineDayStart"
    private let spentBaselineTotalSpentSecondsKey = "parentalcontrol.spentBaselineTotalSpentSeconds"
    private let selectionKey = "parentalcontrol.familySelection"
    private let thresholdKey = "parentalcontrol.deviceActivityThresholdSeconds"
    private let usageBudgetEvent = DeviceActivityEvent.Name("parentalcontrol.usageBudget")
    private let activityName = DeviceActivityName("parentalcontrol.activity")
    private let largeChunkSeconds = 30
    private let smallChunkSeconds = 10
    private let heartbeatTimestampKey = "parentalcontrol.deviceActivityLastHeartbeatTimestamp"
    private let heartbeatEventKey = "parentalcontrol.deviceActivityLastHeartbeatEvent"
    private let heartbeatCountKey = "parentalcontrol.deviceActivityHeartbeatCount"
    private let lastConsumptionTimestampKey = "parentalcontrol.deviceActivityLastConsumptionTimestamp"
    private let mirrorEarnedKey = "parentalcontrol.deviceActivityMirrorEarnedSeconds"
    private let mirrorSpentKey = "parentalcontrol.deviceActivityMirrorSpentSeconds"
    private let warningCountKey = "parentalcontrol.deviceActivityWarningCount"
    private let thresholdCountKey = "parentalcontrol.deviceActivityThresholdCount"
    private let lastTriggerKey = "parentalcontrol.deviceActivityLastTrigger"
    private let lastThresholdValueKey = "parentalcontrol.deviceActivityLastThresholdValue"
    private let lastSpentDeltaKey = "parentalcontrol.deviceActivityLastSpentDelta"
    private let lastAvailableBeforeKey = "parentalcontrol.deviceActivityLastAvailableBefore"
    private let lastAvailableAfterKey = "parentalcontrol.deviceActivityLastAvailableAfter"
    private let monitoringRestartCountKey = "parentalcontrol.deviceActivityMonitoringRestartCount"
    private let lastStartMonitoringTimestampKey = "parentalcontrol.deviceActivityLastStartMonitoringTimestamp"

    override func intervalDidStart(for activity: DeviceActivityName) {
        super.intervalDidStart(for: activity)
        if FamilyAccessEnforcement.releaseIfNeeded() { return }
        markHeartbeat("intervalDidStart")
        if DailyBudgetStore.shared.isEnabled,
           activity == activityName || activity.rawValue == "parentalcontrol.dailyBudget" {
            enforceDailyBudget()
            BackgroundUsageUploader.shared.scheduleFromMonitor()
            return
        }
        if activity == activityName {
            resetDailyBalanceAndEnforceShieldIfNeeded(activity: activity)
        } else if let id = ScheduleControlPlan.scheduleID(activityName: activity.rawValue) {
            reconcileSchedule(scheduleID: id)
        }
    }

    override func intervalDidEnd(for activity: DeviceActivityName) {
        super.intervalDidEnd(for: activity)
        if FamilyAccessEnforcement.releaseIfNeeded() { return }
        markHeartbeat("intervalDidEnd")
        if let id = ScheduleControlPlan.scheduleID(activityName: activity.rawValue) {
            reconcileSchedule(scheduleID: id)
        }
    }

    override func intervalWillEndWarning(for activity: DeviceActivityName) {
        super.intervalWillEndWarning(for: activity)
        if FamilyAccessEnforcement.releaseIfNeeded() { return }
        markHeartbeat("intervalWillEndWarning")
        if let id = ScheduleControlPlan.scheduleID(activityName: activity.rawValue) {
            reconcileSchedule(scheduleID: id)
        }
    }

    override func eventWillReachThresholdWarning(_ event: DeviceActivityEvent.Name, activity: DeviceActivityName) {
        super.eventWillReachThresholdWarning(event, activity: activity)
        if FamilyAccessEnforcement.releaseIfNeeded() { return }
        markHeartbeat("eventWillReachThresholdWarning:\(event.rawValue)")
        incrementCounter(warningCountKey)
        saveString("warning", for: lastTriggerKey)
        handleBudgetEvent(event, trigger: "warning")
    }

    override func eventDidReachThreshold(_ event: DeviceActivityEvent.Name, activity: DeviceActivityName) {
        super.eventDidReachThreshold(event, activity: activity)
        if FamilyAccessEnforcement.releaseIfNeeded() { return }
        incrementCounter(thresholdCountKey)
        saveString("threshold", for: lastTriggerKey)
        handleBudgetEvent(event, trigger: "threshold")
    }

    private func handleBudgetEvent(_ event: DeviceActivityEvent.Name, trigger: String) {
        markHeartbeat("eventDidReachThreshold:\(event.rawValue):\(trigger)")
        if DailyBudgetStore.shared.isEnabled {
            guard trigger == "threshold", event.rawValue.hasPrefix("parentalcontrol.usageBudget.") else { return }
            guard let defaults = UserDefaults(suiteName: appGroupId), !budgetTemporarilyBlocked(defaults) else { return }
            do {
                guard let current = try DailyBudgetStore.shared.current() else { return }
                if current.monitorEvent == nil { enforceDailyBudget(restartUsage: true); return }
                guard current.monitorEvent == event.rawValue else { return }
                _ = try DailyBudgetStore.shared.consume(event: event.rawValue)
                enforceDailyBudget(restartUsage: true)
                BackgroundUsageUploader.shared.scheduleFromMonitor()
            } catch { enforceDailyBudget() }
            return
        }
        guard event == usageBudgetEvent else { return }
        guard let defaults = UserDefaults(suiteName: appGroupId),
              let data = defaults.data(forKey: selectionKey),
              let selection = try? JSONDecoder().decode(FamilyActivitySelection.self, from: data),
              var balance = loadBalance(defaults: defaults) else {
            markHeartbeat("eventGuardFailed:\(trigger)")
            return
        }

        let threshold = max(1, defaults.integer(forKey: thresholdKey))
        defaults.set(threshold, forKey: lastThresholdValueKey)
        if trigger == "warning", shouldSkipTooEarlyWarning(defaults: defaults, threshold: threshold) {
            markHeartbeat("warningSkipped.tooEarly")
            return
        }
        if shouldSkipDuplicateConsumption(defaults: defaults, threshold: threshold) {
            markHeartbeat("consumptionDedupSkip:\(trigger)")
            return
        }

        let availableBeforeSpend = max(0, balance.totalEarnedSeconds - balance.totalSpentSeconds)
        defaults.set(availableBeforeSpend, forKey: lastAvailableBeforeKey)
        let spentDelta = min(availableBeforeSpend, threshold)
        defaults.set(spentDelta, forKey: lastSpentDeltaKey)
        guard spentDelta > 0 else {
            markHeartbeat("spentDeltaZero:\(trigger)")
            return
        }
        balance.totalSpentSeconds += spentDelta
        saveBalance(balance, defaults: defaults)
        defaults.set(Int(Date().timeIntervalSince1970), forKey: lastConsumptionTimestampKey)
        defaults.synchronize()

        if DailyBudgetStore.shared.isEnabled { enforceDailyBudget(); return }
        let remainingSeconds = max(0, balance.totalEarnedSeconds - balance.totalSpentSeconds)
        defaults.set(remainingSeconds, forKey: lastAvailableAfterKey)
        if remainingSeconds <= 0 {
            applyShield(selection: selection)
            centerStopMonitoring()
            defaults.set(0, forKey: thresholdKey)
            markHeartbeat("consumptionAppliedZero:\(trigger)")
        } else {
            clearShield()
            startNextChunkMonitoring(
                selection: selection,
                availableSeconds: remainingSeconds,
                defaults: defaults
            )
            markHeartbeat("consumptionAppliedRemaining:\(trigger)")
        }
    }

    private func loadBalance(defaults: UserDefaults) -> StoredBalance? {
        guard let data = defaults.data(forKey: balanceKey) else { return nil }
        return try? JSONDecoder().decode(StoredBalance.self, from: data)
    }

    private func budgetTemporarilyBlocked(_ defaults: UserDefaults) -> Bool {
        if defaults.bool(forKey: "parentalcontrol.isDeviceActivityMonitoringPaused") { return true }
        guard let data = defaults.data(forKey: "parentalcontrol.focusSessionSnapshot"),
              let snapshot = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        guard let end = snapshot["endsAt"] as? String else { return true }
        return (ISO8601DateFormatter().date(from: end) ?? .distantFuture) > Date()
    }

    private func enforceDailyBudget(restartUsage: Bool = false) {
        guard let defaults = UserDefaults(suiteName: appGroupId),
              let data = defaults.data(forKey: selectionKey),
              let selection = try? JSONDecoder().decode(FamilyActivitySelection.self, from: data) else { return }
        // Manual focus and monitoring pause have priority. Named schedule shields are independent.
        if budgetTemporarilyBlocked(defaults) { return }
        guard let state = try? DailyBudgetStore.shared.current() else {
            applyShield(selection: selection) // Do not unlock on corrupt/missing shared state.
            centerStopMonitoring()
            return
        }
        if state.availableSeconds == 0 {
            applyShield(selection: selection)
            centerStopMonitoring()
            defaults.set(0, forKey: thresholdKey)
        } else {
            let center = DeviceActivityCenter()
            if restartUsage || state.monitorEvent == nil || !center.activities.contains(activityName) {
                guard startNextChunkMonitoring(selection: selection, availableSeconds: state.availableSeconds, defaults: defaults) else {
                    guard !budgetTemporarilyBlocked(defaults),
                          let current = try? DailyBudgetStore.shared.current(),
                          current.policy.revision == state.policy.revision else { return }
                    applyShield(selection: selection)
                    return
                }
            }
            clearShield()
        }
    }

    private func saveBalance(_ balance: StoredBalance, defaults: UserDefaults) {
        guard let encoded = try? JSONEncoder().encode(balance) else { return }
        defaults.set(encoded, forKey: balanceKey)
        defaults.set(balance.totalEarnedSeconds, forKey: mirrorEarnedKey)
        defaults.set(balance.totalSpentSeconds, forKey: mirrorSpentKey)
        defaults.synchronize()
    }

    private func applyShield(selection: FamilyActivitySelection) {
        if FamilyAccessEnforcement.releaseIfNeeded() { return }
        let settingsStore = ManagedSettingsStore()
        settingsStore.shield.applications = selection.applicationTokens.isEmpty ? nil : selection.applicationTokens
        if FamilyAccessEnforcement.releaseIfNeeded() { return }
        settingsStore.shield.applicationCategories = selection.categoryTokens.isEmpty ? nil : .specific(selection.categoryTokens)
        if FamilyAccessEnforcement.releaseIfNeeded() { return }
        settingsStore.shield.webDomains = selection.webDomainTokens.isEmpty ? nil : selection.webDomainTokens
        _ = FamilyAccessEnforcement.releaseIfNeeded()
    }

    private func clearShield() {
        // startMonitoring can return after a newer manual block arrived.
        // Never clear the default store based on the pre-IPC snapshot.
        guard let defaults = UserDefaults(suiteName: appGroupId) else { return }
        defaults.synchronize()
        guard !budgetTemporarilyBlocked(defaults) else { return }
        if DailyBudgetStore.shared.isEnabled {
            guard let state = try? DailyBudgetStore.shared.current(), state.availableSeconds > 0 else { return }
        }
        let settingsStore = ManagedSettingsStore()
        settingsStore.clearAllSettings()
    }

    @discardableResult
    private func startNextChunkMonitoring(
        selection: FamilyActivitySelection,
        availableSeconds: Int,
        defaults: UserDefaults
    ) -> Bool {
        if FamilyAccessEnforcement.releaseIfNeeded() { return false }
        let hasSelection = !selection.applicationTokens.isEmpty ||
            !selection.categoryTokens.isEmpty ||
            !selection.webDomainTokens.isEmpty
        guard hasSelection, availableSeconds > 0 else {
            centerStopMonitoring()
            defaults.set(0, forKey: thresholdKey)
            return false
        }

        let chunkSeconds = preferredChunkSeconds(for: availableSeconds)
        let threshold = max(1, min(chunkSeconds, availableSeconds))
        defaults.set(threshold, forKey: thresholdKey)
        defaults.set(threshold, forKey: lastThresholdValueKey)
        defaults.set(Int(Date().timeIntervalSince1970), forKey: lastStartMonitoringTimestampKey)
        incrementCounter(monitoringRestartCountKey)
        let schedule = DeviceActivitySchedule(
            intervalStart: DateComponents(hour: 0, minute: 0),
            intervalEnd: DateComponents(hour: 23, minute: 59, second: 59),
            repeats: true,
            warningTime: DateComponents(minute: 5)
        )
        let usageEvent = DeviceActivityEvent(
            applications: selection.applicationTokens,
            categories: selection.categoryTokens,
            webDomains: selection.webDomainTokens,
            threshold: DateComponents(second: threshold),
            includesPastActivity: false
        )

        do {
            let center = DeviceActivityCenter()
            let enabled = DailyBudgetStore.shared.isEnabled
            let before = enabled ? try DailyBudgetStore.shared.current() : nil
            guard !budgetTemporarilyBlocked(defaults),
                  !enabled || before?.availableSeconds == availableSeconds else { return false }
            let eventName = enabled
                ? DeviceActivityEvent.Name(try DailyBudgetStore.shared.arm(threshold: threshold, matching: before))
                : usageBudgetEvent
            center.stopMonitoring([activityName])
            guard !budgetTemporarilyBlocked(defaults) else { return false }
            try center.startMonitoring(
                activityName,
                during: schedule,
                events: [eventName: usageEvent]
            )
            if enabled {
                guard let after = try DailyBudgetStore.shared.current(),
                      after.monitorEvent == eventName.rawValue,
                      after.policy.revision == before?.policy.revision,
                      !budgetTemporarilyBlocked(defaults) else { return false }
            }
            markHeartbeat("startNextChunkMonitoring.success")
            return true
        } catch {
            markHeartbeat("startNextChunkMonitoring.error")
            return false
        }
    }

    private func centerStopMonitoring() {
        DeviceActivityCenter().stopMonitoring([activityName])
        markHeartbeat("centerStopMonitoring")
    }

    private func resetDailyBalanceAndEnforceShieldIfNeeded(activity: DeviceActivityName) {
        guard activity == activityName,
              let defaults = UserDefaults(suiteName: appGroupId) else { return }
        // Transition period: retain the old balance until the parent explicitly saves a limit.
        let todayStart = Calendar.current.startOfDay(for: Date())
        let timestamp = defaults.integer(forKey: lastBalanceResetDayStartKey)
        if timestamp > 0, Calendar.current.isDate(Date(timeIntervalSince1970: TimeInterval(timestamp)), inSameDayAs: todayStart) { return }
        let spent = loadBalance(defaults: defaults)?.totalSpentSeconds ?? defaults.integer(forKey: mirrorSpentKey)
        saveSpentBaseline(totalSpentSeconds: spent, dayStart: todayStart, defaults: defaults)
        defaults.set(Int(todayStart.timeIntervalSince1970), forKey: lastBalanceResetDayStartKey)
        defaults.synchronize()
    }

    private func saveSpentBaseline(totalSpentSeconds: Int, dayStart: Date, defaults: UserDefaults) {
        defaults.set(Int(dayStart.timeIntervalSince1970), forKey: spentBaselineDayStartKey)
        defaults.set(max(0, totalSpentSeconds), forKey: spentBaselineTotalSpentSecondsKey)
    }

    private func shouldRunDailyResetNow() -> Bool {
        let calendar = Calendar.current
        let now = Date()
        let startOfDay = calendar.startOfDay(for: now)
        let elapsed = now.timeIntervalSince(startOfDay)
        // 0...2 hours after midnight: tolerant to callback jitter/background wake-up.
        return elapsed >= 0 && elapsed <= 7_200
    }

    private func shouldSkipDuplicateConsumption(defaults: UserDefaults, threshold: Int) -> Bool {
        let now = Int(Date().timeIntervalSince1970)
        let last = defaults.integer(forKey: lastConsumptionTimestampKey)
        guard last > 0 else { return false }
        let minGap = max(8, threshold / 2)
        return (now - last) < minGap
    }

    private func markHeartbeat(_ event: String) {
        guard let defaults = UserDefaults(suiteName: appGroupId) else { return }
        let now = Int(Date().timeIntervalSince1970)
        let count = defaults.integer(forKey: heartbeatCountKey)
        defaults.set(now, forKey: heartbeatTimestampKey)
        defaults.set(event, forKey: heartbeatEventKey)
        defaults.set(count + 1, forKey: heartbeatCountKey)
        defaults.synchronize()
    }

    private func incrementCounter(_ key: String) {
        guard let defaults = UserDefaults(suiteName: appGroupId) else { return }
        let current = defaults.integer(forKey: key)
        defaults.set(current + 1, forKey: key)
        defaults.synchronize()
    }

    private func saveString(_ value: String, for key: String) {
        guard let defaults = UserDefaults(suiteName: appGroupId) else { return }
        defaults.set(value, forKey: key)
        defaults.synchronize()
    }

    private func shouldSkipTooEarlyWarning(defaults: UserDefaults, threshold: Int) -> Bool {
        let startTs = defaults.integer(forKey: lastStartMonitoringTimestampKey)
        guard startTs > 0 else { return false }
        let now = Int(Date().timeIntervalSince1970)
        let elapsed = now - startTs
        // On affected iOS versions warning may fire almost immediately after monitor start.
        // Ignore these early warnings to avoid spending time while tracked app is not used.
        let minExpected = max(5, threshold - 3)
        return elapsed < minExpected
    }

    private func preferredChunkSeconds(for availableSeconds: Int) -> Int {
        availableSeconds < 60 ? smallChunkSeconds : largeChunkSeconds
    }

    // MARK: - Block schedules (named ManagedSettingsStore)

    /// A stop/re-registration also emits intervalDidEnd. Interpret every callback
    /// against CURRENT data/time, never as an unconditional "remove shield".
    private func reconcileSchedule(scheduleID: UUID) {
        guard let defaults = UserDefaults(suiteName: appGroupId) else { return }
        for _ in 0..<3 {
            defaults.synchronize()
            guard defaults.string(forKey: "parentalcontrol.deviceRole") == "child",
                  let data = defaults.data(forKey: ScheduleControlPlan.cacheKey),
                  let plan = try? ScheduleControlPlan(data: data) else {
                markHeartbeat("schedule.invalidCache")
                return // Corrupt data must not remove an existing restriction.
            }
            let selectionData = defaults.data(forKey: selectionKey)
            let selection = selectionData.flatMap { try? JSONDecoder().decode(FamilyActivitySelection.self, from: $0) }
                ?? FamilyActivitySelection()
            let entry = plan.entries.first { $0.id == scheduleID }
            let active = entry?.isActive(at: Date()) == true
            func current() -> Bool {
                defaults.synchronize()
                return FamilyAccessStore.allowed && defaults.data(forKey: ScheduleControlPlan.cacheKey) == data &&
                    defaults.data(forKey: selectionKey) == selectionData &&
                    defaults.string(forKey: "parentalcontrol.deviceRole") == "child" &&
                    (entry?.isActive(at: Date()) == true) == active
            }
            let store = ManagedSettingsStore(named: .init("pcsched_store_\(scheduleID.uuidString)"))
            guard current() else { continue }
            if active {
                guard !selection.applicationTokens.isEmpty || !selection.categoryTokens.isEmpty ||
                        !selection.webDomainTokens.isEmpty else {
                    markHeartbeat("schedule.noSelection")
                    return
                }
                store.shield.applications = selection.applicationTokens.isEmpty ? nil : selection.applicationTokens
                guard current() else { continue }
                store.shield.applicationCategories = selection.categoryTokens.isEmpty ? nil : .specific(selection.categoryTokens)
                guard current() else { continue }
                store.shield.webDomains = selection.webDomainTokens.isEmpty ? nil : selection.webDomainTokens
            } else {
                store.clearAllSettings()
            }
            guard current() else { continue }
            markHeartbeat(active ? "schedule.shieldOn" : "schedule.shieldOff")
            return
        }
    }

}

private struct StoredBalance: Codable {
    var totalEarnedSeconds: Int
    var totalSpentSeconds: Int

    private enum CodingKeys: String, CodingKey {
        case totalEarnedSeconds
        case totalSpentSeconds
        case totalEarnedMinutes
        case totalSpentMinutes
    }

    init(totalEarnedSeconds: Int, totalSpentSeconds: Int) {
        self.totalEarnedSeconds = totalEarnedSeconds
        self.totalSpentSeconds = totalSpentSeconds
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let earnedSeconds = try container.decodeIfPresent(Int.self, forKey: .totalEarnedSeconds),
           let spentSeconds = try container.decodeIfPresent(Int.self, forKey: .totalSpentSeconds) {
            totalEarnedSeconds = earnedSeconds
            totalSpentSeconds = spentSeconds
            return
        }

        let earnedMinutes = try container.decodeIfPresent(Int.self, forKey: .totalEarnedMinutes) ?? 0
        let spentMinutes = try container.decodeIfPresent(Int.self, forKey: .totalSpentMinutes) ?? 0
        totalEarnedSeconds = max(0, earnedMinutes * 60)
        totalSpentSeconds = max(0, spentMinutes * 60)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(totalEarnedSeconds, forKey: .totalEarnedSeconds)
        try container.encode(totalSpentSeconds, forKey: .totalSpentSeconds)
    }
}
