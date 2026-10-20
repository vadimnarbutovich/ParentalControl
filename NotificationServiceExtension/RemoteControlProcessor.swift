import Foundation
import FamilyControls
import ManagedSettings
import DeviceActivity
import OSLog

/// Pilot: only manual block/unblock and the revisioned daily-budget wake signal.
/// Never trusts the action/seconds in the push; reads the authenticated child snapshot.
@MainActor
final class RemoteControlProcessor {
    private let logger = Logger(subsystem: "mycompny.ParentalControl", category: "NotificationControl")
    private let defaults: UserDefaults
    private let family: UUID
    private let pairingData: Data
    private let installID: String
    private let secret: String
    private let session: URLSession
    private let lifetime: NotificationDeliveryLifetime
    private let usage = DeviceActivityName("parentalcontrol.activity")
    private let store = ManagedSettingsStore()
    private var diagnosticCommandID: UUID?
    private var diagnosticCommandType: String?
    private var diagnosticAuthorizationStatus: Int?

    private struct Pairing: Decodable {
        let familyID: UUID
        let parentDeviceID: UUID?
        let childDeviceID: UUID?
    }
    private struct Snapshot: Codable {
        let startedAt: Date
        var plannedSeconds = 0
        var endsAt: Date?
    }
    enum Failure: Error {
        case unavailable, stale, monitoring, http(Int)
        case policy(NotificationControlSnapshot.Rejection)
        case budgetDisabled, budgetUninitialized, selectionMissing, selectionEmpty, monitoringPaused
        case authorizationNotApproved(Int)
        case monitoringAccessRejected
        case monitoringAccessFailed(Int)
        var diagnostic: String {
            switch self {
            case .unavailable: "busy_or_unavailable"
            case .stale: "context_changed"
            case .monitoring: "monitoring_failed"
            case .http(let status): "http_\(status)"
            case .policy(let reason): reason.rawValue
            case .budgetDisabled: "budget_disabled"
            case .budgetUninitialized: "budget_uninitialized"
            case .selectionMissing: "selection_missing"
            case .selectionEmpty: "selection_empty"
            case .monitoringPaused: "monitoring_paused"
            case .authorizationNotApproved(let status): "screen_time_authorization_\(status)"
            case .monitoringAccessRejected: "system_monitoring_unauthorized"
            case .monitoringAccessFailed(let code): "system_monitoring_failed_\(code)"
            }
        }
    }

    init?(lifetime: NotificationDeliveryLifetime) {
        guard let d = RemoteControlGate.defaults,
              d.string(forKey: "parentalcontrol.deviceRole") == "child",
              let data = d.data(forKey: "parentalcontrol.pairingState"),
              let pair = try? JSONDecoder().decode(Pairing.self, from: data),
              pair.parentDeviceID != nil, pair.childDeviceID != nil,
              let install = d.string(forKey: "parentalcontrol.deviceInstallID"),
              let secret = d.string(forKey: "parentalcontrol.deviceSecret"), !secret.isEmpty else { return nil }
        defaults = d; pairingData = data; family = pair.familyID
        installID = install; self.secret = secret
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.timeoutIntervalForRequest = 4
        config.timeoutIntervalForResource = 5
        config.waitsForConnectivity = false
        session = URLSession(configuration: config)
        self.lifetime = lifetime
        lifetime.onCancel { [session] in session.invalidateAndCancel() }
    }

