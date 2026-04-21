//
//  ParentalControlApp.swift
//  ParentalControl
//
//  Created by Vadzim Narbutovich on 03.03.2026.
//

import SwiftUI
import UIKit
import UserNotifications

@main
struct ParentalControlApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
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
                    UNUserNotificationCenter.current().delegate = appDelegate
                    UIApplication.shared.registerForRemoteNotifications()
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

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        NotificationCenter.default.post(name: AppState.didRegisterAPNSTokenNotification, object: token)
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        // Registration can fail on simulator or when APNs is not configured.
    }

    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        NotificationCenter.default.post(name: AppState.didReceiveRemotePayloadNotification, object: userInfo)
        completionHandler(.newData)
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        NotificationCenter.default.post(
            name: AppState.didReceiveRemotePayloadNotification,
            object: notification.request.content.userInfo
        )
        completionHandler([.banner, .sound])
    }
}
