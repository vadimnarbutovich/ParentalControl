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
            if appState.hasCompletedOnboarding {
                ZStack(alignment: .top) {
                    MainTabView()
                        .environmentObject(subscriptionService)
                    PermissionReminderBannerView()
                }
            } else {
                OnboardingFlowView()
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

#Preview {
    ContentView()
        .environmentObject(AppState())
        .environmentObject(ScreenTimeService(appStore: AppGroupStore()))
        .environmentObject(SubscriptionService())
}
