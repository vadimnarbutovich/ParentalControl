import Foundation

#if canImport(ActivityKit)
import ActivityKit

/// Доступ пользователя к Live Activities («Эфир активности») для фокус-сессии.
enum LiveActivityPermission {
    static var isEnabledForApp: Bool {
        ActivityAuthorizationInfo().areActivitiesEnabled
    }
}

#else

enum LiveActivityPermission {
    static var isEnabledForApp: Bool { true }
}

#endif
