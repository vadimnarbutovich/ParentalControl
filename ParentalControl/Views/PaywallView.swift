import RevenueCat
import SwiftUI

/// Store prices and introductory eligibility come from RevenueCat / StoreKit.
/// Showing this screen does not enable paid feature restrictions.
struct PaywallView: View {
    @EnvironmentObject private var subscriptionService: SubscriptionService
    @Binding var isPresented: Bool
    var openSource: PaywallOpenSource = .settings

    @State private var selectedPlan: ProPurchasePlan = .annual
    @State private var isRefreshing = false
    @State private var restoreStatusKey: String?
    @State private var restored = false

    private var selectedPackage: Package? { subscriptionService.package(for: selectedPlan) }
    private var hasTrial: Bool { selectedPlan == .annual && subscriptionService.annualTrialEligible }
    private var busy: Bool { subscriptionService.isLoading || isRefreshing }

    var body: some View {
        ZStack {
            AppBackgroundView()
            ScrollView {
                VStack(spacing: 24) {
                    header
                    features
                    VStack(spacing: 12) {
                        ForEach(ProPurchasePlan.allCases) { plan in planCard(plan) }
                    }
                    status
                    if subscriptionService.hasLifetimeAccess {
                        Text("settings.premium.active")
                            .font(.headline)
                            .foregroundStyle(AppTheme.neonGreen)
                    } else {
                        purchaseButton
                    }
                    legalLinks
                    Text(selectedPlan == .lifetime
                         ? "paywall.legal.lifetime_disclaimer"
                         : "paywall.legal.subscription_disclaimer")
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.65))
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 28)
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.hidden)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            HStack {
                Spacer()
                Button { isPresented = false } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .background(.white.opacity(0.08), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("paywall.close"))
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 6)
        }
        .preferredColorScheme(.dark)
        .task { await refresh() }
        .onAppear {
            AppAnalytics.report("paywall_open", parameters: ["source": openSource.rawValue])
        }
        .alert(Text("paywall.restore.result.restored"), isPresented: $restored) {
            Button("OK") { isPresented = false }
        }
    }

    private var header: some View {
        VStack(spacing: 12) {
            Image(systemName: "person.2.fill")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(AppTheme.neonGreen)
                .frame(width: 64, height: 64)
                .background(AppTheme.neonGreen.opacity(0.12), in: RoundedRectangle(cornerRadius: 22))
                .accessibilityHidden(true)
            Text("paywall.title.brand")
                .font(.system(.largeTitle, design: .rounded, weight: .bold))
                .foregroundStyle(.white)
            Text("paywall.subtitle")
                .font(.body)
                .foregroundStyle(.white.opacity(0.8))
        }
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var features: some View {
        VStack(alignment: .leading, spacing: 14) {
            feature("hourglass", "paywall.feature.limits")
            feature("calendar", "paywall.feature.schedules")
            feature("checkmark.seal", "paywall.feature.tasks")
            feature("location", "paywall.feature.location")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func feature(_ icon: String, _ key: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(AppTheme.neonGreen)
                .frame(width: 24)
                .accessibilityHidden(true)
            Text(key)
                .foregroundStyle(.white.opacity(0.9))
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.subheadline)
    }

    private func priceLine(_ plan: ProPurchasePlan) -> String {
        guard let package = subscriptionService.package(for: plan) else {
            return String(localized: "paywall.price.loading")
        }
        let key = plan == .annual && subscriptionService.annualTrialEligible
            ? "paywall.price.annual_trial_format" : plan.priceKey
        return String(format: NSLocalizedString(key, comment: ""), package.storeProduct.localizedPriceString)
    }

    private func planCard(_ plan: ProPurchasePlan) -> some View {
        let selected = selectedPlan == plan
        return Button {
            selectedPlan = plan
            restoreStatusKey = nil
        } label: {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(LocalizedStringKey(plan.titleKey))
                        .font(.system(.headline, design: .rounded))
                        .foregroundStyle(.white)
                    Text(priceLine(plan))
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.8))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.title2)
                    .foregroundStyle(selected ? AppTheme.neonGreen : .white.opacity(0.35))
                    .accessibilityHidden(true)
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? AppTheme.neonGreen.opacity(0.09) : .white.opacity(0.05),
                        in: RoundedRectangle(cornerRadius: 20))
            .overlay {
                RoundedRectangle(cornerRadius: 20)
                    .stroke(selected ? AppTheme.neonGreen : AppTheme.glassBorder.opacity(0.5),
                            lineWidth: selected ? 2 : 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 20))
        }
        .buttonStyle(.plain)
        .multilineTextAlignment(.leading)
        .disabled(subscriptionService.isLoading)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder private var status: some View {
        if let error = subscriptionService.lastErrorMessage, !error.isEmpty {
            Text(error)
                .font(.footnote)
                .foregroundStyle(.orange)
                .multilineTextAlignment(.center)
            Button("paywall.retry") { Task { await refresh() } }
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
            guard let package = selectedPackage else { return }
            AppAnalytics.report("paywall_cta_tap", parameters: ["cta_type": hasTrial ? "start_trial" : "continue"])
            Task {
                restoreStatusKey = nil
                if await subscriptionService.purchase(package) { isPresented = false }
            }
        } label: {
            HStack(spacing: 10) {
                if busy { ProgressView().tint(.white) }
                Text(hasTrial ? "paywall.cta.start_trial" : "paywall.cta.continue")
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(NeonPrimaryButtonStyle(tint: AppTheme.neonGreen, shimmeringSheen: !busy && selectedPackage != nil))
        .disabled(busy || selectedPackage == nil || !subscriptionService.isConfigured)
        .opacity(busy || selectedPackage == nil ? 0.55 : 1)
    }

    private var legalLinks: some View {
        VStack(spacing: 16) {
            Button("paywall.legal.restore") {
                Task {
                    restoreStatusKey = nil
                    switch await subscriptionService.restorePurchases() {
                    case .restored: restored = true
                    case .noActiveSubscription: restoreStatusKey = "paywall.restore.result.none"
                    case .failed: restoreStatusKey = "paywall.restore.result.failed"
                    }
                }
            }
            .disabled(busy)
            Link("paywall.legal.privacy", destination: RevenueCatConfig.privacyPolicyURL)
            Link("paywall.legal.terms", destination: RevenueCatConfig.termsOfUseURL)
        }
        .font(.footnote)
        .foregroundStyle(AppTheme.neonBlue)
        .multilineTextAlignment(.center)
    }

    private func refresh() async {
        guard !busy else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        await subscriptionService.refreshAll()
    }
}

#Preview {
    PaywallView(isPresented: .constant(true))
        .environmentObject(SubscriptionService())
}
