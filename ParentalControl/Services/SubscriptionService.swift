import Combine
import Foundation
import RevenueCat
import Security

@MainActor
final class SubscriptionService: ObservableObject {
    /// Effective UI access follows the server-verified family lease, including demo.
    /// SDK entitlement and legacy parent_is_pro cannot grant server access.
    @Published private(set) var isPro: Bool = true
    /// Реальный entitlement ИМЕННО этого устройства из RevenueCat (на родителе — основа гейтинга,
    /// на ребёнке обычно `false` и не используется). Источник для отправки статуса на backend.
    @Published private(set) var hasActiveEntitlement: Bool = false
    @Published private(set) var hasLifetimeAccess: Bool = false
    @Published private(set) var purchaseConfirmationState: PurchaseConfirmationState = .idle
    var hasServerConfirmedPurchase: Bool { purchaseConfirmationState == .confirmed }
    var isAwaitingServerConfirmation: Bool { purchaseConfirmationState == .awaiting }
    @Published private(set) var paywallAccess = PaywallAccessPresentation(
        hasPaidAccess: false, productIdentifier: nil, awaitingConfirmation: false)
    /// Descriptive metadata only. Keep the last product even when the SDK's clock
    /// expires it offline; only the family receipt decides whether access is paid.
    private var entitlementProductIdentifier: String?
    /// Присланный с backend Pro-статус родителя (только на ребёнке). `nil` — ещё не синхронизирован.
    private var parentProOverride: Bool?
    /// Вызывается при изменении реального entitlement этого устройства. Родитель подписывается,
    /// чтобы отправить новый статус на backend (`set_parent_pro`). `[weak]`-замыкание в `AppState`.
    var onEntitlementChange: ((Bool) -> Void)?
    var prepareServerPurchase: (() async throws -> String)?
    var verifyServerPurchase: (() async throws -> Bool)?
    var recheckServerPurchase: (() async throws -> Bool)?
    var resolveServerPurchaseIdentity: (() async throws -> String)?
    private var identityInitialization: Task<Void, Never>?
    /// `true` после первого получения `CustomerInfo` из RevenueCat (кэш, сеть или стрим), либо если SDK не настроен — чтобы не мигал Pro-бейдж до проверки подписки.
    @Published private(set) var isSubscriptionStatusKnown: Bool = false
    @Published private(set) var currentOffering: Offering?
    @Published private(set) var annualTrialEligible = false
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
        recomputeIsPro()
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

