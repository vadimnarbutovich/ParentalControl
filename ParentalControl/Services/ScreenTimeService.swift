import Combine
import Foundation
import FamilyControls
import ManagedSettings

@MainActor
final class ScreenTimeService: ObservableObject {
    @Published var selection = FamilyActivitySelection()
    @Published var isAuthorized = false
    @Published var isMonitoringEnabled = false

    private let store = ManagedSettingsStore()
    private let appStore: AppGroupStore
    private let deviceActivityService: DeviceActivityService

    init(appStore: AppGroupStore) {
        self.appStore = appStore
        self.deviceActivityService = DeviceActivityService(appStore: appStore)
        loadSelection()
    }

    func requestAuthorization() async {
        do {
            try await AuthorizationCenter.shared.requestAuthorization(for: .individual)
            isAuthorized = AuthorizationCenter.shared.authorizationStatus == .approved
        } catch {
            isAuthorized = false
        }
    }

    func refreshAuthorizationStatus() {
        isAuthorized = AuthorizationCenter.shared.authorizationStatus == .approved
    }

    func applyShield() {
        let apps = selection.applicationTokens
        let categories = selection.categoryTokens
        let domains = selection.webDomainTokens

        store.shield.applications = apps.isEmpty ? nil : apps
        store.shield.applicationCategories = categories.isEmpty ? nil : .specific(categories)
        store.shield.webDomains = domains.isEmpty ? nil : domains
    }

    func clearShield() {
        store.clearAllSettings()
    }

    @discardableResult
    func startDeviceActivityMonitoring(availableSeconds: Int) -> Bool {
        let started = deviceActivityService.startMonitoringDailySchedule(
            selection: selection,
            availableSeconds: availableSeconds
        )
        isMonitoringEnabled = started
        return started
    }

    func stopDeviceActivityMonitoring() {
        deviceActivityService.stopMonitoring()
        isMonitoringEnabled = false
    }

    func saveSelection() {
        guard let data = try? JSONEncoder().encode(selection) else { return }
        appStore.saveFamilySelectionData(data)
    }

    func loadSelection() {
        guard let data = appStore.loadFamilySelectionData(),
              let decoded = try? JSONDecoder().decode(FamilyActivitySelection.self, from: data) else {
            return
        }
        selection = decoded
    }
}
