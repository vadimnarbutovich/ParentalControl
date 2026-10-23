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

/// Presentation only: SDK product metadata never grants access or overrides a server revocation.
struct PaywallAccessPresentation: Equatable {
    enum Action: Equatable { case purchase, retry, none }
    let hasPaidAccess: Bool
    let productIdentifier: String?
    let awaitingConfirmation: Bool

    var currentPlan: ProPurchasePlan? {
        guard hasPaidAccess, !awaitingConfirmation else { return nil }
        return ProPurchasePlan.allCases.first { $0.productIdentifier == productIdentifier }
    }

    var statusKey: String? {
        guard hasPaidAccess else { return nil }
        switch currentPlan {
        case .monthly: return "paywall.status.monthly"
        case .annual: return "paywall.status.annual"
        case .lifetime: return "paywall.status.lifetime"
        case nil: return "settings.premium.available"
        }
    }

    func action(for selectedPlan: ProPurchasePlan) -> Action {
        if awaitingConfirmation { return .retry }
        guard hasPaidAccess else { return .purchase }
        if currentPlan == .lifetime || currentPlan == selectedPlan { return .none }
        return .purchase
    }
}

/// The server assigns the purchase owner; never derive it from a family or an Apple ID.
enum PurchaseCustomerIdentity {
    static func isCanonical(_ value: String) -> Bool {
        value.hasPrefix("pc-") && UUID(uuidString: String(value.dropFirst(3))) != nil
    }
}

/// Use the existing access-recovery cadence, never create an unbounded retry loop.
enum PendingPurchaseRecovery {
    static func shouldRetry(awaiting: Bool, inFlight: Bool, deadline: Date?, now: Date) -> Bool {
        awaiting && !inFlight && deadline.map { $0 > now } == true
    }
}

/// Completion of a purchase/restore operation, not the user's access entitlement.
/// A cached paid lease or SDK update cannot complete a pending server verification.
enum PurchaseConfirmationState: Equatable {
    case idle, awaiting, confirmed

    mutating func recordVerification(_ serverConfirmed: Bool?) {
        self = serverConfirmed == true ? .confirmed : .awaiting
    }

    mutating func receivedInactiveSDKEntitlement() {
        // A stale SDK response must not erase an operation still being verified.
        if self == .confirmed { self = .idle }
    }

    static func shouldDismiss(previous: Self, current: Self) -> Bool {
        previous == .awaiting && current == .confirmed
    }
}

/// Compare regular yearly billing with twelve monthly payments in the same currency.
/// Never substitute a marketing constant when StoreKit prices are unavailable.
enum PaywallSavings {
    /// Approximate badge values use tens; avoid suggesting zero savings or a free paid plan.
    static func approximateBadgePercent(_ percent: Int) -> Int {
        let rounded = ((percent + 5) / 10) * 10
        return (10...90).contains(rounded) ? rounded : percent
    }

    static func annualPercent(annual: Decimal, monthly: Decimal,
                              annualCurrency: String?, monthlyCurrency: String?) -> Int? {
        guard let annualCurrency, !annualCurrency.isEmpty,
              annualCurrency == monthlyCurrency,
              !annual.isNaN, !monthly.isNaN, annual > 0, monthly > 0 else { return nil }
        let percent = NSDecimalNumber(decimal: (1 - annual / monthly / 12) * 100).doubleValue
        guard percent.isFinite, percent >= 1, percent < 100 else { return nil }
        // Whole-percent display, rounded to nearest; never advertise 100% off a paid plan.
        return min(99, Int(percent.rounded()))
    }
}
