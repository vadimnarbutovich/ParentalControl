import Foundation

protocol KeyValueStore {
    func data(forKey defaultName: String) -> Data?
    func set(_ value: Any?, forKey defaultName: String)
    func integer(forKey defaultName: String) -> Int
    func string(forKey defaultName: String) -> String?
}

extension UserDefaults: KeyValueStore {}

enum StorageKey {
    static let balance = "parentalcontrol.balance"
    static let settings = "parentalcontrol.settings"
    static let ledger = "parentalcontrol.ledger"
    static let lastProcessedSteps = "parentalcontrol.lastProcessedSteps"
    static let lastProcessedStepsDayStart = "parentalcontrol.lastProcessedStepsDayStart"
    static let lastBalanceResetDayStart = "parentalcontrol.lastBalanceResetDayStart"
    static let exerciseTotals = "parentalcontrol.exerciseTotals"
    static let familySelection = "parentalcontrol.familySelection"
    static let deviceActivityThresholdSeconds = "parentalcontrol.deviceActivityThresholdSeconds"
    static let didRequestInitialPermissions = "parentalcontrol.didRequestInitialPermissions"
    static let hasCompletedOnboarding = "parentalcontrol.hasCompletedOnboarding"
    static let isDeviceActivityMonitoringPaused = "parentalcontrol.isDeviceActivityMonitoringPaused"
    static let deviceActivityLastHeartbeatTimestamp = "parentalcontrol.deviceActivityLastHeartbeatTimestamp"
    static let deviceActivityLastHeartbeatEvent = "parentalcontrol.deviceActivityLastHeartbeatEvent"
    static let deviceActivityHeartbeatCount = "parentalcontrol.deviceActivityHeartbeatCount"
    static let deviceActivityMirrorEarnedSeconds = "parentalcontrol.deviceActivityMirrorEarnedSeconds"
    static let deviceActivityMirrorSpentSeconds = "parentalcontrol.deviceActivityMirrorSpentSeconds"
    static let deviceActivityWarningCount = "parentalcontrol.deviceActivityWarningCount"
    static let deviceActivityThresholdCount = "parentalcontrol.deviceActivityThresholdCount"
    static let deviceActivityLastTrigger = "parentalcontrol.deviceActivityLastTrigger"
    static let deviceActivityLastThresholdValue = "parentalcontrol.deviceActivityLastThresholdValue"
    static let deviceActivityLastSpentDelta = "parentalcontrol.deviceActivityLastSpentDelta"
    static let deviceActivityLastAvailableBefore = "parentalcontrol.deviceActivityLastAvailableBefore"
    static let deviceActivityLastAvailableAfter = "parentalcontrol.deviceActivityLastAvailableAfter"
    static let deviceActivityMonitoringRestartCount = "parentalcontrol.deviceActivityMonitoringRestartCount"
    static let deviceActivityLastStartMonitoringTimestamp = "parentalcontrol.deviceActivityLastStartMonitoringTimestamp"
    static let deviceActivityLastConsumptionTimestamp = "parentalcontrol.deviceActivityLastConsumptionTimestamp"
    static let mainAppIsActive = "parentalcontrol.mainAppIsActive"
    static let mainAppStateTimestamp = "parentalcontrol.mainAppStateTimestamp"
    static let midnightResetDisabled = "parentalcontrol.midnightResetDisabled"
    static let spentBaselineDayStart = "parentalcontrol.spentBaselineDayStart"
    static let spentBaselineTotalSpentSeconds = "parentalcontrol.spentBaselineTotalSpentSeconds"
    static let focusSessionSnapshot = "parentalcontrol.focusSessionSnapshot"
    static let deviceRole = "parentalcontrol.deviceRole"
    static let pairingState = "parentalcontrol.pairingState"
    static let deviceInstallID = "parentalcontrol.deviceInstallID"
    static let deviceSecret = "parentalcontrol.deviceSecret"
    static let apnsToken = "parentalcontrol.apnsToken"
    static let lastHandledRemoteCommandID = "parentalcontrol.lastHandledRemoteCommandID"
}

/// Сохраняется в App Group, чтобы пережить kill приложения и совпадать с Live Activity по `endsAt`.
struct FocusSessionSnapshot: Codable, Equatable {
    let startedAt: Date
    let endsAt: Date
    let plannedSeconds: Int
}

