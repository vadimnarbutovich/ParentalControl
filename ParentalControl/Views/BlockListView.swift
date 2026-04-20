import FamilyControls
import SwiftUI
import UIKit

struct BlockListView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var screenTimeService: ScreenTimeService
    @EnvironmentObject private var subscriptionService: SubscriptionService
    @State private var showingPicker = false
    @State private var showPaywall = false
    @State private var selectionBeforePicker = FamilyActivitySelection()

    var body: some View {
        NavigationStack {
            ZStack {
                AppBackgroundView()

                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("blocklist.title")
                            .font(.largeTitle.bold())
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        selectedAppsSection
                        monitoringSliderSection
                        #if DEBUG && !HIDE_DEBUG_UI
                        debugSection
                        #endif
                    }
                    .padding()
                }
            }
            .scrollIndicators(.hidden)
            .familyActivityPicker(
                isPresented: $showingPicker,
                selection: Binding(
                    get: { screenTimeService.selection },
                    set: { screenTimeService.selection = $0 }
                )
            )
            .onChange(of: showingPicker) { _, isPresented in
                if isPresented {
                    selectionBeforePicker = screenTimeService.selection
                    return
                }
                let sel = screenTimeService.selection
                let hasCategories = !sel.categoryTokens.isEmpty
                let hasDomains = !sel.webDomainTokens.isEmpty
                let tooManyApps = sel.applicationTokens.count > 1
                if !subscriptionService.isPro && (tooManyApps || hasCategories || hasDomains) {
                    var trimmed = FamilyActivitySelection()
                    if let firstApp = sel.applicationTokens.first {
                        trimmed.applicationTokens = [firstApp]
                    }
                    screenTimeService.selection = trimmed
                    appState.saveScreenSelection()
                    AppAnalytics.report("blocklist_picker_dismissed", parameters: ["action": "blocked_limit"])
                    showPaywall = true
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
                appState.saveScreenSelection()
            }
            #if DEBUG && !HIDE_DEBUG_UI
            .task {
                while !Task.isCancelled {
                    appState.refreshDeviceActivityDebug()
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                }
            }
            #endif
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

            if !subscriptionService.isPro {
                Button {
                    showPaywall = true
                } label: {
                    Text("blocklist.free.limit")
                        .font(.footnote)
                        .foregroundStyle(AppTheme.neonOrange.opacity(0.85))
                        .underline()
                }
                .buttonStyle(.plain)
                .padding(.top, 2)
            }

            Button("blocklist.pick.apps") {
                AppAnalytics.report("blocklist_pick_apps_tap")
                showingPicker = true
            }
            .buttonStyle(NeonPrimaryButtonStyle(tint: AppTheme.neonGreen))
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .glassCard(cornerRadius: 24, glowColor: AppTheme.neonBlue)
    }

    private var monitoringSliderSection: some View {
        MonitoringSlideButton(
            isPaused: appState.isMonitoringPaused,
            onPause: {
                if subscriptionService.isPro {
                    AppAnalytics.report("blocklist_monitoring_slide", parameters: ["action": "pause"])
                    appState.pauseMonitoring()
                } else {
                    AppAnalytics.report("blocklist_monitoring_slide", parameters: ["action": "pause_blocked"])
                    showPaywall = true
                }
            },
            onResume: {
                AppAnalytics.report("blocklist_monitoring_slide", parameters: ["action": "resume"])
                appState.resumeMonitoring()
            }
        )
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

private struct MonitoringSlideButton: View {
    let isPaused: Bool
    let onPause: () -> Void
    let onResume: () -> Void

    @State private var dragTranslation: CGFloat = 0
    @State private var isDragging = false
    @State private var hintOffset: CGFloat = 0
    @State private var hintLoopTask: Task<Void, Never>?

    private let trackHeight: CGFloat = 68
    private let knobSize: CGFloat = 56
    private let horizontalPadding: CGFloat = 6
    private let hintNudge: CGFloat = 10
    @State private var dragBaseOffset: CGFloat?

    var body: some View {
        GeometryReader { proxy in
            let maxOffset = max(0, proxy.size.width - knobSize - (horizontalPadding * 2))
            let restingOffset = isPaused ? maxOffset : 0
            let liveOffset = min(max(restingOffset + dragTranslation, 0), maxOffset)
            let iconColor = isPaused ? AppTheme.neonGreen : AppTheme.neonBlue

            // Капсула + круг: дуга левого края дорожки и окружность ручки имеют общий центр (геометрия «slide»).
            // Одно число cornerRadius у прямоугольника 56×56 и полосы 68 не даёт совпадающих дуг.
            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(Color.white.opacity(0.08))
                    .overlay(
                        Capsule(style: .continuous)
                            .stroke(Color.white.opacity(0.14), lineWidth: 1)
                    )
                    .frame(width: proxy.size.width, height: trackHeight)

                Text(isPaused ? "blocklist.resume.monitoring" : "blocklist.pause.monitoring")
                    .font(.headline.weight(.bold))
                    .foregroundStyle(.white.opacity(0.92))
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.horizontal, knobSize + 18)

                Circle()
                    .fill(iconColor)
                    .frame(width: knobSize, height: knobSize)
                    .overlay(
                        Image(systemName: isPaused ? "play.fill" : "pause.fill")
                            .font(.title3.weight(.heavy))
                            .foregroundStyle(.white)
                    )
                    .shadow(color: iconColor.opacity(0.35), radius: 8, x: 0, y: 0)
                    .offset(x: liveOffset + horizontalPadding + hintOffset)
            }
            .frame(width: proxy.size.width, height: trackHeight)
            .contentShape(Rectangle())
            .onAppear { restartHintLoopIfNeeded() }
            .onDisappear { stopHintLoop(resetOffset: true) }
            .onChange(of: isPaused) { _, paused in
                if paused {
                    stopHintLoop(resetOffset: true)
                } else {
                    restartHintLoopIfNeeded()
                }
            }
            .onChange(of: isDragging) { _, dragging in
                if dragging {
                    stopHintLoop(resetOffset: true)
                } else {
                    restartHintLoopIfNeeded()
                }
            }
            .gesture(
                DragGesture(minimumDistance: 8)
                    .onChanged { value in
                        if !isDragging {
                            isDragging = true
                        }
                        if dragBaseOffset == nil {
                            dragBaseOffset = restingOffset
                        }
                        dragTranslation = value.translation.width
                    }
                    .onEnded { value in
                        let baseOffset = dragBaseOffset ?? restingOffset
                        let finalOffset = min(max(baseOffset + value.translation.width, 0), maxOffset)
                        let shouldPause = !isPaused && finalOffset > maxOffset * 0.78
                        let shouldResume = isPaused && finalOffset < maxOffset * 0.22

                        // Reset visual drag first to avoid jump when state flips.
                        dragTranslation = 0
                        dragBaseOffset = nil

                        if shouldPause {
                            onPause()
                        } else if shouldResume {
                            onResume()
                        }
                        isDragging = false
                    }
            )
        }
        .frame(height: trackHeight)
    }

    private func restartHintLoopIfNeeded() {
        stopHintLoop(resetOffset: false)
        guard !isPaused, !isDragging else {
            if hintOffset != 0 {
                var t = Transaction()
                t.disablesAnimations = true
                withTransaction(t) { hintOffset = 0 }
            }
            return
        }
        hintLoopTask = Task { @MainActor in
            while !Task.isCancelled {
                withAnimation(.easeInOut(duration: 1.05)) {
                    hintOffset = hintNudge
                }
                try? await Task.sleep(nanoseconds: 1_050_000_000)
                guard !Task.isCancelled else { break }
                withAnimation(.easeInOut(duration: 1.05)) {
                    hintOffset = 0
                }
                try? await Task.sleep(nanoseconds: 1_050_000_000)
            }
        }
    }

    private func stopHintLoop(resetOffset: Bool) {
        hintLoopTask?.cancel()
        hintLoopTask = nil
        guard resetOffset, hintOffset != 0 else { return }
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) { hintOffset = 0 }
    }
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
