import DeviceActivity
import FamilyControls
import Foundation

@MainActor
final class DeviceActivityService {
    private let center = DeviceActivityCenter()
    private let activityName = DeviceActivityName("parentalcontrol.activity")
    private let usageBudgetEvent = DeviceActivityEvent.Name("parentalcontrol.usageBudget")
    private let largeChunkSeconds = 30
    private let smallChunkSeconds = 10
    private let appStore: AppGroupStore

    init(appStore: AppGroupStore) {
        self.appStore = appStore
    }

    func startMonitoringDailySchedule(selection: FamilyActivitySelection, availableSeconds: Int) -> Bool {
        let hasSelection = !selection.applicationTokens.isEmpty ||
            !selection.categoryTokens.isEmpty ||
            !selection.webDomainTokens.isEmpty
        guard hasSelection, availableSeconds > 0 else {
            stopMonitoring()
            return false
        }

        // Opening the main app must not restart a healthy chunk and lose partial usage.
        // Changes to selection, limit, focus or pause explicitly stop the usage monitor first.
        if DailyBudgetStore.shared.isEnabled, center.activities.contains(activityName),
           let state = try? DailyBudgetStore.shared.current(), state.monitorEvent != nil {
            return true
        }

        let schedule = DeviceActivitySchedule(
            intervalStart: DateComponents(hour: 0, minute: 0),
            intervalEnd: DateComponents(hour: 23, minute: 59, second: 59),
            repeats: true,
            warningTime: DateComponents(minute: 5)
        )

        let chunkSeconds = preferredChunkSeconds(for: availableSeconds)
        let thresholdSeconds = max(1, min(chunkSeconds, availableSeconds))
        appStore.saveDeviceActivityThresholdSeconds(thresholdSeconds)
        appStore.markDeviceActivityMonitoringStarted(thresholdSeconds: thresholdSeconds)
        let usageEvent = DeviceActivityEvent(
            applications: selection.applicationTokens,
            categories: selection.categoryTokens,
            webDomains: selection.webDomainTokens,
            threshold: DateComponents(second: thresholdSeconds),
            includesPastActivity: false
        )
        do {
            let eventName = DailyBudgetStore.shared.isEnabled
                ? DeviceActivityEvent.Name(try DailyBudgetStore.shared.arm(threshold: thresholdSeconds))
                : usageBudgetEvent
            let events = [eventName: usageEvent]
            center.stopMonitoring([activityName])
            try center.startMonitoring(activityName, during: schedule, events: events)
            return true
        } catch {
            return false
        }
    }

    func stopMonitoring() {
        center.stopMonitoring([activityName])
        appStore.saveDeviceActivityThresholdSeconds(0)
    }

    func ensureDailyBudgetMonitoring() -> Bool {
        let name = DeviceActivityName("parentalcontrol.dailyBudget")
        guard DailyBudgetStore.shared.isEnabled else {
            center.stopMonitoring([name])
            return true
        }
        if center.activities.contains(name) { return true }
        do {
            try center.startMonitoring(name, during: DeviceActivitySchedule(
                intervalStart: DateComponents(hour: 0, minute: 0),
                intervalEnd: DateComponents(hour: 23, minute: 59, second: 59), repeats: true
            ))
            return true
        } catch { return false }
    }

    private func preferredChunkSeconds(for availableSeconds: Int) -> Int {
        availableSeconds < 60 ? smallChunkSeconds : largeChunkSeconds
    }
}
