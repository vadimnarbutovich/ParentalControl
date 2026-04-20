import AppMetricaCore
import Foundation

/// Источник показа paywall (расширять при добавлении гейтов Pro-фич).
enum PaywallOpenSource: String {
    case settings
    case dashboardBadge = "dashboard_badge"
    case limitedFeature = "limited_feature"
}

enum AppAnalytics {
    private static var didActivate = false

    /// Ключ приложения ParentalControl в консоли AppMetrica (как в HabitsTracker — строка в коде).
    private static let metricaAPIKey = "90679160-6625-4373-bd17-55564f521a13"

    /// Однократная активация SDK.
    static func activateMetricaIfNeeded() {
        guard !didActivate else { return }
        didActivate = true
        guard let configuration = AppMetricaConfiguration(apiKey: metricaAPIKey) else {
            #if DEBUG && !HIDE_DEBUG_UI
            print("[AppAnalytics] invalid AppMetrica API key")
            #endif
            return
        }
        AppMetrica.activate(with: configuration)
    }

    static func report(_ name: String, parameters: [String: Any]? = nil) {
        #if DEBUG && !HIDE_DEBUG_UI
        if let parameters {
            print("[AppAnalytics] \(name) \(parameters)")
        } else {
            print("[AppAnalytics] \(name)")
        }
        #endif
        AppMetrica.reportEvent(name: name, parameters: parameters)
    }
}
