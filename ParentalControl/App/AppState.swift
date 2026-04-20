import AVFoundation
import Combine
import FamilyControls
import Foundation
import HealthKit
import UIKit

enum PermissionReminderKind: Hashable {
    case health
    case screenTime
    case notifications
    /// Live Activities (Dynamic Island / Lock Screen) — системного запроса нет, только Настройки.
    case liveActivities
}

@MainActor
final class AppState: ObservableObject {
    @Published private(set) var balance: MinuteBalance
    @Published var settings: ConversionSettings
    @Published private(set) var ledger: [ActivityLedgerEntry]
    @Published private(set) var todaySteps: Int = 0
    @Published private(set) var exerciseTotals: [String: Int]
    @Published private(set) var isHealthAuthorized = false
    /// Явный запрет чтения шагов в «Здоровье» — снова показать системный лист нельзя, только настройки.
    @Published private(set) var isHealthKitStepReadLikelyDenied = false
    @Published private(set) var isNotificationAuthorized = false
    /// `true`, если уведомления явно запрещены в системе — повторный `requestAuthorization` не покажет диалог.
    @Published private(set) var isNotificationAuthorizationDenied = false
    @Published private(set) var isLiveActivitiesEnabled = true
    @Published private(set) var isCameraAuthorized = false
    @Published private(set) var isFocusSessionActive = false
    @Published private(set) var focusSessionEndsAt: Date?
    @Published private(set) var focusRemainingSeconds: Int = 0
    @Published private(set) var isMonitoringPaused = false
    @Published private(set) var isMidnightResetEnabled = true
    #if DEBUG && !HIDE_DEBUG_UI
    @Published private(set) var deviceActivityDebug = DeviceActivityDebugSnapshot(
        heartbeatCount: 0,
        lastEvent: nil,
        lastHeartbeatAt: nil,
        warningCount: 0,
        thresholdCount: 0,
        lastTrigger: nil,
        thresholdSeconds: 0,
        lastSpentDelta: 0,
        lastAvailableBefore: 0,
        lastAvailableAfter: 0,
        restartCount: 0,
        lastStartMonitoringAt: nil,
        lastConsumptionAt: nil,
        mirrorEarnedSeconds: 0,
        mirrorSpentSeconds: 0
    )
    #endif
    @Published var focusDurationMinutes = 15
    @Published var focusStartError: String?
    @Published private(set) var hasCompletedOnboarding = false
    /// Скрывает баннер после тапа «Разрешить» до следующего `appDidBecomeActive`.
    @Published private(set) var permissionBannerSuppressedAfterCTA = false
    /// Пока `false`, баннер разрешений не показываем — избегаем кадра с устаревшим `isHealthAuthorized` до async-обновления.
    @Published private(set) var permissionStatusesReady = false

    let screenTimeService: ScreenTimeService

    var activePermissionReminder: PermissionReminderKind? {
        guard permissionStatusesReady, hasCompletedOnboarding, !permissionBannerSuppressedAfterCTA else { return nil }
        if !isHealthAuthorized { return .health }
        if !screenTimeService.isAuthorized { return .screenTime }
        if !isNotificationAuthorized { return .notifications }
        if !isLiveActivitiesEnabled { return .liveActivities }
        return nil
    }

    func permissionBannerPrimaryButtonKey(for kind: PermissionReminderKind) -> String {
        switch kind {
        case .liveActivities:
            return "permission.banner.open_settings"
        case .notifications where isNotificationAuthorizationDenied:
            return "permission.banner.open_settings"
        case .health where isHealthKitStepReadLikelyDenied:
            return "permission.banner.open_health"
        default:
            return "permission.banner.allow"
        }
    }

    func openAppSettingsURL() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    /// Шаги включаются в приложении «Здоровье» → «Доступ к данным и устройствам», а не на странице настроек нашего приложения.
    /// Схема `x-apple-health` не документирована Apple и может измениться; при неудаче — настройки приложения.
    func openHealthAppForStepPermissions() {
        tryOpenHealthDeepLink(index: 0, candidates: ["x-apple-health://Sources", "x-apple-health://"])
    }

