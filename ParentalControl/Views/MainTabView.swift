import SwiftUI

private enum MainTab: String, CaseIterable {
    case home
    case map
    case statistics
    case blocklist
    case settings
}

struct MainTabView: View {
    @EnvironmentObject private var appState: AppState
    @State private var selectedTab: MainTab = .home

    var body: some View {
        TabView(selection: $selectedTab) {
            if appState.deviceRole == .parent {
                ParentDashboardView()
                    .tabItem {
                        Label("tab.dashboard", systemImage: "person.2.fill")
                    }
                    .tag(MainTab.home)

                MapTabView()
                    .tabItem {
                        Label("tab.map", systemImage: "map.fill")
                    }
                    .tag(MainTab.map)

                StatisticsView()
                    .tabItem {
                        Label("tab.statistics", systemImage: "chart.bar.fill")
                    }
                    .tag(MainTab.statistics)
            } else {
                DashboardView()
                    .tabItem {
                        Label("tab.dashboard", systemImage: "square.grid.2x2.fill")
                    }
                    .tag(MainTab.home)

                BlockListView()
                    .tabItem {
                        Label("tab.block", systemImage: "checklist")
                    }
                    .tag(MainTab.blocklist)
            }

            SettingsView()
                .tabItem {
                    Label("tab.settings", systemImage: "gearshape.fill")
                }
                .tag(MainTab.settings)
        }
        .preferredColorScheme(.dark)
        .onChange(of: selectedTab) { _, newValue in
            AppAnalytics.report("main_tab_select", parameters: ["tab": newValue.rawValue])
        }
    }
}

private struct ParentDashboardView: View {
    @EnvironmentObject private var appState: AppState

    private var isCommandButtonEnabled: Bool {
        appState.pairingState?.isLinked == true &&
        !appState.remoteCommandInFlight &&
        appState.parentResolvedFocusActive != nil
    }

    private var shouldShowDisabledVisualState: Bool {
        appState.remoteCommandInFlight ||
        appState.parentResolvedFocusActive == nil ||
        appState.pairingState?.isLinked != true
    }

    private var commandButtonTitleKey: LocalizedStringKey {
        if appState.remoteCommandInFlight {
            return LocalizedStringKey("parent.dashboard.syncing_button")
        }
        if appState.parentResolvedFocusActive == nil {
            return LocalizedStringKey("parent.dashboard.syncing_button")
        }
        return (appState.parentResolvedFocusActive ?? false)
            ? LocalizedStringKey("parent.dashboard.stop_focus")
            : LocalizedStringKey("parent.dashboard.start_focus")
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AppBackgroundView()
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("parent.dashboard.title")
                            .font(.largeTitle.bold())
                            .foregroundStyle(.white)
                        VStack(alignment: .leading, spacing: 10) {
                            Text(appState.pairingState?.isLinked == true
                                 ? "parent.dashboard.linked"
                                 : "parent.dashboard.not_linked")
                                .foregroundStyle(.secondary)
                            if let endsAt = appState.remoteChildState.focusEndsAt, (appState.parentResolvedFocusActive ?? false) {
                                Text(L10n.f("parent.dashboard.focus_until", endsAt.formatted(date: .omitted, time: .shortened)))
                                    .foregroundStyle(.white)
                            } else if (appState.parentResolvedFocusActive ?? false) {
                                Text("parent.dashboard.focus_active_no_deadline")
                                    .foregroundStyle(.white)
                            } else {
                                Text("parent.dashboard.focus_inactive")
                                    .foregroundStyle(.secondary)
                            }
                            if appState.parentResolvedFocusActive == nil, appState.pairingState?.isLinked == true {
                                Text("parent.dashboard.state_syncing")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                            if appState.pairingState?.isLinked == true {
                                if let availableSeconds = appState.parentChildAvailableSeconds {
                                    Text(L10n.f("parent.dashboard.child_available", L10n.duration(seconds: availableSeconds)))
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(.white)
                                } else {
                                    Text("parent.dashboard.child_available_syncing")
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            if let health = appState.parentLinkHealth {
                                if !health.childLikelyOnline {
                                    Text("parent.dashboard.child_offline_hint")
                                        .font(.footnote)
                                        .foregroundStyle(AppTheme.neonOrange)
                                } else if health.pendingCommands > 0 {
                                    Text(L10n.f("parent.dashboard.pending_commands", health.pendingCommands))
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            if let message = appState.remoteStatusMessage {
                                Text(message)
                                    .font(.footnote)
                                    .foregroundStyle(AppTheme.neonBlue)
                            }
                            if appState.remoteCommandInFlight {
                                HStack(spacing: 10) {
                                    ProgressView()
                                        .tint(AppTheme.neonBlue)
                                }
                            }
                            if let delivery = appState.parentCommandDelivery {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(L10n.f("parent.dashboard.command_id", delivery.commandID.uuidString))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                    Text(L10n.f("parent.dashboard.command_status", delivery.status.rawValue))
                                        .font(.footnote.weight(.semibold))
                                        .foregroundStyle(delivery.status == .applied ? AppTheme.neonGreen : .white.opacity(0.85))
                                    if let latency = delivery.latencySeconds {
                                        Text(L10n.f("parent.dashboard.command_latency", latency))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    if let error = delivery.errorMessage, !error.isEmpty {
                                        Text(error)
                                            .font(.caption)
                                            .foregroundStyle(AppTheme.neonOrange)
                                    }
                                }
                                .padding(.top, 4)
                            }
                        }
                        .padding()
                        .glassCard(cornerRadius: 20, glowColor: AppTheme.neonBlue)

                        Button(commandButtonTitleKey) {
                            let shouldStartFocus = !(appState.parentResolvedFocusActive ?? false)
                            Task { await appState.sendParentFocusCommand(start: shouldStartFocus) }
                        }
                        .buttonStyle(
                            NeonPrimaryButtonStyle(
                                tint: shouldShowDisabledVisualState
                                    ? .gray
                                    : ((appState.parentResolvedFocusActive ?? false) ? AppTheme.neonBlue : AppTheme.neonGreen)
                            )
                        )
                        .opacity(shouldShowDisabledVisualState ? 0.65 : 1)
                        .disabled(!isCommandButtonEnabled)

                        HStack(spacing: 12) {
                            Button("parent.dashboard.take_all_time") {
                                Task { await appState.sendParentTakeAllTimeCommand() }
                            }
                            .buttonStyle(NeonPrimaryButtonStyle(tint: AppTheme.neonOrange))
                            .opacity(shouldShowDisabledVisualState ? 0.65 : 1)
                            .disabled(!isCommandButtonEnabled)
                            .frame(maxWidth: .infinity)

                            Button("parent.dashboard.add_one_minute") {
                                Task { await appState.sendParentAddOneMinuteCommand() }
                            }
                            .buttonStyle(NeonPrimaryButtonStyle(tint: AppTheme.neonBlue))
                            .opacity(shouldShowDisabledVisualState ? 0.65 : 1)
                            .disabled(!isCommandButtonEnabled)
                            .frame(maxWidth: .infinity)
                        }
                    }
                    .padding()
                }
            }
        }
    }
}

#Preview {
    MainTabView()
        .environmentObject(AppState())
        .environmentObject(SubscriptionService())
}
