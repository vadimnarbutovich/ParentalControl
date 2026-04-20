import Foundation

/// Настройки RevenueCat: ключ из Info.plist (`RevenueCatPublicSDKKey`), идентификаторы в дашборде RevenueCat.
///
/// **Проект в дашборде:** ParentalControl (`proj35cefec3`). SDK не использует project id — только публичный ключ **iOS (App Store)** приложения с bundle `mycompny.ParentalControl`, не ключ из «Test Store». Entitlement lookup key в RC: **`ParentalControl Pro`**.
enum RevenueCatConfig {
    /// Идентификатор проекта в RevenueCat (для справки и MCP); в `Purchases.configure` не передаётся.
    static let revenueCatProjectId = "proj35cefec3"

    /// Публичный SDK key (App Store / TestFlight). Задаётся в Build Settings → `INFOPLIST_KEY_RevenueCatPublicSDKKey` или Info.plist.
    static var publicSDKKey: String {
        let raw = Bundle.main.object(forInfoDictionaryKey: "RevenueCatPublicSDKKey") as? String
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmed.isEmpty { return trimmed }
        // Публичный key можно безопасно хранить в коде как fallback.
        return defaultPublicSDKKey
    }

    /// Fallback, если ключ не попал в Info.plist текущей сборки.
    static let defaultPublicSDKKey = "appl_VkzwWAHFBmJXNVJvjQIOgKcXvbM"

    /// Entitlement в RevenueCat (lookup key в дашборде), который открывают weekly и yearly.
    static let entitlementIdentifier = "ParentalControl Pro"

    /// Текущий offering (по умолчанию в RC — `default`).
    static let offeringIdentifier = "default"

    /// Идентификаторы пакетов внутри offering (можно переименовать в дашборде — тогда обновить здесь).
    static let weeklyPackageIdentifier = "$rc_weekly"
    static let annualPackageIdentifier = "$rc_annual"

    static let privacyPolicyURL = URL(string: "https://vadimnarbutovich.github.io/parentalcontrolapp/privacy-en.html")!
    static let termsOfUseURL = URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!
}