    /// One bounded, non-sensitive record, readable without collecting a system archive.
    /// Never persist credentials, app tokens, task content, or response bodies.
    func recordDiagnostic(_ stage: String, error: Error? = nil) {
        guard !lifetime.isFinished else { return }
        var value: [String: Any] = ["stage": stage, "timestamp": Date().timeIntervalSince1970]
        if let diagnosticCommandID { value["commandID"] = diagnosticCommandID.uuidString }
        if let diagnosticCommandType { value["commandType"] = diagnosticCommandType }
        if let diagnosticAuthorizationStatus { value["authorizationStatus"] = diagnosticAuthorizationStatus }
        if let error {
            value["reason"] = (error as? Failure)?.diagnostic ??
                (error is DecodingError ? "decoding_failed" : "operation_error")
            value["errorCode"] = (error as NSError).code
        }
        defaults.set(value, forKey: "parentalcontrol.notificationControlDiagnostic")
        defaults.synchronize()
        logger.notice("Control stage=\(stage, privacy: .public) reason=\(value["reason"] as? String ?? "none", privacy: .public)")
    }

    func process(id: UUID, type: String) async throws {
        guard ["start_focus", "end_focus", "tasks_updated"].contains(type) else { return }
        diagnosticCommandID = id
        diagnosticCommandType = type
        recordDiagnostic("received")
        try checkContext()
        logger.info("Control received id=\(id.uuidString, privacy: .public) type=\(type, privacy: .public)")
        let poll = try JSONDecoder().decode(NotificationControlSnapshot.self, from: await call("child_poll", ["includeParentSettings": false]))
        recordDiagnostic("snapshot_decoded")
        try checkContext()
        guard poll.contains(id: id, type: type) else {
            recordDiagnostic("no_longer_pending")
            logger.info("Control skipped: no longer pending")
            return
        }
        let active = poll.desired.shouldFocusActive
        let budget: DailyBudgetState
        // Never hold a process lock over network I/O or await. Recheck revisions
        // after obtaining it: a foreground poll may have applied newer state.
        do {
            guard let lease = RemoteControlGate.Lease() else { throw Failure.unavailable }
            defer { withExtendedLifetime(lease) {} }
            try checkContext()
            // Timed sessions and legacy allowance commands remain in the host.
            let minimumRevision = defaults.integer(forKey: RemoteControlGate.revisionKey(family))
            if let rejection = poll.rejection(family: family, minimumFocusRevision: minimumRevision) {
                throw Failure.policy(rejection)
            }
            guard let policy = poll.budget?.policy else { throw Failure.policy(.missingBudgetPolicy) }
            guard DailyBudgetStore.shared.isEnabled else { throw Failure.budgetDisabled }
            let authorization = AuthorizationCenter.shared.authorizationStatus
            diagnosticAuthorizationStatus = authorization.rawValue
            // NSE can report notDetermined while the containing app is authorized.
            // This is not approval: the actual monitoring API must still accept
            // the operation below. Never prompt or use cached consent in NSE.
            guard authorization != .denied else { throw Failure.authorizationNotApproved(authorization.rawValue) }
            guard let selectionData = defaults.data(forKey: "parentalcontrol.familySelection") else { throw Failure.selectionMissing }
            let selection = try JSONDecoder().decode(FamilyActivitySelection.self, from: selectionData)
            guard !selection.applicationTokens.isEmpty || !selection.categoryTokens.isEmpty ||
                    !selection.webDomainTokens.isEmpty else { throw Failure.selectionEmpty }
            recordDiagnostic("preflight_passed")
            let previous = try DailyBudgetStore.shared.current()
            // Initialization/migration is owned by the host; NSE only updates an existing budget.
            guard previous != nil else { throw Failure.budgetUninitialized }
            // Validate system access BEFORE changing the budget, shared focus revision,
            // or shield. Use the real midnight budget monitor, not a dummy activity.
            // Even an existing activity must be registered again: merely finding its
            // name is not evidence that authorization is still valid.
            try verifyMonitoringAccess()
            try checkContext()
            budget = try DailyBudgetStore.shared.apply(policy, legacyUsedToday: 0)
            if active {
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                let saved = defaults.data(forKey: RemoteControlGate.snapshotKey)
                    .flatMap { try? decoder.decode(Snapshot.self, from: $0) }
                // Preserve duplicate indefinite sessions, but replace an older timed one.
                if saved == nil || saved?.endsAt != nil {
                    defaults.set(try encoder.encode(Snapshot(startedAt: Date())), forKey: RemoteControlGate.snapshotKey)
                }
            } else {
                defaults.removeObject(forKey: RemoteControlGate.snapshotKey)
            }
            defaults.set(poll.desired.revision, forKey: RemoteControlGate.revisionKey(family))
            defaults.synchronize()
            // Named schedule stores are intentionally untouched. Unblocking manually
            // must never bypass bedtime or unlock an exhausted allowance.
            try enforce(selection, budget: budget, active: active,
                        restart: previous?.budgetSeconds != budget.budgetSeconds || previous?.day != budget.day)
        }
        try checkContext()
        recordDiagnostic("locally_applied")
        logger.info("Control locally applied revision=\(poll.desired.revision)")

        // Report usage separately: this endpoint is revision/usage guarded and
        // cannot accidentally overwrite focus state with an old budget snapshot.
        let stateData = try JSONEncoder().encode(try DailyBudgetStore.shared.current() ?? budget)
        let stateJSON = try JSONSerialization.jsonObject(with: stateData)
        _ = try await call("report_child_usage", ["budgetState": stateJSON,
                                                 "budgetTimezone": TimeZone.current.identifier, "budgetHistory": []])
        try checkContext()
        _ = try await call("update_child_runtime", ["isFocusActive": active,
                                                   "focusRevision": poll.desired.revision])
        try checkContext()
        if type == "tasks_updated" {
            // This wake signal also carries real task-list updates; don't falsely ACK
            // them after applying only the budget.
            let response = try JSONSerialization.jsonObject(with: await call("list_child_tasks", [:])) as? [String: Any]
            guard let tasks = response?["tasks"] as? [[String: Any]] else { throw Failure.unavailable }
            let cached = try tasks.map { task -> [String: Any] in
                guard let id = task["id"] as? String, UUID(uuidString: id) != nil,
                      let title = task["title"] as? String, let status = task["status"] as? String,
                      let reward = task["rewardSeconds"] as? Int,
                      let created = task["createdAtISO"] as? String,
                      let updated = task["updatedAtISO"] as? String else { throw Failure.unavailable }
                var value: [String: Any] = ["id": id, "title": title, "details": task["details"] as? String ?? "",
                    "rewardSeconds": reward, "status": status,
                    "createdAt": try normalizedDate(created), "updatedAt": try normalizedDate(updated)]
                if let date = task["submittedAtISO"] as? String { value["submittedAt"] = try normalizedDate(date) }
                if let date = task["approvedAtISO"] as? String { value["approvedAt"] = try normalizedDate(date) }
                return value
            }
            try checkContext()
            defaults.set(try JSONSerialization.data(withJSONObject: cached), forKey: "parentalcontrol.childTasks")
            defaults.synchronize()
        }
        let matches = type == "tasks_updated" || active == (type == "start_focus")
        _ = try await call("ack_command", ["commandID": id.uuidString,
            "status": matches ? "applied" : "failed",
            "errorMessage": matches ? NSNull() : "superseded_by_newer_command"])
        recordDiagnostic("acknowledged")
        logger.info("Control acknowledged id=\(id.uuidString, privacy: .public)")
    }

