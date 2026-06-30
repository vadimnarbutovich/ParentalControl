import Combine
import SwiftUI

private enum MainTab: String, CaseIterable {
    case home
    case schedule
    case map
    case statistics
    case blocklist
    case settings
    /// Служебный таб «Родитель» на устройстве ребёнка: при тапе показываем `ParentModeEntryView`
    /// (fullScreenCover с PIN) и сразу же откатываем `selectedTab` назад — в обычном режиме таб
    /// сам не имеет контента, это просто кнопка-триггер.
    case parentEntry
}

struct MainTabView: View {
    @EnvironmentObject private var appState: AppState
    @State private var selectedTab: MainTab = .home
    /// Презентация экрана ввода PIN на ребёнке (тап по табу «Родитель»).
    @State private var isPinEntryPresented = false

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

                SettingsView()
                    .tabItem {
                        Label("tab.settings", systemImage: "gearshape.fill")
                    }
                    .tag(MainTab.settings)
            } else if appState.isParentModeActive {
                // Parent-режим на ребёнке: показываем те же экраны, что и в прошлой версии
                // «обычного» ребёнка (Главная / Блокировка / Настройки) — то есть полный набор
                // управления, доступный родителю физически на устройстве ребёнка.
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

                SettingsView()
                    .tabItem {
                        Label("tab.settings", systemImage: "gearshape.fill")
                    }
                    .tag(MainTab.settings)
            } else {
                // Обычный режим ребёнка: только «Главная» и «Родитель». При тапе по «Родитель»
                // открывается PIN-cover; сам этот View пустой — пользователь его никогда не видит.
                DashboardView()
                    .tabItem {
                        Label("tab.dashboard", systemImage: "square.grid.2x2.fill")
                    }
                    .tag(MainTab.home)

                Color.clear
                    .tabItem {
                        Label(
                            "tab.parent",
                            systemImage: appState.parentPinIsSet
                                ? "person.crop.circle.fill"
                                : "person.crop.circle.badge.questionmark"
                        )
                    }
                    .tag(MainTab.parentEntry)
            }
        }
        .preferredColorScheme(.dark)
        .onChange(of: selectedTab) { oldValue, newValue in
            AppAnalytics.report("main_tab_select", parameters: ["tab": newValue.rawValue])
            // Таб «Родитель» — это не настоящий экран, а триггер модалки. После выбора сразу
            // откатываемся на предыдущий таб и показываем cover с вводом PIN.
            if newValue == .parentEntry, appState.deviceRole == .child, !appState.isParentModeActive {
                isPinEntryPresented = true
                DispatchQueue.main.async {
                    selectedTab = (oldValue == .parentEntry) ? .home : oldValue
                }
            }
        }
        .onChange(of: appState.isParentModeActive) { _, newValue in
            // При переключении режима возвращаемся на главный таб — иначе предыдущий tag может
            // не существовать в новом наборе вкладок (например, был `.parentEntry`).
            selectedTab = .home
            if !newValue {
                // На выходе из режима тоже закроем cover, если он почему-то остался открыт.
                isPinEntryPresented = false
            }
        }
        .fullScreenCover(isPresented: $isPinEntryPresented) {
            ParentModeEntryView(isPresented: $isPinEntryPresented)
                .environmentObject(appState)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            // Красная плашка «Выход из родительского режима» — видна только на ребёнке, когда
            // режим открыт. Тап по плашке немедленно закрывает режим (см. `exitParentMode()`).
            // safeAreaInset аккуратно подвинет содержимое всех экранов TabView вниз — без хаков.
            if appState.deviceRole == .child, appState.isParentModeActive {
                ParentModeExitBanner {
                    AppAnalytics.report("parent_mode_exit_tap")
                    appState.exitParentMode()
                }
            }
        }
    }
}