    private func tryOpenHealthDeepLink(index: Int, candidates: [String]) {
        guard index < candidates.count, let url = URL(string: candidates[index]) else {
            openAppSettingsURL()
            return
        }
        UIApplication.shared.open(url, options: [:]) { [weak self] success in
            Task { @MainActor in
                guard let self else { return }
                if success { return }
                self.tryOpenHealthDeepLink(index: index + 1, candidates: candidates)
            }
        }
    }

    private let storage: AppGroupStore
    private let rewardEngine = RewardEngine()
    private let healthService: HealthKitProviding
    private let notificationService: Notifying
    private let cameraService: CameraCaptureService
    private let focusLiveActivityService = FocusLiveActivityService()
    private let stepsSyncCoordinator = StepsSyncCoordinator()
    private var focusTask: Task<Void, Never>?
    private var focusSessionStartedAt: Date?
    private var focusSessionPlannedSeconds: Int = 0
    private var sharedStateTask: Task<Void, Never>?
    private var lifecycleCancellables = Set<AnyCancellable>()

    init() {
        let storage = AppGroupStore()
        let healthService: HealthKitProviding = HealthKitService()
        let notificationService: Notifying = NotificationService()
        let cameraService = CameraCaptureService()

        self.storage = storage
        self.healthService = healthService
        self.notificationService = notificationService
        self.cameraService = cameraService
        self.screenTimeService = ScreenTimeService(appStore: storage)
        self.balance = storage.loadBalance()
        self.settings = storage.loadSettings()
        self.ledger = storage.loadLedger()
        self.exerciseTotals = storage.loadExerciseTotals()
        self.isMonitoringPaused = storage.loadDeviceActivityMonitoringPaused()
        self.isMidnightResetEnabled = storage.loadMidnightResetEnabled()
        #if DEBUG && !HIDE_DEBUG_UI
        self.deviceActivityDebug = storage.loadDeviceActivityDebugSnapshot()
        #endif
        var onboardingDone = storage.loadHasCompletedOnboarding()
        if !onboardingDone, storage.loadDidRequestInitialPermissions() {
            onboardingDone = true
            storage.saveHasCompletedOnboarding(true)
        }
        self.hasCompletedOnboarding = onboardingDone
        self.isHealthAuthorized = false
        self.isCameraAuthorized = AVCaptureDevice.authorizationStatus(for: .video) == .authorized
        configureMainAppActivityTracking()

        screenTimeService.refreshAuthorizationStatus()
        storage.saveMainAppIsActive(true)
        resetDailyBalanceIfNeeded()
        ensureSpentBaselineForToday()
        screenTimeService.stopDeviceActivityMonitoring()
        restoreFocusSessionIfNeeded()
        syncScreenTimeEnforcement(notifyOnUnlock: false)

        Task { await self.refreshPermissionStatuses() }
    }

    deinit {
        focusTask?.cancel()
        sharedStateTask?.cancel()
        lifecycleCancellables.removeAll()
    }

    func requestPermissions() async {
        await requestHealthAccessOnly()
        await requestNotificationAccessOnly()
        await requestScreenTimeAccessOnly()
        await requestCameraAccessOnly()
    }

    func refreshPermissionStatuses() async {
        isHealthAuthorized = await healthService.hasStepReadAccess()
        // Если доступ есть — отказа точно нет; если нет — проверяем, показывался ли диалог (чтобы отличить «не спрашивали» от «отказали»).
        isHealthKitStepReadLikelyDenied = isHealthAuthorized ? false : await healthService.isStepReadLikelyDenied()
        isNotificationAuthorized = await notificationService.isAuthorizedForAlerts()
        let notifStatus = await notificationService.currentAuthorizationStatus()
        isNotificationAuthorizationDenied = notifStatus == .denied
        screenTimeService.refreshAuthorizationStatus()
        isLiveActivitiesEnabled = LiveActivityPermission.isEnabledForApp
        isCameraAuthorized = AVCaptureDevice.authorizationStatus(for: .video) == .authorized
        permissionStatusesReady = true
    }

    func requestHealthAccessOnly() async {
        _ = await healthService.requestAccess()
        isHealthAuthorized = await healthService.hasStepReadAccess()
        isHealthKitStepReadLikelyDenied = isHealthAuthorized ? false : await healthService.isStepReadLikelyDenied()
        if isHealthAuthorized {
            startStepPolling()
        }
        syncScreenTimeEnforcement(notifyOnUnlock: false)
    }

