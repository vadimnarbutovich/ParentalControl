import SwiftUI

struct DashboardView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var subscriptionService: SubscriptionService
    @State private var rewardToast: String?
    @State private var showPaywall = false
    @State private var isPairingInProgress = false
    @FocusState private var pairingCodeFocused: Bool

    /// Ребёнок ещё не связан с родителем — нужно показать карточку связки прямо на «Главной».
    /// Без этого свежее устройство не может пройти связку: настройки спрятаны за родительским PIN,
    /// а PIN приезжает только после связки (chicken-and-egg).
    private var childNeedsPairing: Bool {
        appState.deviceRole == .child && appState.pairingState?.isLinked != true
    }

    var body: some View {
        let daily = appState.dailyStats()
        NavigationStack {
            ZStack {
                AppBackgroundView()
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if childNeedsPairing {
                            childPairingPromptCard
                        } else {
                            DailyBudgetBalanceCard(
                                availableSeconds: appState.balance.availableSeconds,
                                usedSeconds: appState.dailyBudget?.usedSeconds ?? daily.spentSeconds,
                                limitSeconds: appState.dailyBudget?.policy.limitSeconds,
                                earnedSeconds: appState.dailyBudget == nil ? 0 : appState.dailyBudget?.earnedSeconds,
                                grantedSeconds: appState.dailyBudget == nil ? 0 : appState.dailyBudget?.grantedSeconds,
                                isManuallyBlocked: appState.isFocusSessionActive,
                                blockSchedules: appState.blockSchedules)
                            if appState.dailyBudget == nil { Text("budget.child_waiting").foregroundStyle(.secondary) }
                            if let error = appState.budgetError { Text(error).foregroundStyle(AppTheme.neonOrange) }
                            activeScheduleStatusCard
                            ChildTasksSection()
#if DEBUG && !HIDE_DEBUG_UI
                            testingCard
#endif
                        }
                    }
                    .padding()
                }
                .scrollIndicators(.hidden)
                .refreshable { await appState.refreshChildTasksFromServer() }
                .scrollDismissesKeyboard(.interactively)
            }
            .overlay {
                if appState.deviceRole == .parent && subscriptionService.isSubscriptionStatusKnown && !subscriptionService.isPro {
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
            }
            .onChange(of: appState.balance.availableSeconds) { oldValue, newValue in
                guard newValue > oldValue else { return }
                let delta = newValue - oldValue
                showRewardToast(deltaSeconds: delta)
            }
            .fullScreenCover(isPresented: $showPaywall) {
                PaywallView(isPresented: $showPaywall, openSource: .dashboardBadge)
                    .environmentObject(subscriptionService)
            }
        }
    }

    /// Карточка связки с родителем на «Главной» ребёнка. Видна, пока устройство не связано.
    /// Дублирует поток из `SettingsView.childPairingSection`, но доступна без родительского PIN —
    /// иначе свежий ребёнок не сможет пройти связку (настройки спрятаны за PIN).
    private var childPairingPromptCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: "link.badge.plus")
                    .font(.system(size: 40, weight: .bold))
                    .foregroundStyle(AppTheme.neonBlue)
                Text("dashboard.pairing.title")
                    .font(.title3.bold())
                    .foregroundStyle(.white)
                Text("dashboard.pairing.subtitle")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.8))
                    .fixedSize(horizontal: false, vertical: true)
            }

            TextField(
                L10n.tr("settings.child.link.placeholder"),
                text: $appState.pairingCodeInput
            )
            .focused($pairingCodeFocused)
            .textInputAutocapitalization(.characters)
            .autocorrectionDisabled(true)
            .submitLabel(.go)
            .onSubmit { connectChild() }
            .disabled(isPairingInProgress)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.white.opacity(0.08))
            )

            Button {
                connectChild()
            } label: {
                HStack(spacing: 8) {
                    if isPairingInProgress {
                        ProgressView()
                            .tint(.white)
                    }
                    Text(isPairingInProgress ? "dashboard.pairing.connecting" : "dashboard.pairing.connect")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(NeonPrimaryButtonStyle(tint: AppTheme.neonBlue))
            .disabled(isPairingInProgress || appState.pairingCodeInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            if let message = appState.remoteStatusMessage {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(AppTheme.neonOrange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding()
        // Запекаем фон glass-card в Metal-текстуру, чтобы тяжёлые shadow/glow-слои не пересчитывались
        // покадрово при скролле. Контент (поле ввода кода + кнопка) остаётся снаружи drawingGroup и
        // полностью интерактивен (фоновый паттерн, как в SettingsView/SchedulesTabView).
        .background(
            Color.clear
                .glassCard(cornerRadius: 24, glowColor: AppTheme.neonBlue)
                .padding(36)
                .drawingGroup()
                .padding(-36)
        )
    }

    /// Запускает связку по введённому коду. Сбрасывает фокус (прячет клавиатуру) и блокирует
    /// повторные нажатия на время запроса.
    private func connectChild() {
        let trimmed = appState.pairingCodeInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isPairingInProgress else { return }
        pairingCodeFocused = false
        isPairingInProgress = true
        AppAnalytics.report("dashboard_pairing_connect_tap")
        Task {
            await appState.connectChildWithPairingCode()
            isPairingInProgress = false
        }
    }

    /// Manual blocking is shown on the balance ring. Keep a separate card only
    /// for an active schedule, including its name and end time.
    private var activeScheduleStatusCard: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            if appState.pairingState?.isLinked == true,
               let activeSchedule = appState.activeBlockSchedules(at: context.date).first {
                VStack(alignment: .leading, spacing: 12) {
                    Label("dashboard.active_schedule.title", systemImage: "calendar.badge.clock")
                        .font(.headline.bold())
                        .foregroundStyle(.white.opacity(0.9))
                    blockingScheduleStatus(schedule: activeSchedule)
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    Color.clear
                        .glassCard(cornerRadius: 22)
                        .padding(36)
                        .drawingGroup()
                        .padding(-36)
                )
            }
        }
    }

    @ViewBuilder
    private func blockingScheduleStatus(schedule: BlockSchedule) -> some View {
        Text("dashboard.blocking.schedule_active")
            .font(.title2.weight(.bold))
            .foregroundStyle(AppTheme.neonOrange)

        HStack(spacing: 8) {
            Image(systemName: schedule.icon.rawValue)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AppTheme.neonOrange)
            Text(schedule.localizedName)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(.white)
                .lineLimit(1)
        }

        Text(L10n.f("dashboard.blocking.schedule_until", schedule.endTime.formattedShort))
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.secondary)

        Text("dashboard.blocking.schedule_hint")
            .font(.footnote)
            .foregroundStyle(.secondary)
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
