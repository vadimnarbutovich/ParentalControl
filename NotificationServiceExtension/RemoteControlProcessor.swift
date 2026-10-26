import Foundation
import FamilyControls
import ManagedSettings
import DeviceActivity
import OSLog

/// Manual block/unblock, revisioned daily budget and schedule reconciliation.
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
    private let execution = ControlSystemWorker.Context()
    private var appliedReceipt: ScreenTimeEnforcer.Receipt?
    private var scheduleReceipt: ScheduleControlEnforcer.Receipt?
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
        case accessReleased(Int)
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
            case .accessReleased: "access_released"
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
        lifetime.onCancel { [execution] in execution.cancel() }
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
            if let failure = error as? ControlSystemWorker.Failure {
                switch failure {
                case .expired: value["reason"] = "system_operation_expired"
                case .stale: value["reason"] = "system_operation_stale"
                case .busy: value["reason"] = "system_worker_busy"
                }
            } else {
                value["reason"] = (error as? Failure)?.diagnostic ??
                    (error is DecodingError ? "decoding_failed" : "operation_error")
            }
            value["errorCode"] = (error as NSError).code
        }
        defaults.set(value, forKey: "parentalcontrol.notificationControlDiagnostic")
        defaults.synchronize()
        logger.notice("Control stage=\(stage, privacy: .public) reason=\(value["reason"] as? String ?? "none", privacy: .public)")
    }

    func process(id: UUID, type: String) async throws {
        guard (["start_focus", "end_focus", "tasks_updated"] + ScheduleControlPlan.commandTypes).contains(type) else { return }
        diagnosticCommandID = id
        diagnosticCommandType = type
        recordDiagnostic("received")
        try checkContext()
        logger.info("Control received id=\(id.uuidString, privacy: .public) type=\(type, privacy: .public)")
        let pollData: Data
        do {
            pollData = try await call("child_poll", ["includeParentSettings": false])
        } catch Failure.accessReleased(let revision) {
            // This wake carries no task/budget operation once access has expired.
            // The server independently checks the stored command type and revision.
            guard type == "tasks_updated" else { throw Failure.http(402) }
            try checkContext()
            guard !FamilyAccessStore.allowed,
                  FamilyAccessStore.receipt?.lease.state == .expired,
                  FamilyAccessStore.receipt?.lease.revision == revision else { throw Failure.stale }
            _ = try await call("ack_command", ["commandID": id.uuidString,
                "status": "applied", "accessReleaseRevision": revision], releaseAcknowledgement: true)
            recordDiagnostic("access_release_acknowledged")
            return
        }
        let poll = try JSONDecoder().decode(NotificationControlSnapshot.self, from: pollData)
        recordDiagnostic("snapshot_decoded")
        try checkContext()
        guard poll.contains(id: id, type: type) else {
            recordDiagnostic("no_longer_pending")
            logger.info("Control skipped: no longer pending")
            return
        }
        if ScheduleControlPlan.commandTypes.contains(type) {
            try await processSchedules(id: id)
            return
        }
        let active = poll.desired.shouldFocusActive
        let budget: DailyBudgetState
        let authorization = AuthorizationCenter.shared.authorizationStatus
        diagnosticAuthorizationStatus = authorization.rawValue
        guard authorization != .denied else { throw Failure.authorizationNotApproved(authorization.rawValue) }
        // Validate actual system access OUTSIDE the data lock and MainActor.
        recordDiagnostic("system_monitoring_check")
        do {
            try await ScreenTimeEnforcer.verifyMonitoringAccess(context: execution)
        } catch DeviceActivityCenter.MonitoringError.unauthorized {
            throw Failure.monitoringAccessRejected
        } catch let error as ControlSystemWorker.Failure {
            throw error
        } catch {
            throw Failure.monitoringAccessFailed((error as NSError).code)
        }
        try checkContext()
        recordDiagnostic("system_monitoring_ready")
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
            guard active || !defaults.bool(forKey: "parentalcontrol.isDeviceActivityMonitoringPaused")
            else { throw Failure.monitoringPaused }
            // NSE can report notDetermined while the containing app is authorized.
            // This is not approval: the actual monitoring API must still accept
            // the operation checked above. Never prompt or use cached consent in NSE.
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
        }
        appliedReceipt = try await ScreenTimeEnforcer.apply(context: execution)
        try checkContext()
        guard appliedReceipt?.stamp.focusRevision == poll.desired.revision,
              appliedReceipt?.stamp.focusActive == active else { throw Failure.stale }
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

    private func processSchedules(id: UUID) async throws {
        // The push is only a wake hint. A delayed start/end must NEVER override
        // the latest schedule list or blindly toggle the shared manual shield.
        guard AuthorizationCenter.shared.authorizationStatus != .denied else {
            throw Failure.authorizationNotApproved(AuthorizationCenter.shared.authorizationStatus.rawValue)
        }
        let fetch = try ScheduleControlStore.beginFetch()
        let response = try await call("list_block_schedules", ["installID": installID])
        let data = try ScheduleControlPlan.cacheFromResponse(response)
        try checkContext()
        try ScheduleControlStore.commit(data, fetch: fetch)
        recordDiagnostic("schedule_snapshot_saved")
        // notDetermined in NSE is not proof of permission: verify with a real
        // schedule registration even when all existing names/signatures match.
        scheduleReceipt = try await ScheduleControlEnforcer.apply(context: execution, verifyAccess: true)
        try checkContext()
        recordDiagnostic("schedule_locally_applied")
        // ACK means the latest list was reconciled, NOT that an obsolete "start"
        // was replayed. Registration failures / stale results leave it pending.
        _ = try await call("ack_command", ["commandID": id.uuidString, "status": "applied", "errorMessage": NSNull()])
        recordDiagnostic("acknowledged")
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
        try execution.check()
        try Task.checkCancellation()
        if let appliedReceipt, !appliedReceipt.isCurrent() { throw Failure.stale }
        if let scheduleReceipt, !scheduleReceipt.isCurrent() { throw Failure.stale }
        defaults.synchronize()
        guard defaults.string(forKey: "parentalcontrol.deviceRole") == "child",
              defaults.data(forKey: "parentalcontrol.pairingState") == pairingData,
              defaults.string(forKey: "parentalcontrol.deviceSecret") == secret else { throw Failure.stale }
        // Named schedule shields are independent of a pending local manual toggle.
        if !ScheduleControlPlan.commandTypes.contains(diagnosticCommandType ?? ""),
           defaults.data(forKey: RemoteControlGate.pendingKey(family)) != nil { throw Failure.stale }
    }

    private func call(_ action: String, _ payload: [String: Any], releaseAcknowledgement: Bool = false) async throws -> Data {
        try checkContext()
        let requestWall = Date().timeIntervalSince1970
        let requestUptime = ProcessInfo.processInfo.systemUptime
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
        if let http = response as? HTTPURLResponse {
            FamilyAccessStore.acceptResponse(data, response: http, pairing: pairingData,
                requestWall: requestWall, requestUptime: requestUptime)
            // Recovery ACK is allowed without paid access. Do not recursively
            // release/throw 402 after the server has accepted this acknowledgement.
            if releaseAcknowledgement {
                guard action == "ack_command", (200..<300).contains(http.statusCode) else {
                    throw Failure.http(http.statusCode)
                }
                return data
            }
            if !FamilyAccessStore.allowed {
                let released = try await ControlSystemWorker.shared.run(context: execution) { context in
                    try context.check()
                    return FamilyAccessEnforcement.releaseIfNeeded()
                }
                try checkContext()
                if action == "child_poll", released, !FamilyAccessStore.allowed,
                   let revision = NotificationAccessRelease.revision(status: http.statusCode, data: data,
                        current: FamilyAccessStore.receipt?.lease, family: family) {
                    throw Failure.accessReleased(revision)
                }
                throw Failure.http(402)
            }
        }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw Failure.http((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        return data
    }
}