    private func normalizedDate(_ value: String) throws -> String {
        let plain = ISO8601DateFormatter()
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = fractional.date(from: value) ?? plain.date(from: value) else { throw Failure.unavailable }
        return plain.string(from: date)
    }

    private func checkContext() throws {
        try lifetime.checkCancellation()
        try Task.checkCancellation()
        defaults.synchronize()
        guard defaults.string(forKey: "parentalcontrol.deviceRole") == "child",
              defaults.data(forKey: "parentalcontrol.pairingState") == pairingData,
              defaults.string(forKey: "parentalcontrol.deviceSecret") == secret,
              defaults.data(forKey: RemoteControlGate.pendingKey(family)) == nil else { throw Failure.stale }
    }

    private var dailySchedule: DeviceActivitySchedule {
        DeviceActivitySchedule(intervalStart: DateComponents(hour: 0, minute: 0),
            intervalEnd: DateComponents(hour: 23, minute: 59, second: 59), repeats: true)
    }

    private func verifyMonitoringAccess() throws {
        recordDiagnostic("system_monitoring_check")
        do {
            try DeviceActivityCenter().startMonitoring(
                DeviceActivityName("parentalcontrol.dailyBudget"), during: dailySchedule)
        } catch DeviceActivityCenter.MonitoringError.unauthorized {
            throw Failure.monitoringAccessRejected
        } catch {
            throw Failure.monitoringAccessFailed((error as NSError).code)
        }
        try checkContext()
        recordDiagnostic("system_monitoring_ready")
    }

