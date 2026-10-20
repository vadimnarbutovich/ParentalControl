import Combine
import Foundation
import FamilyControls
import ManagedSettings
import DeviceActivity
import UIKit

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

    private let appStore: AppGroupStore
    private var authorizationObservation: AnyCancellable?
    private var enforcementTask: Task<ScreenTimeEnforcer.Receipt?, Never>?
    private var enforcementGeneration = UUID()
    private var enforcementRequested = false
    private(set) var lastEnforcementReceipt: ScreenTimeEnforcer.Receipt?

    init(appStore: AppGroupStore) {
        self.appStore = appStore
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
        requestEnforcement()
    }

    func clearShield() {
        requestEnforcement()
    }

    func stopDeviceActivityMonitoring() {
        // Persist invalidation, not a stop command that could arrive after a newer start.
        RemoteControlGate.defaults?.set(UUID().uuidString, forKey: ScreenTimeEnforcer.restartKey)
        requestEnforcement()
    }

    func refreshMonitoringStatus() {
        requestEnforcement()
    }

    func ensureDailyBudgetMonitoring() {
        requestEnforcement()
    }

    /// Coalesce simultaneous UI/poll/push requests. The worker reads shared state
    /// after the data transaction finishes, rather than capturing host memory.
    func requestEnforcement() {
        guard appStore.loadDeviceRole() == .child else { return }
        enforcementRequested = true
        guard enforcementTask == nil else { return }
        let generation = UUID()
        enforcementGeneration = generation
        enforcementTask = Task { @MainActor [weak self] in
            guard let self else { return nil }
            let context = ControlSystemWorker.Context()
            let background = ControlBackgroundExecution(context: context)
            defer {
                background.end()
                if self.enforcementGeneration == generation { self.enforcementTask = nil }
            }
            guard background.canRun else { return nil }
            for _ in 0..<3 {
                self.enforcementRequested = false
                do {
                    let receipt = try await ScreenTimeEnforcer.apply(context: context)
                    if !receipt.isCurrent() { continue }
                    self.lastEnforcementReceipt = receipt
                    self.isMonitoringEnabled = receipt.monitoring
                    return receipt
                } catch {
                    self.lastEnforcementReceipt = nil
                    guard self.enforcementRequested, (try? context.check()) != nil else { return nil }
                }
            }
            return nil // Existing poll/push retries persisted state; no optimistic ACK.
        }
    }

    func enforceAndConfirm() async -> ScreenTimeEnforcer.Receipt? {
        requestEnforcement()
        guard let task = enforcementTask else { return nil }
        let receipt = await task.value
        guard !Task.isCancelled, let receipt, receipt.isCurrent() else { return nil }
        return receipt
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
