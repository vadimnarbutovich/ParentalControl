import SwiftUI

private enum MainTab: String, CaseIterable {
    case home
    case schedule
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

                SchedulesTabView()
                    .tabItem {
                        Label("tab.schedule", systemImage: "calendar")
                    }
                    .tag(MainTab.schedule)

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
    /// Презентация шторки `AdjustTimeSheet` (изменить доступное время ребёнку).
    @State private var isAdjustTimePresented = false

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
                        // Верхняя «balance»-карточка: кольцо с доступным временем ребёнка
                        // + Заработано/Потрачено за сегодня. Виден только при связанной паре.
                        // Параметры (cap кольца 240, glassCard + drawingGroup-запекание) совпадают
                        // с детским DashboardView и ScreenBlocker — карточка выглядит идентично.
                        if appState.pairingState?.isLinked == true {
                            ChildBalanceCard(
                                availableSeconds: appState.parentChildAvailableSeconds ?? 0,
                                earnedSecondsToday: appState.parentChildEarnedSecondsToday ?? 0,
                                spentSecondsToday: appState.parentChildSpentSecondsToday ?? 0,
                                isLoadingAvailable: appState.parentChildAvailableSeconds == nil
                            )
                        }

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

                        Button("parent.dashboard.adjust_time") {
                            isAdjustTimePresented = true
                        }
                        .buttonStyle(NeonPrimaryButtonStyle(tint: AppTheme.neonPurple))
                        .opacity(shouldShowDisabledVisualState ? 0.65 : 1)
                        .disabled(!isCommandButtonEnabled)
                        .frame(maxWidth: .infinity)

                        // Карточка-индикатор «Сейчас активно расписание …» / «Следующее расписание».
                        // Видна только если у Родителя в локальном кэше есть включённые расписания.
                        // Сама карточка переоценивает активность каждые 30 секунд через TimelineView,
                        // поэтому не нужно дёргать AppState на каждом тике.
                        if appState.pairingState?.isLinked == true {
                            ActiveBlockScheduleCard(appState: appState)
                        }
                    }
                    .padding()
                }
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 0) {
                    Rectangle()
                        .fill(.white.opacity(0.12))
                        .frame(height: 1)

                    Button(commandButtonTitleKey) {
                        let shouldStartFocus = !(appState.parentResolvedFocusActive ?? false)
                        Task { await appState.sendParentFocusCommand(start: shouldStartFocus) }
                    }
                    .buttonStyle(
                        NeonPrimaryButtonStyle(
                            tint: shouldShowDisabledVisualState
                                ? .gray
                                : ((appState.parentResolvedFocusActive ?? false) ? AppTheme.neonGreen : AppTheme.neonBlue)
                        )
                    )
                    .opacity(shouldShowDisabledVisualState ? 0.65 : 1)
                    .disabled(!isCommandButtonEnabled)
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 10)
                }
                .background(.black.opacity(0.55))
            }
            .task {
                // Подтягиваем актуальные расписания с бэкенда при появлении дашборда —
                // это страховка для случая, когда пользователь зашёл сразу на главный экран
                // (без перехода на таб «Расписание») и локальный кэш ещё не успел синкнуться.
                if appState.deviceRole == .parent {
                    await appState.refreshParentBlockSchedulesIfNeeded()
                }
            }
            .sheet(isPresented: $isAdjustTimePresented) {
                AdjustTimeSheet { deltaMinutes in
                    Task { await appState.sendParentAdjustTimeCommand(deltaMinutes: deltaMinutes) }
                }
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
                .presentationBackground(.thinMaterial)
            }
        }
    }
}

/// «Balance»-карточка для родительского дашборда. Полностью повторяет вёрстку детской `balanceCard`
/// из `DashboardView` (и аналогичной карточки в ScreenBlocker), только использует данные ребёнка,
/// которые сидят на `AppState` родителя:
/// - `availableSeconds`  — `parentChildAvailableSeconds` (live, через `parental-control-balance-sync`);
/// - `earnedSecondsToday` / `spentSecondsToday` — `parentChildEarnedSecondsToday/spentSecondsToday`
///   (заполняются из `fetch_parent_snapshot.dailyStats`, edge function v20).
/// `isLoadingAvailable` — пока мы ещё не получили первый ответ балансом — рисуем плейсхолдер «Sync».
/// Cap кольца — 240 минут (4 часа), как в детском DashboardView.
/// Запекание `padding(36) → drawingGroup() → padding(-36)` оставлено таким же, чтобы тяжёлые тени
/// glass-card не пересчитывались на каждом кадре скролла родительского дашборда.
private struct ChildBalanceCard: View {
    let availableSeconds: Int
    let earnedSecondsToday: Int
    let spentSecondsToday: Int
    let isLoadingAvailable: Bool

