import RevenueCat
import SwiftUI

/// Экран подписки: weekly (intro trial в ASC) + yearly, покупка через RevenueCat.
struct PaywallView: View {
    @EnvironmentObject private var subscriptionService: SubscriptionService
    @Binding var isPresented: Bool
    var openSource: PaywallOpenSource = .settings

    private let closeDelaySeconds: Double = 10
    @State private var selectedWeekly = true
    @State private var isRestoring = false
    @State private var purchaseSucceeded = false
    @State private var restoreStatusKey: String?
    @State private var closeProgress: Double = 0
    @State private var canClosePaywall = false

    var body: some View {
        ZStack {
            AppBackgroundView()

            ScrollView {
                VStack(spacing: 22) {
                    headerBlock
                    featureList
                    iapDiagnosticsBanner
                    planCards
                    ctaBlock
                    legalLinks
                    subscriptionDisclaimer
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 28)
            }
            .scrollIndicators(.hidden)
        }
        // Не используем toolbar: на новых iOS слот обрезает кастомное кольцо и даёт «капсулу»-фон.
        .safeAreaInset(edge: .top, spacing: 0) {
            HStack {
                Spacer(minLength: 0)
                paywallCloseControl
            }
            .frame(height: 52)
            .padding(.horizontal, 12)
        }
        .preferredColorScheme(.dark)
        .task {
            if !subscriptionService.isPro {
                startCloseCountdown()
            }
            await subscriptionService.refreshAll()
        }
        .onChange(of: purchaseSucceeded) { _, ok in
            if ok { isPresented = false }
        }
        .onChange(of: subscriptionService.isPro) { _, pro in
            if pro { isPresented = false }
        }
        .onAppear {
            AppAnalytics.report("paywall_open", parameters: ["source": openSource.rawValue])
        }
    }

