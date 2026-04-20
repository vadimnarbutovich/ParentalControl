import Foundation
import UserNotifications

protocol Notifying {
    func requestAccess() async -> Bool
    func isAuthorizedForAlerts() async -> Bool
    func currentAuthorizationStatus() async -> UNAuthorizationStatus
    /// Если уведомления в `.denied`, повторный `requestAuthorization` диалог не показывает — нужны Настройки.
    func resolveNotificationAccess(openSettings: @escaping () -> Void) async
    func notify(title: String, body: String)
}

final class NotificationService: Notifying {
    func requestAccess() async -> Bool {
        await withCheckedContinuation { continuation in
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
                continuation.resume(returning: granted)
            }
        }
    }

    func currentAuthorizationStatus() async -> UNAuthorizationStatus {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        return settings.authorizationStatus
    }

    func resolveNotificationAccess(openSettings: @escaping () -> Void) async {
        let status = await currentAuthorizationStatus()
        switch status {
        case .denied:
            await MainActor.run { openSettings() }
        case .notDetermined:
            _ = await requestAccess()
        case .authorized, .provisional, .ephemeral:
            break
        @unknown default:
            _ = await requestAccess()
        }
    }

    func isAuthorizedForAlerts() async -> Bool {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        case .notDetermined, .denied:
            return false
        @unknown default:
            return false
        }
    }

    func notify(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: trigger)
        UNUserNotificationCenter.current().add(request)
    }
}