/// Красная плашка-кнопка «Выход» сверху экрана для ребёнка в parent-режиме. Цвет — чтобы
/// родитель/ребёнок сразу видели, что текущая сессия с расширенными правами и её нужно закрыть
/// перед тем, как отдать устройство обратно ребёнку.
private struct ParentModeExitBanner: View {
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 8) {
                Image(systemName: "xmark.shield.fill")
                    .font(.subheadline.weight(.bold))
                Text("parent_mode.exit_banner")
                    .font(.subheadline.weight(.bold))
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .opacity(0.85)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .background(
                LinearGradient(
                    colors: [Color.red.opacity(0.95), Color.red.opacity(0.78)],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
        }
        .buttonStyle(.plain)
    }
}

/// Полноэкранный лист ввода 4-значного PIN на ребёнке. Если PIN ещё не задан родителем — показывает
/// заглушку с пояснением. Lockout-таймер визуализирован обратным отсчётом. Сам ввод PIN никогда
/// не уходит в сеть — он хэшируется локально и сверяется с кэшированным в Keychain хэшем.
private struct ParentModeEntryView: View {
    @EnvironmentObject private var appState: AppState
    @Binding var isPresented: Bool

    @State private var pin: String = ""
    @State private var errorKey: String?
    @State private var remainingAttempts: Int?
    @State private var lockoutTickTrigger = Date()

    /// Таймер ровно для отрисовки обратного отсчёта lockout. Срабатывает раз в секунду —
    /// никаких дорогих операций внутри, только перерисовка label.
    private let lockoutTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    /// Клавиша кейпада: цифра, удаление или пустая ячейка (нижний-левый угол сетки 3×4).
    private enum PinKey {
        case digit(Int)
        case delete
        case empty
    }

    var body: some View {
        ZStack {
            AppBackgroundView()
            VStack(spacing: 20) {
                HStack {
                    Spacer()
                    Button {
                        isPresented = false
                    } label: {
                        Image(systemName: "xmark")
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.85))
                            .padding(12)
                            .background(Circle().fill(Color.white.opacity(0.12)))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 18)
                .padding(.top, 8)

                Spacer(minLength: 0)

                if !appState.parentPinIsSet {
                    pinNotConfiguredView
                } else {
                    pinPromptView
                }

                Spacer()
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            errorKey = nil
            remainingAttempts = nil
        }
        .onReceive(lockoutTimer) { now in
            lockoutTickTrigger = now
        }
    }

    // MARK: - Subviews

    private var pinNotConfiguredView: some View {
        VStack(spacing: 14) {
            Image(systemName: "lock.slash")
                .font(.system(size: 48, weight: .bold))
                .foregroundStyle(AppTheme.neonOrange)
            Text("parent_mode.entry.title")
                .font(.title2.bold())
                .foregroundStyle(.white)
            Text("parent_mode.entry.not_configured")
                .font(.body)
                .multilineTextAlignment(.center)
                .foregroundStyle(.white.opacity(0.8))
                .padding(.horizontal, 32)
            Button("parent_mode.entry.close") {
                isPresented = false
            }
            .buttonStyle(NeonPrimaryButtonStyle(tint: AppTheme.neonBlue))
            .padding(.horizontal, 24)
            .padding(.top, 8)
        }
    }

    private var pinPromptView: some View {
        VStack(spacing: 18) {
            Image(systemName: "lock.fill")
                .font(.system(size: 44, weight: .bold))
                .foregroundStyle(AppTheme.neonBlue)
            Text("parent_mode.entry.title")
                .font(.title2.bold())
                .foregroundStyle(.white)
            Text("parent_mode.entry.subtitle")
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .foregroundStyle(.white.opacity(0.8))
                .padding(.horizontal, 32)

            pinDotsView
                .padding(.vertical, 8)

            if let lockoutEnd = currentLockoutEnd() {
                let remaining = max(0, Int(lockoutEnd.timeIntervalSinceNow.rounded(.up)))
                Text(L10n.f("parent_mode.entry.locked", remaining))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppTheme.neonOrange)
                    .padding(.top, 4)
            } else if let errorKey {
                Text(LocalizedStringKey(errorKey))
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(AppTheme.neonOrange)
                    .padding(.top, 4)
            } else if let remainingAttempts {
                Text(L10n.f("parent_mode.entry.attempts_remaining", remainingAttempts))
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.white.opacity(0.7))
                    .padding(.top, 4)
            }

