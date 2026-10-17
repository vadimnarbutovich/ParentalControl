//
//  ContentView.swift
//  ParentalControl
//
//  Created by Vadzim Narbutovich on 03.03.2026.
//

import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var subscriptionService: SubscriptionService

    var body: some View {
        Group {
            if let role = appState.deviceRole {
                if appState.hasCompletedOnboarding {
                    MainTabView()
                        .environmentObject(subscriptionService)
                } else {
                    OnboardingFlowView()
                        .id(role)
                }
            } else {
                RoleSelectionView()
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            PermissionReminderBannerView()
        }
        .onChange(of: subscriptionService.isPro) { _, isPro in
            appState.enforcePremiumFeatures(isPro: isPro, isStatusKnown: subscriptionService.isSubscriptionStatusKnown)
        }
        .onChange(of: subscriptionService.isSubscriptionStatusKnown) { _, isKnown in
            appState.enforcePremiumFeatures(isPro: subscriptionService.isPro, isStatusKnown: isKnown)
        }
    }
}

private struct RoleSelectionView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 24) {
                    OnboardingFamilyIllustration(tint: AppTheme.neonBlue,
                                                 compact: geometry.size.height < 700)
                    VStack(spacing: 14) {
                        Text("role.select.title")
                            .font(.system(.largeTitle, design: .rounded, weight: .bold))
                            .foregroundStyle(.white)
                            .accessibilityAddTraits(.isHeader)
                        Text("role.select.subtitle")
                            .font(.body)
                            .foregroundStyle(.white.opacity(0.7))
                    }
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    VStack(spacing: 14) {
                        roleCard("role.select.parent", symbol: "person.crop.circle", tint: AppTheme.neonBlue) {
                            appState.chooseDeviceRole(.parent)
                        }
                        roleCard("role.select.child", symbol: "iphone", tint: AppTheme.neonGreen) {
                            appState.chooseDeviceRole(.child)
                        }
                    }
                }
                .frame(maxWidth: 560)
                .padding(.horizontal, 20)
                .padding(.vertical, 32)
                .frame(maxWidth: .infinity, minHeight: geometry.size.height)
            }
            .scrollIndicators(.hidden)
        }
        .background(AppBackgroundView())
        .preferredColorScheme(.dark)
    }

    private func roleCard(_ title: String, symbol: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 16) {
                Image(systemName: symbol)
                    .font(.system(size: 26, weight: .medium))
                    .foregroundStyle(tint)
                    .frame(width: 52, height: 52)
                    .background(tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 16))
                    .accessibilityHidden(true)
                Text(L10n.tr(title))
                    .font(.system(.title3, design: .rounded, weight: .semibold))
                    .foregroundStyle(.white)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
                Image(systemName: "chevron.forward")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(tint)
                    .accessibilityHidden(true)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassCard(cornerRadius: 24, glowColor: tint, drawsOuterShadows: false)
            .contentShape(RoundedRectangle(cornerRadius: 24))
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    ContentView()
        .environmentObject(AppState())
        .environmentObject(ScreenTimeService(appStore: AppGroupStore()))
        .environmentObject(SubscriptionService())
}
