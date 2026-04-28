import Combine
import Foundation
import RevenueCat
import Security

@MainActor
final class SubscriptionService: ObservableObject {
    @Published private(set) var isPro: Bool = true
    /// `true` после первого получения `CustomerInfo` из RevenueCat (кэш, сеть или стрим), либо если SDK не настроен — чтобы не мигал Pro-бейдж до проверки подписки.
    @Published private(set) var isSubscriptionStatusKnown: Bool = false
    @Published private(set) var currentOffering: Offering?
    @Published private(set) var isLoading: Bool = false
    @Published private(set) var lastErrorMessage: String?
    /// После первой попытки `loadOfferings` (для paywall-диагностики, если текст ошибки не подтянулся из строк).
    @Published private(set) var offeringsLoadFinished: Bool = false
    /// Ограничиваем время загрузки, чтобы paywall не зависал на "Загрузка цен...".
    private let offeringsLoadTimeoutNanoseconds: UInt64 = 15_000_000_000

    var isConfigured: Bool { !RevenueCatConfig.publicSDKKey.isEmpty }

    private var customerInfoUpdatesTask: Task<Void, Never>?
    /// Два параллельных `refreshAll()` (из `init` и из `.task` paywall) могли перетирать `currentOffering` пустым ответом.
    private var refreshCoalescedTask: Task<Void, Never>?

    init() {
        let key = RevenueCatConfig.publicSDKKey
        guard !key.isEmpty else {
            lastErrorMessage = Self.localizedPaywallError(
                key: "paywall.error.missing_public_sdk_key",
                fallback: "Не найден RevenueCatPublicSDKKey в Info.plist для текущей сборки."
            )
            offeringsLoadFinished = true
            isSubscriptionStatusKnown = true
            Self.debugLog("RevenueCat key is missing in Info.plist (RevenueCatPublicSDKKey)")
            return
        }

        #if DEBUG && !HIDE_DEBUG_UI
        Purchases.logLevel = .debug
        #else
        Purchases.logLevel = .warn
        #endif
        Purchases.configure(withAPIKey: key)
        let stableAppUserID = Self.stableRevenueCatAppUserID()

        customerInfoUpdatesTask = Task { [weak self] in
            guard let self else { return }
            for await info in Purchases.shared.customerInfoStream {
                await MainActor.run {
                    self.updatePro(from: info)
                }
            }
        }

        Task {
            await identifyStableUserIfNeeded(stableAppUserID)
            await refreshAll()
        }
    }

    deinit {
        customerInfoUpdatesTask?.cancel()
    }

    func refreshAll() async {
        guard isConfigured else {
            offeringsLoadFinished = true
            if lastErrorMessage == nil {
                lastErrorMessage = Self.localizedPaywallError(
                    key: "paywall.error.missing_public_sdk_key",
                    fallback: "Не найден RevenueCatPublicSDKKey в Info.plist для текущей сборки."
                )
            }
            return
        }
        if let running = refreshCoalescedTask {
            await running.value
            return
        }
        let task = Task { @MainActor in
            await self.loadOfferings()
            await self.refreshCustomerInfo()
        }
        refreshCoalescedTask = task
        await task.value
        refreshCoalescedTask = nil
    }

    func refreshCustomerInfo() async {
        guard isConfigured else { return }
        do {
            let info = try await Purchases.shared.customerInfo()
            updatePro(from: info)
        } catch {
            // Не затираем сообщение об IAP/offerings, если оно уже установлено в `loadOfferings`.
            if lastErrorMessage == nil {
                lastErrorMessage = Self.userFacingErrorMessage(from: error)
            }
            isSubscriptionStatusKnown = true
        }
    }

    func loadOfferings() async {
        guard isConfigured else {
            offeringsLoadFinished = true
            if lastErrorMessage == nil {
                lastErrorMessage = Self.localizedPaywallError(
                    key: "paywall.error.missing_public_sdk_key",
                    fallback: "Не найден RevenueCatPublicSDKKey в Info.plist для текущей сборки."
                )
            }
            return
        }
        offeringsLoadFinished = false
        defer { offeringsLoadFinished = true }
        do {
            let offerings: Offerings = try await fetchOfferings()
            let selected: Offering? = {
                if let id = offerings.all[RevenueCatConfig.offeringIdentifier] { return id }
                return offerings.current
            }()
            currentOffering = selected

            let packageCount = selected?.availablePackages.count ?? 0
            let productIds = selected?.availablePackages.map(\.storeProduct.productIdentifier) ?? []
            Self.debugLog("offering=\(selected?.identifier ?? "nil") packages=\(packageCount) ids=\(productIds)")

            // RevenueCat строит пакеты только из продуктов, которые вернул StoreKit.
            if selected == nil {
                lastErrorMessage = Self.localizedPaywallError(
                    key: "paywall.error.no_offering",
                    fallback: "Нет набора подписок (offering). Проверьте в RevenueCat offering «default» и публичный ключ."
                )
            } else if weeklyPackage() == nil || annualPackage() == nil {
                lastErrorMessage = Self.localizedPaywallError(
                    key: "paywall.error.store_products_unavailable",
                    fallback: "App Store не вернул обе подписки (StoreKit). Проверьте Sandbox, bundle mycompny.ParentalControl, ID продуктов в ASC и RevenueCat. Пакетов с ценой: \(packageCount)."
                )
            } else {
                lastErrorMessage = nil
            }
        } catch let error as OfferingsLoadError {
            currentOffering = nil
            switch error {
            case .timedOut:
                lastErrorMessage = Self.localizedPaywallError(
                    key: "paywall.error.offerings_timeout",
                    fallback: "Не удалось получить подписки вовремя. Проверьте интернет и повторите попытку."
                )
            }
            Self.debugLog("offerings timeout")
        } catch {
            currentOffering = nil
            lastErrorMessage = Self.userFacingErrorMessage(from: error)
            Self.debugLog("offerings error: \(error.localizedDescription)")
        }
    }

