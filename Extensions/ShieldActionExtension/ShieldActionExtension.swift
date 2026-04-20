import ManagedSettings
import ManagedSettingsUI
import Foundation
import UserNotifications

// Для работы нужен отдельный Shield Action Extension target.
final class ShieldActionExtension: ShieldActionDelegate {
    override func handle(
        action: ShieldAction,
        for application: ApplicationToken,
        completionHandler: @escaping (ShieldActionResponse) -> Void
    ) {
        switch action {
        case .primaryButtonPressed:
            // Прямой open родительского приложения из shield ограничен API.
            // Fallback: отправляем локальное уведомление с подсказкой открыть ParentalControl.
            scheduleOpenAppHintNotification()
            completionHandler(.close)
        case .secondaryButtonPressed:
            completionHandler(.close)
        @unknown default:
            completionHandler(.close)
        }
    }

    private func scheduleOpenAppHintNotification() {
        let content = UNMutableNotificationContent()
        content.title = NSLocalizedString("shield.open.notification.title", comment: "")
        content.body = NSLocalizedString("shield.open.notification.body", comment: "")
        content.sound = .default

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: trigger
        )
        UNUserNotificationCenter.current().add(request)
    }
}