            pinKeypadView
                .padding(.top, 12)
        }
    }

    /// Визуальные 4 «точки» PIN — заполняются по мере набора.
    private var pinDotsView: some View {
        HStack(spacing: 18) {
            ForEach(0..<4, id: \.self) { idx in
                Circle()
                    .strokeBorder(Color.white.opacity(0.35), lineWidth: 2)
                    .background(
                        Circle().fill(idx < pin.count ? Color.white : Color.clear)
                    )
                    .frame(width: 18, height: 18)
            }
        }
    }

    /// Собственный цифровой кейпад: полностью убирает зависимость от системной клавиатуры и
    /// `@FocusState` (которые у `fullScreenCover` нестабильны — клавиатура иногда не поднималась).
    /// Также безопаснее: нет сторонних клавиатур/автоподстановки над вводом родительского PIN.
    private var pinKeypadView: some View {
        let rows: [[PinKey]] = [
            [.digit(1), .digit(2), .digit(3)],
            [.digit(4), .digit(5), .digit(6)],
            [.digit(7), .digit(8), .digit(9)],
            [.empty, .digit(0), .delete],
        ]
        let locked = currentLockoutEnd() != nil
        return VStack(spacing: 16) {
            ForEach(0..<rows.count, id: \.self) { row in
                HStack(spacing: 24) {
                    ForEach(0..<rows[row].count, id: \.self) { col in
                        keypadButton(rows[row][col])
                    }
                }
            }
        }
        .disabled(locked)
        .opacity(locked ? 0.4 : 1.0)
    }

    @ViewBuilder
    private func keypadButton(_ key: PinKey) -> some View {
        switch key {
        case .empty:
            Color.clear.frame(width: 72, height: 72)
        case .digit(let value):
            Button {
                appendDigit(value)
            } label: {
                Text("\(value)")
                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(width: 72, height: 72)
                    .background(Circle().fill(Color.white.opacity(0.10)))
            }
            .buttonStyle(.plain)
        case .delete:
            Button {
                deleteDigit()
            } label: {
                Image(systemName: "delete.left")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(width: 72, height: 72)
            }
            .buttonStyle(.plain)
            .disabled(pin.isEmpty)
            .opacity(pin.isEmpty ? 0.4 : 1.0)
        }
    }

    // MARK: - Helpers

    private func currentLockoutEnd() -> Date? {
        // Зависит от `lockoutTickTrigger`, чтобы перерисовываться каждую секунду.
        _ = lockoutTickTrigger
        guard let end = appState.parentPinLockoutEnd else { return nil }
        return end > Date() ? end : nil
    }

    /// Добавляет цифру с кейпада. По достижении 4 цифр сразу проверяем PIN. Во время lockout
    /// ввод заблокирован на уровне `pinKeypadView.disabled`, поэтому дополнительной проверки тут нет.
    private func appendDigit(_ value: Int) {
        guard pin.count < 4 else { return }
        errorKey = nil
        pin.append(String(value))
        if pin.count == 4 {
            verifyPinAndReact()
        }
    }

    private func deleteDigit() {
        guard !pin.isEmpty else { return }
        pin.removeLast()
    }

    private func verifyPinAndReact() {
        let result = appState.enterParentMode(pin: pin)
        switch result {
        case .success:
            // cover закроется автоматически через `onChange(isParentModeActive)` в MainTabView,
            // но мы тоже снимаем флаг — чтобы анимация была мгновенной.
            isPresented = false
        case .wrongPin(let remaining):
            remainingAttempts = remaining
            errorKey = "parent_mode.entry.error.wrong"
            pin = ""
        case .lockedOut:
            errorKey = nil
            pin = ""
        case .notConfigured:
            // Кэш мог обновиться, пока пользователь набирал PIN — переадресуем на «не задан».
            errorKey = nil
            pin = ""
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