struct DeviceActivityDebugSnapshot: Equatable {
    let heartbeatCount: Int
    let lastEvent: String?
    let lastHeartbeatAt: Date?
    let warningCount: Int
    let thresholdCount: Int
    let lastTrigger: String?
    let thresholdSeconds: Int
    let lastSpentDelta: Int
    let lastAvailableBefore: Int
    let lastAvailableAfter: Int
    let restartCount: Int
    let lastStartMonitoringAt: Date?
    let lastConsumptionAt: Date?
    let mirrorEarnedSeconds: Int
    let mirrorSpentSeconds: Int
}

final class AppGroupStore {
    private let store: KeyValueStore
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()
    private let appGroupId: String

    init(appGroupId: String = "group.mycompny.parentalcontrol") {
        self.appGroupId = appGroupId
        if let shared = UserDefaults(suiteName: appGroupId) {
            store = shared
        } else {
            store = UserDefaults.standard
        }
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }

    func loadBalance() -> MinuteBalance {
        if let defaults = UserDefaults(suiteName: appGroupId) {
            defaults.synchronize()
            let earned = defaults.integer(forKey: StorageKey.deviceActivityMirrorEarnedSeconds)
            let spent = defaults.integer(forKey: StorageKey.deviceActivityMirrorSpentSeconds)
            if earned > 0 || spent > 0 {
                return MinuteBalance(totalEarnedSeconds: max(0, earned), totalSpentSeconds: max(0, spent))
            }
            if let data = defaults.data(forKey: StorageKey.balance),
               let decoded = try? decoder.decode(MinuteBalance.self, from: data) {
                return decoded
            }
        }
        return load(MinuteBalance.self, key: StorageKey.balance) ?? .empty
    }

    func saveBalance(_ balance: MinuteBalance) {
        if let defaults = UserDefaults(suiteName: appGroupId) {
            if let data = try? encoder.encode(balance) {
                defaults.set(data, forKey: StorageKey.balance)
            }
            defaults.set(balance.totalEarnedSeconds, forKey: StorageKey.deviceActivityMirrorEarnedSeconds)
            defaults.set(balance.totalSpentSeconds, forKey: StorageKey.deviceActivityMirrorSpentSeconds)
            defaults.synchronize()
            return
        }
        save(balance, key: StorageKey.balance)
    }

    func loadSettings() -> ConversionSettings {
        load(ConversionSettings.self, key: StorageKey.settings) ?? .default
    }

    func saveSettings(_ settings: ConversionSettings) {
        save(settings, key: StorageKey.settings)
    }

    func loadLedger() -> [ActivityLedgerEntry] {
        load([ActivityLedgerEntry].self, key: StorageKey.ledger) ?? []
    }

    func saveLedger(_ ledger: [ActivityLedgerEntry]) {
        save(ledger, key: StorageKey.ledger)
    }

    func loadLastProcessedSteps() -> Int {
        store.integer(forKey: StorageKey.lastProcessedSteps)
    }

    func saveLastProcessedSteps(_ steps: Int) {
        store.set(steps, forKey: StorageKey.lastProcessedSteps)
    }

