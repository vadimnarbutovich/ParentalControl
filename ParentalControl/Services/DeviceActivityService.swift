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

        let schedule = DeviceActivitySchedule(
            intervalStart: DateComponents(hour: 0, minute: 0),
            intervalEnd: DateComponents(hour: 23, minute: 59),
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
            threshold: DateComponents(second: thresholdSeconds)
        )
        let events = [usageBudgetEvent: usageEvent]

        do {
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

    private func preferredChunkSeconds(for availableSeconds: Int) -> Int {
        availableSeconds < 60 ? smallChunkSeconds : largeChunkSeconds
    }
}
