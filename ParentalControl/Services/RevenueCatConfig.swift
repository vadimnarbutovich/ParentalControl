import Foundation

/// Настройки RevenueCat: ключ из Info.plist (`RevenueCatPublicSDKKey`), идентификаторы в дашборде RevenueCat.
///
/// **Проект в дашборде:** ParentalControl (`proj77ee7cb3`). SDK не использует project id — только публичный ключ **iOS (App Store)** приложения с bundle `mycompny.ParentalControl`, не ключ из «Test Store». Entitlement lookup key в RC: **`ParentalControl Pro`**.
enum RevenueCatConfig {
    /// Идентификатор проекта в RevenueCat (для справки и MCP); в `Purchases.configure` не передаётся.
    static let revenueCatProjectId = "proj77ee7cb3"

    /// Публичный SDK key (App Store / TestFlight). Задаётся в Build Settings → `INFOPLIST_KEY_RevenueCatPublicSDKKey` или Info.plist.
    static var publicSDKKey: String {
        let raw = Bundle.main.object(forInfoDictionaryKey: "RevenueCatPublicSDKKey") as? String
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmed.isEmpty { return trimmed }
        // Публичный key можно безопасно хранить в коде как fallback.
        return defaultPublicSDKKey
    }

    /// Fallback, если ключ не попал в Info.plist текущей сборки.
    static let defaultPublicSDKKey = "appl_KrCdjMXWpMntCfiZHePfqlqHZyC"

    /// Общее право для годовой/месячной подписки и бессрочной покупки.
    static let entitlementIdentifier = "ParentalControl Pro"

    /// Текущий offering (по умолчанию в RC — `default`).
    static let offeringIdentifier = "default"

    static let annualPackageIdentifier = "$rc_annual"
    static let monthlyPackageIdentifier = "$rc_monthly"
    static let lifetimePackageIdentifier = "$rc_lifetime"

    static let privacyPolicyURL = URL(string: "https://vadimnarbutovich.github.io/parentalcontrolapp/privacy-en.html")!
    static let termsOfUseURL = URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!
}

/// Identifiers are shared by the paywall, analytics and the RevenueCat catalog.
enum ProPurchasePlan: String, CaseIterable, Identifiable {
    case annual, monthly, lifetime

    var id: String { rawValue }
    var packageIdentifier: String {
        switch self {
        case .annual: RevenueCatConfig.annualPackageIdentifier
        case .monthly: RevenueCatConfig.monthlyPackageIdentifier
        case .lifetime: RevenueCatConfig.lifetimePackageIdentifier
        }
    }
    var productIdentifier: String { "mycompny.ParentalControl.pro.\(rawValue)" }
    var titleKey: String {
        switch self {
        case .annual: "paywall.plan.yearly"
        case .monthly: "paywall.plan.monthly"
        case .lifetime: "paywall.plan.lifetime"
        }
    }
    var priceKey: String {
        switch self {
        case .annual: "paywall.price.per_year_format"
        case .monthly: "paywall.price.per_month_format"
        case .lifetime: "paywall.price.once_format"
        }
    }

    func offersThreeDayTrial(isEligible: Bool, isFreeTrial: Bool,
                             durationDays: Int?, numberOfPeriods: Int) -> Bool {
        self == .annual && isEligible && isFreeTrial
            && durationDays == 3 && numberOfPeriods == 1
    }
}
