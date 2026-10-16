import CoreLocation
import FamilyControls
import SwiftUI

/// Each role completes setup here using the same operations and editors as Settings.
struct OnboardingFlowView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var screenTimeService: ScreenTimeService
    @EnvironmentObject private var subscriptionService: SubscriptionService
    @Environment(\.scenePhase) private var scenePhase

    /// Replay preserves existing pairing, permissions, limits and PIN.
    var onReplayFinished: (() -> Void)? = nil

    private enum Step: String {
        case parentIntro, childIntro, install, notifications, screenTime, location
        case pairing, pin, apps, protection, limit, finish
    }
    private enum Sheet: String, Identifiable {
        case share, pin, apps, protection, limit
        var id: String { rawValue }
    }

    @State private var stepIndex = 0
    @State private var isRequesting = false
    @State private var didRequestLocation = false
    @State private var didRequestScreenTime = false
    @State private var activeSheet: Sheet?
    @State private var showsPinEntry = false
    @State private var enteredParentModeForSetup = false

    private var isParent: Bool { appState.deviceRole == .parent }
    private var isLinked: Bool { appState.pairingState?.isLinked == true }
    private var steps: [Step] {
        isParent
            ? [.parentIntro, .notifications, .install, .pairing, .pin, .limit, .finish]
            : [.childIntro, .pairing, .screenTime, .notifications, .location, .pin, .apps, .protection, .limit, .finish]
    }
    private var step: Step { steps[min(stepIndex, steps.count - 1)] }
    private var busy: Bool {
        isRequesting || appState.isRefreshingSetup || screenTimeService.isAuthorizationRequestInProgress
    }
    private var pairingCode: String? { appState.parentPairingCode ?? appState.pairingState?.pairingCode }
    private var hasSelectedApps: Bool {
        !screenTimeService.selection.applicationTokens.isEmpty
            || !screenTimeService.selection.categoryTokens.isEmpty
            || !screenTimeService.selection.webDomainTokens.isEmpty
    }
    private var limitSeconds: Int? {
        isParent ? appState.parentBudgetStatus?.currentLimitSeconds : appState.dailyBudget?.policy.limitSeconds
    }
    private var isPermissionStep: Bool { [.screenTime, .notifications, .location].contains(step) }
    private var permissionGranted: Bool {
        switch step {
        case .screenTime: return screenTimeService.isAuthorized
        case .notifications: return appState.isNotificationAuthorized
        case .location: return appState.childLocationAuthorizationStatus == .authorizedAlways
        default: return true
        }
    }
    private var needsSettings: Bool {
        switch step {
        case .notifications: return appState.isNotificationAuthorizationDenied
        case .location:
            // A skipped/reset first permission must still show the system prompt,
            // even if this onboarding instance previously attempted a request.
            if appState.childLocationAuthorizationStatus == .notDetermined { return false }
            return didRequestLocation || appState.childLocationAuthorizationStatus == .denied
                || appState.childLocationAuthorizationStatus == .restricted
        default: return false
        }
    }
    private var canAdvance: Bool {
        if isPermissionStep { return permissionGranted }
        switch step {
        case .pairing: return isLinked
        case .pin: return isLinked && (isParent ? appState.parentPinIsSet : appState.isParentModeActive)
        case .apps: return isLinked && hasSelectedApps && screenTimeService.isAuthorized
        case .protection: return screenTimeService.isRemovalProtectionEnabled
        case .limit: return isLinked && limitSeconds != nil
        default: return true
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(L10n.tr(isParent ? "role.select.parent" : "role.select.child"))
                Spacer()
                Text("\(stepIndex + 1) / \(steps.count)").monospacedDigit()
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .padding(24)

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text(L10n.tr(titleKey))
                        .font(.largeTitle.bold())
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                    stepDescription
                        .font(.title3)
                        .fixedSize(horizontal: false, vertical: true)
                    stepControls
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }
            .id(step)
            .scrollIndicators(.hidden)
            .scrollDismissesKeyboard(.interactively)

            VStack(spacing: 12) {
                Button { performPrimaryAction() } label: {
                    HStack {
                        if busy { ProgressView().controlSize(.small) }
                        Text(L10n.tr(primaryActionKey))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .tint(AppTheme.neonBlue)
                .disabled(busy || (step == .pairing && isParent && !isLinked && pairingCode != nil)
                          || (step == .pairing && !isParent && !isLinked
                              && appState.pairingCodeInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))

                if !canAdvance {
                    Button("location.setup.later") { advance() }.disabled(busy)
                }
                if stepIndex > 0 {
                    Button("setup.back") { stepIndex -= 1 }.disabled(busy)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(red: 0.05, green: 0.08, blue: 0.12).ignoresSafeArea())
        .preferredColorScheme(.dark)
        .interactiveDismissDisabled(busy)
        .task { await appState.refreshPermissionStatuses() }
        .task(id: step) {
            // Only one explicit refresh on entry. No extra timers on either phone.
            if step == .pin || step == .limit { await appState.refreshSetupStatus() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task { await appState.refreshPermissionStatuses() }
            }
        }
        .onChange(of: appState.isParentModeActive) { _, active in
            if active { enteredParentModeForSetup = true }
            else if activeSheet == .apps || activeSheet == .protection { activeSheet = nil }
        }
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .share:
                ActivityShareSheet(items: [AppStoreLinks.shareURL])
            case .pin:
                ParentPinSetupSheet()
                    .environmentObject(appState)
                    .presentationDragIndicator(.visible)
            case .apps:
                BlockListView(selectionOnly: true)
                    .environmentObject(appState)
                    .environmentObject(screenTimeService)
                    .environmentObject(subscriptionService)
                    .presentationDragIndicator(.visible)
            case .protection:
                RemovalProtectionView()
                    .environmentObject(appState)
                    .environmentObject(screenTimeService)
            case .limit:
                DailyLimitSheet(policy: appState.parentBudgetStatus?.policy).environmentObject(appState)
            }
        }
        .fullScreenCover(isPresented: $showsPinEntry) {
            ParentModeEntryView(isPresented: $showsPinEntry).environmentObject(appState)
        }
        .onAppear {
            AppAnalytics.report("onboarding_flow_shown", parameters: [
                "mode": onReplayFinished == nil ? "first_launch" : "replay",
                "role": isParent ? "parent" : "child"
            ])
        }
    }

    @ViewBuilder
    private var stepControls: some View {
        if isPermissionStep {
            status(permissionGranted)
            if step == .screenTime && didRequestScreenTime && !permissionGranted {
                Text("permission.banner.screentime.body").foregroundStyle(.secondary)
            }
            if step == .location && needsSettings && !permissionGranted {
                Text("location.settings.description").foregroundStyle(.secondary)
            }
        }
        switch step {
        case .install:
            AppInstallQRCodeView()
            Button("settings.item.share_app", action: shareApp)
                .buttonStyle(.bordered)
        case .pairing:
            if isLinked {
                Text("settings.pairing.linked.status").foregroundStyle(AppTheme.neonGreen)
            } else {
                if isParent, let pairingCode {
                    Text(pairingCode).font(.largeTitle.monospaced().bold()).textSelection(.enabled)
                    Text("setup.link.wait").foregroundStyle(.secondary)
                    Button("settings.parent.link.generate") {
                        runOperation { await appState.createPairingCodeForParent() }
                    }.disabled(busy)
                } else if !isParent {
                    TextField(L10n.tr("settings.child.link.placeholder"), text: $appState.pairingCodeInput)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .textFieldStyle(.roundedBorder)
                        .disabled(busy)
                }
                if let message = appState.remoteStatusMessage {
                    Text(message).font(.subheadline).foregroundStyle(AppTheme.neonOrange)
                }
            }
        case .pin:
            status(isLinked && appState.parentPinIsSet)
            if !isLinked { linkRequired }
            if !isParent && appState.parentPinIsSet {
                Text("setup.pin.verify").foregroundStyle(.secondary)
            }
        case .apps:
            status(canAdvance)
            if !isLinked { linkRequired }
            else if !screenTimeService.isAuthorized {
                Button("onboarding.screentime.title") { go(to: .screenTime) }
            }
            if hasSelectedApps && isLinked {
                Button("blocklist.pick.apps") { openProtectedSheet(.apps) }.disabled(busy)
            }
        case .protection:
            status(screenTimeService.isRemovalProtectionEnabled)
            if !isLinked { linkRequired }
        case .limit:
            if let limitSeconds {
                Text(L10n.f("unit.minutes.short", limitSeconds / 60)).font(.title2.bold())
                if isParent {
                    if appState.parentBudgetStatus?.isPending == true {
                        Text("budget.pending").foregroundStyle(.secondary)
                    }
                    Button("budget.title") { activeSheet = .limit }.disabled(busy || !isLinked)
                }
            } else {
                Text("budget.not_set").foregroundStyle(.secondary)
            }
            if !isLinked { linkRequired }
        case .finish:
            summary
        default: EmptyView()
        }
    }

    @ViewBuilder
    private var stepDescription: some View {
        if step == .install {
            Text(installDescription)
                .tint(AppTheme.neonBlue)
                .environment(\.openURL, OpenURLAction { url in
                    guard url == AppStoreLinks.shareURL else { return .systemAction }
                    shareApp()
                    return .handled
                })
        } else {
            Text(L10n.tr(bodyKey))
        }
    }

    private var installDescription: AttributedString {
        let text = L10n.f("setup.install.body", AppStoreLinks.shareURL.absoluteString)
        return (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(text)
    }

    private func shareApp() {
        AppAnalytics.report("onboarding_share_app")
        activeSheet = .share
    }

    private var linkRequired: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("setup.link.required").foregroundStyle(.secondary)
            Button("setup.pairing.title") { go(to: .pairing) }.disabled(busy)
        }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 16) {
            summaryRow("setup.pairing.title", ready: isLinked, target: .pairing)
            summaryRow("settings.pin.section", ready: isLinked && appState.parentPinIsSet, target: .pin)
            summaryRow("onboarding.notifications.title", ready: appState.isNotificationAuthorized, target: .notifications)
            if !isParent {
                summaryRow("onboarding.screentime.title", ready: screenTimeService.isAuthorized, target: .screenTime)
                summaryRow("onboarding.location.title",
                           ready: appState.childLocationAuthorizationStatus == .authorizedAlways, target: .location)
                summaryRow("blocklist.pick.apps", ready: isLinked && hasSelectedApps && screenTimeService.isAuthorized, target: .apps)
                summaryRow("protection.title", ready: screenTimeService.isRemovalProtectionEnabled, target: .protection)
            }
            summaryRow("budget.title", ready: isLinked && limitSeconds != nil, target: .limit)
            if isParent && appState.parentBudgetStatus?.isPending == true {
                Text("budget.pending").foregroundStyle(.secondary)
            }
        }
    }

    private func status(_ ready: Bool) -> some View {
        Text(L10n.tr(ready ? "setup.status.ready" : "setup.status.pending"))
            .font(.headline)
            .foregroundStyle(ready ? AppTheme.neonGreen : AppTheme.neonOrange)
    }

    private func summaryRow(_ title: String, ready: Bool, target: Step) -> some View {
        Button { go(to: target) } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.tr(title)).font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                Text(L10n.tr(ready ? "setup.status.ready" : "setup.status.pending"))
                    .font(.subheadline)
                    .foregroundStyle(ready ? AppTheme.neonGreen : AppTheme.neonOrange)
            }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

    private var titleKey: String {
        switch step {
        case .parentIntro: return "setup.parent.title"
        case .childIntro: return "setup.child.title"
        case .install: return "setup.install.title"
        case .screenTime: return "onboarding.screentime.title"
        case .notifications: return "onboarding.notifications.title"
        case .location: return "onboarding.location.title"
        case .pairing: return "setup.pairing.title"
        case .pin: return "settings.pin.section"
        case .apps: return "blocklist.pick.apps"
        case .protection: return "protection.title"
        case .limit: return "budget.title"
        case .finish: return "setup.check.title"
        }
    }

    private var bodyKey: String {
        switch step {
        case .parentIntro: return "setup.parent.body"
        case .childIntro: return "setup.child.body"
        case .install: return "setup.install.body"
        case .screenTime: return "setup.screen_time.body"
        case .notifications:
            return isParent ? "permission.notifications.parent.body" : "setup.notifications.child.body"
        case .location: return "setup.location.body"
        case .pairing: return isParent ? "setup.link.parent" : "setup.link.child"
        case .pin: return isParent ? "setup.pin.parent" : "setup.pin.child"
        case .apps: return "setup.apps.body"
        case .protection: return "setup.protection.action_body"
        case .limit: return isParent ? "budget.explanation" : "setup.limit.child"
        case .finish: return isParent ? "setup.check.parent" : "setup.check.child"
        }
    }

    private var primaryActionKey: String {
        if step == .finish { return "setup.finish.action" }
        if canAdvance { return "onboarding.cta.next" }
        if isPermissionStep {
            if needsSettings { return "permission.banner.open_settings" }
            return step == .location ? "location.setup.allow" : "permission.banner.allow"
        }
        switch step {
        case .pairing:
            return isParent ? (pairingCode == nil ? "settings.parent.link.generate" : "setup.link.wait")
                : "settings.child.link.connect"
        case .pin:
            if !isLinked { return "setup.pairing.title" }
            return isParent ? "settings.pin.set" : (appState.parentPinIsSet ? "setup.pin.enter" : "setup.refresh")
        case .apps:
            if !isLinked { return "setup.pairing.title" }
            return screenTimeService.isAuthorized ? "blocklist.pick.apps" : "onboarding.screentime.title"
        case .protection: return "protection.enable"
        case .limit:
            if !isLinked { return "setup.pairing.title" }
            return isParent ? "budget.title" : "setup.refresh"
        default: return "onboarding.cta.next"
        }
    }

    private func performPrimaryAction() {
        guard !busy else { return }
        if canAdvance { advance(); return }
        if isPermissionStep {
            if needsSettings { appState.openAppSettingsURL(); return }
            let requestedStep = step
            runOperation {
                AppAnalytics.report("onboarding_permission_request", parameters: [
                    "permission": requestedStep.rawValue, "role": isParent ? "parent" : "child"
                ])
                switch requestedStep {
                case .screenTime:
                    didRequestScreenTime = true
                    await appState.requestScreenTimeAccessOnly()
                case .notifications: await appState.requestNotificationAccessOnly()
                case .location:
                    didRequestLocation = true
                    let result = await appState.requestChildLocationPermissionIfNeeded()
                    if result == .authorizedWhenInUse {
                        _ = await appState.requestChildLocationAlwaysAuthorizationIfNeeded()
                    }
                default: break
                }
                await appState.refreshPermissionStatuses()
            }
            return
        }
        switch step {
        case .pairing:
            runOperation {
                if isParent { await appState.createPairingCodeForParent() }
                else { await appState.connectChildWithPairingCode() }
            }
        case .pin:
            guard isLinked else { go(to: .pairing); return }
            if isParent { activeSheet = .pin }
            else if appState.parentPinIsSet { showsPinEntry = true }
            else { runOperation { await appState.refreshSetupStatus() } }
        case .apps:
            guard isLinked else { go(to: .pairing); return }
            guard screenTimeService.isAuthorized else { go(to: .screenTime); return }
            openProtectedSheet(.apps)
        case .protection: openProtectedSheet(.protection)
        case .limit:
            guard isLinked else { go(to: .pairing); return }
            if isParent { activeSheet = .limit }
            else { runOperation { await appState.refreshSetupStatus() } }
        default: break
        }
    }

    private func openProtectedSheet(_ sheet: Sheet) {
        guard isLinked else { go(to: .pairing); return }
        guard appState.parentPinIsSet else { go(to: .pin); return }
        guard appState.isParentModeActive else { showsPinEntry = true; return }
        activeSheet = sheet
    }

    private func runOperation(_ operation: @escaping @MainActor () async -> Void) {
        guard !busy else { return }
        isRequesting = true
        Task { @MainActor in
            defer { isRequesting = false }
            await operation()
        }
    }

    private func go(to target: Step) {
        if let index = steps.firstIndex(of: target) { stepIndex = index }
    }

    private func advance() {
        if stepIndex + 1 < steps.count { stepIndex += 1 }
        else {
            AppAnalytics.report("onboarding_closed", parameters: [
                "mode": onReplayFinished == nil ? "first_launch" : "replay",
                "role": isParent ? "parent" : "child"
            ])
            // Do not leave the child's phone unlocked for changing parent settings.
            if enteredParentModeForSetup { appState.exitParentMode() }
            if let onReplayFinished { onReplayFinished() } else { appState.completeOnboarding() }
        }
    }
}
