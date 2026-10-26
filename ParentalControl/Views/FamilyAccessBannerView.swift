import SwiftUI

struct FamilyAccessBannerView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var subscriptionService: SubscriptionService

    private var presentation: FamilyAccessBannerPresentation {
        .resolve(allowed: appState.isFamilyAccessAllowed,
                 isParent: appState.deviceRole == .parent,
                 awaitingPurchase: subscriptionService.isAwaitingServerConfirmation,
                 leaseState: FamilyAccessStore.receipt?.lease.state,
                 statusConfirmed: appState.isFamilyAccessStatusConfirmedForBanner)
    }

    var body: some View {
        let state = presentation
        if state != .hidden {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: state.symbolName)
                        .font(.title3)
                        .foregroundStyle(AppTheme.neonOrange)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L10n.tr(state.titleKey))
                            .font(.system(.subheadline, design: .rounded, weight: .bold))
                            .foregroundStyle(.white)
                            .accessibilityAddTraits(.isHeader)
                        Text(L10n.tr(state.messageKey))
                            .font(.footnote)
                            .foregroundStyle(.white.opacity(0.8))
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                if let action = state.action {
                    Button {
                        switch action {
                        case .paywall:
                            _ = appState.requireFamilyAccess()
                        }
                    } label: {
                        Text(L10n.tr(state.buttonKey))
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 12)
                    }
                    .buttonStyle(NeonPrimaryButtonStyle(tint: AppTheme.neonGreen))
                }
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color(red: 0.07, green: 0.11, blue: 0.18))
                    .overlay {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(AppTheme.neonOrange.opacity(0.45), lineWidth: 1)
                    }
            )
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            // Real layout height above TabView, not an overlay or a fixed inset.
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}
