//
//  ParentalControlApp.swift
//  ParentalControl
//
//  Created by Vadzim Narbutovich on 03.03.2026.
//

import SwiftUI

@main
struct ParentalControlApp: App {
    @StateObject private var appState = AppState()
    @StateObject private var subscriptionService = SubscriptionService()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .environmentObject(appState.screenTimeService)
                .environmentObject(subscriptionService)
                .onAppear {
                    AppAnalytics.activateMetricaIfNeeded()
                }
                .onChange(of: scenePhase) { _, phase in
                    switch phase {
                    case .active:
                        appState.appDidBecomeActive()
                        Task { await subscriptionService.refreshAll() }
                    case .background:
                        appState.appDidEnterBackground()
                    case .inactive:
                        appState.appDidBecomeInactive()
                    @unknown default:
                        break
                    }
                }
        }
    }
}
