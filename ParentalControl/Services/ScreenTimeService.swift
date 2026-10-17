import Combine
import Foundation
import FamilyControls
import ManagedSettings

enum RemovalProtectionError: Error {
    case busy
    case notApproved
    case parentRequired

    static func messageKey(for error: Error) -> String {
        if let error = error as? FamilyControlsError {
            switch error {
            case .invalidAccountType: return "protection.error.account"
            case .authorizationCanceled: return "protection.error.cancelled"
            case .networkError: return "protection.error.network"
            case .authorizationConflict: return "protection.error.conflict"
            default: break
            }
        }
        return "protection.error.generic"
    }
}

@MainActor
final class ScreenTimeService: ObservableObject {
    @Published var selection = FamilyActivitySelection()
    @Published var isAuthorized = false
    @Published var isMonitoringEnabled = false
    @Published private(set) var isAuthorizationRequestInProgress = false
    @Published private(set) var childAuthorizationConfirmed = false
    @Published private(set) var prefersChildAuthorization = false

    // .approved alone does not identify the authorization member. Only record
    // success after an explicit .child request, and invalidate on observed loss.
    var isRemovalProtectionEnabled: Bool { childAuthorizationConfirmed && isAuthorized }

    private let store = ManagedSettingsStore()
    private let appStore: AppGroupStore
    private let deviceActivityService: DeviceActivityService
    private var authorizationObservation: AnyCancellable?

    init(appStore: AppGroupStore) {
        self.appStore = appStore
        self.deviceActivityService = DeviceActivityService(appStore: appStore)
        prefersChildAuthorization = appStore.loadScreenTimeAuthorizationMember() == "child"
        childAuthorizationConfirmed = appStore.loadChildAuthorizationConfirmed()
        loadSelection()
        authorizationObservation = AuthorizationCenter.shared.$authorizationStatus
            .sink { [weak self] _ in
                // Published emits before the property is updated. Read on the
                // next main-actor turn, and also refresh explicitly on foreground.
                Task { @MainActor [weak self] in self?.refreshAuthorizationStatus() }
            }
    }

    func requestAuthorization() async {
        guard !isAuthorizationRequestInProgress else { return }
        refreshAuthorizationStatus()
        // Do not re-request .individual on an already-authorized device: that
        // can remove the anti-circumvention restrictions of child authorization.
        guard !isAuthorized else { return }
        isAuthorizationRequestInProgress = true
        defer { isAuthorizationRequestInProgress = false }
        do {
            let member: FamilyControlsMember = prefersChildAuthorization ? .child : .individual
            try await AuthorizationCenter.shared.requestAuthorization(for: member)
            refreshAuthorizationStatus()
            if isAuthorized, member == .child { recordChildAuthorization() }
        } catch {
            // A rejected upgrade/renewal must not overwrite still-valid access.
            refreshAuthorizationStatus()
        }
    }

    func refreshAuthorizationStatus() {
        isAuthorized = AuthorizationCenter.shared.authorizationStatus == .approved
        if !isAuthorized, childAuthorizationConfirmed {
            childAuthorizationConfirmed = false
            appStore.saveChildAuthorizationConfirmed(false)
        }
    }

    /// Called only through AppState's PIN/role guard. No revoke or fallback on error.
    func enableRemovalProtection() async throws {
        guard !isAuthorizationRequestInProgress else { throw RemovalProtectionError.busy }
        isAuthorizationRequestInProgress = true
        defer { isAuthorizationRequestInProgress = false }
        do {
            try await AuthorizationCenter.shared.requestAuthorization(for: .child)
            refreshAuthorizationStatus()
            guard isAuthorized else { throw RemovalProtectionError.notApproved }
            recordChildAuthorization()
        } catch {
            refreshAuthorizationStatus()
            throw error
        }
    }

    private func recordChildAuthorization() {
        prefersChildAuthorization = true
        appStore.saveScreenTimeAuthorizationMember("child")
        childAuthorizationConfirmed = true
        appStore.saveChildAuthorizationConfirmed(true)
    }

    /// Explicit destructive action, guarded by parent PIN + confirmation in the UI.
    /// This ends Screen Time authorization, not just the removal restriction.
    func revokeForRemoval() async throws {
        guard !isAuthorizationRequestInProgress else { throw RemovalProtectionError.busy }
        isAuthorizationRequestInProgress = true
        defer { isAuthorizationRequestInProgress = false }
        let result: Result<Void, Error> = await withCheckedContinuation { continuation in
            AuthorizationCenter.shared.revokeAuthorization { result in
                continuation.resume(returning: result)
            }
        }
        refreshAuthorizationStatus()
        try result.get()
        guard !isAuthorized else { throw RemovalProtectionError.notApproved }
        childAuthorizationConfirmed = false
        appStore.saveChildAuthorizationConfirmed(false)
        // Only this explicitly confirmed action permits subsequent basic setup.
        prefersChildAuthorization = false
        appStore.saveScreenTimeAuthorizationMember("individual")
        stopDeviceActivityMonitoring()
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

    func ensureDailyBudgetMonitoring() -> Bool {
        deviceActivityService.ensureDailyBudgetMonitoring()
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