    /// Берём offerings из SDK с таймаутом, чтобы не зависать бесконечно.
    private func fetchOfferings() async throws -> Offerings {
        try await withTimeout(nanoseconds: offeringsLoadTimeoutNanoseconds) {
            try await Purchases.shared.offerings()
        }
    }

    private func withTimeout<T>(
        nanoseconds: UInt64,
        operation: @escaping () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: nanoseconds)
                throw OfferingsLoadError.timedOut
            }
            guard let value = try await group.next() else {
                throw OfferingsLoadError.timedOut
            }
            group.cancelAll()
            return value
        }
    }

    private static func localizedPaywallError(key: String, fallback: String) -> String {
        let s = Bundle.main.localizedString(forKey: key, value: fallback, table: nil)
        if s.isEmpty || s == key { return fallback }
        return s
    }

    private static func userFacingErrorMessage(from error: Error) -> String {
        #if DEBUG && !HIDE_DEBUG_UI
        return error.localizedDescription
        #else
        return localizedPaywallError(
            key: "paywall.error.generic",
            fallback: "Не удалось выполнить операцию с подпиской. Попробуйте еще раз."
        )
        #endif
    }

    /// Пакет weekly (trial задаётся в App Store Connect).
    func weeklyPackage() -> Package? {
        let o = currentOffering
        if let w = o?.weekly { return w }
        return o?.package(identifier: RevenueCatConfig.weeklyPackageIdentifier)
    }

    /// Годовой пакет.
    func annualPackage() -> Package? {
        let o = currentOffering
        if let a = o?.annual { return a }
        return o?.package(identifier: RevenueCatConfig.annualPackageIdentifier)
    }

    @discardableResult
    func purchase(_ package: Package) async -> Bool {
        guard isConfigured else { return false }
        isLoading = true
        defer { isLoading = false }
        do {
            let result = try await Purchases.shared.purchase(package: package)
            updatePro(from: result.customerInfo)
            return true
        } catch ErrorCode.purchaseCancelledError {
            return false
        } catch {
            lastErrorMessage = Self.userFacingErrorMessage(from: error)
            return false
        }
    }

    @discardableResult
    func restorePurchases() async -> RestoreResult {
        guard isConfigured else {
            return .failed(
                Self.localizedPaywallError(
                    key: "paywall.error.missing_public_sdk_key",
                    fallback: "Не найден RevenueCatPublicSDKKey в Info.plist для текущей сборки."
                )
            )
        }
        isLoading = true
        defer { isLoading = false }
        do {
            let info = try await Purchases.shared.restorePurchases()
            updatePro(from: info)
            let restored = info.entitlements[RevenueCatConfig.entitlementIdentifier]?.isActive == true
            return restored ? .restored : .noActiveSubscription
        } catch {
            lastErrorMessage = Self.userFacingErrorMessage(from: error)
            return .failed(lastErrorMessage)
        }
    }

    private func updatePro(from info: CustomerInfo) {
//        isPro = info.entitlements[RevenueCatConfig.entitlementIdentifier]?.isActive == true
        isSubscriptionStatusKnown = true
    }

    /// Логиним стабильный app user id, чтобы профиль не терялся при переустановке приложения.
    private func identifyStableUserIfNeeded(_ appUserID: String) async {
        guard isConfigured else { return }
        guard Purchases.shared.appUserID != appUserID else { return }
        do {
            let result = try await Purchases.shared.logIn(appUserID)
            updatePro(from: result.customerInfo)
            Self.debugLog("logged in stable appUserID")
        } catch {
            Self.debugLog("failed to log in stable appUserID: \(error.localizedDescription)")
        }
    }

    private static func stableRevenueCatAppUserID() -> String {
        let keychainKey = "parentalcontrol.revenuecat.app_user_id"
        if let existing = KeychainStore.read(key: keychainKey), !existing.isEmpty {
            return existing
        }
        let generated = "sb-\(UUID().uuidString.lowercased())"
        _ = KeychainStore.save(value: generated, key: keychainKey)
        return generated
    }

    private static func debugLog(_ message: String) {
        #if DEBUG && !HIDE_DEBUG_UI
        print("[ParentalControl][IAP] \(message)")
        #endif
    }
}

enum RestoreResult {
    case restored
    case noActiveSubscription
    case failed(String?)
}

private enum OfferingsLoadError: Error {
    case timedOut
}

private enum KeychainStore {
    private static let service = "mycompny.ParentalControl"

    static func save(value: String, key: String) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]

        SecItemDelete(query as CFDictionary)

        var addQuery = query
        addQuery[kSecValueData as String] = data

        return SecItemAdd(addQuery as CFDictionary, nil) == errSecSuccess
    }

    static func read(key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else { return nil }
        guard let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