    private var headerBlock: some View {
        VStack(spacing: 10) {
            Text("paywall.title.brand")
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .foregroundStyle(AppTheme.neonGreen)
                .multilineTextAlignment(.center)

            Text("paywall.subtitle")
                .font(.system(size: 16, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.88))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 4)

            ZStack {
                Image(systemName: "iphone.gen3")
                    .font(.system(size: 88, weight: .light))
                    .foregroundStyle(.white.opacity(0.2))
                Image(systemName: "lock.open.fill")
                    .font(.system(size: 44, weight: .semibold))
                    .foregroundStyle(AppTheme.neonGreen)
                    .neonGlow(AppTheme.neonGreen, radius: 16)
            }
            .padding(.vertical, 8)
        }
        .padding(.top, 8)
    }

    private var featureList: some View {
        VStack(alignment: .leading, spacing: 14) {
            paywallFeatureRow(icon: "square.grid.2x2.fill", titleKey: "paywall.feature.unlimited_apps")
            paywallFeatureRow(icon: "pause.circle.fill", titleKey: "paywall.feature.advanced_config")
            paywallFeatureRow(icon: "arrow.counterclockwise.circle.fill", titleKey: "paywall.feature.quick_break")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func paywallFeatureRow(icon: String, titleKey: LocalizedStringKey) -> some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(AppTheme.neonGreen)
                .frame(width: 36, height: 36)
                .background(Circle().fill(AppTheme.neonGreen.opacity(0.15)))

            Text(titleKey)
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
        }
    }

    /// Сообщения об ошибке IAP выше карточек планов (и запасной текст, если `lastErrorMessage` затёрт).
    @ViewBuilder
    private var iapDiagnosticsBanner: some View {
        let trimmed = subscriptionService.lastErrorMessage?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let packagesMissing = subscriptionService.weeklyPackage() == nil
            || subscriptionService.annualPackage() == nil
        if !trimmed.isEmpty {
            Text(trimmed)
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(Color.orange.opacity(0.95))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        } else if subscriptionService.offeringsLoadFinished, packagesMissing {
            Text(fallbackMissingPackagesMessageKey)
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(Color.orange.opacity(0.95))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        if isRestoring {
            Text("paywall.restore.checking")
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(AppTheme.neonBlue.opacity(0.95))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        } else if let restoreStatusKey {
            Text(LocalizedStringKey(restoreStatusKey))
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(restoreStatusKey == "paywall.restore.result.failed" ? Color.orange.opacity(0.95) : AppTheme.neonGreen)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var planCards: some View {
        VStack(spacing: 12) {
            planCard(
                titleKey: "paywall.plan.yearly",
                subtitle: annualSubtitle,
                showSaveBadge: true,
                isSelected: !selectedWeekly
            ) {
                selectedWeekly = false
            }

            planCard(
                titleKey: "paywall.plan.weekly",
                subtitle: weeklySubtitle,
                showSaveBadge: false,
                isSelected: selectedWeekly
            ) {
                selectedWeekly = true
            }
        }
    }

    private var weeklySubtitle: String {
        guard let pkg = subscriptionService.weeklyPackage() else {
            return String(localized: "paywall.price.loading")
        }
        return Self.priceLine(for: pkg, isWeekly: true)
    }

    private var annualSubtitle: String {
        guard let pkg = subscriptionService.annualPackage() else {
            return String(localized: "paywall.price.loading")
        }
        return Self.priceLine(for: pkg, isWeekly: false)
    }

    private static func priceLine(for package: Package, isWeekly: Bool) -> String {
        let price = package.storeProduct.localizedPriceString
        if isWeekly {
            if let intro = package.storeProduct.introductoryDiscount {
                let period = intro.subscriptionPeriod
                let units = period.value
                let unitStr = period.unit.localizedShort
                let fmt = String(localized: "paywall.price.weekly_intro_format")
                return String(format: fmt, units, unitStr, price)
            }
            let fmt = String(localized: "paywall.price.per_week_format")
            return String(format: fmt, price)
        }
        let fmt = String(localized: "paywall.price.per_year_format")
        return String(format: fmt, price)
    }

    private func planCard(
        titleKey: LocalizedStringKey,
        subtitle: String,
        showSaveBadge: Bool,
        isSelected: Bool,
        onSelect: @escaping () -> Void
    ) -> some View {
        Button(action: onSelect) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text(titleKey)
                            .font(.system(size: 17, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                        if showSaveBadge {
                            Text("paywall.badge.save")
                                .font(.system(size: 11, weight: .heavy, design: .rounded))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Capsule().fill(Color.red.opacity(0.85)))
                        }
                    }
                    Text(subtitle)
                        .font(.system(size: 14, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.75))
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 8)
                selectionRing(selected: isSelected)
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.white.opacity(0.06))
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(
                                isSelected ? AppTheme.neonGreen : AppTheme.glassBorder.opacity(0.5),
                                lineWidth: isSelected ? 2 : 1
                            )
                    )
            )
        }
        .buttonStyle(.plain)
    }

    private func selectionRing(selected: Bool) -> some View {
        ZStack {
            Circle()
                .stroke(selected ? AppTheme.neonGreen : Color.white.opacity(0.35), lineWidth: 2)
                .frame(width: 26, height: 26)
            if selected {
                Image(systemName: "checkmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(AppTheme.neonGreen)
            }
        }
    }

    private var ctaBlock: some View {
        VStack(spacing: 10) {
            Button {
                let ctaType: String = {
                    if selectedWeekly, subscriptionService.weeklyPackage()?.storeProduct.introductoryDiscount != nil {
                        return "start_trial"
                    }
                    return "continue"
                }()
                AppAnalytics.report("paywall_cta_tap", parameters: ["cta_type": ctaType])
                Task {
                    let pkg = selectedWeekly ? subscriptionService.weeklyPackage() : subscriptionService.annualPackage()
                    guard let pkg else { return }
                    let ok = await subscriptionService.purchase(pkg)
                    purchaseSucceeded = ok
                }
            } label: {
                HStack(spacing: 8) {
                    Text(ctaTitleKey)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 14, weight: .semibold))
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(
                NeonPrimaryButtonStyle(
                    tint: AppTheme.neonGreen,
                    shimmeringSheen: paywallCTAShimmerEnabled
                )
            )
            .disabled(
                subscriptionService.isLoading
                    || !subscriptionService.isConfigured
                    || (selectedWeekly ? subscriptionService.weeklyPackage() == nil : subscriptionService.annualPackage() == nil)
            )
            .opacity(subscriptionService.isLoading ? 0.55 : 1)

            if selectedWeekly, subscriptionService.weeklyPackage()?.storeProduct.introductoryDiscount != nil {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(AppTheme.neonGreen)
                    Text("paywall.no_payment_now")
                        .font(.system(size: 13, weight: .heavy, design: .rounded))
                        .foregroundStyle(AppTheme.neonGreen)
                }
            }
        }
    }

    private var ctaTitleKey: LocalizedStringKey {
        if selectedWeekly, subscriptionService.weeklyPackage()?.storeProduct.introductoryDiscount != nil {
            return "paywall.cta.start_trial"
        }
        return "paywall.cta.continue"
    }

    /// Блик только когда кнопка реально доступна (есть пакеты и не идёт покупка).
    private var paywallCTAShimmerEnabled: Bool {
        subscriptionService.isConfigured
            && !subscriptionService.isLoading
            && (selectedWeekly ? subscriptionService.weeklyPackage() != nil : subscriptionService.annualPackage() != nil)
    }

    private var fallbackMissingPackagesMessageKey: LocalizedStringKey {
        #if DEBUG && !HIDE_DEBUG_UI
        return "paywall.error.iap_fallback_console"
        #else
        return "paywall.error.store_products_unavailable"
        #endif
    }

    /// Только дуга прогресса (без фонового кольца); по завершении сменяется на крестик в `paywallCloseControl`.
    @ViewBuilder
    private var closeProgressIndicator: some View {
        let ringWidth: CGFloat = 5
        let side: CGFloat = 30
        Circle()
            .trim(from: 0, to: closeProgress)
            .stroke(
                AppTheme.neonGreen,
                style: StrokeStyle(lineWidth: ringWidth, lineCap: .round)
            )
            .rotationEffect(.degrees(-90))
            .animation(.linear(duration: 0.2), value: closeProgress)
            .frame(width: side, height: side)
    }

    /// Крестик сразу для активной подписки; иначе — после кольца‑таймера (`canClosePaywall`).
    private var canDismissPaywallNow: Bool {
        subscriptionService.isPro || canClosePaywall
    }

    @ViewBuilder
    private var paywallCloseControl: some View {
        if canDismissPaywallNow {
            Button {
                isPresented = false
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 36, weight: .regular))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.white.opacity(0.85))
            }
            .buttonStyle(.plain)
            .frame(minWidth: 48, minHeight: 48)
            .contentShape(Rectangle())
            .accessibilityLabel(Text("paywall.close"))
        } else {
            closeProgressIndicator
                .accessibilityLabel(Text("paywall.close.wait"))
        }
    }

    private func startCloseCountdown() {
        guard !subscriptionService.isPro, !canClosePaywall else { return }
        closeProgress = 0
        Task {
            let step: UInt64 = 200_000_000
            let ticks = Int((closeDelaySeconds * 1_000_000_000) / Double(step))
            for index in 1 ... ticks {
                try? await Task.sleep(nanoseconds: step)
                closeProgress = min(1, Double(index) / Double(ticks))
            }
            canClosePaywall = true
        }
    }

    private var legalLinks: some View {
        HStack(spacing: 6) {
            Link("paywall.legal.privacy", destination: RevenueCatConfig.privacyPolicyURL)
            Text("|").foregroundStyle(.white.opacity(0.35))
            Button("paywall.legal.restore") {
                Task {
                    restoreStatusKey = nil
                    isRestoring = true
                    let result = await subscriptionService.restorePurchases()
                    isRestoring = false
                    switch result {
                    case .restored:
                        restoreStatusKey = "paywall.restore.result.restored"
                    case .noActiveSubscription:
                        restoreStatusKey = "paywall.restore.result.none"
                    case .failed:
                        restoreStatusKey = "paywall.restore.result.failed"
                    }
                }
            }
            .disabled(isRestoring || subscriptionService.isLoading)
            Text("|").foregroundStyle(.white.opacity(0.35))
            Link("paywall.legal.terms", destination: RevenueCatConfig.termsOfUseURL)
        }
        .font(.system(size: 14, weight: .medium, design: .rounded))
        .foregroundStyle(AppTheme.neonBlue)
        .padding(.top, 4)
    }

    private var subscriptionDisclaimer: some View {
        Text("paywall.legal.subscription_disclaimer")
            .font(.system(size: 11, weight: .regular, design: .rounded))
            .foregroundStyle(.white.opacity(0.45))
            .multilineTextAlignment(.center)
            .padding(.top, 8)
    }
}

private extension SubscriptionPeriod.Unit {
    var localizedShort: String {
        switch self {
        case .day: return String(localized: "paywall.period.day")
        case .week: return String(localized: "paywall.period.week")
        case .month: return String(localized: "paywall.period.month")
        case .year: return String(localized: "paywall.period.year")
        @unknown default: return ""
        }
    }
}

#Preview {
    PaywallView(isPresented: .constant(true), openSource: .settings)
        .environmentObject(SubscriptionService())
}