    func requestNotificationAccessOnly() async {
        await notificationService.resolveNotificationAccess { [weak self] in
            self?.openAppSettingsURL()
        }
        isNotificationAuthorized = await notificationService.isAuthorizedForAlerts()
        isNotificationAuthorizationDenied = await notificationService.currentAuthorizationStatus() == .denied
    }

    func requestScreenTimeAccessOnly() async {
        await screenTimeService.requestAuthorization()
        screenTimeService.refreshAuthorizationStatus()
        syncScreenTimeEnforcement(notifyOnUnlock: false)
    }

    func requestCameraAccessOnly() async {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        if status == .denied || status == .restricted {
            openAppSettingsURL()
        } else {
            _ = await cameraService.requestPermission()
        }
        refreshCameraAuthorizationFromSystem()
    }

    func refreshCameraAuthorizationFromSystem() {
        isCameraAuthorized = AVCaptureDevice.authorizationStatus(for: .video) == .authorized
    }

    func completeOnboarding() {
        storage.saveHasCompletedOnboarding(true)
        storage.saveDidRequestInitialPermissions(true)
        hasCompletedOnboarding = true
        Task {
            await refreshPermissionStatuses()
            await refreshStepsAndRewards()
        }
    }

    func handlePermissionBannerAllow(kind: PermissionReminderKind) async {
        switch kind {
        case .health:
            await requestHealthAccessOnly()
            if !isHealthAuthorized {
                openHealthAppForStepPermissions()
            }
        case .screenTime:
            await requestScreenTimeAccessOnly()
        case .notifications:
            await requestNotificationAccessOnly()
        case .liveActivities:
            openAppSettingsURL()
        }
        await refreshPermissionStatuses()
        permissionBannerSuppressedAfterCTA = true
    }

    func refreshStepsAndRewards() async {
        resetDailyBalanceIfNeeded()
        guard await healthService.hasStepReadAccess() else {
            isHealthAuthorized = false
            isHealthKitStepReadLikelyDenied = true
            todaySteps = 0
            return
        }
        do {
            let currentSteps = try await healthService.fetchTodaySteps()
            isHealthAuthorized = true
            isHealthKitStepReadLikelyDenied = false
            if todaySteps != currentSteps {
                todaySteps = currentSteps
            }

            let processed = processedStepsBaselineForToday()
            let rewards = rewardEngine.stepSecondsEarned(
                currentSteps: currentSteps,
                lastProcessedSteps: processed,
                settings: settings
            )
            // Keep baseline in sync even when earned seconds are zero.
            if rewards.newProcessedSteps != processed {
                storage.saveLastProcessedSteps(rewards.newProcessedSteps)
            }
            guard rewards.seconds > 0 else { return }

            addSeconds(rewards.seconds, source: .steps, note: L10n.tr("ledger.steps"))
            notificationService.notify(
                title: L10n.tr("notification.minutes.added.title"),
                body: L10n.f("notification.minutes.added.body", L10n.duration(seconds: rewards.seconds))
            )
        } catch {
            if let hkError = error as? HKError, hkError.code == .errorAuthorizationDenied {
                isHealthAuthorized = false
                isHealthKitStepReadLikelyDenied = true
                todaySteps = 0
            }
        }
    }

    func addExerciseReps(type: ExerciseType, reps: Int) {
        guard reps > 0 else { return }
        let seconds = rewardEngine.repSecondsEarned(reps: reps, type: type, settings: settings)
        guard seconds > 0 else { return }

        var totals = exerciseTotals
        totals[type.rawValue, default: 0] += reps
        exerciseTotals = totals
        storage.saveExerciseTotals(totals)

        let source: LedgerEntrySource = type == .squat ? .squat : .pushUp
        addSeconds(
            seconds,
            source: source,
            note: L10n.f("ledger.exercise", type.title.lowercased()),
            repetitionCount: reps
        )
        notificationService.notify(
            title: L10n.tr("notification.workout.counted.title"),
            body: L10n.f("notification.workout.counted.body", L10n.duration(seconds: seconds), type.title.lowercased())
        )
    }

