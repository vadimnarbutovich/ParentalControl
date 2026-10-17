//
//  NotificationService.swift
//  NotificationServiceExtension
//
//  Created by Vadzim Narbutovich on 27.04.2026.
//

import UserNotifications

class NotificationService: UNNotificationServiceExtension {

    override func didReceive(_ request: UNNotificationRequest, withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        // Preserve the server's text and command payload. No asynchronous work or
        // retained completion handler is needed for an unchanged notification.
        contentHandler(request.content)
    }

}
