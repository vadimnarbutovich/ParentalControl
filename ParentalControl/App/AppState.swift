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
    static let didReceiveRemotePayloadNotification = Notification.Name("parentalcontrol.didReceiveRemotePayload")
    static let didRegisterAPNSTokenNotification = Notification.Name("parentalcontrol.didRegisterAPNSToken")
    static let childBackgroundRefreshTaskIdentifier = "mycompny.parentalcontrol.child-refresh"
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
    @Published private(set) var deviceRole: DeviceRole?
    @Published private(set) var pairingState: DevicePairingState?
    @Published var pairingCodeInput: String = ""
    @Published private(set) var parentPairingCode: String?
    @Published private(set) var remoteChildState = RemoteChildRuntimeState(
        isFocusActive: false,
        focusEndsAt: nil,
        lastUpdatedAt: Date(timeIntervalSince1970: 0)
    )
    @Published private(set) var isParentChildStateResolved = false
    @Published private(set) var parentDesiredFocusActive: Bool?
    @Published private(set) var parentResolvedFocusActive: Bool?
    @Published private(set) var parentCommandDelivery: ParentCommandDeliveryState?
    @Published private(set) var parentLinkHealth: ParentLinkHealthState?
    @Published private(set) var parentChildAvailableSeconds: Int?
    @Published private(set) var remoteCommandInFlight = false
    @Published private(set) var remoteStatusMessage: String?
    /// Скрывает баннер после тапа «Разрешить» до следующего `appDidBecomeActive`.
    @Published private(set) var permissionBannerSuppressedAfterCTA = false
    /// Пока `false`, баннер разрешений не показываем — избегаем кадра с устаревшим `isHealthAuthorized` до async-обновления.
    @Published private(set) var permissionStatusesReady = false

    var isRemoteChildFocusEffectivelyActive: Bool {
        if let resolved = parentResolvedFocusActive {
            return resolved
        }
        if let health = parentLinkHealth,
           !health.childLikelyOnline,
           let desired = parentDesiredFocusActive {
            return desired
        }
        return isRemoteChildFocusSessionActive(remoteChildState)
    }

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
    private let remoteSyncService: ParentalRemoteSyncService
    private var focusTask: Task<Void, Never>?
    private var focusSessionStartedAt: Date?
    private var focusSessionPlannedSeconds: Int = 0
    private var sharedStateTask: Task<Void, Never>?
    private var remotePollingTask: Task<Void, Never>?
    private var parentCommandWatchTask: Task<Void, Never>?
    private var activeParentCommandID: UUID?
    /// Последний `normalized` runtime с `fetchParentSnapshot` — чтобы после `commandStatus=applied` дождаться того же согласования, что в `reconcile` (снимать «Синхронизацию» без кадра со старым CTA).
    private var lastNormalizedParentChildRuntime: RemoteChildRuntimeState?
    private var lifecycleCancellables = Set<AnyCancellable>()

    init() {
        let storage = AppGroupStore()
        let healthService: HealthKitProviding = HealthKitService()
        let notificationService: Notifying = NotificationService()
        let cameraService = CameraCaptureService()
        let remoteSyncService = ParentalRemoteSyncService(storage: storage)

        self.storage = storage
        self.healthService = healthService
        self.notificationService = notificationService
        self.cameraService = cameraService
        self.remoteSyncService = remoteSyncService
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
        self.deviceRole = storage.loadDeviceRole()
        self.pairingState = storage.loadPairingState()
        self.isParentChildStateResolved = !(self.deviceRole == .parent && self.pairingState?.isLinked == true)
        self.parentResolvedFocusActive = nil
        self.isHealthAuthorized = false
        self.isCameraAuthorized = AVCaptureDevice.authorizationStatus(for: .video) == .authorized
        configureMainAppActivityTracking()
        configurePushObservers()

        screenTimeService.refreshAuthorizationStatus()
        storage.saveMainAppIsActive(true)
        resetDailyBalanceIfNeeded()
        ensureSpentBaselineForToday()
        screenTimeService.stopDeviceActivityMonitoring()
        restoreFocusSessionIfNeeded()
        syncScreenTimeEnforcement(notifyOnUnlock: false)

        Task { await self.refreshPermissionStatuses() }
        Task { await self.bootstrapRemoteIfNeeded() }
    }

    deinit {
        focusTask?.cancel()
        sharedStateTask?.cancel()
        remotePollingTask?.cancel()
        parentCommandWatchTask?.cancel()
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
            await syncChildStatsSnapshotIfNeeded()
        }
    }

    func chooseDeviceRole(_ role: DeviceRole) {
        guard deviceRole != role else { return }
        storage.saveDeviceRole(role)
        deviceRole = role
        isParentChildStateResolved = role != .parent
        parentResolvedFocusActive = nil
        parentChildAvailableSeconds = nil
        if role != .parent { lastNormalizedParentChildRuntime = nil }
        if role == .parent {
            storage.saveHasCompletedOnboarding(true)
            hasCompletedOnboarding = true
        }
        Task {
            await bootstrapRemoteIfNeeded()
        }
    }

    func clearPairing() {
        pairingState = nil
        parentPairingCode = nil
        isParentChildStateResolved = true
        parentResolvedFocusActive = nil
        parentChildAvailableSeconds = nil
        lastNormalizedParentChildRuntime = nil
        storage.savePairingState(nil)
    }

    func createPairingCodeForParent() async {
        guard deviceRole == .parent else { return }
        do {
            let state = try await remoteSyncService.generatePairingCode()
            pairingState = state
            parentPairingCode = state.pairingCode
            remoteStatusMessage = nil
            storage.savePairingState(state)
        } catch {
            remoteStatusMessage = error.localizedDescription
        }
    }

    func connectChildWithPairingCode() async {
        guard deviceRole == .child else { return }
        let trimmed = pairingCodeInput.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !trimmed.isEmpty else { return }
        do {
            let state = try await remoteSyncService.joinPairingCode(trimmed)
            pairingState = state
            storage.savePairingState(state)
            remoteStatusMessage = nil
            startRemotePollingIfNeeded()
        } catch {
            remoteStatusMessage = error.localizedDescription
        }
    }

    func sendParentFocusCommand(start: Bool) async {
        let commandType: RemoteFocusCommandType = start ? .startFocus : .endFocus
        await sendParentCommand(commandType: commandType, durationSeconds: nil)
    }

    func sendParentTakeAllTimeCommand() async {
        await sendParentCommand(commandType: .resetEarnedBalance, durationSeconds: nil)
    }

    func sendParentAddOneMinuteCommand() async {
        await sendParentCommand(commandType: .addEarnedSeconds, durationSeconds: 60)
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

    /// Локальная фокус-сессия с таймером (на устройстве ребёнка UI не предлагает старт; оставлено для тестов и совместимости).
    func startFocusSession() {
        let seconds = focusDurationMinutes * 60
        guard seconds > 0 else { return }
        startTimedFocusSession(totalSeconds: seconds)
    }

    private func startTimedFocusSession(totalSeconds: Int) {
        focusStartError = nil
        guard totalSeconds > 0 else { return }
        screenTimeService.applyShield()
        isFocusSessionActive = true
        focusRemainingSeconds = totalSeconds
        let startDate = Date()
        focusSessionStartedAt = startDate
        focusSessionPlannedSeconds = totalSeconds
        let endsAt = startDate.addingTimeInterval(TimeInterval(totalSeconds))
        focusSessionEndsAt = endsAt
        focusLiveActivityService.start(endsAt: endsAt, totalSeconds: totalSeconds)
        storage.saveFocusSessionSnapshot(
            FocusSessionSnapshot(startedAt: startDate, endsAt: endsAt, plannedSeconds: totalSeconds)
        )
        startFocusCountdownTask()
    }

    /// Блокировка как при фокус-сессии (shield), без дедлайна — пока родитель не отключит.
    private func startIndefiniteFocusSession() {
        focusStartError = nil
        focusTask?.cancel()
        screenTimeService.applyShield()
        isFocusSessionActive = true
        focusRemainingSeconds = 0
        let startDate = Date()
        focusSessionStartedAt = startDate
        focusSessionPlannedSeconds = 0
        focusSessionEndsAt = nil
        storage.saveFocusSessionSnapshot(
            FocusSessionSnapshot(startedAt: startDate, endsAt: nil, plannedSeconds: 0)
        )
        syncScreenTimeEnforcement(notifyOnUnlock: false)
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
        let focusDurationSeconds: Int
        if focusSessionEndsAt == nil {
            focusDurationSeconds = elapsedByClock
        } else {
            focusDurationSeconds = min(plannedSeconds, max(elapsedByTimer, elapsedByClock))
        }

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
        Task { await syncChildStatsSnapshotIfNeeded() }
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

        if snapshot.endsAt == nil {
            guard snapshot.plannedSeconds == 0 else {
                storage.clearFocusSessionSnapshot()
                return
            }
            isFocusSessionActive = true
            focusSessionStartedAt = snapshot.startedAt
            focusSessionPlannedSeconds = 0
            focusSessionEndsAt = nil
            focusRemainingSeconds = 0
            focusTask?.cancel()
            syncScreenTimeEnforcement(notifyOnUnlock: false)
            return
        }

        guard let endsAt = snapshot.endsAt, snapshot.plannedSeconds > 0, endsAt > snapshot.startedAt else {
            storage.clearFocusSessionSnapshot()
            return
        }
        let now = Date()
        if now >= endsAt {
            storage.clearFocusSessionSnapshot()
            let wallSeconds = max(0, Int(endsAt.timeIntervalSince(snapshot.startedAt)))
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
        focusSessionEndsAt = endsAt
        focusRemainingSeconds = Self.focusRemainingSeconds(until: endsAt, now: now)
        startFocusCountdownTask()
    }

    func clearFocusStartError() {
        focusStartError = nil
    }

    func updateAPNSToken(_ token: String) {
        storage.saveAPNSToken(token)
        Task {
            do {
                try await remoteSyncService.updateAPNSToken(token)
            } catch {
                // Token sync retried on next bootstrap.
            }
        }
    }

    func handleRemoteNotificationPayload(_ userInfo: [AnyHashable: Any]) {
        guard let commandIDRaw = userInfo["command_id"] as? String,
              let commandID = UUID(uuidString: commandIDRaw) else {
            return
        }
        let commandTypeRaw = (userInfo["command_type"] as? String) ?? ""
        let commandType = RemoteFocusCommandType(rawValue: commandTypeRaw) ?? .startFocus
        let durationSeconds = userInfo["duration_seconds"] as? Int
        Task {
            await applyRemoteCommandIfNeeded(id: commandID, type: commandType, durationSeconds: durationSeconds)
        }
    }

    /// Awaitable entry point used by `AppDelegate.didReceiveRemoteNotification` and `willPresent`.
    /// Drains the App Group queue (commands captured by NSE while we were suspended) and
    /// applies the freshly-arrived payload. Then performs a full backend sync so we don't
    /// miss anything iOS may have throttled. Returns only after work is finished, allowing
    /// iOS to keep the app alive in the background until commands are acked to the backend.
    func applyAndDrainRemoteCommandsIfNeeded(initialPayload: [AnyHashable: Any]?) async {
        // 1) Drain App Group queue first — these are commands NSE captured while we were suspended.
        let pending = storage.drainPendingRemoteCommands()
        for item in pending {
            guard let uuid = UUID(uuidString: item.commandID) else { continue }
            let type = RemoteFocusCommandType(rawValue: item.commandType) ?? .startFocus
            await applyRemoteCommandIfNeeded(id: uuid, type: type, durationSeconds: item.durationSeconds)
        }

        // 2) Apply the freshly-arrived payload (idempotent via lastHandledRemoteCommandID).
        if let userInfo = initialPayload,
           let commandIDRaw = userInfo["command_id"] as? String,
           let commandID = UUID(uuidString: commandIDRaw) {
            let commandTypeRaw = (userInfo["command_type"] as? String) ?? ""
            let commandType = RemoteFocusCommandType(rawValue: commandTypeRaw) ?? .startFocus
            let durationSeconds = userInfo["duration_seconds"] as? Int
            await applyRemoteCommandIfNeeded(id: commandID, type: commandType, durationSeconds: durationSeconds)
        }

        // 3) Backend sweep — pull anything the push payload may have missed (collapsed / lost).
        if deviceRole == .child {
            await syncChildWithDesiredStateIfNeeded()
            await processPendingRemoteCommandsIfNeeded()
        }
    }

    private func bootstrapRemoteIfNeeded() async {
        guard let role = deviceRole else { return }
        do {
            let bootstrap = try await remoteSyncService.registerDevice(role: role)
            if let serverPair = bootstrap.pairingState {
                pairingState = serverPair
                storage.savePairingState(serverPair)
                if role == .parent {
                    parentPairingCode = serverPair.pairingCode
                    isParentChildStateResolved = false
                    parentResolvedFocusActive = nil
                }
            }
            if let apns = storage.loadAPNSToken() {
                try? await remoteSyncService.updateAPNSToken(apns)
            }
        } catch {
            remoteStatusMessage = error.localizedDescription
        }
        startRemotePollingIfNeeded()
    }

    private func startRemotePollingIfNeeded() {
        guard pairingState?.isLinked == true else { return }
        remotePollingTask?.cancel()
        remotePollingTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                if self.deviceRole == .child {
                    await self.syncChildWithDesiredStateIfNeeded()
                    await self.processPendingRemoteCommandsIfNeeded()
                    await self.syncChildStatsSnapshotIfNeeded()
                } else if self.deviceRole == .parent {
                    await self.refreshParentChildState()
                }
                try? await Task.sleep(nanoseconds: 4_000_000_000)
            }
        }
    }

    private func processPendingRemoteCommandsIfNeeded() async {
        guard deviceRole == .child, pairingState?.isLinked == true else { return }
        do {
            let commands = try await remoteSyncService.fetchPendingCommands()
            guard !commands.isEmpty else { return }
            let sorted = commands.sorted { $0.createdAt < $1.createdAt }
            if sorted.count > 1 {
                for stale in sorted.dropLast() {
                    // Avoid command burst after delayed delivery:
                    // only the latest parent intent is applied.
                    try? await remoteSyncService.ackCommand(
                        id: stale.id,
                        status: .failed,
                        errorMessage: "superseded_by_newer_command"
                    )
                }
            }
            guard let latest = sorted.last else { return }
            await applyRemoteCommandIfNeeded(
                id: latest.id,
                type: latest.commandType,
                durationSeconds: latest.durationSeconds
            )
        } catch {
            remoteStatusMessage = error.localizedDescription
        }
    }

    private func syncChildWithDesiredStateIfNeeded() async {
        guard deviceRole == .child, pairingState?.isLinked == true else { return }
        do {
            let desired = try await remoteSyncService.fetchDesiredFocusState()
            let localIsActive: Bool = {
                guard isFocusSessionActive else { return false }
                if let end = focusSessionEndsAt { return end > Date() }
                return true
            }()
            guard desired.shouldFocusActive != localIsActive else { return }

            if desired.shouldFocusActive {
                if let seconds = desired.durationSeconds, seconds > 0 {
                    focusDurationMinutes = max(1, seconds / 60)
                    startTimedFocusSession(totalSeconds: seconds)
                } else {
                    startIndefiniteFocusSession()
                }
            } else {
                endFocusSession()
            }

            let runtime = RemoteChildRuntimeState(
                isFocusActive: isFocusSessionActive,
                focusEndsAt: focusSessionEndsAt,
                lastUpdatedAt: Date()
            )
            remoteChildState = runtime
            try await remoteSyncService.updateChildRuntimeState(runtime)
        } catch {
            remoteStatusMessage = error.localizedDescription
        }
    }

    private func applyRemoteCommandIfNeeded(id: UUID, type: RemoteFocusCommandType, durationSeconds: Int?) async {
        if storage.loadLastHandledRemoteCommandID() == id.uuidString {
            try? await remoteSyncService.ackCommand(id: id, status: .applied, errorMessage: nil)
            return
        }
        // Visible banner is now produced by the APNs alert push itself (formed on the backend
        // with localized title/body via `commandLocalizedAlert`). We must NOT post a local
        // UNUserNotification here — otherwise the user gets two notifications for one command:
        // one from the server push and another from this local notify call.
        switch type {
        case .startFocus:
            if let durationSeconds, durationSeconds > 0 {
                focusDurationMinutes = max(1, durationSeconds / 60)
                startTimedFocusSession(totalSeconds: durationSeconds)
            } else {
                startIndefiniteFocusSession()
            }
        case .endFocus:
            endFocusSession()
        case .resetEarnedBalance:
            applyParentResetEarnedBalance()
        case .addEarnedSeconds:
            let secondsToAdd = max(0, durationSeconds ?? 0)
            if secondsToAdd > 0 {
                addSeconds(
                    secondsToAdd,
                    source: .parentAdjustment,
                    note: L10n.tr("ledger.parent.add_time")
                )
            }
        }
        storage.saveLastHandledRemoteCommandID(id.uuidString)
        let newState = RemoteChildRuntimeState(
            isFocusActive: isFocusSessionActive,
            focusEndsAt: focusSessionEndsAt,
            lastUpdatedAt: Date()
        )
        remoteChildState = newState
        do {
            try await remoteSyncService.ackCommand(id: id, status: .applied, errorMessage: nil)
            try await remoteSyncService.updateChildRuntimeState(newState)
        } catch {
            remoteStatusMessage = error.localizedDescription
        }
    }

    private func refreshParentChildState() async {
        guard deviceRole == .parent, pairingState?.isLinked == true else {
            parentChildAvailableSeconds = nil
            return
        }
        var lastError: Error?
        for attempt in 0..<2 {
            if let desired = try? await remoteSyncService.fetchDesiredFocusState() {
                parentDesiredFocusActive = desired.shouldFocusActive
            }
            do {
                let snapshot = try await remoteSyncService.fetchParentSnapshot()
                parentLinkHealth = try? await remoteSyncService.fetchLinkHealth()

                let actualRuntime = normalizedRuntimeForParent(snapshot.runtime)
                lastNormalizedParentChildRuntime = actualRuntime
                // Сравниваем команду с фактическим runtime (не с «проекцией» desired) — иначе UI переключался бы до apply.
                reconcileParentCommandWithRuntime(actualRuntime)

                if remoteCommandInFlight {
                    remoteChildState = actualRuntime
                    parentResolvedFocusActive = isFocusActiveNowOnParentUI(actualRuntime)
                } else {
                    // «Desired» в БД может кратковременно отставать от `child_runtime` сразу после apply —
                    // тогда CTA нельзя брать из desired, иначе мигание: Заблокировать → (старый) → Разблокировать.
                    let useDesiredProjection = parentLinkHealth.map { !$0.childLikelyOnline } ?? false
                    var displayRuntime = actualRuntime
                    if useDesiredProjection, let desired = parentDesiredFocusActive {
                        displayRuntime = runtimeFromDesiredFallback(desired, current: actualRuntime)
                    }
                    remoteChildState = displayRuntime
                    if useDesiredProjection, let desired = parentDesiredFocusActive {
                        parentResolvedFocusActive = desired
                    } else {
                        parentResolvedFocusActive = isFocusActiveNowOnParentUI(actualRuntime)
                    }
                }
                if let childAvailable = try? await remoteSyncService.fetchChildBalanceState() {
                    parentChildAvailableSeconds = childAvailable
                }
                isParentChildStateResolved = true
                return
            } catch {
                lastError = error
                if remoteCommandInFlight {
                    if attempt == 0 { try? await Task.sleep(nanoseconds: 400_000_000) }
                } else if let desired = parentDesiredFocusActive {
                    remoteChildState = runtimeFromDesiredFallback(desired, current: remoteChildState)
                    parentResolvedFocusActive = desired
                    isParentChildStateResolved = true
                    return
                } else if attempt == 0 {
                    try? await Task.sleep(nanoseconds: 400_000_000)
                }
            }
        }
        if let lastError {
            if !remoteCommandInFlight {
                parentResolvedFocusActive = nil
                isParentChildStateResolved = false
            }
            remoteStatusMessage = lastError.localizedDescription
        }
    }

    /// Фокус/блок на устройстве ребёнка: с дедлайном в будущем **или** открытый конец (`isFocusActive` без `focusEndsAt` / по смыслу remote block).
    private func isRemoteChildFocusSessionActive(_ runtime: RemoteChildRuntimeState) -> Bool {
        guard runtime.isFocusActive else { return false }
        if let end = runtime.focusEndsAt { return end > Date() }
        return true
    }

    private func isFocusActiveNowOnParentUI(_ runtime: RemoteChildRuntimeState) -> Bool {
        isRemoteChildFocusSessionActive(runtime)
    }

    private func runtimeFromDesiredFallback(_ desiredActive: Bool, current: RemoteChildRuntimeState) -> RemoteChildRuntimeState {
        guard desiredActive else {
            return RemoteChildRuntimeState(
                isFocusActive: false,
                focusEndsAt: nil,
                lastUpdatedAt: current.lastUpdatedAt
            )
        }
        if current.isFocusActive, let endsAt = current.focusEndsAt, endsAt > Date() {
            return current
        }
        return RemoteChildRuntimeState(
            isFocusActive: true,
            focusEndsAt: nil,
            lastUpdatedAt: current.lastUpdatedAt
        )
    }

    private func watchParentCommandUntilTerminal(commandID: UUID, timeoutSeconds: Int) async {
        // Parent keeps spinner while waiting for child apply/ack.
        let ticks = max(1, timeoutSeconds)
        for tick in 0..<ticks {
            guard !Task.isCancelled else {
                finishParentCommandWatch(commandID: commandID)
                return
            }
            if tick % 3 == 0 {
                do {
                    let retrySummary = try await remoteSyncService.retryStuckCommands()
                    if retrySummary.retried > 0 {
                        remoteStatusMessage = L10n.f("parent.command.retrying_batch", retrySummary.retried)
                    }
                } catch {
                    // Retry helper is best-effort and should not break command status polling.
                }
            }
            do {
                if let status = try await remoteSyncService.fetchCommandStatus(commandID: commandID) {
                    parentCommandDelivery = ParentCommandDeliveryState(
                        commandID: status.id,
                        commandType: status.commandType,
                        status: status.status,
                        queuedAt: status.createdAt,
                        updatedAt: status.updatedAt,
                        appliedAt: status.appliedAt,
                        errorMessage: status.errorMessage
                    )
                    if status.status == .applied {
                        if let latency = parentCommandDelivery?.latencySeconds {
                            remoteStatusMessage = L10n.f("parent.command.applied.latency", latency)
                        } else {
                            remoteStatusMessage = L10n.tr("parent.command.applied")
                        }
                        if status.commandType == .startFocus || status.commandType == .endFocus {
                            // `command_status=applied` часто приходит раньше, чем `child_runtime` в snapshot обновлён
                            // — снимаем «Синхронизацию» только когда runtime согласован с типом команды (как в `reconcile`).
                            await self.waitForParentSnapshotToMatchAppliedCommand(
                                commandID: commandID,
                                commandType: status.commandType
                            )
                        } else {
                            finishParentCommandWatch(commandID: commandID)
                            await refreshParentChildState()
                        }
                        return
                    }
                    if status.status == .failed {
                        remoteStatusMessage = status.errorMessage ?? L10n.tr("parent.command.failed")
                        finishParentCommandWatch(commandID: commandID)
                        await refreshParentChildState()
                        return
                    }
                }
            } catch {
                remoteStatusMessage = error.localizedDescription
            }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        remoteStatusMessage = L10n.tr("parent.command.timeout")
        finishParentCommandWatch(commandID: commandID)
        await refreshParentChildState()
    }

    private func waitForParentSnapshotToMatchAppliedCommand(commandID: UUID, commandType: RemoteFocusCommandType) async {
        for _ in 0..<10 {
            if Task.isCancelled {
                if activeParentCommandID == commandID { finishParentCommandWatch(commandID: commandID) }
                return
            }
            await refreshParentChildState()
            if let r = lastNormalizedParentChildRuntime, runtimeMatchesCommand(r, commandType: commandType) {
                finishParentCommandWatch(commandID: commandID)
                return
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        // `applied` на бэке есть; снапшот иногда «не сходится» по полям, но `status=applied` уже отражает применение — выставляем CTA от типа команды. Без немедленного `refresh` здесь: иначе устаревший snapshot снова даст неверный `parentResolved`.
        parentResolvedFocusActive = (commandType == .startFocus)
        remoteChildState = runtimeFromDesiredFallback(commandType == .startFocus, current: remoteChildState)
        isParentChildStateResolved = true
        finishParentCommandWatch(commandID: commandID)
    }

    private func finishParentCommandWatch(commandID: UUID) {
        guard activeParentCommandID == commandID else { return }
        activeParentCommandID = nil
        remoteCommandInFlight = false
    }

    private func reconcileParentCommandWithRuntime(_ runtime: RemoteChildRuntimeState) {
        guard let delivery = parentCommandDelivery else { return }
        guard delivery.status != .applied, delivery.status != .failed else { return }
        guard runtimeMatchesCommand(runtime, commandType: delivery.commandType) else { return }

        parentCommandDelivery = ParentCommandDeliveryState(
            commandID: delivery.commandID,
            commandType: delivery.commandType,
            status: .applied,
            queuedAt: delivery.queuedAt,
            updatedAt: runtime.lastUpdatedAt,
            appliedAt: runtime.lastUpdatedAt,
            errorMessage: nil
        )
        if let latency = parentCommandDelivery?.latencySeconds {
            remoteStatusMessage = L10n.f("parent.command.applied.latency", latency)
        } else {
            remoteStatusMessage = L10n.tr("parent.command.applied")
        }
        if activeParentCommandID == delivery.commandID {
            finishParentCommandWatch(commandID: delivery.commandID)
            parentCommandWatchTask?.cancel()
        }
    }

    private func runtimeMatchesCommand(_ runtime: RemoteChildRuntimeState, commandType: RemoteFocusCommandType) -> Bool {
        let isActiveNow = isRemoteChildFocusSessionActive(runtime)
        switch commandType {
        case .startFocus:
            return isActiveNow
        case .endFocus:
            return !isActiveNow
        case .resetEarnedBalance, .addEarnedSeconds:
            return true
        }
    }

    private func sendParentCommand(commandType: RemoteFocusCommandType, durationSeconds: Int?) async {
        guard deviceRole == .parent, pairingState?.isLinked == true else { return }
        remoteCommandInFlight = true
        remoteStatusMessage = L10n.tr("parent.command.processing")
        if commandType == .startFocus {
            parentDesiredFocusActive = true
        } else if commandType == .endFocus {
            parentDesiredFocusActive = false
        }
        let intentID = UUID()
        do {
            let command: RemoteFocusCommand
            if commandType == .startFocus || commandType == .endFocus {
                command = try await remoteSyncService.replaceFocusCommand(
                    commandType: commandType,
                    durationSeconds: durationSeconds,
                    intentID: intentID
                )
            } else {
                command = try await remoteSyncService.queueBalanceCommand(
                    commandType: commandType,
                    durationSeconds: durationSeconds,
                    intentID: intentID
                )
            }
            parentCommandDelivery = ParentCommandDeliveryState(
                commandID: command.id,
                commandType: command.commandType,
                status: command.status,
                queuedAt: command.createdAt,
                updatedAt: command.updatedAt,
                appliedAt: nil,
                errorMessage: nil
            )
            parentCommandWatchTask?.cancel()
            activeParentCommandID = command.id
            parentCommandWatchTask = Task { [weak self] in
                guard let self else { return }
                await self.watchParentCommandUntilTerminal(commandID: command.id, timeoutSeconds: 10)
            }
            await refreshParentChildState()
        } catch {
            activeParentCommandID = nil
            remoteCommandInFlight = false
            remoteStatusMessage = error.localizedDescription
        }
    }

    private func applyParentResetEarnedBalance() {
        let available = balance.availableSeconds
        guard available > 0 else { return }
        balance.totalSpentSeconds += available
        persistState()
        prependLedger(
            ActivityLedgerEntry(
                source: .parentAdjustment,
                deltaSeconds: -available,
                note: L10n.tr("ledger.parent.take_all_time")
            )
        )
        Task { await syncChildStatsSnapshotIfNeeded() }
    }

    private func normalizedRuntimeForParent(_ runtime: RemoteChildRuntimeState) -> RemoteChildRuntimeState {
        if !runtime.isFocusActive { return runtime }
        if let endsAt = runtime.focusEndsAt {
            if endsAt > Date() { return runtime }
            // Срок вышел — сессия неактивна.
            return RemoteChildRuntimeState(
                isFocusActive: false,
                focusEndsAt: nil,
                lastUpdatedAt: runtime.lastUpdatedAt
            )
        }
        // Активна без дедлайна: не сбрасывать (раньше ошибочно превращалось в «неактивна» и вечно ждали match).
        return runtime
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
        if deviceRole == .parent, pairingState?.isLinked == true {
            do {
                if let remoteDay = try await remoteSyncService.fetchChildDayStats(for: date) {
                    return remoteDay
                }
            } catch {
                remoteStatusMessage = error.localizedDescription
            }
            return DailyStats(
                date: date,
                steps: 0,
                earnedSeconds: 0,
                spentSeconds: 0,
                pushUps: 0,
                squats: 0,
                focusSessionTotalSeconds: 0
            )
        }
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

    private func syncChildStatsSnapshotIfNeeded() async {
        guard deviceRole == .child, pairingState?.isLinked == true else { return }
        let today = dailyStats(for: Date(), steps: todaySteps)
        do {
            try await remoteSyncService.upsertChildDayStats(today)
            let runtime = RemoteChildRuntimeState(
                isFocusActive: isFocusSessionActive,
                focusEndsAt: focusSessionEndsAt,
                lastUpdatedAt: Date()
            )
            try await remoteSyncService.updateChildRuntimeState(runtime)
            try? await remoteSyncService.updateChildBalanceState(availableSeconds: balance.availableSeconds)
        } catch {
            remoteStatusMessage = error.localizedDescription
        }
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
        Task { await syncChildStatsSnapshotIfNeeded() }
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
            await bootstrapRemoteIfNeeded()
            // Drain commands captured by NSE / earlier push handlers while suspended,
            // before pulling fresh state — ensures the latest parent intent wins.
            await applyAndDrainRemoteCommandsIfNeeded(initialPayload: nil)
            await refreshParentChildState()
        }
    }

    func appDidEnterBackground() {
        storage.saveMainAppIsActive(false)
        stepsSyncCoordinator.stop()
        sharedStateTask?.cancel()
        sharedStateTask = nil
        // Keep remote polling alive for child mode as long as iOS allows background execution.
        if deviceRole == .parent {
            remotePollingTask?.cancel()
            remotePollingTask = nil
        }
    }

    /// Used by BGAppRefresh task to recover missed pushes when app stays closed for long periods.
    func performChildBackgroundRefreshSync() async -> Bool {
        guard deviceRole == .child, pairingState?.isLinked == true else { return false }
        await bootstrapRemoteIfNeeded()
        await syncChildWithDesiredStateIfNeeded()
        await processPendingRemoteCommandsIfNeeded()
        await syncChildStatsSnapshotIfNeeded()
        return true
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

    private func configurePushObservers() {
        NotificationCenter.default.publisher(for: Self.didRegisterAPNSTokenNotification)
            .sink { [weak self] notification in
                guard let token = notification.object as? String else { return }
                self?.updateAPNSToken(token)
            }
            .store(in: &lifecycleCancellables)

        NotificationCenter.default.publisher(for: Self.didReceiveRemotePayloadNotification)
            .sink { [weak self] notification in
                guard let payload = notification.object as? [AnyHashable: Any] else { return }
                self?.handleRemoteNotificationPayload(payload)
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

private struct ParentSnapshotDTO: Codable {
    let runtime: RemoteChildRuntimeState
}

private struct RegisterDeviceResponseDTO: Codable {
    let deviceSecret: String
    let pairingState: DevicePairingState?
}

private struct PendingCommandDTO: Codable {
    let id: UUID
    let familyID: UUID
    let commandType: RemoteFocusCommandType
    let durationSeconds: Int?
    let status: RemoteFocusCommandStatus
    let createdAt: Date
    let updatedAt: Date
}

private struct CommandStatusDTO: Codable {
    let id: UUID
    let commandType: RemoteFocusCommandType
    let status: RemoteFocusCommandStatus
    let errorMessage: String?
    let createdAt: Date
    let updatedAt: Date
    let appliedAt: Date?
}

private struct RetrySummaryDTO: Codable {
    let retried: Int
    let failed: Int
    let skipped: Int
}

private struct LinkHealthDTO: Codable {
    let pendingCommands: Int
    let oldestPendingAgeSeconds: Int?
    let childLastSeenAgeSeconds: Int?
    let childLikelyOnline: Bool
    let recentFailedCommands30m: Int
}

private struct DesiredFocusStateDTO: Codable {
    let shouldFocusActive: Bool
    let durationSeconds: Int?
    let updatedAt: Date
}

private struct BackendDayStatsDTO: Codable {
    let dayStartISO: String
    let steps: Int
    let earnedSeconds: Int
    let spentSeconds: Int
    let pushUps: Int
    let squats: Int
    let focusSessionTotalSeconds: Int
}

private final class ParentalRemoteSyncService {
    private enum Endpoint {
        static let focusBaseURL = URL(string: "https://tzpalbdmfsaeinciiyac.supabase.co/functions/v1/parental-control-sync")!
        static let balanceBaseURL = URL(string: "https://tzpalbdmfsaeinciiyac.supabase.co/functions/v1/parental-control-balance-sync")!
        static let anonKey = "sb_publishable_Rz5hfd6b5I90Eipwk3fFrQ_5ALQnDdB"
    }

    private enum SyncError: LocalizedError {
        case roleNotSelected
        case missingDeviceSecret
        case invalidServerResponse

        var errorDescription: String? {
            switch self {
            case .roleNotSelected:
                return L10n.tr("remote.error.role_required")
            case .missingDeviceSecret:
                return L10n.tr("remote.error.register_required")
            case .invalidServerResponse:
                return L10n.tr("remote.error.invalid_response")
            }
        }
    }

    private struct RequestEnvelope<T: Encodable>: Encodable {
        let action: String
        let payload: T
    }

    private let storage: AppGroupStore
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let session: URLSession
    private let installID: String
    private let decodeISO8601 = ISO8601DateFormatter()
    private let decodeISO8601Fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private let encodeISO8601Fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    init(storage: AppGroupStore) {
        self.storage = storage
        self.session = .shared
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
        encoder.dateEncodingStrategy = .custom { [encodeISO8601Fractional] date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(encodeISO8601Fractional.string(from: date))
        }
        decoder.dateDecodingStrategy = .custom { [decodeISO8601, decodeISO8601Fractional] decoder in
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)
            if let date = decodeISO8601Fractional.date(from: raw) ?? decodeISO8601.date(from: raw) {
                return date
            }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported date format: \(raw)"
            )
        }
        if let saved = storage.loadDeviceInstallID() {
            installID = saved
        } else {
            let newID = UUID().uuidString
            installID = newID
            storage.saveDeviceInstallID(newID)
        }
    }

    func registerDevice(role: DeviceRole) async throws -> RegisterDeviceResponseDTO {
        struct Payload: Encodable {
            let installID: String
            let role: String
        }
        let response: RegisterDeviceResponseDTO = try await call(
            action: "register_device",
            payload: Payload(installID: installID, role: role.rawValue),
            includeSecret: false
        )
        storage.saveDeviceSecret(response.deviceSecret)
        return response
    }

    func generatePairingCode() async throws -> DevicePairingState {
        struct Payload: Encodable { let installID: String }
        return try await call(action: "generate_pairing_code", payload: Payload(installID: installID))
    }

    func joinPairingCode(_ code: String) async throws -> DevicePairingState {
        struct Payload: Encodable {
            let installID: String
            let pairingCode: String
        }
        return try await call(
            action: "join_pairing_code",
            payload: Payload(installID: installID, pairingCode: code)
        )
    }

    func updateAPNSToken(_ token: String) async throws {
        struct Payload: Encodable {
            let installID: String
            let apnsToken: String
        }
        let _: EmptyResponse = try await call(
            action: "update_apns_token",
            payload: Payload(installID: installID, apnsToken: token)
        )
    }

    func queueFocusCommand(start: Bool, durationSeconds: Int?) async throws -> RemoteFocusCommand {
        struct Payload: Encodable {
            let installID: String
            let commandType: String
            let durationSeconds: Int?
        }
        let commandType: String = start ? RemoteFocusCommandType.startFocus.rawValue : RemoteFocusCommandType.endFocus.rawValue
        return try await call(
            action: "queue_focus_command",
            payload: Payload(installID: installID, commandType: commandType, durationSeconds: durationSeconds)
        )
    }

    func replaceFocusCommand(
        commandType: RemoteFocusCommandType,
        durationSeconds: Int?,
        intentID: UUID
    ) async throws -> RemoteFocusCommand {
        struct Payload: Encodable {
            let installID: String
            let commandType: String
            let durationSeconds: Int?
            let intentID: String
        }
        return try await call(
            action: "replace_focus_command",
            payload: Payload(
                installID: installID,
                commandType: commandType.rawValue,
                durationSeconds: durationSeconds,
                intentID: intentID.uuidString
            ),
            endpoint: Endpoint.focusBaseURL
        )
    }

    func queueBalanceCommand(
        commandType: RemoteFocusCommandType,
        durationSeconds: Int?,
        intentID: UUID
    ) async throws -> RemoteFocusCommand {
        struct Payload: Encodable {
            let installID: String
            let commandType: String
            let durationSeconds: Int?
            let intentID: String
        }
        return try await call(
            action: "queue_balance_command",
            payload: Payload(
                installID: installID,
                commandType: commandType.rawValue,
                durationSeconds: durationSeconds,
                intentID: intentID.uuidString
            ),
            endpoint: Endpoint.balanceBaseURL
        )
    }

    func updateChildBalanceState(availableSeconds: Int) async throws {
        struct Payload: Encodable {
            let installID: String
            let availableSeconds: Int
        }
        let _: EmptyResponse = try await call(
            action: "update_child_balance",
            payload: Payload(
                installID: installID,
                availableSeconds: max(0, availableSeconds)
            ),
            endpoint: Endpoint.balanceBaseURL
        )
    }

    func fetchChildBalanceState() async throws -> Int {
        struct Payload: Encodable { let installID: String }
        struct Response: Decodable { let availableSeconds: Int }
        let response: Response = try await call(
            action: "fetch_child_balance",
            payload: Payload(installID: installID),
            endpoint: Endpoint.balanceBaseURL
        )
        return max(0, response.availableSeconds)
    }

    func fetchPendingCommands() async throws -> [RemoteFocusCommand] {
        struct Payload: Encodable { let installID: String }
        let dtos: [PendingCommandDTO] = try await call(
            action: "fetch_pending_commands",
            payload: Payload(installID: installID)
        )
        return dtos.map {
            RemoteFocusCommand(
                id: $0.id,
                familyID: $0.familyID,
                commandType: $0.commandType,
                durationSeconds: $0.durationSeconds,
                status: $0.status,
                createdAt: $0.createdAt,
                updatedAt: $0.updatedAt
            )
        }
    }

    func fetchCommandStatus(commandID: UUID) async throws -> CommandStatusDTO? {
        struct Payload: Encodable {
            let installID: String
            let commandID: String
        }
        return try await call(
            action: "fetch_command_status",
            payload: Payload(installID: installID, commandID: commandID.uuidString)
        )
    }

    func retryStuckCommands() async throws -> RetrySummaryDTO {
        struct Payload: Encodable {
            let installID: String
            let maxBatch: Int
            let minAgeSeconds: Int
        }
        return try await call(
            action: "retry_stuck_commands",
            payload: Payload(installID: installID, maxBatch: 4, minAgeSeconds: 20)
        )
    }

    func ackCommand(id: UUID, status: RemoteFocusCommandStatus, errorMessage: String?) async throws {
        struct Payload: Encodable {
            let installID: String
            let commandID: String
            let status: String
            let errorMessage: String?
        }
        let _: EmptyResponse = try await call(
            action: "ack_command",
            payload: Payload(
                installID: installID,
                commandID: id.uuidString,
                status: status.rawValue,
                errorMessage: errorMessage
            )
        )
    }

    func upsertChildDayStats(_ stats: DailyStats) async throws {
        struct Payload: Encodable {
            let installID: String
            let dayStartISO: String
            let steps: Int
            let earnedSeconds: Int
            let spentSeconds: Int
            let pushUps: Int
            let squats: Int
            let focusSessionTotalSeconds: Int
        }
        let dayStart = Calendar.current.startOfDay(for: stats.date)
        let dayISO = ISO8601DateFormatter().string(from: dayStart)
        let _: EmptyResponse = try await call(
            action: "upsert_child_day_stats",
            payload: Payload(
                installID: installID,
                dayStartISO: dayISO,
                steps: stats.steps,
                earnedSeconds: stats.earnedSeconds,
                spentSeconds: stats.spentSeconds,
                pushUps: stats.pushUps,
                squats: stats.squats,
                focusSessionTotalSeconds: stats.focusSessionTotalSeconds
            )
        )
    }

    func fetchChildDayStats(for date: Date) async throws -> DailyStats? {
        struct Payload: Encodable {
            let installID: String
            let dayStartISO: String
        }
        let dayStart = Calendar.current.startOfDay(for: date)
        let dayISO = ISO8601DateFormatter().string(from: dayStart)
        let dto: BackendDayStatsDTO? = try await call(
            action: "fetch_child_day_stats",
            payload: Payload(installID: installID, dayStartISO: dayISO)
        )
        guard let dto else { return nil }
        let parsedDate = ISO8601DateFormatter().date(from: dto.dayStartISO) ?? dayStart
        return DailyStats(
            date: parsedDate,
            steps: dto.steps,
            earnedSeconds: dto.earnedSeconds,
            spentSeconds: dto.spentSeconds,
            pushUps: dto.pushUps,
            squats: dto.squats,
            focusSessionTotalSeconds: dto.focusSessionTotalSeconds
        )
    }

    func updateChildRuntimeState(_ state: RemoteChildRuntimeState) async throws {
        struct Payload: Encodable {
            let installID: String
            let isFocusActive: Bool
            let focusEndsAt: String?
        }
        let endISO = state.focusEndsAt.map { ISO8601DateFormatter().string(from: $0) }
        let _: EmptyResponse = try await call(
            action: "update_child_runtime",
            payload: Payload(installID: installID, isFocusActive: state.isFocusActive, focusEndsAt: endISO)
        )
    }

    func fetchParentSnapshot() async throws -> ParentSnapshotDTO {
        struct Payload: Encodable { let installID: String }
        return try await call(action: "fetch_parent_snapshot", payload: Payload(installID: installID))
    }

    func fetchLinkHealth() async throws -> ParentLinkHealthState {
        struct Payload: Encodable { let installID: String }
        let dto: LinkHealthDTO = try await call(action: "fetch_link_health", payload: Payload(installID: installID))
        return ParentLinkHealthState(
            pendingCommands: dto.pendingCommands,
            oldestPendingAgeSeconds: dto.oldestPendingAgeSeconds,
            childLastSeenAgeSeconds: dto.childLastSeenAgeSeconds,
            childLikelyOnline: dto.childLikelyOnline,
            recentFailedCommands30m: dto.recentFailedCommands30m
        )
    }

    func fetchDesiredFocusState() async throws -> DesiredFocusStateDTO {
        struct Payload: Encodable { let installID: String }
        return try await call(action: "fetch_desired_focus_state", payload: Payload(installID: installID))
    }

    private func call<T: Decodable, P: Encodable>(
        action: String,
        payload: P,
        includeSecret: Bool = true,
        endpoint: URL? = nil
    ) async throws -> T {
        let endpointURL = endpoint ?? Endpoint.focusBaseURL
        var request = URLRequest(url: endpointURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Endpoint.anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(Endpoint.anonKey)", forHTTPHeaderField: "Authorization")
        request.setValue(installID, forHTTPHeaderField: "x-device-install-id")
        if includeSecret {
            guard let secret = storage.loadDeviceSecret(), !secret.isEmpty else {
                throw SyncError.missingDeviceSecret
            }
            request.setValue(secret, forHTTPHeaderField: "x-device-secret")
        }
        request.httpBody = try encoder.encode(RequestEnvelope(action: action, payload: payload))
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw SyncError.invalidServerResponse
        }
        guard (200...299).contains(http.statusCode) else {
            if let decoded = try? decoder.decode(ErrorResponse.self, from: data),
               let msg = decoded.error {
                throw NSError(domain: "ParentalRemoteSync", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: msg])
            }
            throw NSError(
                domain: "ParentalRemoteSync",
                code: http.statusCode,
                userInfo: [NSLocalizedDescriptionKey: L10n.tr("remote.error.network_generic")]
            )
        }
        if T.self == EmptyResponse.self {
            return EmptyResponse() as! T
        }
        return try decoder.decode(T.self, from: data)
    }

    private struct EmptyResponse: Codable {}
    private struct ErrorResponse: Codable { let error: String? }
}