    func updateSettings(_ newSettings: ConversionSettings) {
        settings = newSettings
        storage.saveSettings(newSettings)
    }

    func saveScreenSelection() {
        if isMonitoringPaused {
            isMonitoringPaused = false
            storage.saveDeviceActivityMonitoringPaused(false)
        }
        screenTimeService.saveSelection()
        // После изменения selection перезапускаем мониторинг с новой конфигурацией.
        screenTimeService.stopDeviceActivityMonitoring()
        syncScreenTimeEnforcement(notifyOnUnlock: false)
    }

    func pauseMonitoring() {
        isMonitoringPaused = true
        storage.saveDeviceActivityMonitoringPaused(true)
        syncScreenTimeEnforcement(notifyOnUnlock: false)
    }

    func resumeMonitoring() {
        isMonitoringPaused = false
        storage.saveDeviceActivityMonitoringPaused(false)
        syncScreenTimeEnforcement(notifyOnUnlock: false)
    }

    func updateMidnightResetEnabled(_ value: Bool) {
        guard isMidnightResetEnabled != value else { return }
        isMidnightResetEnabled = value
        storage.saveMidnightResetEnabled(value)
        // Align reset marker with current day while feature is off,
        // so re-enabling during the day does not trigger immediate reset.
        if !value {
            storage.saveLastBalanceResetDayStart(Calendar.current.startOfDay(for: Date()))
        }
    }

    /// Revokes premium-only features when subscription expires.
    /// Called only when `isStatusKnown == true` to avoid revoking while offline (cached status stays active).
    func enforcePremiumFeatures(isPro: Bool, isStatusKnown: Bool) {
        guard isStatusKnown, !isPro else { return }
        if isMonitoringPaused {
            resumeMonitoring()
        }
        if !isMidnightResetEnabled {
            updateMidnightResetEnabled(true)
        }
        trimSelectionToFreeLimit()
    }

    /// Free users can track at most 1 app. Trims selection and re-saves if over the limit.
    private func trimSelectionToFreeLimit() {
        let sel = screenTimeService.selection
        let totalItems = sel.applicationTokens.count + sel.categoryTokens.count + sel.webDomainTokens.count
        guard totalItems > 1 else { return }
        var trimmed = FamilyActivitySelection()
        if let firstApp = sel.applicationTokens.first {
            trimmed.applicationTokens = [firstApp]
        }
        screenTimeService.selection = trimmed
        saveScreenSelection()
    }

    #if DEBUG && !HIDE_DEBUG_UI
    func refreshDeviceActivityDebug() {
        let fresh = storage.loadDeviceActivityDebugSnapshot()
        if fresh != deviceActivityDebug {
            deviceActivityDebug = fresh
        }
    }
    #endif

    func refreshSharedStateFromAppGroup() {
        reloadBalanceFromSharedStore()
        #if DEBUG && !HIDE_DEBUG_UI
        refreshDeviceActivityDebug()
        #endif
    }

    func startFocusSession() {
        focusStartError = nil
        let seconds = focusDurationMinutes * 60
        guard seconds > 0 else { return }
        screenTimeService.applyShield()
        isFocusSessionActive = true
        focusRemainingSeconds = seconds
        let startDate = Date()
        focusSessionStartedAt = startDate
        focusSessionPlannedSeconds = seconds
        let endsAt = startDate.addingTimeInterval(TimeInterval(seconds))
        focusSessionEndsAt = endsAt
        focusLiveActivityService.start(endsAt: endsAt, totalSeconds: seconds)
        storage.saveFocusSessionSnapshot(
            FocusSessionSnapshot(startedAt: startDate, endsAt: endsAt, plannedSeconds: seconds)
        )
        startFocusCountdownTask()
    }