    private let ringBalanceCapMinutes = 240

    var body: some View {
        let safeAvailable = max(0, availableSeconds)
        let availableMinutes = safeAvailable / 60
        let ringValue = safeAvailable < 60 ? safeAvailable : availableMinutes
        let ringUnitKey = safeAvailable < 60 ? "unit.seconds.abbrev" : "unit.minutes.abbrev"
        let ringProgress = min(
            max(Double(availableMinutes) / Double(ringBalanceCapMinutes), 0),
            1
        )

        return VStack(spacing: 14) {
            HStack {
                Spacer(minLength: 0)
                HStack(spacing: 24) {
                    MinutesRingView(progress: CGFloat(ringProgress), lineWidth: 16) {
                        VStack(spacing: 2) {
                            if isLoadingAvailable {
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
                            value: L10n.duration(seconds: max(0, earnedSecondsToday)),
                            color: AppTheme.neonGreen
                        )

                        metricChip(
                            icon: "arrow.down.right",
                            title: L10n.tr("statistics.spent"),
                            value: L10n.duration(seconds: max(0, spentSecondsToday)),
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

    /// Локальная копия `metricChip` — точная копия helper-а из `DashboardView`, чтобы не плодить общий код
    /// и не зависеть от приватных methods детского экрана.
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
}

/// Шторка «Изменить доступное время» (открывается на половину экрана через `.presentationDetents([.medium])`).
/// Содержит вертикальный wheel-Picker со значениями −60…+60 мин с шагом 5 (отрицательные — забрать,
/// положительные — добавить, 0 — без изменений в центре). Кнопка «Готово» внизу применяет дельту,
/// свайп вниз / drag indicator закрывает без сохранения. Логика выбора server-команды — в
/// `AppState.sendParentAdjustTimeCommand(deltaMinutes:)`.
private struct AdjustTimeSheet: View {
    @Environment(\.dismiss) private var dismiss
    /// Колбэк передаёт выбранную дельту в минутах (со знаком). Если `0` — `AppState` сам сделает no-op.
    let onApply: (Int) -> Void

    @State private var selectedDelta: Int = 0

    /// Допустимые значения пикера: −60, −55, …, −5, 0, +5, …, +55, +60.
    private static let allowedDeltas: [Int] = stride(from: -60, through: 60, by: 5).map { $0 }

    var body: some View {
        VStack(spacing: 16) {
            Text("parent.dashboard.adjust_time.title")
                .font(.headline.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.top, 16)

            Picker("parent.dashboard.adjust_time.title", selection: $selectedDelta) {
                ForEach(Self.allowedDeltas, id: \.self) { delta in
                    Text(label(for: delta))
                        .foregroundStyle(.white)
                        .tag(delta)
                }
            }
            .pickerStyle(.wheel)
            .labelsHidden()
            .tint(AppTheme.neonPurple)
            .frame(maxHeight: 180)

            Button("parent.dashboard.adjust_time.done") {
                onApply(selectedDelta)
                dismiss()
            }
            .buttonStyle(NeonPrimaryButtonStyle(tint: AppTheme.neonPurple))
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .preferredColorScheme(.dark)
    }

    /// Формирует подпись пункта пикера: «+5 мин», «0 мин», «−10 мин».
    /// Используем явно знак «−» (U+2212) для отрицательных значений — выглядит аккуратнее
    /// типографически, чем минус U+002D, и совпадает по ширине с «+».
    private func label(for delta: Int) -> String {
        if delta == 0 {
            return L10n.f("parent.dashboard.adjust_time.minutes_format", "0")
        }
        let sign = delta > 0 ? "+" : "−"
        return L10n.f("parent.dashboard.adjust_time.minutes_format", "\(sign)\(abs(delta))")
    }
}

#Preview {
    MainTabView()
        .environmentObject(AppState())
        .environmentObject(SubscriptionService())
}
