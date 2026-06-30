import AVFoundation
import Combine
import CoreLocation
import FamilyControls
import Foundation
import HealthKit
import os.log
import UIKit

private let appStateLog = OSLog(subsystem: "mycompny.ParentalControl", category: "AppState")

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
    /// Дневная статистика ребёнка для верхней «balance»-карточки родителя (`Заработано/Потрачено`).
    /// Заполняется в `refreshParentChildState()` из `fetchParentSnapshot.dailyStats`. `nil` — пока не пришло.
    @Published private(set) var parentChildEarnedSecondsToday: Int?
    @Published private(set) var parentChildSpentSecondsToday: Int?
    @Published private(set) var remoteCommandInFlight = false
    @Published private(set) var remoteStatusMessage: String?
    /// Список расписаний блокировки: на родителе редактируется и синкается с сервером; на ребёнке
    /// подставляется из `list_block_schedules` и применяется через Device Activity + named shields.
    @Published private(set) var blockSchedules: [BlockSchedule] = []
    /// Последняя известная координата ребёнка. Хранится также в App Group, чтобы
    /// карта моментально показывала «вчерашнюю» точку до того, как сервер ответит.
    @Published private(set) var childLocationSnapshot: ChildLocationSnapshot?
    /// Флаг для UI карты: показываем спиннер, пока ждём ответ ребёнка.
    @Published private(set) var isParentRefreshingChildLocation = false
    /// Сообщение об ошибке последнего refresh — отображается на карте.
    @Published private(set) var parentLocationStatusMessage: String?
    /// Локально на ребёнке — статус разрешения геолокации (для онбординга/настроек).
    @Published private(set) var childLocationAuthorizationStatus: CLAuthorizationStatus = .notDetermined
    /// Скрывает баннер после тапа «Разрешить» до следующего `appDidBecomeActive`.
    @Published private(set) var permissionBannerSuppressedAfterCTA = false
    /// Пока `false`, баннер разрешений не показываем — избегаем кадра с устаревшим `isHealthAuthorized` до async-обновления.
    @Published private(set) var permissionStatusesReady = false
    /// `true`, когда ребёнок успешно ввёл родительский PIN и сейчас доступны «скрытые» табы
    /// `Блокировка` / `Настройки`. Сбрасывается в `false` при `appDidEnterBackground`, смене роли,
    /// разрыве пейринга и тапе по красной плашке «Выход».
    @Published private(set) var isParentModeActive = false
    /// `true`, если в Keychain есть кэшированный родительский PIN (хэш+соль). У ребёнка обновляется
    /// при каждом успешном `refreshChildParentPinIfNeeded`. У родителя — после `setParentPinFromUI`.
    /// UI ориентируется на этот флаг, чтобы знать, можно ли вообще пытаться вводить PIN.
    @Published private(set) var parentPinIsSet = false
    /// Конец активного lockout-таймера, если он сейчас идёт (после 5 неверных попыток PIN).
    /// `nil` — lockout не активен. UI на экране ввода показывает обратный отсчёт по этому полю.
    @Published private(set) var parentPinLockoutEnd: Date?

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
    private let blockScheduleEnforcement: BlockScheduleEnforcementService

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
    private let locationService: LocationProviding
    /// Управление родительским PIN'ом: хэширование, Keychain, lockout-счётчики.
    /// Используется обеими ролями: parent — для `setParentPinFromUI/clearParentPinFromUI`,
    /// child — для `applyParentPinFromBackend/verifyPin`. Сам PIN никогда не покидает устройства,
    /// где введён; в сеть шлётся только `SHA-256(pin || salt)` + соль.
    private let parentPinService = ParentPinService()
    /// Слабая ссылка на сервис подписки. Pro привязан к устройству родителя: родитель шлёт свой
    /// статус на backend, ребёнок применяет присланный. Связывается из `attachSubscriptionService`.
    private weak var subscriptionService: SubscriptionService?
    /// Последний отправленный на backend Pro-статус родителя — дедупликация, чтобы родительский
    /// polling-тик не дёргал `set_parent_pro` на каждой итерации (шлём только при реальном изменении).
    private var lastPushedParentIsPro: Bool?
    private var focusTask: Task<Void, Never>?
    private var focusSessionStartedAt: Date?
    private var focusSessionPlannedSeconds: Int = 0
    private var sharedStateTask: Task<Void, Never>?
    private var remotePollingTask: Task<Void, Never>?
    private var parentCommandWatchTask: Task<Void, Never>?
    private var activeParentCommandID: UUID?
    /// Троттлинг фоновых child-polling вызовов для экономии Edge Function Invocations (free plan).
    /// Критичные по задержке вызовы (desired focus state + pending commands) бегут каждый тик;
    /// пуш статистики/баланса наверх и фоллбэк-обновление PIN/Pro — реже, т.к. у них есть
    /// мгновенные push-триггеры и они обновляются при выходе из фона.
    private var lastChildStatsHeartbeatAt: Date?
    private var lastChildPinProRefreshAt: Date?
    /// Пуш статистики/runtime/баланса наверх — раз в 30 сек (вместо каждого тика). Родитель видит
    /// свежие данные через wake silent-push при открытии своего приложения; плюс пуш на изменение
    /// баланса идёт из `addSeconds`. Лаг ≤30 сек для «живого» кольца у родителя приемлем.
    private static let childStatsHeartbeatInterval: TimeInterval = 30
    /// Фоллбэк-обновление родительского PIN/Pro — раз в 60 сек. Изменения и так приходят мгновенно
    /// silent push'ом `child_sync_request` и при выходе из фона; периодический pull — лишь страховка.
    private static let childPinProRefreshInterval: TimeInterval = 60
    /// Базовый интервал polling-цикла. Раньше 4 сек; поднят до 8 сек для экономии edge-invocations.
    /// Безопасно, т.к. быстрый путь доставки команд — push (child) и `parentCommandWatchTask`
    /// (parent), а этот цикл — фоллбэк/обновление «живого» состояния. 8 сек = вдвое меньше вызовов
    /// desired/pending (child) и refreshParentChildState (parent) без заметной потери реактивности.
    private static let remotePollingIntervalNanos: UInt64 = 8_000_000_000
    /// Последний `normalized` runtime с `fetchParentSnapshot` — чтобы после `commandStatus=applied` дождаться того же согласования, что в `reconcile` (снимать «Синхронизацию» без кадра со старым CTA).
    private var lastNormalizedParentChildRuntime: RemoteChildRuntimeState?
    /// Throttle для silent-push wake-up на child. iOS троттлит background push-ы (~2–3/час
    /// на устройство), а наш polling-цикл тикает каждые 4 сек — нельзя дёргать wake на
    /// каждом тике, иначе APNs начнёт молча отбрасывать push. Запрашиваем wake не чаще,
    /// чем раз в 60 сек на parent-устройство; этого хватает для устранения staleness и
    /// не упирается в APNs throttle.
    private var lastChildWakeRequestAt: Date?
    private static let childWakeMinimumInterval: TimeInterval = 60
    /// Если `child_runtime_state.updated_at` старее этого порога — считаем балланс stale
    /// и отправляем wake. 60 сек — компромисс: больше = пользователь видит устаревший
    /// counter дольше; меньше = бессмысленный wake-spam.
    private static let childRuntimeStaleThreshold: TimeInterval = 60
    private var lifecycleCancellables = Set<AnyCancellable>()

    init() {
        let storage = AppGroupStore()
        let healthService: HealthKitProviding = HealthKitService()
        let notificationService: Notifying = NotificationService()
        let cameraService = CameraCaptureService()
        let remoteSyncService = ParentalRemoteSyncService(storage: storage)
        let locationService: LocationProviding = LocationService()

        self.storage = storage
        self.healthService = healthService
        self.notificationService = notificationService
        self.cameraService = cameraService
        self.remoteSyncService = remoteSyncService
        self.locationService = locationService
        self.screenTimeService = ScreenTimeService(appStore: storage)
        self.blockScheduleEnforcement = BlockScheduleEnforcementService(appStore: storage)
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
        self.blockSchedules = storage.loadBlockSchedules()
        // Поднимаем актуальный статус PIN из Keychain (если в прошлой сессии родитель уже задавал
        // PIN или ребёнок уже получил его с backend — он сразу видим в UI без сетевого роунд-трипа).
        self.parentPinIsSet = parentPinService.isPinConfigured()
        self.parentPinLockoutEnd = parentPinService.currentLockoutEnd()
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
        seedDefaultBlockSchedulesIfNeeded()
        if deviceRole == .child, pairingState?.isLinked == true {
            blockScheduleEnforcement.refreshFromStoredSchedules()
        }
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
        parentChildEarnedSecondsToday = nil
        parentChildSpentSecondsToday = nil
        // Любая смена роли — это полный reset privacy-state'а: чистим PIN-кэш и закрываем
        // родительский режим, чтобы старый хэш родителя не остался на устройстве с новой ролью
        // (например, если parent перепрошился в child).
        parentPinService.clearMetadata()
        parentPinIsSet = false
        parentPinLockoutEnd = nil
        isParentModeActive = false
        // Сбрасываем кэш Pro-статуса: смена роли = новая семья, старый статус неактуален.
        storage.saveParentIsPro(false)
        subscriptionService?.applyParentProStatus(false)
        lastPushedParentIsPro = nil
        if role != .parent { lastNormalizedParentChildRuntime = nil }
        if role == .parent {
            storage.saveHasCompletedOnboarding(true)
            hasCompletedOnboarding = true
            seedDefaultBlockSchedulesIfNeeded()
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
        parentChildEarnedSecondsToday = nil
        parentChildSpentSecondsToday = nil
        lastNormalizedParentChildRuntime = nil
        // Разрыв пейринга = чужой родитель/семья — PIN из прошлого сценария не должен оставаться
        // на устройстве. Закрываем родительский режим и чистим Keychain.
        parentPinService.clearMetadata()
        parentPinIsSet = false
        parentPinLockoutEnd = nil
        isParentModeActive = false
        // Разрыв пейринга = чужая семья: сбрасываем кэш Pro-статуса родителя.
        storage.saveParentIsPro(false)
        subscriptionService?.applyParentProStatus(false)
        lastPushedParentIsPro = nil
        storage.savePairingState(nil)
    }

    /// Полная отвязка устройств (с любого из них): backend отсоединяет оба устройства от семьи,
    /// затем локально приводим состояние к «не связано». Второе устройство подхватит сброс при
    /// следующем `registerDevice` (вход в активное состояние) — `bootstrapRemoteIfNeeded` вернёт
    /// `pairingState: null` и тоже вызовет `clearPairing()`.
    @discardableResult
    func unlinkDevices() async -> Bool {
        guard pairingState?.isLinked == true else { return false }
        do {
            try await remoteSyncService.unlinkDevices()
            remotePollingTask?.cancel()
            remotePollingTask = nil
            clearPairing()
            remoteStatusMessage = nil
            return true
        } catch {
            remoteStatusMessage = error.localizedDescription
            return false
        }
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
            await refreshChildBlockSchedulesFromServerAndApplyEnforcement()
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

    /// Универсальная команда «изменить доступное время ребёнка на ±N минут».
    /// Используется новой шторкой `AdjustTimeSheet`. Логика выбора command_type:
    /// - `delta == 0` → no-op;
    /// - `delta > 0` → `addEarnedSeconds` с `durationSeconds = delta * 60`;
    /// - `delta < 0`:
    ///   - если `|delta| * 60 >= parentChildAvailableSeconds` (известный родителю live-баланс)
    ///     → `resetEarnedBalance` (как «забрать всё»), чтобы гарантированно обнулить;
    ///   - иначе → `subtractEarnedSeconds` с `durationSeconds = |delta| * 60`.
    /// На стороне ребёнка `subtractEarnedSeconds` применяется как `addSeconds(-N)` с clamp 0.
    func sendParentAdjustTimeCommand(deltaMinutes: Int) async {
        guard deltaMinutes != 0 else { return }

        if deltaMinutes > 0 {
            let seconds = deltaMinutes * 60
            await sendParentCommand(commandType: .addEarnedSeconds, durationSeconds: seconds)
            return
        }

        let absSeconds = abs(deltaMinutes) * 60
        // Если родитель знает live-баланс ребёнка и запрос >= баланса — обнуляем целиком.
        // Если live-баланс неизвестен (`nil`) — играем безопасно через subtract: ребёнок сам
        // защитится clamp-ом до нуля.
        if let availableSeconds = parentChildAvailableSeconds, absSeconds >= availableSeconds {
            await sendParentCommand(commandType: .resetEarnedBalance, durationSeconds: nil)
        } else {
            await sendParentCommand(commandType: .subtractEarnedSeconds, durationSeconds: absSeconds)
        }
    }

    // MARK: - Parent mode (PIN access on child device)

    /// Вызывается ребёнком при тапе по таб-кнопке «Родитель» и вводе 4-значного PIN.
    /// Возвращает результат верификации (см. `ParentPinEntryResult`); при `.success` уже выставлен
    /// `isParentModeActive = true`. UI на этот же `@Published` повесит появление вкладок
    /// `Блокировка`/`Настройки` и красной плашки «Выход».
    func enterParentMode(pin: String) -> ParentPinEntryResult {
        let result = parentPinService.verifyPin(pin)
        switch result {
        case .success:
            isParentModeActive = true
            parentPinLockoutEnd = nil
        case .lockedOut(let until):
            parentPinLockoutEnd = until
        case .wrongPin:
            parentPinLockoutEnd = parentPinService.currentLockoutEnd()
        case .notConfigured:
            parentPinLockoutEnd = nil
        }
        return result
    }

    /// Закрывает родительский режим (тап по красной плашке «Выход»). Идемпотентно.
    func exitParentMode() {
        guard isParentModeActive else { return }
        isParentModeActive = false
    }

    /// Родитель задаёт/меняет PIN из своих настроек. Локально считается хэш с новой солью,
    /// сохраняется в Keychain, и `set_parent_pin` отправляется на backend (edge function v22+).
    /// При успехе backend разошлёт child'у silent push для синка кэша.
    /// Возвращает `true` при успешной отправке на backend, `false` при сетевой ошибке
    /// (локальный кэш всё равно обновляется — родитель сможет проверить PIN на child вручную позже).
    @discardableResult
    func setParentPinFromUI(_ pin: String) async -> Bool {
        guard deviceRole == .parent else { return false }
        guard pin.count == 4, pin.allSatisfy({ $0.isNumber }) else { return false }
        let salt = parentPinService.generateSalt()
        let hash = parentPinService.hashPin(pin, salt: salt)
        let updatedAt = Date()
        let metadata = ParentPinMetadata(hash: hash, salt: salt, updatedAt: updatedAt)
        parentPinService.saveMetadata(metadata)
        parentPinIsSet = true
        do {
            try await remoteSyncService.setParentPin(
                hashBase64: metadata.hashBase64,
                saltBase64: metadata.saltBase64,
                updatedAt: updatedAt
            )
            return true
        } catch {
            remoteStatusMessage = error.localizedDescription
            return false
        }
    }

    /// Родитель удаляет PIN из своих настроек. Локальный кэш чистится сразу, backend синхронно
    /// уведомляется через `clear_parent_pin`. После этого child больше не сможет войти в режим.
    @discardableResult
    func clearParentPinFromUI() async -> Bool {
        guard deviceRole == .parent else { return false }
        parentPinService.clearMetadata()
        parentPinIsSet = false
        parentPinLockoutEnd = nil
        do {
            try await remoteSyncService.clearParentPin()
            return true
        } catch {
            remoteStatusMessage = error.localizedDescription
            return false
        }
    }

    /// Применяет PIN, полученный с backend в snapshot/fetch — у ребёнка. Если значения не
    /// поменялись (`hashBase64+saltBase64+updatedAt`) — no-op, чтобы не дёргать `objectWillChange`
    /// на каждом polling-тике. Если backend вернул `nil` — PIN снят родителем, чистим кэш и
    /// автоматически выходим из режима, если он был активен.
    func applyParentPinFromBackend(hashBase64: String?, saltBase64: String?, updatedAt: Date?) {
        guard let hashBase64, let saltBase64, let updatedAt,
              let metadata = ParentPinMetadata.fromBackend(
                hashBase64: hashBase64,
                saltBase64: saltBase64,
                updatedAt: updatedAt
              )
        else {
            // Backend сообщил, что PIN снят — на ребёнке тоже снимаем.
            if parentPinIsSet {
                parentPinService.clearMetadata()
                parentPinIsSet = false
                parentPinLockoutEnd = nil
                if isParentModeActive { isParentModeActive = false }
            }
            return
        }
        // Сравниваем с уже сохранённым — обновляем только при реальном изменении.
        if let existing = parentPinService.loadMetadata(),
           existing.hash == metadata.hash,
           existing.salt == metadata.salt,
           existing.updatedAt == metadata.updatedAt {
            if !parentPinIsSet { parentPinIsSet = true }
            return
        }
        parentPinService.saveMetadata(metadata)
        parentPinIsSet = true
        parentPinLockoutEnd = nil
        // Принудительный exit, если родитель сменил PIN, пока ребёнок был внутри режима —
        // безопасный дефолт: попросим ввести новый.
        if isParentModeActive { isParentModeActive = false }
    }

    /// Ребёнок дёргает backend за актуальным PIN. Вызывается из polling-цикла и из обработчика
    /// silent push `child_sync_request` (когда родитель только что сменил PIN — backend пушит
    /// wake, ребёнок мгновенно синкает свой кэш).
    func refreshChildParentPinIfNeeded() async {
        guard deviceRole == .child, pairingState?.isLinked == true else { return }
        do {
            let response = try await remoteSyncService.fetchParentPin()
            // Если backend вернул `null` (PIN не задан или удалён родителем) — передаём `nil`'ы:
            // `applyParentPinFromBackend` сам очистит кэш и закроет parent-mode, если он был активен.
            applyParentPinFromBackend(
                hashBase64: response?.hashBase64,
                saltBase64: response?.saltBase64,
                updatedAt: response.flatMap { $0.updatedAt }
            )
        } catch {
            // Тихо — это фоновая операция, оффлайн-ребёнок продолжает работать на кэшированном PIN.
        }
    }

    // MARK: - Pro subscription (привязка к устройству родителя)

    /// Связывает `AppState` с `SubscriptionService` (вызывается один раз при старте приложения).
    /// Подписывается на изменение entitlement родителя (→ отправка на backend) и инициализирует
    /// сторону ребёнка кэшированным статусом + фоновым обновлением с backend.
    func attachSubscriptionService(_ service: SubscriptionService) {
        subscriptionService = service
        service.onEntitlementChange = { [weak self] isActive in
            guard let self else { return }
            Task { await self.pushParentProStatusIfNeeded(isActive) }
        }
        if deviceRole == .child {
            // Сразу применяем кэш (офлайн-устойчивость) и тянем актуальный статус с backend.
            service.applyParentProStatus(storage.loadParentIsPro())
            Task { await refreshChildParentProIfNeeded() }
        } else if deviceRole == .parent {
            // Публикуем текущий известный статус родителя (на случай, если он изменился офлайн).
            Task { await pushParentProStatusIfNeeded(service.hasActiveEntitlement) }
        }
    }

    /// Parent → backend: отправляет Pro-статус родителя (`set_parent_pro`). No-op для не-родителя,
    /// до связки и если значение не изменилось с прошлой отправки. Ошибки тихие — повторится на
    /// следующем тике/изменении подписки.
    func pushParentProStatusIfNeeded(_ isPro: Bool) async {
        guard deviceRole == .parent, pairingState?.isLinked == true else { return }
        guard lastPushedParentIsPro != isPro else { return }
        do {
            try await remoteSyncService.setParentPro(isPro: isPro)
            lastPushedParentIsPro = isPro
        } catch {
            // Тихо: backend получит статус при следующей попытке (старт/изменение подписки).
        }
    }

    /// Child → backend: тянет Pro-статус родителя и применяет его к `SubscriptionService`
    /// (источник правды гейтинга на ребёнке). Кэширует значение для офлайна.
    func refreshChildParentProIfNeeded() async {
        guard deviceRole == .child, pairingState?.isLinked == true else { return }
        do {
            let dto = try await remoteSyncService.fetchParentPro()
            let value = dto?.isPro ?? false
            storage.saveParentIsPro(value)
            subscriptionService?.applyParentProStatus(value)
        } catch {
            // Тихо — оффлайн-ребёнок продолжает работать на кэшированном статусе.
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

        // 2.5) Silent push wake-up `child_sync_request` (parent попросил освежить баланс
        // ребёнка). Не содержит `command_id`, не идёт через очередь `focus_commands`,
        // никакого ACK не требует. Просто принудительно делаем midnight-reset (если новый
        // день), затем пушим свежий снапшот на сервер — это попутно обновит и dailyStats,
        // и `child_runtime_state.available_seconds`, который и читает parent.
        if deviceRole == .child,
           let userInfo = initialPayload,
           (userInfo["command_type"] as? String) == "child_sync_request" {
            resetDailyBalanceIfNeeded()
            await syncChildStatsSnapshotIfNeeded()
            // Тот же silent push используется и для синка родительского PIN: если родитель
            // только что сменил/удалил PIN, backend разбудит child и попросит подтянуть
            // актуальные `parent_pin_hash/salt/updated_at` (если они изменились — кэш обновится
            // и `parent_mode` принудительно закроется, см. `applyParentPinFromBackend`).
            await refreshChildParentPinIfNeeded()
            // Тот же канал синкает Pro-статус родителя (подписка привязана к устройству родителя).
            await refreshChildParentProIfNeeded()
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
            } else if pairingState != nil {
                // Сервер авторитетно сообщил, что устройство больше не связано (например, связку
                // сбросили с другого устройства через `unlink_devices`) — приводим локальное
                // состояние в соответствие, чтобы UI вернулся к экрану связки.
                parentPairingCode = nil
                clearPairing()
            }
            if let apns = storage.loadAPNSToken() {
                try? await remoteSyncService.updateAPNSToken(apns)
            }
        } catch {
            remoteStatusMessage = error.localizedDescription
        }
        startRemotePollingIfNeeded()
    }

    /// Возвращает `true`, если с момента `last` прошло не меньше `interval` (или `last == nil`).
    /// Используется для троттлинга некритичных фоновых вызовов в polling-цикле.
    private static func shouldRunThrottled(last: Date?, interval: TimeInterval, now: Date) -> Bool {
        guard let last else { return true }
        return now.timeIntervalSince(last) >= interval
    }

    private func startRemotePollingIfNeeded() {
        guard pairingState?.isLinked == true else { return }
        remotePollingTask?.cancel()
        // Сброс троттл-таймеров: первый тик новой polling-сессии делает полный синк.
        lastChildStatsHeartbeatAt = nil
        lastChildPinProRefreshAt = nil
        remotePollingTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                if self.deviceRole == .child {
                    let now = Date()
                    // PIN/Pro родителя подмешиваем в тот же `child_poll` лишь раз в ~60 сек (не каждый тик).
                    let includeSettings = Self.shouldRunThrottled(
                        last: self.lastChildPinProRefreshAt,
                        interval: Self.childPinProRefreshInterval,
                        now: now
                    )
                    if includeSettings { self.lastChildPinProRefreshAt = now }
                    // Один combined-вызов вместо desired + pending (+ PIN/Pro). Критично по задержке —
                    // каждый тик (фоллбэк к push для блок/разблок и команд).
                    await self.pollChildAndApply(includeParentSettings: includeSettings)
                    // Пуш статистики/runtime/баланса наверх — одним bundle-вызовом, раз в 30 сек.
                    if Self.shouldRunThrottled(last: self.lastChildStatsHeartbeatAt, interval: Self.childStatsHeartbeatInterval, now: now) {
                        self.lastChildStatsHeartbeatAt = now
                        await self.syncChildStatsSnapshotIfNeeded()
                    }
                } else if self.deviceRole == .parent {
                    await self.refreshParentChildState()
                    // Дешёвая no-op после первой отправки (дедуп по `lastPushedParentIsPro`):
                    // покрывает случай «купил Pro до связки» и «связался после покупки».
                    await self.pushParentProStatusIfNeeded(self.subscriptionService?.hasActiveEntitlement ?? false)
                }
                try? await Task.sleep(nanoseconds: Self.remotePollingIntervalNanos)
            }
        }
    }

    private func processPendingRemoteCommandsIfNeeded() async {
        guard deviceRole == .child, pairingState?.isLinked == true else { return }
        do {
            let commands = try await remoteSyncService.fetchPendingCommands()
            await applyPendingCommands(commands)
        } catch {
            remoteStatusMessage = error.localizedDescription
        }
    }

    /// Применяет уже полученный список pending-команд (вынесено из `processPendingRemoteCommandsIfNeeded`,
    /// чтобы переиспользовать из combined `pollChildAndApply` без повторного fetch).
    private func applyPendingCommands(_ commands: [RemoteFocusCommand]) async {
        guard deviceRole == .child, pairingState?.isLinked == true else { return }
        do {
            guard !commands.isEmpty else { return }
            let sorted = commands.sorted { $0.createdAt < $1.createdAt }

            let scheduleCmds = sorted.filter { $0.commandType == .schedulesUpdated }
            if !scheduleCmds.isEmpty {
                await refreshChildBlockSchedulesFromServerAndApplyEnforcement()
                for cmd in scheduleCmds {
                    try? await remoteSyncService.ackCommand(id: cmd.id, status: .applied, errorMessage: nil)
                }
            }

            // Команды schedule_started/schedule_ended приходят с бэкенд-cron при наступлении
            // границы окна расписания. На клиенте делаем единый refresh enforcement (а не
            // по каждой команде отдельно — чтобы избежать множественных последовательных
            // start/stopMonitoring). Acknowledge всех таких команд.
            let scheduleEventCmds = sorted.filter {
                $0.commandType == .scheduleStarted || $0.commandType == .scheduleEnded
            }
            if !scheduleEventCmds.isEmpty {
                blockScheduleEnforcement.refreshFromStoredSchedules()
                for cmd in scheduleEventCmds {
                    try? await remoteSyncService.ackCommand(id: cmd.id, status: .applied, errorMessage: nil)
                }
            }

            let nonSchedule = sorted.filter {
                $0.commandType != .schedulesUpdated
                    && $0.commandType != .scheduleStarted
                    && $0.commandType != .scheduleEnded
            }
            guard let latest = nonSchedule.last else { return }
            if nonSchedule.count > 1 {
                for stale in nonSchedule.dropLast() {
                    try? await remoteSyncService.ackCommand(
                        id: stale.id,
                        status: .failed,
                        errorMessage: "superseded_by_newer_command"
                    )
                }
            }
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
            await applyDesiredFocusState(desired)
        } catch {
            remoteStatusMessage = error.localizedDescription
        }
    }

    /// Child → backend (combined): один вызов `child_poll` вместо `fetch_desired_focus_state`
    /// + `fetch_pending_commands` (+ PIN/Pro когда `includeParentSettings`). Применяет результат
    /// тем же кодом, что и одиночные пути (для совместимости с push-доставкой).
    private func pollChildAndApply(includeParentSettings: Bool) async {
        guard deviceRole == .child, pairingState?.isLinked == true else { return }
        do {
            let poll = try await remoteSyncService.childPoll(includeParentSettings: includeParentSettings)
            await applyDesiredFocusState(poll.desired)
            let commands = poll.pendingCommands.map {
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
            await applyPendingCommands(commands)
            if includeParentSettings {
                applyParentPinFromBackend(
                    hashBase64: poll.parentPin?.hashBase64,
                    saltBase64: poll.parentPin?.saltBase64,
                    updatedAt: poll.parentPin.flatMap { $0.updatedAt }
                )
                let proValue = poll.parentPro?.isPro ?? false
                storage.saveParentIsPro(proValue)
                subscriptionService?.applyParentProStatus(proValue)
            }
        } catch {
            remoteStatusMessage = error.localizedDescription
        }
    }

    /// Применяет уже полученное desired-состояние фокуса (вынесено из `syncChildWithDesiredStateIfNeeded`).
    private func applyDesiredFocusState(_ desired: DesiredFocusStateDTO) async {
        guard deviceRole == .child, pairingState?.isLinked == true else { return }
        do {
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

    // MARK: - Block schedules (remote)

    private func refreshChildBlockSchedulesFromServerAndApplyEnforcement() async {
        guard deviceRole == .child, pairingState?.isLinked == true else { return }
        do {
            let dtos = try await remoteSyncService.fetchBlockSchedules()
            let merged = dtos.map { BlockSchedule(remoteDTO: $0) }
            blockSchedules = merged
            storage.saveBlockSchedules(merged)
            blockScheduleEnforcement.refreshFromStoredSchedules()
        } catch {
            os_log("refreshChildBlockSchedules: %{public}@", log: appStateLog, type: .error, error.localizedDescription)
            // Оставляем/восстанавливаем мониторинг из кэша App Group, если сервер временно недоступен.
            blockScheduleEnforcement.refreshFromStoredSchedules()
        }
    }

    /// Публичный refresh для UI-слоя (Dashboard / Schedules). Тонкая обёртка над приватной
    /// логикой синхронизации с бэкендом для роли parent. Безопасно вызывать из `.task`.
    func refreshParentBlockSchedulesIfNeeded() async {
        await syncParentBlockSchedulesFromServerIfNeeded()
    }

    private func syncParentBlockSchedulesFromServerIfNeeded() async {
        guard deviceRole == .parent, pairingState?.isLinked == true else { return }
        do {
            let dtos = try await remoteSyncService.fetchBlockSchedules()
            let remoteModels = dtos.map { BlockSchedule(remoteDTO: $0) }
            if remoteModels.isEmpty, !blockSchedules.isEmpty {
                for schedule in blockSchedules {
                    try? await remoteSyncService.upsertBlockSchedule(schedule)
                }
                return
            }
            blockSchedules = remoteModels
            storage.saveBlockSchedules(remoteModels)
        } catch {
            os_log("syncParentBlockSchedules: %{public}@", log: appStateLog, type: .error, error.localizedDescription)
        }
    }

    private func schedulePushBlockScheduleToServer(_ schedule: BlockSchedule) {
        guard deviceRole == .parent, pairingState?.isLinked == true else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.remoteSyncService.upsertBlockSchedule(schedule)
            } catch {
                os_log("upsertBlockSchedule: %{public}@", log: appStateLog, type: .error, error.localizedDescription)
            }
        }
    }

    private func scheduleDeleteBlockScheduleOnServer(id: UUID) {
        guard deviceRole == .parent, pairingState?.isLinked == true else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.remoteSyncService.deleteBlockSchedule(id: id)
            } catch {
                os_log("deleteBlockSchedule: %{public}@", log: appStateLog, type: .error, error.localizedDescription)
            }
        }
    }

    // MARK: - Child location

    /// Запросить у пользователя‑ребёнка разрешение When-in-Use. Вызывается из онбординга.
    /// Возвращает финальный статус. UI на онбординге может на его основе решать показывать ли алерт.
    @discardableResult
    func requestChildLocationPermissionIfNeeded() async -> CLAuthorizationStatus {
        let status = await locationService.requestWhenInUseAuthorization()
        childLocationAuthorizationStatus = status
        return status
    }

    /// Запросить апгрейд до `Always`. Должен вызываться ПОСЛЕ того, как пользователь выдал
    /// `When-in-Use` — это требование Apple. Возвращает финальный статус.
    /// На устройстве ребёнка `Always` критически важен: он позволяет снимать GPS-fix по push'у,
    /// даже когда приложение свёрнуто или выгружено из памяти. Расход батареи минимальный — мы
    /// включаем фоновые апдейты только на момент одного capture.
    @discardableResult
    func requestChildLocationAlwaysAuthorizationIfNeeded() async -> CLAuthorizationStatus {
        let status = await locationService.requestAlwaysAuthorization()
        childLocationAuthorizationStatus = status
        return status
    }

    /// Обновить значение `childLocationAuthorizationStatus` (нужно после возврата из Settings).
    func refreshChildLocationAuthorizationStatus() {
        childLocationAuthorizationStatus = locationService.authorizationStatus
    }

    /// Пользователь‑родитель нажал «Обновить местоположение» на вкладке Карта.
    /// Шлёт ребёнку команду `request_location` (alert push) и пуллит свежую координату из БД.
    func refreshChildLocationFromParent() async {
        guard deviceRole == .parent, pairingState?.isLinked == true else { return }
        isParentRefreshingChildLocation = true
        parentLocationStatusMessage = nil
        defer { isParentRefreshingChildLocation = false }

        // Запоминаем «базовый» момент — фиксацию ДО отправки команды считаем устаревшей даже
        // если её timestamp совпадает с уже сохранённым (на случай повторного нажатия в ту же секунду).
        let requestSentAt = Date()
        let baselineCapturedAt = childLocationSnapshot?.capturedAt

        do {
            try await remoteSyncService.requestChildLocation()
        } catch {
            parentLocationStatusMessage = error.localizedDescription
            return
        }

        // Пуллим до 30 секунд — за это время push должен дойти (alert priority=10),
        // ребёнок при When-in-Use получит до ~30с фонового времени, снимет первый GPS fix и зальёт его.
        let pollInterval: UInt64 = 1_500_000_000
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: pollInterval)
            if Task.isCancelled { return }
            do {
                if let snapshot = try await remoteSyncService.fetchChildLocation() {
                    let isNewer = snapshot.capturedAt > (baselineCapturedAt ?? .distantPast)
                    let isFreshAfterRequest = snapshot.updatedAt >= requestSentAt
                    if isNewer || isFreshAfterRequest {
                        childLocationSnapshot = snapshot
                        storage.saveChildLocationSnapshot(snapshot)
                        return
                    }
                }
            } catch {
                parentLocationStatusMessage = error.localizedDescription
            }
        }
        parentLocationStatusMessage = L10n.tr("map.refresh.timeout")
    }

    /// Подгрузить кэш и при возможности свежую точку с бэкенда.
    /// Вызывается при открытии вкладки и при `appDidBecomeActive` для роли parent.
    func loadChildLocationIfNeeded() async {
        if childLocationSnapshot == nil, let cached = storage.loadChildLocationSnapshot() {
            childLocationSnapshot = cached
        }
        guard deviceRole == .parent, pairingState?.isLinked == true else { return }
        do {
            if let snapshot = try await remoteSyncService.fetchChildLocation() {
                childLocationSnapshot = snapshot
                storage.saveChildLocationSnapshot(snapshot)
            }
        } catch {
            parentLocationStatusMessage = error.localizedDescription
        }
    }

    /// Снять одну координату на ребёнке и отправить на бэкенд.
    /// Вызывается из `applyRemoteCommandIfNeeded` после получения push'а `request_location`.
    private func captureAndUploadChildLocationIfNeeded() async {
        // Намеренно НЕ требуем pairingState?.isLinked == true: при холодном пуске из push'а
        // pairingState может быть ещё не подгружен из бэкенда, но device_secret и family-binding
        // уже есть в storage — remoteSyncService.updateChildLocation отработает корректно.
        guard deviceRole == .child else {
            os_log("captureAndUpload: skipped (role != child)", log: appStateLog, type: .info)
            return
        }
        let status = locationService.authorizationStatus
        guard status == .authorizedWhenInUse || status == .authorizedAlways else {
            os_log("captureAndUpload: skipped (auth status=%{public}d)",
                   log: appStateLog, type: .error, status.rawValue)
            return
        }
        os_log("captureAndUpload: starting capture (auth=%{public}d)",
               log: appStateLog, type: .info, status.rawValue)
        do {
            let location = try await locationService.captureCurrentLocation(timeout: 25)
            let snapshot = ChildLocationSnapshot(
                latitude: location.coordinate.latitude,
                longitude: location.coordinate.longitude,
                horizontalAccuracy: location.horizontalAccuracy >= 0 ? location.horizontalAccuracy : nil,
                capturedAt: location.timestamp,
                updatedAt: Date()
            )
            try await remoteSyncService.updateChildLocation(snapshot)
            storage.saveChildLocationSnapshot(snapshot)
            os_log("captureAndUpload: success (lat=%.5f lon=%.5f acc=%.1f)",
                   log: appStateLog, type: .info,
                   snapshot.latitude, snapshot.longitude, snapshot.horizontalAccuracy ?? -1)
        } catch {
            os_log("captureAndUpload: FAILED — %{public}@",
                   log: appStateLog, type: .error, error.localizedDescription)
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
        case .subtractEarnedSeconds:
            // Списываем N секунд через `applyParentSubtractEarnedSeconds`, который повторяет
            // паттерн `applyParentResetEarnedBalance`: увеличивает `totalSpentSeconds` на
            // `min(N, available)` и НЕ трогает `totalEarnedSeconds`. Так аналитика остаётся
            // корректной, а доступный баланс никогда не уходит в минус.
            let secondsToSubtract = max(0, durationSeconds ?? 0)
            if secondsToSubtract > 0 {
                applyParentSubtractEarnedSeconds(secondsToSubtract)
            }
        case .requestLocation:
            // Parent asked for a fresh GPS fix. Capture once via LocationService and
            // push the snapshot back to the backend. We ack the command as `applied`
            // even before the upload completes — backend will treat next location row
            // as the actual delivery confirmation. This avoids blocking the alert push
            // background time budget if the GPS fix is slow.
            await captureAndUploadChildLocationIfNeeded()
        case .schedulesUpdated:
            await refreshChildBlockSchedulesFromServerAndApplyEnforcement()
        case .scheduleStarted, .scheduleEnded:
            // Бэкенд-cron детектировал переход start/end окна расписания. Просто перезапускаем
            // enforcement — внутренняя логика `isScheduleActiveNow` сама применит/снимет
            // именованный shield для нужного расписания. Список расписаний не изменился,
            // поэтому fetch делать не нужно.
            blockScheduleEnforcement.refreshFromStoredSchedules()
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

    /// Throttled silent-push wake-up. Вызывается только из `refreshParentChildState`
    /// когда runtime stale > 60 сек. Несмотря на throttle (`childWakeMinimumInterval`)
    /// сетевой запрос short-circuit'ится локально — никогда не звоним на бэк чаще, чем
    /// раз в минуту. Ошибки сети глотаются: для UI это «опциональный» механизм, ничего
    /// не сломается если он временно недоступен (родитель просто увидит stale baseline).
    private func requestChildWakeIfNeeded() async {
        guard deviceRole == .parent, pairingState?.isLinked == true else { return }
        let now = Date()
        if let last = lastChildWakeRequestAt,
           now.timeIntervalSince(last) < Self.childWakeMinimumInterval {
            return
        }
        lastChildWakeRequestAt = now
        do {
            _ = try await remoteSyncService.requestChildWakeSync()
        } catch {
            // Throttle сбрасывать не будем — иначе сразу retry'нем при следующем тике
            // и забьём канал. Спокойно подождём `childWakeMinimumInterval` и попробуем
            // снова. Это безопасно: stale-данные просто продержатся на минуту дольше.
            remoteStatusMessage = error.localizedDescription
        }
    }

    private func refreshParentChildState() async {
        guard deviceRole == .parent, pairingState?.isLinked == true else {
            parentChildAvailableSeconds = nil
            parentChildEarnedSecondsToday = nil
            parentChildSpentSecondsToday = nil
            return
        }
        var lastError: Error?
        for attempt in 0..<2 {
            do {
                // Один combined-вызов вместо desired + snapshot + linkHealth + childBalance.
                let poll = try await remoteSyncService.parentPoll()
                parentDesiredFocusActive = poll.desired.shouldFocusActive
                parentLinkHealth = ParentLinkHealthState(
                    pendingCommands: poll.linkHealth.pendingCommands,
                    oldestPendingAgeSeconds: poll.linkHealth.oldestPendingAgeSeconds,
                    childLastSeenAgeSeconds: poll.linkHealth.childLastSeenAgeSeconds,
                    childLikelyOnline: poll.linkHealth.childLikelyOnline,
                    recentFailedCommands30m: poll.linkHealth.recentFailedCommands30m
                )

                // Сохраняем earned/spent ребёнка за сегодня для верхней balance-карточки на parent.
                // Если бэкенд ещё не вернул `dailyStats` (старая версия / child не синкал), оставляем
                // прошлые значения как есть — карточка просто покажет последние известные числа.
                if let stats = poll.dailyStats {
                    parentChildEarnedSecondsToday = max(0, stats.earnedSeconds)
                    parentChildSpentSecondsToday = max(0, stats.spentSeconds)
                }

                let actualRuntime = normalizedRuntimeForParent(poll.runtime)
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
                if let childAvailable = poll.availableSeconds {
                    parentChildAvailableSeconds = childAvailable
                }
                // Если runtime на сервере старее `childRuntimeStaleThreshold` — child давно
                // не синкал (закрыт/спит/был полночный rollover), и cached `available_seconds`
                // не отражает реальность. Отправляем silent push wake-up, ограниченный
                // throttle'ом `childWakeMinimumInterval` — следующий polling-тик через
                // несколько секунд подтянет свежий баланс уже от проснувшегося child.
                let staleness = Date().timeIntervalSince(actualRuntime.lastUpdatedAt)
                if staleness > Self.childRuntimeStaleThreshold {
                    await requestChildWakeIfNeeded()
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
        case .resetEarnedBalance, .addEarnedSeconds, .subtractEarnedSeconds,
             .requestLocation, .schedulesUpdated, .scheduleStarted, .scheduleEnded:
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

    /// Списывает у ребёнка `secondsToSubtract` секунд, но не больше, чем `availableSeconds`.
    /// Эквивалент `applyParentResetEarnedBalance`, только с заданным верхним лимитом.
    /// Используется для команды `subtractEarnedSeconds` из шторки «Изменить доступное время».
    private func applyParentSubtractEarnedSeconds(_ secondsToSubtract: Int) {
        let available = balance.availableSeconds
        let actualDelta = min(max(0, secondsToSubtract), available)
        guard actualDelta > 0 else { return }
        balance.totalSpentSeconds += actualDelta
        persistState()
        prependLedger(
            ActivityLedgerEntry(
                source: .parentAdjustment,
                deltaSeconds: -actualDelta,
                note: L10n.tr("ledger.parent.subtract_time")
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
            // Один combined-вызов вместо трёх (upsert_child_day_stats + update_child_runtime
            // + update_child_balance). Runtime и balance пишутся в одну строку child_runtime_state.
            try await remoteSyncService.upsertChildRuntimeBundle(
                stats: today,
                isFocusActive: isFocusSessionActive,
                focusEndsAt: focusSessionEndsAt,
                availableSeconds: balance.availableSeconds
            )
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
        // Расписания: сразу регистрируем Device Activity из последнего JSON в App Group,
        // не дожидаясь сетевого pull (иначе окно до завершения Task без мониторов).
        if deviceRole == .child, pairingState?.isLinked == true {
            blockScheduleEnforcement.refreshFromStoredSchedules()
        }
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
            if deviceRole == .parent {
                await syncParentBlockSchedulesFromServerIfNeeded()
            } else if deviceRole == .child {
                await refreshChildBlockSchedulesFromServerAndApplyEnforcement()
            }
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
        // Безопасность: любой уход приложения в background мгновенно закрывает родительский режим
        // на ребёнке — даже если родитель просто свернул приложение «на минуту», следующий вход
        // снова потребует PIN.
        if isParentModeActive {
            isParentModeActive = false
        }
    }

    /// Used by BGAppRefresh task to recover missed pushes when app stays closed for long periods.
    func performChildBackgroundRefreshSync() async -> Bool {
        guard deviceRole == .child, pairingState?.isLinked == true else { return false }
        await bootstrapRemoteIfNeeded()
        await syncChildWithDesiredStateIfNeeded()
        await processPendingRemoteCommandsIfNeeded()
        await refreshChildBlockSchedulesFromServerAndApplyEnforcement()
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

    // MARK: - Block schedules (read-only helpers for UI)

    /// Возвращает все включённые расписания, чьё окно активно прямо сейчас (с учётом
    /// дней недели и переходов через полночь). Используется как Родителем (для карточки
    /// «Сейчас активно расписание»), так и Ребёнком (для индикации причины блокировки).
    /// Сортировка — по более раннему `endTime` (что первым закончится — выше в UI).
    func activeBlockSchedules(at date: Date = Date()) -> [BlockSchedule] {
        blockSchedules
            .filter { $0.isActive(at: date) }
            .sorted { $0.endTime.totalMinutes < $1.endTime.totalMinutes }
    }

    /// Ближайшее следующее расписание (которое включено, но сейчас не активно). Возвращает
    /// пару (расписание, дата ближайшего start). Используется для UI «Следующее: ... в HH:MM».
    /// Поиск идёт в окне ближайших 7 дней.
    func nextScheduledBlock(after date: Date = Date(), calendar: Calendar = .current) -> (schedule: BlockSchedule, startDate: Date)? {
        let candidates = blockSchedules.filter { $0.isEnabled }
        guard !candidates.isEmpty else { return nil }

        var best: (BlockSchedule, Date)?
        for daysAhead in 0..<8 {
            guard let dayDate = calendar.date(byAdding: .day, value: daysAhead, to: date) else { continue }
            let calWeekday = calendar.component(.weekday, from: dayDate)
            let dayWD = calWeekday == 1 ? 7 : calWeekday - 1
            guard let dayEnum = ScheduleWeekday(rawValue: dayWD) else { continue }

            for schedule in candidates where schedule.weekdays.contains(dayEnum) {
                var components = calendar.dateComponents([.year, .month, .day], from: dayDate)
                components.hour = schedule.startTime.hour
                components.minute = schedule.startTime.minute
                components.second = 0
                guard let startDate = calendar.date(from: components) else { continue }
                guard startDate > date else { continue }
                if let current = best {
                    if startDate < current.1 { best = (schedule, startDate) }
                } else {
                    best = (schedule, startDate)
                }
            }
            if best != nil { break }
        }
        return best.map { ($0.0, $0.1) }
    }

    // MARK: - Block schedules (parent role)

    /// Гарантирует, что у роли parent при первом запуске есть выключенное расписание
    /// «Время спать». Идемпотентно: повторные вызовы не создают дубликатов.
    func seedDefaultBlockSchedulesIfNeeded() {
        guard deviceRole == .parent else { return }
        guard !storage.loadDidSeedDefaultBlockSchedules() else { return }
        if blockSchedules.isEmpty {
            let sleep = BlockSchedule.defaultSleepSchedule()
            blockSchedules = [sleep]
            storage.saveBlockSchedules(blockSchedules)
        }
        storage.saveDidSeedDefaultBlockSchedules(true)
        for schedule in blockSchedules {
            schedulePushBlockScheduleToServer(schedule)
        }
    }

    /// Создаёт пустое расписание-черновик (используется при нажатии «Создать новое расписание»).
    /// Не сохраняется в список до явного `commitBlockSchedule`.
    /// Имя оставляем пустым — в редакторе показывается плейсхолдер «Например, Время спать»;
    /// `isEnabled = true`, чтобы при сохранении расписание сразу было активно без ручного переключения.
    func makeDraftBlockSchedule() -> BlockSchedule {
        BlockSchedule(
            name: "",
            icon: .generic,
            accent: .purple,
            startTime: ScheduleTimeOfDay(hour: 9, minute: 0),
            endTime: ScheduleTimeOfDay(hour: 10, minute: 0),
            weekdays: ScheduleWeekday.everyday,
            isEnabled: true
        )
    }

    /// Создаёт расписание из шаблона и добавляет его в начало списка.
    /// Возвращает добавленный объект — UI открывает редактор именно для него.
    @discardableResult
    func addBlockSchedule(from template: BlockScheduleTemplate) -> BlockSchedule {
        let schedule = template.makeSchedule()
        var list = blockSchedules
        list.insert(schedule, at: 0)
        blockSchedules = list
        storage.saveBlockSchedules(blockSchedules)
        schedulePushBlockScheduleToServer(schedule)
        return schedule
    }

    /// Обновляет существующее расписание (по `id`) или добавляет новое, если его ещё нет.
    /// Используется и для commit редактора, и для сохранения нового расписания из draft.
    func commitBlockSchedule(_ schedule: BlockSchedule) {
        var updated = schedule
        updated.updatedAt = Date()
        var list = blockSchedules
        if let index = list.firstIndex(where: { $0.id == schedule.id }) {
            list[index] = updated
        } else {
            list.insert(updated, at: 0)
        }
        blockSchedules = list
        storage.saveBlockSchedules(blockSchedules)
        schedulePushBlockScheduleToServer(updated)
    }

    /// Переключает флаг `isEnabled` для конкретного расписания.
    func setBlockSchedule(_ scheduleID: UUID, enabled: Bool) {
        guard let index = blockSchedules.firstIndex(where: { $0.id == scheduleID }) else { return }
        var list = blockSchedules
        var updated = list[index]
        guard updated.isEnabled != enabled else { return }
        updated.isEnabled = enabled
        updated.updatedAt = Date()
        list[index] = updated
        blockSchedules = list
        storage.saveBlockSchedules(blockSchedules)
        schedulePushBlockScheduleToServer(updated)
    }

    /// Удаляет расписание из списка. Возвращает `true`, если удаление произошло.
    @discardableResult
    func deleteBlockSchedule(_ scheduleID: UUID) -> Bool {
        guard blockSchedules.contains(where: { $0.id == scheduleID }) else { return false }
        scheduleDeleteBlockScheduleOnServer(id: scheduleID)
        blockSchedules.removeAll { $0.id == scheduleID }
        storage.saveBlockSchedules(blockSchedules)
        return true
    }
}

private struct ParentSnapshotDTO: Codable {
    let runtime: RemoteChildRuntimeState
    /// Опциональный блок дневной статистики ребёнка (за сегодня, UTC-сутки).
    /// Заполняется edge function `parental-control-sync` v20 при наличии записи в `daily_stats_snapshots`.
    /// `nil` — child ещё не синкал сегодняшний день, рендерим нули в UI.
    let dailyStats: ParentChildDailyStatsDTO?
}

/// DTO дневной статистики ребёнка для родительского снапшота.
/// Точное зеркало `BackendDayStatsDTO` — используется только для парсинга snapshot-ответа.
private struct ParentChildDailyStatsDTO: Codable {
    let dayStartISO: String
    let steps: Int
    let earnedSeconds: Int
    let spentSeconds: Int
    let pushUps: Int
    let squats: Int
    let focusSessionTotalSeconds: Int
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

/// Ответ combined-экшена `child_poll`: всё, что ребёнок тянет за один тик.
/// `parentPin`/`parentPro` присутствуют только когда клиент запросил `includeParentSettings`.
private struct ChildPollDTO: Decodable {
    let desired: DesiredFocusStateDTO
    let pendingCommands: [PendingCommandDTO]
    let parentPin: ParentPinSyncDTO?
    let parentPro: ParentProSyncDTO?
}

/// Ответ combined-экшена `parent_poll`: объединяет desired + snapshot + linkHealth + childBalance.
private struct ParentPollDTO: Decodable {
    let desired: DesiredFocusStateDTO
    let runtime: RemoteChildRuntimeState
    let dailyStats: ParentChildDailyStatsDTO?
    let linkHealth: LinkHealthDTO
    let availableSeconds: Int?
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

private struct ChildLocationDTO: Codable {
    let latitude: Double
    let longitude: Double
    let horizontalAccuracy: Double?
    let capturedAtISO: String
    let updatedAtISO: String
}

/// Снимок родительского PIN от backend для синка кэша на child (через `fetch_parent_pin`).
/// Хэш и соль приходят в base64 — `AppState.applyParentPinFromBackend` сам восстановит `Data` и
/// сравнит с уже сохранённым в Keychain через `ParentPinService`. `updatedAtISO` — момент,
/// когда родитель в последний раз менял PIN; используется как ключ дедупликации.
private struct ParentPinSyncDTO: Decodable {
    let hashBase64: String
    let saltBase64: String
    let updatedAtISO: String

    /// Парсинг `updatedAtISO` в `Date`. ISO8601 с дробной частью допускается на бэке — обрабатываем
    /// оба формата (с миллисекундами и без), чтобы не зависеть от точного представления Postgres.
    var updatedAt: Date? {
        let primary = ISO8601DateFormatter()
        if let d = primary.date(from: updatedAtISO) { return d }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: updatedAtISO)
    }
}

/// Снимок Pro-статуса родителя от backend (через `fetch_parent_pro`). Pro привязан к устройству
/// родителя; ребёнок применяет это значение для гейтинга фич (см. `SubscriptionService`).
private struct ParentProSyncDTO: Decodable {
    let isPro: Bool
    let updatedAtISO: String
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

    /// Parent → backend (v5 of `parental-control-balance-sync`): просит «разбудить» child
    /// silent-push'ом (без alert), чтобы тот синхронизировал свой `available_seconds`,
    /// дневную статистику и при необходимости выполнил `resetDailyBalanceIfNeeded()`.
    /// Возвращает `true`, если backend подтвердил отправку push (`sent: true`), и
    /// `false` если child пока без APNs token (push не отправлен). Любые ошибки сети
    /// пробрасываются наружу — `AppState` сам решает retry/throttle.
    func requestChildWakeSync() async throws -> Bool {
        struct Payload: Encodable { let installID: String }
        struct Response: Decodable {
            let ok: Bool
            let sent: Bool?
        }
        let response: Response = try await call(
            action: "wake_child_sync",
            payload: Payload(installID: installID),
            endpoint: Endpoint.balanceBaseURL
        )
        return response.sent ?? false
    }

    // MARK: - Parent PIN (v22 of `parental-control-sync`)

    /// Parent → backend: устанавливает/обновляет родительский PIN. PIN никогда не передаётся —
    /// только заранее посчитанный `SHA-256(pin || salt)` (base64) и сама соль (base64).
    /// Backend сохраняет это в `families.parent_pin_hash/salt/updated_at` и отправляет child'у
    /// silent push wake-up, чтобы тот синхронизировал кэш.
    func setParentPin(hashBase64: String, saltBase64: String, updatedAt: Date) async throws {
        struct Payload: Encodable {
            let installID: String
            let pinHash: String
            let pinSalt: String
            let pinUpdatedAt: String
        }
        let _: EmptyResponse = try await call(
            action: "set_parent_pin",
            payload: Payload(
                installID: installID,
                pinHash: hashBase64,
                pinSalt: saltBase64,
                pinUpdatedAt: ISO8601DateFormatter().string(from: updatedAt)
            )
        )
    }

    /// Parent → backend: удаляет родительский PIN (`families.parent_pin_* = NULL`). После этого
    /// child получит `parentPin: null` при следующем `fetch_parent_pin` и сам очистит кэш.
    func clearParentPin() async throws {
        struct Payload: Encodable { let installID: String }
        let _: EmptyResponse = try await call(
            action: "clear_parent_pin",
            payload: Payload(installID: installID)
        )
    }

    /// Child → backend: возвращает актуальный родительский PIN (хэш+соль+updatedAt) или `nil`,
    /// если родитель ещё не задал/удалил. Сам PIN никогда не возвращается — только хэш+соль,
    /// проверка PIN происходит локально на устройстве ребёнка через `ParentPinService`.
    func fetchParentPin() async throws -> ParentPinSyncDTO? {
        struct Payload: Encodable { let installID: String }
        return try await call(
            action: "fetch_parent_pin",
            payload: Payload(installID: installID)
        )
    }

    /// Parent → backend: сохраняет Pro-статус родителя в `families.parent_is_pro` и будит ребёнка
    /// silent push'ом, чтобы тот сразу подтянул новый статус.
    func setParentPro(isPro: Bool) async throws {
        struct Payload: Encodable {
            let installID: String
            let isPro: Bool
        }
        let _: EmptyResponse = try await call(
            action: "set_parent_pro",
            payload: Payload(installID: installID, isPro: isPro)
        )
    }

    /// Child/Parent → backend: текущий Pro-статус родителя семьи (для гейтинга фич на ребёнке).
    func fetchParentPro() async throws -> ParentProSyncDTO? {
        struct Payload: Encodable { let installID: String }
        return try await call(
            action: "fetch_parent_pro",
            payload: Payload(installID: installID)
        )
    }

    /// Любое связанное устройство → backend: полная отвязка семьи (оба устройства отсоединяются,
    /// семья помечается неактивной). После — оба устройства очистят локальную связку.
    func unlinkDevices() async throws {
        struct Payload: Encodable { let installID: String }
        let _: EmptyResponse = try await call(
            action: "unlink_devices",
            payload: Payload(installID: installID)
        )
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

    // MARK: - Combined polling endpoints (экономия Edge Function Invocations)

    /// Child → backend: один вызов вместо `fetch_desired_focus_state` + `fetch_pending_commands`
    /// (+ `fetch_parent_pin` + `fetch_parent_pro`, если `includeParentSettings == true`).
    func childPoll(includeParentSettings: Bool) async throws -> ChildPollDTO {
        struct Payload: Encodable {
            let installID: String
            let includeParentSettings: Bool
        }
        return try await call(
            action: "child_poll",
            payload: Payload(installID: installID, includeParentSettings: includeParentSettings)
        )
    }

    /// Parent → backend: один вызов вместо `fetch_desired_focus_state` + `fetch_parent_snapshot`
    /// + `fetch_link_health` + `fetch_child_balance`.
    func parentPoll() async throws -> ParentPollDTO {
        struct Payload: Encodable { let installID: String }
        return try await call(action: "parent_poll", payload: Payload(installID: installID))
    }

    /// Child → backend: один вызов вместо `upsert_child_day_stats` + `update_child_runtime`
    /// + `update_child_balance`. Runtime и balance пишутся в одну строку `child_runtime_state`.
    func upsertChildRuntimeBundle(
        stats: DailyStats,
        isFocusActive: Bool,
        focusEndsAt: Date?,
        availableSeconds: Int
    ) async throws {
        struct Payload: Encodable {
            let installID: String
            let dayStartISO: String
            let steps: Int
            let earnedSeconds: Int
            let spentSeconds: Int
            let pushUps: Int
            let squats: Int
            let focusSessionTotalSeconds: Int
            let isFocusActive: Bool
            let focusEndsAt: String?
            let availableSeconds: Int
        }
        let dayStart = Calendar.current.startOfDay(for: stats.date)
        let dayISO = ISO8601DateFormatter().string(from: dayStart)
        let endISO = focusEndsAt.map { ISO8601DateFormatter().string(from: $0) }
        let _: EmptyResponse = try await call(
            action: "upsert_child_runtime_bundle",
            payload: Payload(
                installID: installID,
                dayStartISO: dayISO,
                steps: stats.steps,
                earnedSeconds: stats.earnedSeconds,
                spentSeconds: stats.spentSeconds,
                pushUps: stats.pushUps,
                squats: stats.squats,
                focusSessionTotalSeconds: stats.focusSessionTotalSeconds,
                isFocusActive: isFocusActive,
                focusEndsAt: endISO,
                availableSeconds: max(0, availableSeconds)
            )
        )
    }

    /// Parent → backend: попросить ребёнка прислать свежую координату.
    /// Сервер ставит focus_command типа request_location и шлёт alert push на ребёнка.
    func requestChildLocation() async throws {
        struct Payload: Encodable { let installID: String }
        let _: EmptyResponse = try await call(
            action: "request_child_location",
            payload: Payload(installID: installID)
        )
    }

    /// Child → backend: записать только что снятую координату в child_location_state.
    func updateChildLocation(_ snapshot: ChildLocationSnapshot) async throws {
        struct Payload: Encodable {
            let installID: String
            let latitude: Double
            let longitude: Double
            let horizontalAccuracy: Double?
            let capturedAtISO: String
        }
        let _: EmptyResponse = try await call(
            action: "update_child_location",
            payload: Payload(
                installID: installID,
                latitude: snapshot.latitude,
                longitude: snapshot.longitude,
                horizontalAccuracy: snapshot.horizontalAccuracy,
                capturedAtISO: ISO8601DateFormatter().string(from: snapshot.capturedAt)
            )
        )
    }

    /// Parent → backend: достать последнюю известную координату ребёнка для своей семьи.
    func fetchChildLocation() async throws -> ChildLocationSnapshot? {
        struct Payload: Encodable { let installID: String }
        let dto: ChildLocationDTO? = try await call(
            action: "fetch_child_location",
            payload: Payload(installID: installID)
        )
        guard let dto else { return nil }
        let formatter = ISO8601DateFormatter()
        let captured = formatter.date(from: dto.capturedAtISO) ?? Date()
        let updated = formatter.date(from: dto.updatedAtISO) ?? captured
        return ChildLocationSnapshot(
            latitude: dto.latitude,
            longitude: dto.longitude,
            horizontalAccuracy: dto.horizontalAccuracy,
            capturedAt: captured,
            updatedAt: updated
        )
    }

    func fetchBlockSchedules() async throws -> [RemoteBlockScheduleDTO] {
        struct Payload: Encodable { let installID: String }
        struct Response: Decodable { let schedules: [RemoteBlockScheduleDTO] }
        let response: Response = try await call(
            action: "list_block_schedules",
            payload: Payload(installID: installID)
        )
        return response.schedules
    }

    func upsertBlockSchedule(_ schedule: BlockSchedule) async throws {
        struct Payload: Encodable {
            let installID: String
            let id: String
            let name: String
            let icon: String
            let accent: String
            let startHour: Int
            let startMinute: Int
            let endHour: Int
            let endMinute: Int
            let weekdays: [Int]
            let isEnabled: Bool
            /// IANA timezone родителя в момент сохранения. Используется бэкенд-cron
            /// `cron_evaluate_block_schedules`, чтобы корректно вычислить локальное время
            /// и не путать UTC с фактическим временем семьи.
            let timezoneIdentifier: String
        }
        let payload = Payload(
            installID: installID,
            id: schedule.id.uuidString,
            name: schedule.name,
            icon: schedule.icon.rawValue,
            accent: schedule.accent.rawValue,
            startHour: schedule.startTime.hour,
            startMinute: schedule.startTime.minute,
            endHour: schedule.endTime.hour,
            endMinute: schedule.endTime.minute,
            weekdays: schedule.orderedWeekdays.map(\.rawValue),
            isEnabled: schedule.isEnabled,
            timezoneIdentifier: TimeZone.current.identifier
        )
        let _: EmptyResponse = try await call(action: "upsert_block_schedule", payload: payload)
    }

    func deleteBlockSchedule(id: UUID) async throws {
        struct Payload: Encodable {
            let installID: String
            let id: String
        }
        let _: EmptyResponse = try await call(
            action: "delete_block_schedule",
            payload: Payload(installID: installID, id: id.uuidString)
        )
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
