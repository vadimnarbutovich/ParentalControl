import RevenueCat
import SwiftUI

private struct PaywallIntroductionBoundsKey: PreferenceKey {
    static var defaultValue: Anchor<CGRect>? { nil }

    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = nextValue() ?? value
    }
}

/// Store prices and introductory eligibility come from RevenueCat / StoreKit.
/// Showing this screen does not enable paid feature restrictions.
struct PaywallView: View {
    @EnvironmentObject private var subscriptionService: SubscriptionService
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding var isPresented: Bool
    var openSource: PaywallOpenSource = .settings

    @State private var selectedPlan: ProPurchasePlan = .annual
    @State private var isRefreshing = false
    @State private var restoreStatusKey: String?
    @State private var restored = false
    @ScaledMetric(relativeTo: .title) private var titleSize = 28
    @ScaledMetric(relativeTo: .body) private var bodySize = 16
    @ScaledMetric(relativeTo: .headline) private var planTitleSize = 17
    @ScaledMetric(relativeTo: .subheadline) private var priceSize = 14

    private let closeButtonSize: CGFloat = 44
    private let closeBarVerticalPadding: CGFloat = 2

    private var selectedPackage: Package? { subscriptionService.package(for: selectedPlan) }
    private var access: PaywallAccessPresentation { subscriptionService.paywallAccess }
    private var offersTrial: Bool { !access.hasPaidAccess && !access.awaitingConfirmation && subscriptionService.annualTrialEligible }
    private var hasTrial: Bool { selectedPlan == .annual && offersTrial }
    private var busy: Bool { subscriptionService.isLoading || isRefreshing }
    private var annualSavings: Int? {
        guard let annual = subscriptionService.package(for: .annual)?.storeProduct,
              let monthly = subscriptionService.package(for: .monthly)?.storeProduct else { return nil }
        return PaywallSavings.annualPercent(annual: annual.price, monthly: monthly.price,
                                           annualCurrency: annual.currencyCode, monthlyCurrency: monthly.currencyCode)
    }

