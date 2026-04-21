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
                if role == .child {
                    if appState.hasCompletedOnboarding {
                        ZStack(alignment: .top) {
                            MainTabView()
                                .environmentObject(subscriptionService)
                            PermissionReminderBannerView()
                        }
                    } else {
                        OnboardingFlowView()
                    }
                } else {
                    MainTabView()
                }
            } else {
                RoleSelectionView()
            }
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
        ZStack {
            AppBackgroundView()
            VStack(spacing: 18) {
                Spacer()
                Text("role.select.title")
                    .font(.largeTitle.bold())
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
                Text("role.select.subtitle")
                    .font(.headline)
                    .foregroundStyle(.white.opacity(0.85))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
                Spacer()
                Button("role.select.parent") {
                    appState.chooseDeviceRole(.parent)
                }
                .buttonStyle(NeonPrimaryButtonStyle(tint: AppTheme.neonBlue))
                Button("role.select.child") {
                    appState.chooseDeviceRole(.child)
                }
                .buttonStyle(NeonPrimaryButtonStyle(tint: AppTheme.neonGreen))
                Spacer(minLength: 28)
            }
            .padding(.horizontal, 20)
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(AppState())
        .environmentObject(ScreenTimeService(appStore: AppGroupStore()))
        .environmentObject(SubscriptionService())
}
