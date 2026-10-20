//
//  NotificationService.swift
//  NotificationServiceExtension
//
//  Created by Vadzim Narbutovich on 27.04.2026.
//

import UserNotifications
import OSLog

final class NotificationService: UNNotificationServiceExtension, @unchecked Sendable {
    // Accessed by system expiry, delivery and background deadline, never actor-isolated.
    private let deliveryLock = NSLock()
    private var delivery: NotificationDeliveryLifetime?
    private let logger = Logger(subsystem: "mycompny.ParentalControl", category: "NotificationControl")

    private final class Delivery: @unchecked Sendable {
        let content: UNNotificationContent
        let callback: (UNNotificationContent) -> Void
        init(_ content: UNNotificationContent, _ callback: @escaping (UNNotificationContent) -> Void) {
            self.content = content; self.callback = callback
        }
    }
    override func didReceive(_ request: UNNotificationRequest, withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        let incoming = Delivery(request.content, contentHandler)
        let lifetime = NotificationDeliveryLifetime { [logger] reason in
            incoming.callback(incoming.content)
            logger.notice("Control delivery finished reason=\(reason, privacy: .public)")
        }
        deliveryLock.lock()
        let previous = delivery
        delivery = lifetime
        deliveryLock.unlock()
        previous?.finish(reason: "superseded")
        let work = Task { @MainActor in
            guard !lifetime.isFinished else { return }
            guard let raw = incoming.content.userInfo["command_id"] as? String,
                  let id = UUID(uuidString: raw),
                  let type = incoming.content.userInfo["command_type"] as? String,
                  (["start_focus", "end_focus", "tasks_updated"] + ScheduleControlPlan.commandTypes).contains(type),
                  let client = RemoteControlProcessor(lifetime: lifetime) else {
                lifetime.finish(reason: "not_processable")
                return
            }
            do { try await client.process(id: id, type: type) }
            catch {
                // Expired / superseded work must not overwrite a newer diagnostic.
                if !lifetime.isFinished {
                    client.recordDiagnostic("unfinished", error: error)
                }
                let failure = error as? RemoteControlProcessor.Failure
                logger.notice("Control unfinished reason=\(failure?.diagnostic ?? "operation_error", privacy: .public) code=\((error as NSError).code)")
            }
            lifetime.finish(reason: "completed")
        }
        lifetime.onCancel { work.cancel() }
    }

    override func serviceExtensionTimeWillExpire() {
        deliveryLock.lock()
        let current = delivery
        delivery = nil
        deliveryLock.unlock()
        current?.finish(reason: "system_expiry")
    }
}