        identityInitialization = Task {
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

    /// Older installations saved the legacy SDK user, but purchases use the
    /// authenticated server owner. Resolve that owner once on opening the paywall,
    /// then retain it in Keychain for subsequent launches (including offline).
    func refreshForPaywall() async {
        guard isConfigured else { await refreshAll(); return }
        await identityInitialization?.value
        if !PurchaseCustomerIdentity.isCanonical(Purchases.shared.appUserID),
           let resolveServerPurchaseIdentity {
            do {
                try await identifyPurchaseOwner(try await resolveServerPurchaseIdentity())
            } catch {
                // No new access and no fabricated plan on failure. Cached server
                // access remains authoritative; a later explicit refresh can retry.
                Self.debugLog("Could not resolve paywall purchase owner")
            }
        }
        await refreshAll()
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
        annualTrialEligible = false
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
            let selected = offerings.all[RevenueCatConfig.offeringIdentifier]
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
            } else if ProPurchasePlan.allCases.contains(where: { package(for: $0) == nil }) {
                lastErrorMessage = Self.localizedPaywallError(
                    key: "paywall.error.store_products_unavailable",
                    fallback: "Не удалось загрузить все варианты покупки. Проверьте интернет и повторите попытку."
                )
            } else {
                lastErrorMessage = nil
            }
            if let product = package(for: .annual)?.storeProduct,
               let intro = product.introductoryDiscount,
               ProPurchasePlan.annual.offersThreeDayTrial(
                   isEligible: true, isFreeTrial: intro.paymentMode == .freeTrial,
                   durationDays: intro.subscriptionPeriod.unit == .day ? intro.subscriptionPeriod.value : nil,
                   numberOfPeriods: intro.numberOfPeriods
               ) {
                let eligibility = await Purchases.shared.checkTrialOrIntroDiscountEligibility(product: product)
                annualTrialEligible = eligibility == .eligible
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

    /// Reject mismatched products rather than showing another app's or plan's price.
    func package(for plan: ProPurchasePlan) -> Package? {
        guard let package = currentOffering?.package(identifier: plan.packageIdentifier),
              package.storeProduct.productIdentifier == plan.productIdentifier else { return nil }
        return package
    }

    @discardableResult
    func purchase(_ package: Package) async -> Bool {
        if isAwaitingServerConfirmation { return await retryPendingPurchaseConfirmation() }
        guard isConfigured, !isLoading,
              let selectedPlan = ProPurchasePlan.allCases.first(where: {
                  $0.productIdentifier == package.storeProduct.productIdentifier
                    && $0.packageIdentifier == package.identifier
              }) else { return false }
        let plan = selectedPlan.rawValue
        AppAnalytics.report("purchase_started", parameters: ["plan": plan])
        isLoading = true
        lastErrorMessage = nil
        defer { isLoading = false }
        do {
            try await preparePurchaseIdentity()
            // An Apple purchase already exists: retry server verification, never charge again.
            if hasActiveEntitlement && (hasLifetimeAccess || !FamilyAccessStore.allowed || isAwaitingServerConfirmation
                || entitlementProductIdentifier == selectedPlan.productIdentifier) {
                return await confirmServerPurchase()
            }
            let result = try await Purchases.shared.purchase(package: package)
            if result.userCancelled {
                AppAnalytics.report("purchase_result", parameters: ["plan": plan, "result": "cancelled"])
                return false
            }
            updatePro(from: result.customerInfo)
            guard hasActiveEntitlement else {
                lastErrorMessage = Self.localizedPaywallError(
                    key: "paywall.error.generic", fallback: "Не удалось подтвердить покупку. Попробуйте восстановить покупки."
                )
                AppAnalytics.report("purchase_result", parameters: ["plan": plan, "result": "failed"])
                return false
            }
            guard await confirmServerPurchase() else {
                AppAnalytics.report("purchase_result", parameters: ["plan": plan, "result": "pending_verification"])
                return false
            }
            AppAnalytics.report("purchase_result", parameters: ["plan": plan, "result": "success"])
            return true
        } catch ErrorCode.purchaseCancelledError {
            AppAnalytics.report("purchase_result", parameters: ["plan": plan, "result": "cancelled"])
            return false
        } catch {
            AppAnalytics.report("purchase_result", parameters: ["plan": plan, "result": "failed"])
            lastErrorMessage = Self.userFacingErrorMessage(from: error)
            return false
        }
    }

    @discardableResult
    func restorePurchases() async -> RestoreResult {
        guard !isLoading else { return .failed(nil) }
        guard isConfigured else {
            return .failed(
                Self.localizedPaywallError(
                    key: "paywall.error.missing_public_sdk_key",
                    fallback: "Не найден RevenueCatPublicSDKKey в Info.plist для текущей сборки."
                )
            )
        }
        AppAnalytics.report("restore_started")
        isLoading = true
        lastErrorMessage = nil
        defer { isLoading = false }
        do {
            try await preparePurchaseIdentity()
            let info = try await Purchases.shared.restorePurchases()
            updatePro(from: info)
            let restored = info.entitlements[RevenueCatConfig.entitlementIdentifier]?.isActive == true
            if restored {
                guard await confirmServerPurchase() else { return .pendingVerification }
            }
            AppAnalytics.report("restore_result", parameters: [
                "result": restored ? "restored" : "no_active_subscription"
            ])
            return restored ? .restored : .noActiveSubscription
        } catch {
            AppAnalytics.report("restore_result", parameters: ["result": "failed"])
            lastErrorMessage = Self.userFacingErrorMessage(from: error)
            return .failed(lastErrorMessage)
        }
    }

    private func updatePro(from info: CustomerInfo) {
        isSubscriptionStatusKnown = true
        entitlementProductIdentifier = info.entitlements[RevenueCatConfig.entitlementIdentifier]?.productIdentifier
        let active = info.entitlements[RevenueCatConfig.entitlementIdentifier]?.isActive == true
        hasLifetimeAccess = active
            && info.entitlements[RevenueCatConfig.entitlementIdentifier]?.productIdentifier
                == ProPurchasePlan.lifetime.productIdentifier
        let changed = active != hasActiveEntitlement
        hasActiveEntitlement = active
        if !active { purchaseConfirmationState.receivedInactiveSDKEntitlement() }
        recomputeIsPro()
        // Уведомляем подписчика (родитель → backend) только при реальном изменении статуса.
        if changed { onEntitlementChange?(active) }
    }

    /// Retrying verification never invokes StoreKit purchase/restore or needs offerings.
    @discardableResult
    func retryPendingPurchaseConfirmation(automatic: Bool = false) async -> Bool {
        guard isAwaitingServerConfirmation, !isLoading else { return false }
        isLoading = true
        defer { isLoading = false }
        let confirmed = await confirmServerPurchase(automatic: automatic)
        return confirmed
    }

    private func confirmServerPurchase(automatic: Bool = false) async -> Bool {
        defer { recomputeIsPro() }
        do {
            let verifier = automatic ? recheckServerPurchase : verifyServerPurchase
            if try await verifier?() == true {
                purchaseConfirmationState.recordVerification(true)
                lastErrorMessage = nil
                return true
            }
        } catch {
            // StoreKit may already have charged. A transport failure is not a failed purchase.
        }
        purchaseConfirmationState.recordVerification(false)
        lastErrorMessage = L10n.tr("paywall.purchase.pending_verification")
        return false
    }

    /// Child-сторона: применяет Pro-статус родителя, присланный backend'ом. Источник правды
    /// гейтинга на ребёнке — именно это значение, а не собственный RevenueCat ребёнка.
    func applyParentProStatus(_ isProFromParent: Bool) {
        guard parentProOverride != isProFromParent else { return }
        parentProOverride = isProFromParent
        recomputeIsPro()
    }

    /// Refresh effective access after a shared lease changes or expires.
    func refreshAccessState() { recomputeIsPro() }

    private func recomputeIsPro() {
        // Server rollout/lease decides access, never a client-supplied isPro.
        let effective = FamilyAccessStore.allowed
        if isPro != effective { isPro = effective }
        let presentation = PaywallAccessPresentation(
            hasPaidAccess: effective && FamilyAccessStore.receipt?.lease.state == .paid,
            productIdentifier: entitlementProductIdentifier,
            awaitingConfirmation: isAwaitingServerConfirmation)
        if paywallAccess != presentation { paywallAccess = presentation }
    }

    private func preparePurchaseIdentity() async throws {
        await identityInitialization?.value
        guard let prepareServerPurchase else { throw NSError(domain: "ParentalAccess", code: 503) }
        let identity = try await prepareServerPurchase()
        try await identifyPurchaseOwner(identity)
    }

    private func identifyPurchaseOwner(_ identity: String) async throws {
        guard PurchaseCustomerIdentity.isCanonical(identity) else {
            throw NSError(domain: "ParentalAccess", code: 502)
        }
        if Purchases.shared.appUserID != identity {
            let result = try await Purchases.shared.logIn(identity)
            updatePro(from: result.customerInfo)
            annualTrialEligible = false
            await loadOfferings()
        }
        // A successful login must survive restart/reinstall. Otherwise startup
        // logs back into the legacy sb- profile, which may have no purchases.
        let key = "parentalcontrol.revenuecat.app_user_id"
        if KeychainStore.read(key: key) != identity {
            _ = KeychainStore.save(value: identity, key: key)
        }
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
    case pendingVerification
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

        // Preserve the previous identity if Keychain is temporarily unavailable.
        let status = SecItemUpdate(query as CFDictionary,
                                   [kSecValueData as String: data] as CFDictionary)
        if status == errSecSuccess { return true }
        guard status == errSecItemNotFound else { return false }
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
