import FamilyControls
import SwiftUI
import UIKit

struct BlockListView: View {
    /// Onboarding reuses the same picker, persistence and subscription limits.
    var selectionOnly = false
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var screenTimeService: ScreenTimeService
    @EnvironmentObject private var subscriptionService: SubscriptionService
    @State private var showingPicker = false
    @State private var showPaywall = false
    @State private var selectionBeforePicker = FamilyActivitySelection()
    @State private var setupSelection = FamilyActivitySelection()

    private var isChildControlPaused: Bool {
        appState.deviceRole == .child && !appState.isFamilyAccessAllowed
    }

    // Initial setup still permits choosing apps; an expired subscription does not.
    private var isChildSelectionPaused: Bool {
        isChildControlPaused && !FamilyAccessStore.isSettingUp
    }

    private var pausedControlNotice: some View {
        Text("access.paused")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AppBackgroundView(usesSharedCanvas: !selectionOnly)

                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("blocklist.title")
                            .font(.largeTitle.bold())
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        if !selectionOnly || appState.isParentModeActive {
                            selectedAppsSection
                        } else {
                            Text("parent_mode.entry.title")
                        }
                        if !selectionOnly { manualBlockSliderSection }
                        #if DEBUG && !HIDE_DEBUG_UI
                        if !selectionOnly { debugSection }
                        #endif
                    }
                    .padding()
                }
            }
            .scrollIndicators(.hidden)
            .toolbar {
                if selectionOnly {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("exercise.done") { dismiss() }
                            .tint(.white)
                    }
                }
            }
            .familyActivityPicker(
                isPresented: $showingPicker,
                selection: Binding(
                    get: { selectionOnly ? setupSelection : screenTimeService.selection },
                    set: {
                        if selectionOnly { setupSelection = $0 }
                        else { screenTimeService.selection = $0 }
                    }
                )
            )
            .onChange(of: showingPicker) { _, isPresented in
                if isPresented {
                    selectionBeforePicker = screenTimeService.selection
                    return
                }
                guard !selectionOnly || appState.isParentModeActive else {
                    return
                }
                let sel = selectionOnly ? setupSelection : screenTimeService.selection
                if !appState.requireFamilyConfigurationAccess() {
                    screenTimeService.selection = selectionBeforePicker
                    AppAnalytics.report("blocklist_picker_dismissed", parameters: ["action": "blocked_limit"])
                    return
                }
                AppAnalytics.report(
                    "blocklist_picker_dismissed",
                    parameters: [
                        "apps_count": sel.applicationTokens.count,
                        "categories_count": sel.categoryTokens.count,
                        "domains_count": sel.webDomainTokens.count,
                    ]
                )
                if selectionOnly { screenTimeService.selection = sel }
                appState.saveScreenSelection()
            }
            #if DEBUG && !HIDE_DEBUG_UI
            .task {
                guard !selectionOnly else { return }
                while !Task.isCancelled {
                    appState.refreshDeviceActivityDebug()
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                }
            }
            #endif
            .onChange(of: appState.isParentModeActive) { _, active in
                if selectionOnly && !active {
                    showingPicker = false
                    showPaywall = false
                }
            }
            .fullScreenCover(isPresented: $showPaywall) {
                PaywallView(isPresented: $showPaywall, openSource: .limitedFeature)
                    .environmentObject(subscriptionService)
            }
        }
    }

    private var selectedAppsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "app.badge.checkmark")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(AppTheme.neonBlue)
                Text("blocklist.selected.header")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.95))
            }

            if screenTimeService.selection.applicationTokens.isEmpty &&
                screenTimeService.selection.categoryTokens.isEmpty &&
                screenTimeService.selection.webDomainTokens.isEmpty {
                Text("blocklist.selected.empty")
                    .foregroundStyle(.secondary)
                    .font(.footnote)
                    .padding(.top, 2)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(screenTimeService.selection.applicationTokens), id: \.self) { token in
                        Label(token)
                            .labelStyle(.titleAndIcon)
                            .foregroundStyle(.white)
                    }

                    if !screenTimeService.selection.categoryTokens.isEmpty {
                        ForEach(Array(screenTimeService.selection.categoryTokens), id: \.self) { token in
                            Label(token)
                                .labelStyle(.titleAndIcon)
                                .foregroundStyle(.white)
                        }
                    }

                    if !screenTimeService.selection.webDomainTokens.isEmpty {
                        ForEach(Array(screenTimeService.selection.webDomainTokens), id: \.self) { token in
                            Label(token)
                                .labelStyle(.titleAndIcon)
                                .foregroundStyle(.white)
                        }
                    }
                }
                .padding(.top, 2)
            }

            if !subscriptionService.isPro && appState.deviceRole == .parent {
                Button {
                    showPaywall = true
                } label: {
                    Text("settings.premium.unlock_all")
                        .font(.footnote)
                        .foregroundStyle(AppTheme.neonOrange.opacity(0.85))
                        .underline()
                }
                .buttonStyle(.plain)
                .padding(.top, 2)
            }

            Button("blocklist.pick.apps") {
                guard appState.requireFamilyConfigurationAccess() else { return }
                AppAnalytics.report("blocklist_pick_apps_tap")
                if selectionOnly { setupSelection = screenTimeService.selection }
                showingPicker = true
            }
            .buttonStyle(NeonPrimaryButtonStyle(tint: AppTheme.neonGreen))
            .disabled(isChildSelectionPaused)
            .opacity(isChildSelectionPaused ? 0.45 : 1)
            .padding(.top, 4)
            if isChildSelectionPaused { pausedControlNotice }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .glassCard(cornerRadius: 24, glowColor: AppTheme.neonBlue)
    }

    private var manualBlockSliderSection: some View {
        VStack(spacing: 10) {
            ActionSlideButton(
                isOn: appState.isFocusSessionActive,
                inactiveTitle: "parent.dashboard.start_focus",
                activeTitle: "parent.dashboard.stop_focus",
                inactiveSymbol: "lock.fill",
                activeSymbol: "lock.open.fill",
                activeTint: AppTheme.neonRed,
                isEnabled: appState.isParentModeActive && appState.pairingState?.isLinked == true
                    && appState.isFamilyAccessAllowed && !appState.isLocalManualBlockSyncing,
                onActivate: { appState.setLocalManualBlock(active: true) },
                onDeactivate: { appState.setLocalManualBlock(active: false) }
            )
            if isChildControlPaused {
                pausedControlNotice
            } else if let notice = appState.localManualBlockNotice {
                Text(notice)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    #if DEBUG && !HIDE_DEBUG_UI
    private var debugSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("blocklist.debug.title")
                .font(.headline)
                .foregroundStyle(.white)
            Text(L10n.f("blocklist.debug.count", appState.deviceActivityDebug.heartbeatCount))
                .font(.footnote)
                .foregroundStyle(.secondary)
            Text(
                L10n.f(
                    "blocklist.debug.last_event",
                    appState.deviceActivityDebug.lastEvent ?? L10n.tr("blocklist.debug.none")
                )
            )
            .font(.footnote)
            .foregroundStyle(.secondary)
            Text(
                L10n.f(
                    "blocklist.debug.last_time",
                    appState.deviceActivityDebug.lastHeartbeatAt?.formatted(date: .omitted, time: .standard) ??
                        L10n.tr("blocklist.debug.none")
                )
            )
            .font(.footnote)
            .foregroundStyle(.secondary)
            Text(L10n.f("blocklist.debug.warning_count", appState.deviceActivityDebug.warningCount))
                .font(.footnote)
                .foregroundStyle(.secondary)
            Text(L10n.f("blocklist.debug.threshold_count", appState.deviceActivityDebug.thresholdCount))
                .font(.footnote)
                .foregroundStyle(.secondary)
            Text(L10n.f("blocklist.debug.last_trigger", appState.deviceActivityDebug.lastTrigger ?? L10n.tr("blocklist.debug.none")))
                .font(.footnote)
                .foregroundStyle(.secondary)
            Text(L10n.f("blocklist.debug.threshold_seconds", appState.deviceActivityDebug.thresholdSeconds))
                .font(.footnote)
                .foregroundStyle(.secondary)
            Text(L10n.f("blocklist.debug.last_spent_delta", appState.deviceActivityDebug.lastSpentDelta))
                .font(.footnote)
                .foregroundStyle(.secondary)
            Text(L10n.f("blocklist.debug.available_before", appState.deviceActivityDebug.lastAvailableBefore))
                .font(.footnote)
                .foregroundStyle(.secondary)
            Text(L10n.f("blocklist.debug.available_after", appState.deviceActivityDebug.lastAvailableAfter))
                .font(.footnote)
                .foregroundStyle(.secondary)
            Text(L10n.f("blocklist.debug.restart_count", appState.deviceActivityDebug.restartCount))
                .font(.footnote)
                .foregroundStyle(.secondary)
            Text(
                L10n.f(
                    "blocklist.debug.last_start_monitoring",
                    appState.deviceActivityDebug.lastStartMonitoringAt?.formatted(date: .omitted, time: .standard) ??
                        L10n.tr("blocklist.debug.none")
                )
            )
            .font(.footnote)
            .foregroundStyle(.secondary)
            Text(
                L10n.f(
                    "blocklist.debug.last_consumption",
                    appState.deviceActivityDebug.lastConsumptionAt?.formatted(date: .omitted, time: .standard) ??
                        L10n.tr("blocklist.debug.none")
                )
            )
            .font(.footnote)
            .foregroundStyle(.secondary)
            Text(L10n.f("blocklist.debug.mirror_earned", appState.deviceActivityDebug.mirrorEarnedSeconds))
                .font(.footnote)
                .foregroundStyle(.secondary)
            Text(L10n.f("blocklist.debug.mirror_spent", appState.deviceActivityDebug.mirrorSpentSeconds))
                .font(.footnote)
                .foregroundStyle(.secondary)
            Button("blocklist.debug.refresh") {
                appState.refreshSharedStateFromAppGroup()
            }
            .buttonStyle(SecondaryButtonStyle())
            Button("blocklist.debug.copy_report") {
                UIPasteboard.general.string = appState.diagnosticsReport()
            }
            .buttonStyle(SecondaryButtonStyle())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .glassCard(cornerRadius: 22, glowColor: AppTheme.neonBlue)
        .padding(36)
        .drawingGroup()
        .padding(-36)
    }
    #endif

}

#if DEBUG && !HIDE_DEBUG_UI
private struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                Color.white.opacity(configuration.isPressed ? 0.06 : 0.12),
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .foregroundStyle(.white)
    }
}
#endif

#Preview {
    let state = AppState()
    return BlockListView()
        .environmentObject(state)
        .environmentObject(state.screenTimeService)
}
