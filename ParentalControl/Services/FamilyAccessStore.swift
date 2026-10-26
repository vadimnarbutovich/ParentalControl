import Foundation

nonisolated enum FamilyAccessStore {
    private static let key = "parentalcontrol.accessReceipt.v1"
    private static let scopeKey = "parentalcontrol.accessPairing.v1"
    static let changed = Notification.Name("ParentalControlAccessChanged")
    static let purchaseRequired = Notification.Name("ParentalControlPurchaseRequired")
    private static var defaults: UserDefaults? { RemoteControlGate.defaults }
    struct Pair: Decodable, Equatable {
        let familyID: UUID
        let parentDeviceID: UUID?
        let childDeviceID: UUID?
    }
    static var pairingData: Data? { defaults?.data(forKey: "parentalcontrol.pairingState") }
    private static func pair(_ data: Data?) -> Pair? {
        data.flatMap { try? JSONDecoder().decode(Pair.self, from: $0) }
    }
    private static func samePair(_ first: Data?, _ second: Data?) -> Bool {
        guard let first = pair(first), let second = pair(second) else { return false }
        return first == second
    }
    static var receipt: ReceivedFamilyAccessLease? {
        guard let d = defaults, samePair(d.data(forKey: scopeKey), pairingData),
              let data = d.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(ReceivedFamilyAccessLease.self, from: data)
    }
    static var isEnrolled: Bool {
        guard let pairingData else { return false }
        return samePair(defaults?.data(forKey: scopeKey), pairingData)
    }
    static var allowed: Bool {
        // Changing a pairing must not temporarily reopen locally enrolled access.
        guard isEnrolled else { return defaults?.data(forKey: scopeKey) == nil }
        guard let pairingData, let pair = try? JSONDecoder().decode(Pair.self, from: pairingData),
              let child = pair.childDeviceID, let receipt else { return false }
        return receipt.canControl(family: pair.familyID, pairing: child,
            wallTime: Date().timeIntervalSince1970, uptime: ProcessInfo.processInfo.systemUptime)
    }
    /// Setup can save a selection and a limit, but never apply Screen Time restrictions.
    static var isSettingUp: Bool { isEnrolled && receipt?.lease.state == .setup }
    static let setupActions: Set<String> = ["parent_poll", "child_poll", "change_daily_budget"]
    static func accept(_ data: Data, pairing: Data?, requestWall: TimeInterval, requestUptime: TimeInterval) {
        guard let pairing, let pair = try? JSONDecoder().decode(Pair.self, from: pairing),
              let child = pair.childDeviceID,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let enforced = object["enforced"] as? Bool else { return }
        var changedValue = false
        _ = RemoteControlGate.withLock {
            guard let d = defaults else { return }
            d.synchronize()
            guard samePair(pairingData, pairing) else { return }
            if !enforced {
                // A delayed legacy response must not undo enrollment. Explicit
                // release remains available even during a rollout rollback.
                guard !isEnrolled else { return }
                d.removeObject(forKey: key); d.removeObject(forKey: scopeKey)
                changedValue = true
            } else if let lease = try? JSONDecoder().decode(FamilyAccessLease.self, from: data),
                      lease.mayReplace(receipt?.lease, family: pair.familyID, pairing: child),
                      let encoded = try? JSONEncoder().encode(ReceivedFamilyAccessLease(lease: lease,
                        requestWallTime: requestWall, requestUptime: requestUptime)) {
                if let previous = receipt, previous.lease.revision == lease.revision,
                   !previous.needsRefresh(uptime: ProcessInfo.processInfo.systemUptime),
                   previous.canControl(family: pair.familyID, pairing: child,
                     wallTime: Date().timeIntervalSince1970, uptime: ProcessInfo.processInfo.systemUptime) {
                    // Ordinary polling must not reset the receipt or invalidate
                    // an in-flight system operation every few seconds.
                    return
                }
                d.set(pairing, forKey: scopeKey); d.set(encoded, forKey: key)
                changedValue = true
            }
            d.synchronize()
        }
        if changedValue { NotificationCenter.default.post(name: changed, object: nil) }
    }
    static func acceptResponse(_ data: Data, response: HTTPURLResponse, pairing: Data?, requestWall: TimeInterval, requestUptime: TimeInterval) {
        if let header = response.value(forHTTPHeaderField: "x-family-access"), let encoded = header.data(using: .utf8) {
            accept(encoded, pairing: pairing, requestWall: requestWall, requestUptime: requestUptime)
        } else if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let access = object["access"], let encoded = try? JSONSerialization.data(withJSONObject: access) {
            accept(encoded, pairing: pairing, requestWall: requestWall, requestUptime: requestUptime)
        }
    }
    static let recoveryActions: Set<String> = ["access_status", "purchase_identity", "verify_purchase", "release_control", "resume_control",
        "register_device", "generate_pairing_code", "join_pairing_code", "register_location_push", "update_apns_token",
        "unlink_devices", "fetch_parent_pin", "set_parent_pin", "clear_parent_pin", "fetch_link_health", "ack_command", "finish_location_push"]
    static let paidMutations: Set<String> = ["replace_focus_command", "queue_focus_command", "change_daily_budget", "request_child_location",
        "upsert_block_schedule", "delete_block_schedule", "upsert_child_task", "delete_child_task", "approve_child_task", "submit_child_task", "set_local_manual_block"]
}
