import SwiftUI

struct DashboardView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var subscriptionService: SubscriptionService
    @State private var selectedExercise: ExerciseType?
    @State private var rewardToast: String?
    @State private var previousAvailableSeconds: Int = 0
    @State private var isStepsInfoPresented = false
    @State private var showPaywall = false
    #if DEBUG && !HIDE_DEBUG_UI
    private let focusOptions = [1, 5, 10, 15, 25, 30, 45, 60, 90, 120]
    #else
    private let focusOptions = [5, 10, 15, 25, 30, 45, 60, 90, 120]
    #endif
    private let ringBalanceCapMinutes = 240

    var body: some View {
        let daily = appState.dailyStats()
        NavigationStack {
            ZStack {
                AppBackgroundView()
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        balanceCard(daily: daily)
                        earnMinutesSection(daily: daily)
                        focusCard
#if DEBUG && !HIDE_DEBUG_UI
                        testingCard
#endif
                    }
                    .padding()
                }
                .scrollIndicators(.hidden)
            }
            .overlay {
                if subscriptionService.isSubscriptionStatusKnown && !subscriptionService.isPro {
                    GeometryReader { geo in
                        Button {
                            AppAnalytics.report("dashboard_pro_badge_tap")
                            showPaywall = true
                        } label: {
                            ProSubscriptionBadge()
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint(Text("dashboard.badge.pro.hint"))
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .padding(.leading, 16)
                        // Ближе к верху экрана, остаёмся в safe area (не под вырез/Dynamic Island).
                        .padding(.top)
                        .offset(y: -3)
                    }
                }
            }
            .overlay(alignment: .top) {
                if let rewardToast {
                    Text(rewardToast)
                        .font(.headline.weight(.bold))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 10)
                        .background(
                            Capsule(style: .continuous)
                                .fill(AppTheme.neonGreen)
                        )
                        .neonGlow(AppTheme.neonGreen, radius: 16)
                        .padding(.top, 8)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .task {
                await appState.refreshStepsAndRewards()
                await subscriptionService.refreshCustomerInfo()
                previousAvailableSeconds = appState.balance.availableSeconds
            }
            .onAppear {
                previousAvailableSeconds = appState.balance.availableSeconds
            }
            .onChange(of: appState.balance.availableSeconds) { oldValue, newValue in
                guard newValue > oldValue else {
                    previousAvailableSeconds = newValue
                    return
                }
                let delta = newValue - oldValue
                showRewardToast(deltaSeconds: delta)
                previousAvailableSeconds = newValue
            }
            .fullScreenCover(isPresented: $showPaywall) {
                PaywallView(isPresented: $showPaywall, openSource: .dashboardBadge)
                    .environmentObject(subscriptionService)
            }
            .sheet(item: $selectedExercise) { type in
                ExerciseSessionView(type: type)
                    .environmentObject(appState)
            }
            .alert(
                L10n.tr("dashboard.focus.error.title"),
                isPresented: Binding(
                    get: { appState.focusStartError != nil },
                    set: { if !$0 { appState.clearFocusStartError() } }
                )
            ) {
                Button("common.ok", role: .cancel) {
                    appState.clearFocusStartError()
                }
            } message: {
                Text(appState.focusStartError ?? "")
            }
        }
    }

    private func balanceCard(daily: DailyStats) -> some View {
        let availableSeconds = max(0, appState.balance.availableSeconds)
        let isMonitoringPaused = appState.isMonitoringPaused
        let ringValue = availableSeconds < 60 ? availableSeconds : (availableSeconds / 60)
        let ringUnitKey = availableSeconds < 60 ? "unit.seconds.abbrev" : "unit.minutes.abbrev"
        let ringProgress = min(
            max(Double(appState.balance.availableMinutes) / Double(ringBalanceCapMinutes), 0),
            1
        )

        return VStack(spacing: 14) {
            HStack {
                Spacer(minLength: 0)
                HStack(spacing: 24) {
                    MinutesRingView(progress: CGFloat(ringProgress), lineWidth: 16) {
                        VStack(spacing: 2) {
                            if isMonitoringPaused {
                                Text("dashboard.balance.paused")
                                    .font(.system(size: 24, weight: .black, design: .rounded))
                                    .foregroundStyle(.white)
                            } else {
                                Text("\(ringValue)")
                                    .font(.system(size: 38, weight: .black, design: .rounded))
                                    .foregroundStyle(.white)
                                    .contentTransition(.numericText())
                                Text(L10n.tr(ringUnitKey))
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.white.opacity(0.85))
                            }
                        }
                    }
                    .frame(width: 124, height: 124)

                    VStack(alignment: .leading, spacing: 14) {
                        Text("dashboard.section.today")
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(AppTheme.neonGreen)
                            .padding(.leading, 26)

                        metricChip(
                            icon: "arrow.up.right",
                            title: L10n.tr("statistics.earned"),
                            value: L10n.duration(seconds: daily.earnedSeconds),
                            color: AppTheme.neonGreen
                        )

                        metricChip(
                            icon: "arrow.down.right",
                            title: L10n.tr("statistics.spent"),
                            value: L10n.duration(seconds: daily.spentSeconds),
                            color: AppTheme.neonOrange
                        )
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .padding()
        .glassCard(cornerRadius: 28, glowColor: AppTheme.neonBlue)
        .padding(36)
        .drawingGroup()
        .padding(-36)
    }

    private func earnMinutesSection(daily: DailyStats) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("dashboard.section.earn")
                .font(.title2.bold())
                .frame(maxWidth: .infinity, alignment: .center)

            LazyVGrid(columns: [
                GridItem(.flexible(), spacing: 12),
                GridItem(.flexible(), spacing: 12),
                GridItem(.flexible(), spacing: 12)
            ], spacing: 12) {
                earnCard(
                    iconAssetName: "walk",
                    value: appState.isHealthAuthorized
                        ? formattedNumber(appState.todaySteps)
                        : "—",
                    valueLabel: L10n.plural("unit.steps.count", appState.todaySteps),
                    rewardPrefix: L10n.tr("dashboard.earn.rate.prefix"),
                    rewardDetail: L10n.plural("dashboard.earn.rate.steps.detail", appState.settings.stepsPerMinute),
                    glowColor: AppTheme.neonGreen
                ) {
                    AppAnalytics.report("dashboard_earn_card_tap", parameters: ["kind": "steps"])
                    isStepsInfoPresented = true
                }
                .alert(isPresented: $isStepsInfoPresented) {
                    Alert(
                        title: Text(""),
                        message: Text("dashboard.steps.alert.message"),
                        dismissButton: .cancel(Text("dashboard.steps.alert.close"))
                    )
                }

                earnCard(
                    iconAssetName: "squat",
                    value: formattedNumber(daily.squats),
                    valueLabel: L10n.plural("unit.reps.count", daily.squats),
                    rewardPrefix: L10n.tr("dashboard.earn.rate.prefix"),
                    rewardDetail: L10n.plural("dashboard.earn.rate.reps.detail", appState.settings.squatsPerMinute),
                    glowColor: AppTheme.neonOrange
                ) {
                    AppAnalytics.report("dashboard_earn_card_tap", parameters: ["kind": "squat"])
                    selectedExercise = .squat
                }

                earnCard(
                    iconAssetName: "pushups",
                    value: formattedNumber(daily.pushUps),
                    valueLabel: L10n.plural("unit.reps.count", daily.pushUps),
                    rewardPrefix: L10n.tr("dashboard.earn.rate.prefix"),
                    rewardDetail: L10n.plural("dashboard.earn.rate.reps.detail", appState.settings.pushUpsPerMinute),
                    glowColor: AppTheme.neonBlue
                ) {
                    AppAnalytics.report("dashboard_earn_card_tap", parameters: ["kind": "pushup"])
                    selectedExercise = .pushUp
                }
            }
        }
    }

    private var focusCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("dashboard.focus.title", systemImage: "timer")
                .font(.headline.bold())
                .foregroundStyle(.white.opacity(0.9))

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(focusOptions, id: \.self) { option in
                        Button {
                            appState.focusDurationMinutes = option
                        } label: {
                            Text(L10n.f("unit.minutes.compact", option))
                        }
                        .buttonStyle(NeonChipButtonStyle(
                            isActive: appState.focusDurationMinutes == option,
                            tint: AppTheme.neonGreen,
                            fillHorizontally: false
                        ))
                    }
                }
                .padding(.vertical, 2)
            }

            Button {
                if appState.isFocusSessionActive {
                    AppAnalytics.report("dashboard_focus_control_tap", parameters: ["action": "end"])
                    appState.endFocusSession()
                } else {
                    AppAnalytics.report(
                        "dashboard_focus_control_tap",
                        parameters: [
                            "action": "start",
                            "duration_minutes": appState.focusDurationMinutes,
                        ]
                    )
                    appState.startFocusSession()
                }
            } label: {
                Text(appState.isFocusSessionActive ? "dashboard.focus.end" : "dashboard.focus.start")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(NeonPrimaryButtonStyle(tint: AppTheme.neonGreen))

            if appState.isFocusSessionActive {
                Text(countdownText(from: appState.focusRemainingSeconds))
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .frame(maxWidth: .infinity, alignment: .center)
                Text("dashboard.focus.remaining")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                if let endsAt = appState.focusSessionEndsAt {
                    Text(L10n.f("dashboard.session.until", endsAt.formatted(date: .omitted, time: .shortened)))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("dashboard.lock.restore")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .glassCard(cornerRadius: 22)
        #if !DEBUG || HIDE_DEBUG_UI
        .onAppear {
            if appState.focusDurationMinutes == 1 {
                appState.focusDurationMinutes = 5
            }
        }
        #endif
    }

    #if DEBUG && !HIDE_DEBUG_UI
    private var testingCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("dashboard.testing.title")
                .font(.headline)
            HStack(spacing: 10) {
                Button("dashboard.testing.consume_all") {
                    appState.consumeAllEarnedTimeForTesting()
                }
                .buttonStyle(SecondaryTestButtonStyle())

                Button("dashboard.testing.add_ten_seconds") {
                    appState.addTenSecondsForTesting()
                }
                .buttonStyle(SecondaryTestButtonStyle())
            }
        }
        .padding()
        .glassCard(cornerRadius: 20)
    }
    #endif

    private func metricChip(icon: String, title: String, value: String, color: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(color)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.white)
            }
        }
    }

    @ViewBuilder
    private func earnCard(
        iconAssetName: String,
        value: String,
        valueLabel: String,
        rewardPrefix: String,
        rewardDetail: String,
        glowColor: Color,
        action: (() -> Void)? = nil
    ) -> some View {
        let content = VStack(alignment: .center, spacing: 8) {
            Image(iconAssetName)
                .resizable()
                .scaledToFit()
                .frame(width: 56, height: 56)

            Text(value)
                .font(.system(size: 34, weight: .black, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.18)
                .allowsTightening(true)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, minHeight: 40, alignment: .center)

            Text(valueLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .minimumScaleFactor(0.7)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)

            VStack(spacing: 2) {
                Text(rewardPrefix)
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(glowColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.55)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                Text(rewardDetail)
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(glowColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.45)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, minHeight: 178, alignment: .top)
        .padding(.vertical, 14)
        .padding(.horizontal, 4)
        .glassCard(cornerRadius: 20, glowColor: glowColor)
        .padding(36)
        .drawingGroup()
        .padding(-36)

        if let action {
            Button(action: action) {
                content
            }
            .buttonStyle(.plain)
        } else {
            content
        }
    }

    private func formattedNumber(_ value: Int) -> String {
        value.formatted(.number.grouping(.automatic))
    }

    private func showRewardToast(deltaSeconds: Int) {
        guard deltaSeconds > 0 else { return }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.86)) {
            rewardToast = L10n.f("dashboard.reward.toast", L10n.duration(seconds: deltaSeconds))
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            withAnimation(.easeOut(duration: 0.25)) {
                rewardToast = nil
            }
        }
    }

    private func countdownText(from seconds: Int) -> String {
        let normalized = max(0, seconds)
        let minutes = normalized / 60
        let secs = normalized % 60
        return String(format: "%02d:%02d", minutes, secs)
    }
}

#if DEBUG && !HIDE_DEBUG_UI
private struct SecondaryTestButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(Color.white.opacity(configuration.isPressed ? 0.06 : 0.12), in: RoundedRectangle(cornerRadius: 10))
            .foregroundStyle(.white)
    }
}
#endif

#Preview {
    DashboardView()
        .environmentObject(AppState())
        .environmentObject(SubscriptionService())
}