    var body: some View {
        ZStack {
            ScrollView {
                VStack(spacing: 18) {
                    VStack(spacing: 18) {
                        header
                        features
                    }
                    .anchorPreference(key: PaywallIntroductionBoundsKey.self, value: .bounds) { $0 }
                    VStack(spacing: 10) {
                        ForEach(ProPurchasePlan.allCases) { plan in planCard(plan) }
                    }
                    status
                    Text(selectedPlan == .lifetime
                         ? "paywall.legal.lifetime_disclaimer"
                         : "paywall.legal.subscription_disclaimer")
                        .font(.system(.caption, design: .rounded))
                        .foregroundStyle(.white.opacity(0.6))
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.hidden)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            HStack {
                Spacer()
                Button { isPresented = false } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 32))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.white.opacity(0.85))
                        .frame(width: closeButtonSize, height: closeButtonSize)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("paywall.close"))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, closeBarVerticalPadding)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            purchaseFooter
        }
        .backgroundPreferenceValue(PaywallIntroductionBoundsKey.self) { bounds in
            ZStack {
                AppBackgroundView()
                familyArtwork(endingAt: bounds)
            }
        }
        .overlayPreferenceValue(PaywallIntroductionBoundsKey.self) { bounds in
            scrollingTitle(following: bounds)
        }
        .preferredColorScheme(.dark)
        .task { await refresh() }
        .onChange(of: subscriptionService.purchaseConfirmationState) { previous, current in
            // Close only after an operation that was pending completes. Merely
            // opening the paywall with an existing paid lease must not dismiss it.
            if PurchaseConfirmationState.shouldDismiss(previous: previous, current: current) {
                isPresented = false
            }
        }
        .onAppear {
            AppAnalytics.report("paywall_open", parameters: ["source": openSource.rawValue])
        }
        .alert(Text("paywall.restore.result.restored"), isPresented: $restored) {
            Button("OK") { isPresented = false }
        }
    }

    private func scrollingTitle(following bounds: Anchor<CGRect>?) -> some View {
        // Start at the close bar, then move with the same introduction anchor
        // as the artwork. The close button itself remains fixed and tappable.
        GeometryReader { geometry in
            if let bounds {
                Text("paywall.title.brand")
                    .font(.system(size: titleSize, weight: .bold, design: .rounded))
                    .foregroundStyle(AppTheme.neonGreen)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .padding(.horizontal, closeButtonSize + 24)
                    .frame(width: geometry.size.width, height: closeButtonSize)
                    .offset(y: geometry[bounds].minY - closeButtonSize - closeBarVerticalPadding)
                    .accessibilityAddTraits(.isHeader)
            }
        }
        .clipped()
        .allowsHitTesting(false)
    }

    private func familyArtwork(endingAt bounds: Anchor<CGRect>?) -> some View {
        // Extend only to the close button's top. Scrolling moves the artwork
        // with the introduction; its size never depends on the scroll position.
        GeometryReader { geometry in
            if let bounds {
                let introduction = geometry[bounds]
                let topExtension = closeButtonSize + closeBarVerticalPadding
                let height = introduction.height + topExtension
                Image("onboardingFamily")
                    .resizable()
                    .scaledToFit()
                    .frame(width: min(introduction.width, 360), height: height)
                    .frame(width: introduction.width, height: height, alignment: .center)
                    .clipped()
                    .offset(x: introduction.minX, y: introduction.minY - topExtension)
            }
        }
        .opacity(0.24)
        .clipped()
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var header: some View {
        VStack(spacing: 8) {
            // Preserve the original title's layout space so all content below
            // stays in place; the visible title follows this block above it.
            Text("paywall.title.brand")
                .font(.system(size: titleSize, weight: .bold, design: .rounded))
                .foregroundStyle(AppTheme.neonGreen)
                .hidden()
                .accessibilityHidden(true)
            if let statusKey = access.statusKey {
                Text(LocalizedStringKey(statusKey))
                    .font(.system(.subheadline, design: .rounded, weight: .semibold))
                    .foregroundStyle(AppTheme.neonGreen)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("paywall.subtitle")
                .font(.system(size: bodySize, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.88))
        }
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var features: some View {
        VStack(alignment: .leading, spacing: 10) {
            feature("hourglass", "paywall.feature.limits")
            feature("calendar", "paywall.feature.schedules")
            feature("checkmark.seal", "paywall.feature.tasks")
            feature("location", "paywall.feature.location")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func feature(_ icon: String, _ key: LocalizedStringKey) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(AppTheme.neonGreen)
                .frame(width: 34, height: 34)
                .background(AppTheme.neonGreen.opacity(0.15), in: Circle())
                .accessibilityHidden(true)
            Text(key)
                .foregroundStyle(.white.opacity(0.9))
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: bodySize, weight: .semibold, design: .rounded))
    }

    private func priceLine(_ plan: ProPurchasePlan) -> String {
        guard let package = subscriptionService.package(for: plan) else {
            return String(localized: "paywall.price.loading")
        }
        let key = plan == .annual && offersTrial
            ? "paywall.price.annual_trial_format" : plan.priceKey
        return String(format: NSLocalizedString(key, comment: ""), package.storeProduct.localizedPriceString)
    }

    private func planCard(_ plan: ProPurchasePlan) -> some View {
        let selected = selectedPlan == plan
        return Button {
            selectedPlan = plan
            restoreStatusKey = nil
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                if plan == .annual {
                    annualBadges
                }
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(LocalizedStringKey(plan.titleKey))
                            .font(.system(size: planTitleSize, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                        if access.currentPlan == plan {
                            Text("paywall.plan.current")
                                .font(.system(.caption, design: .rounded, weight: .semibold))
                                .foregroundStyle(AppTheme.neonGreen)
                        }
                        Text(priceLine(plan))
                            .font(.system(size: priceSize, weight: .medium, design: .rounded))
                            .foregroundStyle(.white.opacity(0.75))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    ZStack {
                        Circle()
                            .stroke(selected ? AppTheme.neonGreen : .white.opacity(0.35), lineWidth: 2)
                        if selected {
                            Image(systemName: "checkmark")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(AppTheme.neonGreen)
                        }
                    }
                    .frame(width: 26, height: 26)
                    .accessibilityHidden(true)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 18))
            .overlay {
                RoundedRectangle(cornerRadius: 18)
                    .stroke(selected ? AppTheme.neonGreen : AppTheme.glassBorder.opacity(0.5),
                            lineWidth: selected ? 2 : 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 18))
        }
        .buttonStyle(.plain)
        .multilineTextAlignment(.leading)
        .disabled(subscriptionService.isLoading)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder private var annualBadges: some View {
        if offersTrial || annualSavings != nil {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    trialBadge
                    Spacer(minLength: 0)
                    savingsBadge
                }
                VStack(alignment: .leading, spacing: 8) {
                    trialBadge
                    savingsBadge
                }
            }
        }
    }

    @ViewBuilder private var trialBadge: some View {
        if offersTrial {
            PaywallTrialBadge()
        }
    }

    @ViewBuilder private var savingsBadge: some View {
        if let annualSavings {
            Text(String(format: String(localized: "paywall.badge.savings_format"),
                        PaywallSavings.approximateBadgePercent(annualSavings)))
                .font(.system(.caption2, design: .rounded, weight: .heavy))
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(Color.red.opacity(0.85), in: Capsule())
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityHint(Text("paywall.badge.savings_hint"))
        }
    }

    /// Keep the action and the selected price visible, including on compact phones.
    private var purchaseFooter: some View {
        VStack(spacing: 10) {
            switch access.action(for: selectedPlan) {
            case .none:
                EmptyView()
            case .retry:
                purchaseButton
            case .purchase:
                Text(priceLine(selectedPlan))
                    .font(.system(.caption, design: .rounded, weight: .medium))
                    .foregroundStyle(.white.opacity(0.8))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                purchaseButton
            }
            legalLinks
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .frame(maxWidth: 560)
        .frame(maxWidth: .infinity)
        .background(.ultraThinMaterial)
    }

    @ViewBuilder private var status: some View {
        if let error = subscriptionService.lastErrorMessage, !error.isEmpty {
            Text(error)
                .font(.footnote)
                .foregroundStyle(.orange)
                .multilineTextAlignment(.center)
            Button("paywall.retry") {
                Task {
                    if subscriptionService.isAwaitingServerConfirmation {
                        if await subscriptionService.retryPendingPurchaseConfirmation() { isPresented = false }
                    } else {
                        await refresh()
                    }
                }
            }
                .foregroundStyle(AppTheme.neonBlue)
                .disabled(busy)
        }
        if let restoreStatusKey {
            Text(LocalizedStringKey(restoreStatusKey))
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.8))
                .multilineTextAlignment(.center)
        }
    }

    private var purchaseButton: some View {
        Button {
            AppAnalytics.report("paywall_cta_tap", parameters: ["cta_type": hasTrial ? "start_trial" : "continue"])
            Task {
                restoreStatusKey = nil
                if subscriptionService.isAwaitingServerConfirmation {
                    if await subscriptionService.retryPendingPurchaseConfirmation() { isPresented = false }
                } else if let package = selectedPackage {
                    if await subscriptionService.purchase(package) { isPresented = false }
                }
            }
        } label: {
            HStack(spacing: 10) {
                if busy { ProgressView().tint(.white) }
                Text(subscriptionService.isAwaitingServerConfirmation ? "paywall.retry" :
                     (hasTrial ? "paywall.cta.start_trial" : "paywall.cta.continue"))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                if !busy {
                    Image(systemName: "chevron.forward")
                        .font(.system(size: 14, weight: .semibold))
                        .accessibilityHidden(true)
                }
            }
            .font(.system(.headline, design: .rounded, weight: .semibold))
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(NeonPrimaryButtonStyle(tint: AppTheme.neonGreen,
                                           shimmeringSheen: !reduceMotion && !busy && selectedPackage != nil))
        .disabled(busy || (!subscriptionService.isAwaitingServerConfirmation
            && (selectedPackage == nil || !subscriptionService.isConfigured)))
        .opacity(busy || (!subscriptionService.isAwaitingServerConfirmation && selectedPackage == nil) ? 0.55 : 1)
    }

    private var legalLinks: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) { legalLinkItems(showSeparators: true) }
            VStack(spacing: 10) { legalLinkItems(showSeparators: false) }
        }
        .font(.system(.caption, design: .rounded, weight: .medium))
        .foregroundStyle(AppTheme.neonBlue)
        .multilineTextAlignment(.center)
    }

    private var legalLinkSeparator: some View {
        Text(verbatim: "|")
            .foregroundStyle(.white.opacity(0.35))
            .accessibilityHidden(true)
    }

    @ViewBuilder private func legalLinkItems(showSeparators: Bool) -> some View {
        Link("paywall.legal.privacy", destination: RevenueCatConfig.privacyPolicyURL)
        if showSeparators { legalLinkSeparator }
        Button("paywall.legal.restore") {
            Task {
                restoreStatusKey = nil
                switch await subscriptionService.restorePurchases() {
                case .restored: restored = true
                case .pendingVerification: restoreStatusKey = nil
                case .noActiveSubscription: restoreStatusKey = "paywall.restore.result.none"
                case .failed: restoreStatusKey = "paywall.restore.result.failed"
                }
            }
        }
        .disabled(busy)
        if showSeparators { legalLinkSeparator }
        Link("paywall.legal.terms", destination: RevenueCatConfig.termsOfUseURL)
    }

    private func refresh() async {
        guard !busy else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        await subscriptionService.refreshForPaywall()
    }
}

private struct PaywallTrialBadge: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "gift.fill")
                .foregroundStyle(LinearGradient(
                    colors: [.yellow, .orange], startPoint: .topLeading, endPoint: .bottomTrailing))
                .accessibilityHidden(true)
            Text("paywall.badge.three_days_free")
                .foregroundStyle(.white)
        }
        .font(.system(.caption, design: .rounded, weight: .heavy))
        .textCase(.uppercase)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 11)
        .padding(.vertical, 6)
        .background {
            ZStack {
                LinearGradient(colors: [Color(red: 0.14, green: 0.11, blue: 0.08),
                                        Color(red: 0.07, green: 0.06, blue: 0.11)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                if !reduceMotion { ShimmeringLightSheen(opacity: 0.92) }
            }
            .clipShape(Capsule())
            .overlay { Capsule().stroke(.yellow.opacity(0.5), lineWidth: 1) }
        }
        .shadow(color: .orange.opacity(0.12), radius: 8, y: 2)
    }
}

#Preview {
    PaywallView(isPresented: .constant(true))
        .environmentObject(SubscriptionService())
}