    func endFocusSession() {
        guard isFocusSessionActive else { return }
        storage.clearFocusSessionSnapshot()
        let startDate = focusSessionStartedAt
        let plannedSeconds = focusSessionPlannedSeconds
        let elapsedByTimer = max(0, plannedSeconds - focusRemainingSeconds)
        let elapsedByClock: Int
        if let startDate {
            elapsedByClock = max(0, Int(Date().timeIntervalSince(startDate)))
        } else {
            elapsedByClock = 0
        }
        let focusDurationSeconds = min(plannedSeconds, max(elapsedByTimer, elapsedByClock))

        focusTask?.cancel()
        Task { [weak self] in
            guard let self else { return }
            await self.focusLiveActivityService.stop()
        }
        isFocusSessionActive = false
        focusSessionEndsAt = nil
        focusRemainingSeconds = 0
        focusStartError = nil
        focusSessionStartedAt = nil
        focusSessionPlannedSeconds = 0

        if focusDurationSeconds > 0 {
            prependLedger(
                ActivityLedgerEntry(
                    source: .focusSession,
                    deltaSeconds: 0,
                    note: L10n.tr("ledger.focus.session"),
                    focusDurationSeconds: focusDurationSeconds
                )
            )
        }

        // Focus session does not modify balance; avoid "Balance updated" notification.
        syncScreenTimeEnforcement(notifyOnUnlock: false)
    }

    /// Оставшиеся секунды до `endDate` по системным часам (как Live Activity с `endDate`).
    private static func focusRemainingSeconds(until endDate: Date, now: Date = .init()) -> Int {
        max(0, Int(endDate.timeIntervalSince(now).rounded(.down)))
    }

    /// После фона `Task.sleep` не тикает — подтягиваем UI и при необходимости завершаем сессию.
    private func syncFocusSessionWithWallClock() {
        guard isFocusSessionActive, let endsAt = focusSessionEndsAt else { return }
        let now = Date()
        if now >= endsAt {
            endFocusSession()
            return
        }
        let next = Self.focusRemainingSeconds(until: endsAt, now: now)
        if focusRemainingSeconds != next {
            focusRemainingSeconds = next
        }
    }