    private func enforce(_ selection: FamilyActivitySelection, budget: DailyBudgetState, active: Bool, restart: Bool) throws {
        try checkContext()
        let center = DeviceActivityCenter()
        if active || budget.availableSeconds <= 0 {
            try shield(selection)
            try checkContext()
            center.stopMonitoring([usage])
            try checkContext()
            return
        }
        // Don't override an explicit local monitoring pause in the pilot.
        guard !defaults.bool(forKey: "parentalcontrol.isDeviceActivityMonitoringPaused") else { throw Failure.monitoringPaused }
        do {
            // The daily monitor was already validated by verifyMonitoringAccess().
            let needsRestart = restart || budget.monitorEvent == nil || !center.activities.contains(usage)
            try checkContext()
            if needsRestart {
                let threshold = min(budget.availableSeconds, budget.availableSeconds < 60 ? 10 : 30)
                let event = try DailyBudgetStore.shared.arm(threshold: threshold)
                center.stopMonitoring([usage])
                try checkContext()
                try center.startMonitoring(usage, during: dailySchedule, events: [
                    DeviceActivityEvent.Name(event): DeviceActivityEvent(applications: selection.applicationTokens,
                        categories: selection.categoryTokens, webDomains: selection.webDomainTokens,
                        threshold: DateComponents(second: threshold), includesPastActivity: false)
                ])
                try checkContext()
            }
            // The API returning does not prove on-device shielding; TestFlight QA is required.
            store.clearAllSettings()
        } catch {
            // Expiry/cancellation/context change must not start another system operation.
            try checkContext()
            try shield(selection)
            logger.error("Control monitoring failed code=\((error as NSError).code)")
            throw Failure.monitoring
        }
    }

    private func shield(_ selection: FamilyActivitySelection) throws {
        try checkContext()
        store.shield.applications = selection.applicationTokens.isEmpty ? nil : selection.applicationTokens
        try checkContext()
        store.shield.applicationCategories = selection.categoryTokens.isEmpty ? nil : .specific(selection.categoryTokens)
        try checkContext()
        store.shield.webDomains = selection.webDomainTokens.isEmpty ? nil : selection.webDomainTokens
    }

    private func call(_ action: String, _ payload: [String: Any]) async throws -> Data {
        try checkContext()
        let publicKey = "sb_publishable_urT7eQPRIxyXso8VKA2tHQ_-U0I0CsO"
        var request = URLRequest(url: URL(string: "https://tttwrzgjddalgiwmgmyz.supabase.co/functions/v1/parental-control-sync")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(publicKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(publicKey)", forHTTPHeaderField: "Authorization")
        request.setValue(installID, forHTTPHeaderField: "x-device-install-id")
        request.setValue(secret, forHTTPHeaderField: "x-device-secret")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["action": action, "payload": payload])
        let (data, response) = try await session.data(for: request)
        try checkContext()
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw Failure.http((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        return data
    }
}
