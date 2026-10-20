import AppMetricaCore
import Foundation

/// Источник показа paywall (расширять при добавлении гейтов Pro-фич).
enum PaywallOpenSource: String {
    case settings
    case dashboardBadge = "dashboard_badge"
    case limitedFeature = "limited_feature"
}

@MainActor
enum AppAnalytics {
    private static var didActivate = false
    private static var role = "unselected"
    private static var parentMode = false

    /// Public SDK key of the separate ParentalControl project. Never use an OAuth token here.
    private static let metricaAPIKey = "9edea000-9fd2-4da0-9b68-845eedb8bf86"

    static var distribution: String {
        #if DEBUG
        return "debug"
        #else
        return Bundle.main.appStoreReceiptURL?.lastPathComponent == "sandboxReceipt" ? "sandbox" : "release"
        #endif
    }

    static func updateContext(role: String?, parentMode: Bool) {
        let candidate = role ?? "unselected"
        self.role = ["parent", "child"].contains(candidate) ? candidate : "unselected"
        self.parentMode = parentMode
    }

    /// Однократная активация SDK.
    static func activateMetricaIfNeeded() {
        guard !didActivate else { return }
        // Xcode/simulator testing must not inflate production usage or send SDK automatic events.
        #if DEBUG
        return
        #else
        guard AnalyticsSchema.isAllowedKey(metricaAPIKey, bundleID: Bundle.main.bundleIdentifier) else { return }
        guard let configuration = AppMetricaConfiguration(apiKey: metricaAPIKey) else {
            return
        }
        configuration.locationTracking = false
        configuration.accurateLocationTracking = false
        configuration.allowsBackgroundLocationUpdates = false
        configuration.advertisingIdentifierTrackingEnabled = false
        configuration.appOpenTrackingEnabled = false
        configuration.revenueAutoTrackingEnabled = false
        configuration.areLogsEnabled = false
        configuration.appEnvironment = [
            "app": "parental_control", "schema_version": "2", "distribution": distribution
        ]
        AppMetrica.activate(with: configuration)
        didActivate = true
        #endif
    }

    static func report(_ name: String, parameters: [String: Any]? = nil) {
        guard var safe = AnalyticsSchema.sanitized(name, parameters: parameters) else { return }
        safe["app"] = "parental_control"
        safe["schema_version"] = 2
        safe["role"] = role
        safe["parent_mode"] = parentMode
        safe["distribution"] = distribution
        #if DEBUG
        // Sanitized names/parameters only. No SDK initialization or network traffic in Debug.
        print("[AppAnalytics/local] \(name) \(safe)")
        #else
        activateMetricaIfNeeded()
        guard didActivate else { return }
        AppMetrica.reportEvent(name: name, parameters: safe)
        #endif
    }
}