    private func startFocusCountdownTask() {
        focusTask?.cancel()
        focusTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                let shouldFinish = await MainActor.run { () -> Bool in
                    guard self.isFocusSessionActive, let endsAt = self.focusSessionEndsAt else { return true }
                    if Date() >= endsAt {
                        return true
                    }
                    self.focusRemainingSeconds = Self.focusRemainingSeconds(until: endsAt)
                    return false
                }
                if shouldFinish {
                    await MainActor.run {
                        self.endFocusSession()
                    }
                    return
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    /// Восстановление после kill: состояние в App Group + тот же `endsAt`, что у Live Activity.
    private func restoreFocusSessionIfNeeded() {
        guard let snapshot = storage.loadFocusSessionSnapshot() else { return }
        guard snapshot.plannedSeconds > 0, snapshot.endsAt > snapshot.startedAt else {
            storage.clearFocusSessionSnapshot()
            return
        }
        let now = Date()
        if now >= snapshot.endsAt {
            storage.clearFocusSessionSnapshot()
            let wallSeconds = max(0, Int(snapshot.endsAt.timeIntervalSince(snapshot.startedAt)))
            let focusDurationSeconds = min(snapshot.plannedSeconds, wallSeconds)
            if focusDurationSeconds > 0 {
                prependLedger(
                    ActivityLedgerEntry(
                        source: .focusSession,
                        deltaSeconds: 0,
                        note: L10n.tr("ledger.focus.session"),
                        focusDurationSeconds: focusDurationSeconds
                    )
                )
            }
            Task { await focusLiveActivityService.stop() }
            return
        }
        isFocusSessionActive = true
        focusSessionStartedAt = snapshot.startedAt
        focusSessionPlannedSeconds = snapshot.plannedSeconds
        focusSessionEndsAt = snapshot.endsAt
        focusRemainingSeconds = Self.focusRemainingSeconds(until: snapshot.endsAt, now: now)
        startFocusCountdownTask()
    }

    func clearFocusStartError() {
        focusStartError = nil
    }

    #if DEBUG && !HIDE_DEBUG_UI
    func consumeAllEarnedTimeForTesting() {
        let available = balance.availableSeconds
        guard available > 0 else { return }
        balance.totalSpentSeconds += available
        persistState()
        prependLedger(
            ActivityLedgerEntry(
                source: .testAdjustment,
                deltaSeconds: -available,
                note: L10n.tr("ledger.test.consume_all")
            )
        )
    }

    func addTenSecondsForTesting() {
        addSeconds(
            10,
            source: .testAdjustment,
            note: L10n.tr("ledger.test.add_ten_seconds")
        )
    }
    #endif

    func dailyStats() -> DailyStats {
        dailyStats(for: Date(), steps: todaySteps)
    }

    func dailyStats(for date: Date) async -> DailyStats {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: date)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start

        var steps = calendar.isDateInToday(date) ? todaySteps : 0
        if await healthService.hasStepReadAccess() {
            do {
                let queryEnd = min(end, Date())
                steps = try await healthService.fetchSteps(from: start, to: queryEnd)
            } catch {
                if calendar.isDateInToday(date) {
                    steps = todaySteps
                }
            }
        }

        return dailyStats(for: date, steps: steps)
    }

    func dailyStats(for date: Date, steps: Int) -> DailyStats {
        let calendar = Calendar.current
        let entries = dayLedgerEntries(for: date)
        let earned = entries
            .filter { $0.deltaSeconds > 0 }
            .reduce(0) { $0 + $1.deltaSeconds }
        let ledgerSpent = entries
            .filter { $0.deltaSeconds < 0 }
            .reduce(0) { $0 + abs($1.deltaSeconds) }
        // DeviceActivity spending is written to shared balance, not to local ledger.
        let spent: Int
        if calendar.isDateInToday(date) {
            let startOfToday = calendar.startOfDay(for: Date())
            let baselineDay = storage.loadSpentBaselineDayStart()
            let baselineSpent = storage.loadSpentBaselineTotalSpentSeconds()
            let deviceActivitySpentToday: Int
            if let baselineDay, calendar.isDate(baselineDay, inSameDayAs: startOfToday) {
                deviceActivitySpentToday = max(0, balance.totalSpentSeconds - baselineSpent)
            } else {
                deviceActivitySpentToday = 0
            }
            spent = max(ledgerSpent, deviceActivitySpentToday)
        } else {
            spent = ledgerSpent
        }
        let focusSessionTotalSeconds = entries
            .filter { $0.source == .focusSession }
            .reduce(0) { partial, entry in
                partial + max(0, entry.focusDurationSeconds ?? abs(entry.deltaSeconds))
            }
        let pushUps = entries
            .filter { $0.source == .pushUp }
            .reduce(0) { $0 + repetitionCount(for: $1) }
        let squats = entries
            .filter { $0.source == .squat }
            .reduce(0) { $0 + repetitionCount(for: $1) }

        return DailyStats(
            date: date,
            steps: steps,
            earnedSeconds: earned,
            spentSeconds: spent,
            pushUps: pushUps,
            squats: squats,
            focusSessionTotalSeconds: focusSessionTotalSeconds
        )
    }

    private func addSeconds(
        _ seconds: Int,
        source: LedgerEntrySource,
        note: String,
        repetitionCount: Int? = nil
    ) {
        balance.totalEarnedSeconds += seconds
        persistState()
        prependLedger(
            ActivityLedgerEntry(
                source: source,
                deltaSeconds: seconds,
                note: note,
                repetitionCount: repetitionCount
            )
        )
    }

    private func prependLedger(_ entry: ActivityLedgerEntry) {
        ledger.insert(entry, at: 0)
        if ledger.count > 200 {
            ledger = Array(ledger.prefix(200))
        }
        storage.saveLedger(ledger)
    }

    private func persistState() {
        storage.saveBalance(balance)
        syncScreenTimeEnforcement(notifyOnUnlock: true)
    }

    func appDidBecomeActive() {
        storage.saveMainAppIsActive(true)
        resetDailyBalanceIfNeeded()
        syncFocusSessionWithWallClock()
        screenTimeService.stopDeviceActivityMonitoring()
        refreshSharedStateFromAppGroup()
        syncScreenTimeEnforcement(notifyOnUnlock: false)
        startStepPolling()
        startSharedStateRefreshLoop()
        // Сначала свежие статусы, потом сброс подавления баннера — иначе один кадр с устаревшим Health и снова «нет доступа».
        Task {
            await refreshPermissionStatuses()
            permissionBannerSuppressedAfterCTA = false
            await refreshStepsAndRewards()
        }
    }

    func appDidEnterBackground() {
        storage.saveMainAppIsActive(false)
        stepsSyncCoordinator.stop()
        sharedStateTask?.cancel()
        sharedStateTask = nil
    }

    func appDidBecomeInactive() {
        storage.saveMainAppIsActive(false)
    }

    private func startStepPolling() {
        Task { [weak self] in
            guard let self else { return }
            guard await self.healthService.hasStepReadAccess() else { return }
            self.stepsSyncCoordinator.start { [weak self] in
                guard let self else { return }
                await self.refreshStepsAndRewards()
            }
        }
    }

    private func reloadBalanceFromSharedStore() {
        let freshBalance = storage.loadBalance()
        if freshBalance != balance {
            balance = freshBalance
            syncScreenTimeEnforcement(notifyOnUnlock: false)
        }
    }

    private func startSharedStateRefreshLoop() {
        sharedStateTask?.cancel()
        sharedStateTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                await MainActor.run {
                    self.refreshSharedStateFromAppGroup()
                }
            }
        }
    }

    private func syncScreenTimeEnforcement(notifyOnUnlock: Bool) {
        if isFocusSessionActive {
            screenTimeService.stopDeviceActivityMonitoring()
            screenTimeService.applyShield()
            return
        }

        if isMonitoringPaused {
            screenTimeService.stopDeviceActivityMonitoring()
            // Пауза должна временно отключать и мониторинг, и блокировку.
            screenTimeService.clearShield()
            return
        }

        let hasSelection = !screenTimeService.selection.applicationTokens.isEmpty ||
            !screenTimeService.selection.categoryTokens.isEmpty ||
            !screenTimeService.selection.webDomainTokens.isEmpty

        if hasSelection && balance.availableSeconds > 0 {
            if !screenTimeService.isMonitoringEnabled {
                _ = screenTimeService.startDeviceActivityMonitoring(availableSeconds: balance.availableSeconds)
            }
        } else {
            screenTimeService.stopDeviceActivityMonitoring()
        }

        if balance.availableSeconds <= 0 {
            screenTimeService.applyShield()
            return
        }

        screenTimeService.clearShield()
        if notifyOnUnlock {
            notificationService.notify(
                title: L10n.tr("notification.balance.updated.title"),
                body: L10n.f("notification.balance.updated.body", L10n.duration(seconds: balance.availableSeconds))
            )
        }
    }

    var canStartFocusSession: Bool {
        balance.availableSeconds >= focusDurationMinutes * 60
    }

    private func configureMainAppActivityTracking() {
        NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in
                self?.storage.saveMainAppIsActive(true)
            }
            .store(in: &lifecycleCancellables)

        NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)
            .sink { [weak self] _ in
                self?.storage.saveMainAppIsActive(false)
            }
            .store(in: &lifecycleCancellables)

        NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)
            .sink { [weak self] _ in
                self?.storage.saveMainAppIsActive(false)
            }
            .store(in: &lifecycleCancellables)
    }

    #if DEBUG && !HIDE_DEBUG_UI
    func diagnosticsReport() -> String {
        let hasSelection = !screenTimeService.selection.applicationTokens.isEmpty ||
            !screenTimeService.selection.categoryTokens.isEmpty ||
            !screenTimeService.selection.webDomainTokens.isEmpty

        let lines: [String] = [
            "=== ParentalControl Diagnostics ===",
            "app_time=\(Date().formatted(date: .abbreviated, time: .standard))",
            "isMonitoringPaused=\(isMonitoringPaused)",
            "isMonitoringEnabled=\(screenTimeService.isMonitoringEnabled)",
            "isAuthorized=\(screenTimeService.isAuthorized)",
            "mainAppIsActiveKey=\(storage.loadMainAppIsActive())",
            "mainAppStateTs=\(storage.loadMainAppStateTimestamp())",
            "hasSelection=\(hasSelection)",
            "selection_apps=\(screenTimeService.selection.applicationTokens.count)",
            "selection_categories=\(screenTimeService.selection.categoryTokens.count)",
            "selection_domains=\(screenTimeService.selection.webDomainTokens.count)",
            "balance_earned=\(balance.totalEarnedSeconds)",
            "balance_spent=\(balance.totalSpentSeconds)",
            "balance_available=\(balance.availableSeconds)",
            "debug_heartbeat_count=\(deviceActivityDebug.heartbeatCount)",
            "debug_last_event=\(deviceActivityDebug.lastEvent ?? "nil")",
            "debug_last_heartbeat=\(deviceActivityDebug.lastHeartbeatAt?.formatted(date: .omitted, time: .standard) ?? "nil")",
            "debug_warning_count=\(deviceActivityDebug.warningCount)",
            "debug_threshold_count=\(deviceActivityDebug.thresholdCount)",
            "debug_last_trigger=\(deviceActivityDebug.lastTrigger ?? "nil")",
            "debug_threshold_seconds=\(deviceActivityDebug.thresholdSeconds)",
            "debug_last_spent_delta=\(deviceActivityDebug.lastSpentDelta)",
            "debug_available_before=\(deviceActivityDebug.lastAvailableBefore)",
            "debug_available_after=\(deviceActivityDebug.lastAvailableAfter)",
            "debug_restart_count=\(deviceActivityDebug.restartCount)",
            "debug_last_start_monitoring=\(deviceActivityDebug.lastStartMonitoringAt?.formatted(date: .omitted, time: .standard) ?? "nil")",
            "debug_last_consumption=\(deviceActivityDebug.lastConsumptionAt?.formatted(date: .omitted, time: .standard) ?? "nil")",
            "debug_mirror_earned=\(deviceActivityDebug.mirrorEarnedSeconds)",
            "debug_mirror_spent=\(deviceActivityDebug.mirrorSpentSeconds)"
        ]

        return lines.joined(separator: "\n")
    }
    #endif

    private func processedStepsBaselineForToday() -> Int {
        let todayStart = Calendar.current.startOfDay(for: Date())
        if let storedDay = storage.loadLastProcessedStepsDayStart(),
           Calendar.current.isDate(storedDay, inSameDayAs: todayStart) {
            return storage.loadLastProcessedSteps()
        }

        // New day: reset baseline to today's HealthKit counter.
        storage.saveLastProcessedSteps(0)
        storage.saveLastProcessedStepsDayStart(todayStart)
        return 0
    }

    private func resetDailyBalanceIfNeeded() {
        let todayStart = Calendar.current.startOfDay(for: Date())
        if !isMidnightResetEnabled {
            if let resetDay = storage.loadLastBalanceResetDayStart(),
               Calendar.current.isDate(resetDay, inSameDayAs: todayStart) {
                ensureSpentBaselineForToday()
                return
            }
            storage.saveLastBalanceResetDayStart(todayStart)
            storage.saveSpentBaseline(totalSpentSeconds: balance.totalSpentSeconds, dayStart: todayStart)
            return
        }

        if let resetDay = storage.loadLastBalanceResetDayStart(),
           Calendar.current.isDate(resetDay, inSameDayAs: todayStart) {
            ensureSpentBaselineForToday()
            return
        }

        balance = .empty
        storage.saveBalance(balance)
        storage.saveLastBalanceResetDayStart(todayStart)
        storage.saveSpentBaseline(totalSpentSeconds: 0, dayStart: todayStart)
        syncScreenTimeEnforcement(notifyOnUnlock: false)
    }

    private func ensureSpentBaselineForToday() {
        let todayStart = Calendar.current.startOfDay(for: Date())
        if let baselineDay = storage.loadSpentBaselineDayStart(),
           Calendar.current.isDate(baselineDay, inSameDayAs: todayStart) {
            return
        }
        storage.saveSpentBaseline(totalSpentSeconds: balance.totalSpentSeconds, dayStart: todayStart)
    }

    private func dayLedgerEntries(for date: Date) -> [ActivityLedgerEntry] {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: date)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start
        return ledger.filter { $0.date >= start && $0.date < end }
    }

    private func repetitionCount(for entry: ActivityLedgerEntry) -> Int {
        if let repetitionCount = entry.repetitionCount {
            return max(0, repetitionCount)
        }
        let repsPerMinute: Int
        switch entry.source {
        case .squat:
            repsPerMinute = settings.squatsPerMinute
        case .pushUp:
            repsPerMinute = settings.pushUpsPerMinute
        default:
            repsPerMinute = max(settings.squatsPerMinute, settings.pushUpsPerMinute)
        }
        let estimated = Int((Double(max(0, entry.deltaSeconds)) / 60.0) * Double(repsPerMinute))
        return max(0, estimated)
    }
}
