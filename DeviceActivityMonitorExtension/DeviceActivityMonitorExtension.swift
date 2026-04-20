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
        markHeartbeat("intervalDidStart")
        resetDailyBalanceAndEnforceShieldIfNeeded(activity: activity)
    }

    override func intervalDidEnd(for activity: DeviceActivityName) {
        super.intervalDidEnd(for: activity)
        markHeartbeat("intervalDidEnd")
    }

    override func intervalWillEndWarning(for activity: DeviceActivityName) {
        super.intervalWillEndWarning(for: activity)
        markHeartbeat("intervalWillEndWarning")
    }

    override func eventWillReachThresholdWarning(_ event: DeviceActivityEvent.Name, activity: DeviceActivityName) {
        super.eventWillReachThresholdWarning(event, activity: activity)
        markHeartbeat("eventWillReachThresholdWarning:\(event.rawValue)")
        incrementCounter(warningCountKey)
        saveString("warning", for: lastTriggerKey)
        handleBudgetEvent(event, trigger: "warning")
    }

    override func eventDidReachThreshold(_ event: DeviceActivityEvent.Name, activity: DeviceActivityName) {
        super.eventDidReachThreshold(event, activity: activity)
        incrementCounter(thresholdCountKey)
        saveString("threshold", for: lastTriggerKey)
        handleBudgetEvent(event, trigger: "threshold")
    }

    private func handleBudgetEvent(_ event: DeviceActivityEvent.Name, trigger: String) {
        markHeartbeat("eventDidReachThreshold:\(event.rawValue):\(trigger)")
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

    private func saveBalance(_ balance: StoredBalance, defaults: UserDefaults) {
        guard let encoded = try? JSONEncoder().encode(balance) else { return }
        defaults.set(encoded, forKey: balanceKey)
        defaults.set(balance.totalEarnedSeconds, forKey: mirrorEarnedKey)
        defaults.set(balance.totalSpentSeconds, forKey: mirrorSpentKey)
        defaults.synchronize()
    }

    private func applyShield(selection: FamilyActivitySelection) {
        let settingsStore = ManagedSettingsStore()
        settingsStore.shield.applications = selection.applicationTokens.isEmpty ? nil : selection.applicationTokens
        settingsStore.shield.applicationCategories = selection.categoryTokens.isEmpty ? nil : .specific(selection.categoryTokens)
        settingsStore.shield.webDomains = selection.webDomainTokens.isEmpty ? nil : selection.webDomainTokens
    }

    private func clearShield() {
        let settingsStore = ManagedSettingsStore()
        settingsStore.clearAllSettings()
    }

    private func startNextChunkMonitoring(
        selection: FamilyActivitySelection,
        availableSeconds: Int,
        defaults: UserDefaults
    ) {
        let hasSelection = !selection.applicationTokens.isEmpty ||
            !selection.categoryTokens.isEmpty ||
            !selection.webDomainTokens.isEmpty
        guard hasSelection, availableSeconds > 0 else {
            centerStopMonitoring()
            defaults.set(0, forKey: thresholdKey)
            return
        }

        let chunkSeconds = preferredChunkSeconds(for: availableSeconds)
        let threshold = max(1, min(chunkSeconds, availableSeconds))
        defaults.set(threshold, forKey: thresholdKey)
        defaults.set(threshold, forKey: lastThresholdValueKey)
        defaults.set(Int(Date().timeIntervalSince1970), forKey: lastStartMonitoringTimestampKey)
        incrementCounter(monitoringRestartCountKey)
        let schedule = DeviceActivitySchedule(
            intervalStart: DateComponents(hour: 0, minute: 0),
            intervalEnd: DateComponents(hour: 23, minute: 59),
            repeats: true,
            warningTime: DateComponents(minute: 5)
        )
        let usageEvent = DeviceActivityEvent(
            applications: selection.applicationTokens,
            categories: selection.categoryTokens,
            webDomains: selection.webDomainTokens,
            threshold: DateComponents(second: threshold)
        )

        do {
            let center = DeviceActivityCenter()
            center.stopMonitoring([activityName])
            try center.startMonitoring(
                activityName,
                during: schedule,
                events: [usageBudgetEvent: usageEvent]
            )
            markHeartbeat("startNextChunkMonitoring.success")
        } catch {
            markHeartbeat("startNextChunkMonitoring.error")
        }
    }

    private func centerStopMonitoring() {
        DeviceActivityCenter().stopMonitoring([activityName])
        markHeartbeat("centerStopMonitoring")
    }

    private func resetDailyBalanceAndEnforceShieldIfNeeded(activity: DeviceActivityName) {
        guard activity == activityName else { return }
        guard let defaults = UserDefaults(suiteName: appGroupId) else { return }
        // intervalDidStart can be fired on monitor restarts, not only at true day boundary.
        // Restrict reset to a small window after local midnight.
        guard shouldRunDailyResetNow() else {
            markHeartbeat("dailyReset.skipped.notBoundary")
            return
        }

        let todayStart = Calendar.current.startOfDay(for: Date())
        let storedResetTs = defaults.integer(forKey: lastBalanceResetDayStartKey)
        if storedResetTs > 0 {
            let storedResetDate = Date(timeIntervalSince1970: TimeInterval(storedResetTs))
            if Calendar.current.isDate(storedResetDate, inSameDayAs: todayStart) {
                return
            }
        }

        if defaults.integer(forKey: midnightResetDisabledKey) != 0 {
            // Feature is disabled: keep marker in sync with current day, do not reset balance.
            let currentSpent = loadBalance(defaults: defaults)?.totalSpentSeconds ?? defaults.integer(forKey: mirrorSpentKey)
            saveSpentBaseline(totalSpentSeconds: currentSpent, dayStart: todayStart, defaults: defaults)
            defaults.set(Int(todayStart.timeIntervalSince1970), forKey: lastBalanceResetDayStartKey)
            defaults.synchronize()
            markHeartbeat("dailyReset.disabled.dayChanged")
            return
        }

        // If reset marker is missing, initialize it and do not force-reset in extension.
        // Main app remains the primary source for first-day initialization.
        guard storedResetTs > 0 else {
            let currentSpent = loadBalance(defaults: defaults)?.totalSpentSeconds ?? defaults.integer(forKey: mirrorSpentKey)
            saveSpentBaseline(totalSpentSeconds: currentSpent, dayStart: todayStart, defaults: defaults)
            defaults.set(Int(todayStart.timeIntervalSince1970), forKey: lastBalanceResetDayStartKey)
            defaults.synchronize()
            markHeartbeat("dailyReset.markerInitialized")
            return
        }

        let resetBalance = StoredBalance(totalEarnedSeconds: 0, totalSpentSeconds: 0)
        saveBalance(resetBalance, defaults: defaults)
        defaults.set(Int(todayStart.timeIntervalSince1970), forKey: lastBalanceResetDayStartKey)
        saveSpentBaseline(totalSpentSeconds: 0, dayStart: todayStart, defaults: defaults)
        defaults.set(0, forKey: thresholdKey)

        if let data = defaults.data(forKey: selectionKey),
           let selection = try? JSONDecoder().decode(FamilyActivitySelection.self, from: data) {
            let hasSelection = !selection.applicationTokens.isEmpty ||
                !selection.categoryTokens.isEmpty ||
                !selection.webDomainTokens.isEmpty
            if hasSelection {
                applyShield(selection: selection)
                centerStopMonitoring()
                markHeartbeat("dailyReset.appliedShield")
            } else {
                clearShield()
                markHeartbeat("dailyReset.noSelection")
            }
        } else {
            clearShield()
            markHeartbeat("dailyReset.noSelectionData")
        }

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
