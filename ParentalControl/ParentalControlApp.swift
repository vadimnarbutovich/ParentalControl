//
//  ParentalControlApp.swift
//  ParentalControl
//
//  Created by Vadzim Narbutovich on 03.03.2026.
//

import SwiftUI
import BackgroundTasks
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
                    appDelegate.attach(appState: appState)
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
                        appDelegate.scheduleChildRefreshIfNeeded()
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
    private let refreshIdentifier = AppState.childBackgroundRefreshTaskIdentifier
    private var refreshTask: Task<Void, Never>?
    private let storage = AppGroupStore()
    weak var appState: AppState?

    func attach(appState: AppState) {
        self.appState = appState
    }

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: refreshIdentifier, using: nil) { [weak self] task in
            guard let self, let refresh = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            self.handleChildRefreshTask(refresh)
        }
        return true
    }

    func scheduleChildRefreshIfNeeded() {
        guard storage.loadDeviceRole() == .child, storage.loadPairingState()?.isLinked == true else { return }
        let request = BGAppRefreshTaskRequest(identifier: refreshIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            // Best-effort: iOS may reject duplicates or tight scheduling.
        }
    }

    private func handleChildRefreshTask(_ task: BGAppRefreshTask) {
        scheduleChildRefreshIfNeeded()
        refreshTask?.cancel()
        refreshTask = Task { @MainActor [weak self] in
            guard let self else {
                task.setTaskCompleted(success: false)
                return
            }
            let success = await self.appState?.performChildBackgroundRefreshSync() ?? false
            task.setTaskCompleted(success: success)
        }
        task.expirationHandler = { [weak self] in
            self?.refreshTask?.cancel()
        }
    }

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