    func loadLastProcessedStepsDayStart() -> Date? {
        let timestamp = store.integer(forKey: StorageKey.lastProcessedStepsDayStart)
        guard timestamp > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(timestamp))
    }

    func saveLastProcessedStepsDayStart(_ date: Date) {
        store.set(Int(date.timeIntervalSince1970), forKey: StorageKey.lastProcessedStepsDayStart)
    }

    func loadLastBalanceResetDayStart() -> Date? {
        let timestamp = store.integer(forKey: StorageKey.lastBalanceResetDayStart)
        guard timestamp > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(timestamp))
    }

    func saveLastBalanceResetDayStart(_ date: Date) {
        store.set(Int(date.timeIntervalSince1970), forKey: StorageKey.lastBalanceResetDayStart)
    }

    func loadExerciseTotals() -> [String: Int] {
        load([String: Int].self, key: StorageKey.exerciseTotals) ?? [:]
    }

    func saveExerciseTotals(_ totals: [String: Int]) {
        save(totals, key: StorageKey.exerciseTotals)
    }

    func loadFamilySelectionData() -> Data? {
        store.data(forKey: StorageKey.familySelection)
    }

    func saveFamilySelectionData(_ data: Data?) {
        store.set(data, forKey: StorageKey.familySelection)
    }

    func saveDeviceActivityThresholdSeconds(_ seconds: Int) {
        store.set(max(0, seconds), forKey: StorageKey.deviceActivityThresholdSeconds)
    }

    func markDeviceActivityMonitoringStarted(thresholdSeconds: Int) {
        if let defaults = UserDefaults(suiteName: appGroupId) {
            defaults.set(Int(Date().timeIntervalSince1970), forKey: StorageKey.deviceActivityLastStartMonitoringTimestamp)
            defaults.set(max(0, thresholdSeconds), forKey: StorageKey.deviceActivityLastThresholdValue)
            let currentRestartCount = defaults.integer(forKey: StorageKey.deviceActivityMonitoringRestartCount)
            defaults.set(currentRestartCount + 1, forKey: StorageKey.deviceActivityMonitoringRestartCount)
            defaults.synchronize()
            return
        }
        store.set(Int(Date().timeIntervalSince1970), forKey: StorageKey.deviceActivityLastStartMonitoringTimestamp)
        store.set(max(0, thresholdSeconds), forKey: StorageKey.deviceActivityLastThresholdValue)
        let currentRestartCount = store.integer(forKey: StorageKey.deviceActivityMonitoringRestartCount)
        store.set(currentRestartCount + 1, forKey: StorageKey.deviceActivityMonitoringRestartCount)
    }

    func loadDeviceActivityThresholdSeconds() -> Int {
        store.integer(forKey: StorageKey.deviceActivityThresholdSeconds)
    }

    func saveDidRequestInitialPermissions(_ value: Bool) {
        store.set(value ? 1 : 0, forKey: StorageKey.didRequestInitialPermissions)
    }

    func loadDidRequestInitialPermissions() -> Bool {
        store.integer(forKey: StorageKey.didRequestInitialPermissions) == 1
    }

    func saveHasCompletedOnboarding(_ value: Bool) {
        store.set(value ? 1 : 0, forKey: StorageKey.hasCompletedOnboarding)
    }

    func loadHasCompletedOnboarding() -> Bool {
        store.integer(forKey: StorageKey.hasCompletedOnboarding) == 1
    }

    func saveMainAppIsActive(_ value: Bool) {
        if let defaults = UserDefaults(suiteName: appGroupId) {
            defaults.set(value ? 1 : 0, forKey: StorageKey.mainAppIsActive)
            defaults.set(Int(Date().timeIntervalSince1970), forKey: StorageKey.mainAppStateTimestamp)
            defaults.synchronize()
            return
        }
        store.set(value ? 1 : 0, forKey: StorageKey.mainAppIsActive)
        store.set(Int(Date().timeIntervalSince1970), forKey: StorageKey.mainAppStateTimestamp)
    }

    func loadMainAppIsActive() -> Bool {
        if let defaults = UserDefaults(suiteName: appGroupId) {
            defaults.synchronize()
            return defaults.integer(forKey: StorageKey.mainAppIsActive) == 1
        }
        return store.integer(forKey: StorageKey.mainAppIsActive) == 1
    }

    func loadMainAppStateTimestamp() -> Int {
        if let defaults = UserDefaults(suiteName: appGroupId) {
            defaults.synchronize()
            return defaults.integer(forKey: StorageKey.mainAppStateTimestamp)
        }
        return store.integer(forKey: StorageKey.mainAppStateTimestamp)
    }

    func saveDeviceActivityMonitoringPaused(_ value: Bool) {
        store.set(value ? 1 : 0, forKey: StorageKey.isDeviceActivityMonitoringPaused)
    }

    func loadDeviceActivityMonitoringPaused() -> Bool {
        store.integer(forKey: StorageKey.isDeviceActivityMonitoringPaused) == 1
    }

    func saveMidnightResetEnabled(_ value: Bool) {
        // Persist as "disabled" flag so missing key means default enabled.
        store.set(value ? 0 : 1, forKey: StorageKey.midnightResetDisabled)
    }

    func loadMidnightResetEnabled() -> Bool {
        store.integer(forKey: StorageKey.midnightResetDisabled) == 0
    }

    func loadSpentBaselineDayStart() -> Date? {
        let timestamp = store.integer(forKey: StorageKey.spentBaselineDayStart)
        guard timestamp > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(timestamp))
    }

    func loadSpentBaselineTotalSpentSeconds() -> Int {
        max(0, store.integer(forKey: StorageKey.spentBaselineTotalSpentSeconds))
    }

    func saveSpentBaseline(totalSpentSeconds: Int, dayStart: Date) {
        store.set(Int(dayStart.timeIntervalSince1970), forKey: StorageKey.spentBaselineDayStart)
        store.set(max(0, totalSpentSeconds), forKey: StorageKey.spentBaselineTotalSpentSeconds)
    }

    func loadFocusSessionSnapshot() -> FocusSessionSnapshot? {
        if let defaults = UserDefaults(suiteName: appGroupId) {
            defaults.synchronize()
        }
        return load(FocusSessionSnapshot.self, key: StorageKey.focusSessionSnapshot)
    }

    func saveFocusSessionSnapshot(_ snapshot: FocusSessionSnapshot) {
        save(snapshot, key: StorageKey.focusSessionSnapshot)
        if let defaults = UserDefaults(suiteName: appGroupId) {
            defaults.synchronize()
        }
    }

    func clearFocusSessionSnapshot() {
        store.set(nil, forKey: StorageKey.focusSessionSnapshot)
        if let defaults = UserDefaults(suiteName: appGroupId) {
            defaults.synchronize()
        }
    }

    func loadDeviceRole() -> DeviceRole? {
        guard let raw = store.string(forKey: StorageKey.deviceRole) else { return nil }
        return DeviceRole(rawValue: raw)
    }

    func saveDeviceRole(_ role: DeviceRole) {
        store.set(role.rawValue, forKey: StorageKey.deviceRole)
    }

    func loadPairingState() -> DevicePairingState? {
        load(DevicePairingState.self, key: StorageKey.pairingState)
    }

    func savePairingState(_ state: DevicePairingState?) {
        guard let state else {
            store.set(nil, forKey: StorageKey.pairingState)
            return
        }
        save(state, key: StorageKey.pairingState)
    }

    func loadDeviceInstallID() -> String? {
        store.string(forKey: StorageKey.deviceInstallID)
    }

    func saveDeviceInstallID(_ value: String) {
        store.set(value, forKey: StorageKey.deviceInstallID)
    }

    func loadDeviceSecret() -> String? {
        store.string(forKey: StorageKey.deviceSecret)
    }

    func saveDeviceSecret(_ value: String?) {
        store.set(value, forKey: StorageKey.deviceSecret)
    }

    func loadAPNSToken() -> String? {
        store.string(forKey: StorageKey.apnsToken)
    }

    func saveAPNSToken(_ value: String?) {
        store.set(value, forKey: StorageKey.apnsToken)
    }

    func loadLastHandledRemoteCommandID() -> String? {
        store.string(forKey: StorageKey.lastHandledRemoteCommandID)
    }

    func saveLastHandledRemoteCommandID(_ value: String?) {
        store.set(value, forKey: StorageKey.lastHandledRemoteCommandID)
    }

    func loadDeviceActivityDebugSnapshot() -> DeviceActivityDebugSnapshot {
        if let defaults = UserDefaults(suiteName: appGroupId) {
            defaults.synchronize()
            let count = defaults.integer(forKey: StorageKey.deviceActivityHeartbeatCount)
            let event = defaults.string(forKey: StorageKey.deviceActivityLastHeartbeatEvent)
            let timestamp = defaults.integer(forKey: StorageKey.deviceActivityLastHeartbeatTimestamp)
            let date = timestamp > 0 ? Date(timeIntervalSince1970: TimeInterval(timestamp)) : nil
            let warningCount = defaults.integer(forKey: StorageKey.deviceActivityWarningCount)
            let thresholdCount = defaults.integer(forKey: StorageKey.deviceActivityThresholdCount)
            let lastTrigger = defaults.string(forKey: StorageKey.deviceActivityLastTrigger)
            let thresholdSeconds = defaults.integer(forKey: StorageKey.deviceActivityLastThresholdValue)
            let lastSpentDelta = defaults.integer(forKey: StorageKey.deviceActivityLastSpentDelta)
            let lastAvailableBefore = defaults.integer(forKey: StorageKey.deviceActivityLastAvailableBefore)
            let lastAvailableAfter = defaults.integer(forKey: StorageKey.deviceActivityLastAvailableAfter)
            let restartCount = defaults.integer(forKey: StorageKey.deviceActivityMonitoringRestartCount)
            let startTimestamp = defaults.integer(forKey: StorageKey.deviceActivityLastStartMonitoringTimestamp)
            let startDate = startTimestamp > 0 ? Date(timeIntervalSince1970: TimeInterval(startTimestamp)) : nil
            let consumeTimestamp = defaults.integer(forKey: StorageKey.deviceActivityLastConsumptionTimestamp)
            let consumeDate = consumeTimestamp > 0 ? Date(timeIntervalSince1970: TimeInterval(consumeTimestamp)) : nil
            let mirrorEarnedSeconds = defaults.integer(forKey: StorageKey.deviceActivityMirrorEarnedSeconds)
            let mirrorSpentSeconds = defaults.integer(forKey: StorageKey.deviceActivityMirrorSpentSeconds)
            return DeviceActivityDebugSnapshot(
                heartbeatCount: count,
                lastEvent: event,
                lastHeartbeatAt: date,
                warningCount: warningCount,
                thresholdCount: thresholdCount,
                lastTrigger: lastTrigger,
                thresholdSeconds: thresholdSeconds,
                lastSpentDelta: lastSpentDelta,
                lastAvailableBefore: lastAvailableBefore,
                lastAvailableAfter: lastAvailableAfter,
                restartCount: restartCount,
                lastStartMonitoringAt: startDate,
                lastConsumptionAt: consumeDate,
                mirrorEarnedSeconds: mirrorEarnedSeconds,
                mirrorSpentSeconds: mirrorSpentSeconds
            )
        }

        let count = store.integer(forKey: StorageKey.deviceActivityHeartbeatCount)
        let event = store.string(forKey: StorageKey.deviceActivityLastHeartbeatEvent)
        let timestamp = store.integer(forKey: StorageKey.deviceActivityLastHeartbeatTimestamp)
        let date = timestamp > 0 ? Date(timeIntervalSince1970: TimeInterval(timestamp)) : nil
        let warningCount = store.integer(forKey: StorageKey.deviceActivityWarningCount)
        let thresholdCount = store.integer(forKey: StorageKey.deviceActivityThresholdCount)
        let lastTrigger = store.string(forKey: StorageKey.deviceActivityLastTrigger)
        let thresholdSeconds = store.integer(forKey: StorageKey.deviceActivityLastThresholdValue)
        let lastSpentDelta = store.integer(forKey: StorageKey.deviceActivityLastSpentDelta)
        let lastAvailableBefore = store.integer(forKey: StorageKey.deviceActivityLastAvailableBefore)
        let lastAvailableAfter = store.integer(forKey: StorageKey.deviceActivityLastAvailableAfter)
        let restartCount = store.integer(forKey: StorageKey.deviceActivityMonitoringRestartCount)
        let startTimestamp = store.integer(forKey: StorageKey.deviceActivityLastStartMonitoringTimestamp)
        let startDate = startTimestamp > 0 ? Date(timeIntervalSince1970: TimeInterval(startTimestamp)) : nil
        let consumeTimestamp = store.integer(forKey: StorageKey.deviceActivityLastConsumptionTimestamp)
        let consumeDate = consumeTimestamp > 0 ? Date(timeIntervalSince1970: TimeInterval(consumeTimestamp)) : nil
        let mirrorEarnedSeconds = store.integer(forKey: StorageKey.deviceActivityMirrorEarnedSeconds)
        let mirrorSpentSeconds = store.integer(forKey: StorageKey.deviceActivityMirrorSpentSeconds)
        return DeviceActivityDebugSnapshot(
            heartbeatCount: count,
            lastEvent: event,
            lastHeartbeatAt: date,
            warningCount: warningCount,
            thresholdCount: thresholdCount,
            lastTrigger: lastTrigger,
            thresholdSeconds: thresholdSeconds,
            lastSpentDelta: lastSpentDelta,
            lastAvailableBefore: lastAvailableBefore,
            lastAvailableAfter: lastAvailableAfter,
            restartCount: restartCount,
            lastStartMonitoringAt: startDate,
            lastConsumptionAt: consumeDate,
            mirrorEarnedSeconds: mirrorEarnedSeconds,
            mirrorSpentSeconds: mirrorSpentSeconds
        )
    }

    private func load<T: Decodable>(_ type: T.Type, key: String) -> T? {
        guard let data = store.data(forKey: key) else { return nil }
        return try? decoder.decode(type, from: data)
    }

    private func save<T: Encodable>(_ value: T, key: String) {
        guard let data = try? encoder.encode(value) else { return }
        store.set(data, forKey: key)
    }
}
