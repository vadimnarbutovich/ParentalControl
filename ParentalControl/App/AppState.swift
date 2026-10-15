import AVFoundation
import Combine
import CoreLocation
import FamilyControls
import Foundation
import os.log
import UIKit

private let appStateLog = OSLog(subsystem: "mycompny.ParentalControl", category: "AppState")

enum PermissionReminderKind: Hashable {
    case screenTime
    case notifications
}

@MainActor
final class AppState: ObservableObject {
    static let didReceiveRemotePayloadNotification = Notification.Name("parentalcontrol.didReceiveRemotePayload")
    static let didRegisterAPNSTokenNotification = Notification.Name("parentalcontrol.didRegisterAPNSToken")
    static let childBackgroundRefreshTaskIdentifier = "mycompny.parentalcontrol.child-refresh"
    @Published private(set) var balance: MinuteBalance
    @Published var settings: ConversionSettings
    @Published private(set) var ledger: [ActivityLedgerEntry]
    @Published private(set) var dailyBudget: DailyBudgetState?
    @Published private(set) var parentBudgetStatus: DailyBudgetStatus?
    @Published private(set) var hasLoadedParentBudget = false
    @Published private(set) var isBudgetSaving = false
    @Published var budgetError: String?
    private var budgetMonitorReady = false
    private var budgetChangeIntent: (kind: String, seconds: Int, weekly: [Int]?, day: String, revision: Int, id: UUID)?
    @Published private(set) var todaySteps: Int = 0
    @Published private(set) var exerciseTotals: [String: Int]
    @Published private(set) var isHealthAuthorized = false
    @Published private(set) var isNotificationAuthorized = false
    /// `true`, если уведомления явно запрещены в системе — повторный `requestAuthorization` не покажет диалог.
    @Published private(set) var isNotificationAuthorizationDenied = false
    @Published private(set) var isCameraAuthorized = false
    @Published private(set) var isFocusSessionActive = false
    @Published private(set) var focusSessionEndsAt: Date?
    @Published private(set) var focusRemainingSeconds: Int = 0
    @Published private(set) var isMonitoringPaused = false
    @Published private var pendingLocalFocusChange: LocalManualBlockIntent?
    @Published private(set) var isLocalManualBlockSyncing = false
    @Published private(set) var localManualBlockNotice: String?
    var isLocalManualBlockPending: Bool { pendingLocalFocusChange != nil }
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
    @Published private var pendingParentManualBlock: Bool?
    /// Optimistic position only for the disabled control, not confirmed child status.
    var parentManualBlockControlState: Bool {
        pendingParentManualBlock ?? parentResolvedFocusActive ?? false
    }
    @Published private(set) var remoteStatusMessage: String?
    /// Список расписаний блокировки: на родителе редактируется и синкается с сервером; на ребёнке
    /// подставляется из `list_block_schedules` и применяется через Device Activity + named shields.
    @Published private(set) var blockSchedules: [BlockSchedule] = []
    /// Задания для ребёнка: на родителе создаются/редактируются/подтверждаются, на ребёнке
    /// отображаются и отправляются на проверку. Синкается через `family_child_tasks`
    /// (push `tasks_updated` + foreground refresh, без участия в 8-сек polling).
    @Published private(set) var childTasks: [ChildTask] = []
    @Published private(set) var isUpdatingChildTasks = false
    private var childTasksGeneration: UInt = 0
    private var childTasksRequest: UInt = 0
    private var childTasksRefreshPending = false
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
    /// Do not show permission reminders before the system statuses have loaded.
    @Published private(set) var permissionStatusesReady = false
    /// `true`, когда ребёнок успешно ввёл родительский PIN и сейчас доступны «скрытые» табы
    /// `Блокировка` / `Статистика` / `Настройки`. Сбрасывается в `false` при `appDidEnterBackground`, смене роли,
    /// разрыве пейринга и тапе по красной плашке «Выход».
    @Published private(set) var isParentModeActive = false
    /// `true`, если в Keychain есть кэшированный родительский PIN (хэш+соль). У ребёнка обновляется
    /// при каждом успешном `refreshChildParentPinIfNeeded`. У родителя — после `setParentPinFromUI`.
    /// UI ориентируется на этот флаг, чтобы знать, можно ли вообще пытаться вводить PIN.
    @Published private(set) var parentPinIsSet = false
    @Published private(set) var isRefreshingSetup = false
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

    /// Status decoration must not mistake an offline desired state for an applied block.
    var isParentManualBlockConfirmed: Bool {
        guard deviceRole == .parent, pairingState?.isLinked == true else { return false }
        let runtime = lastNormalizedParentChildRuntime
        if let delivery = parentCommandDelivery, delivery.status == .applied,
           delivery.commandType == .startFocus || delivery.commandType == .endFocus,
           (delivery.appliedAt ?? delivery.updatedAt) >= (runtime?.lastUpdatedAt ?? .distantPast) {
            return delivery.commandType == .startFocus
        }
        return runtime.map { isRemoteChildFocusSessionActive($0) } ?? false
    }

    let screenTimeService: ScreenTimeService
    private let blockScheduleEnforcement: BlockScheduleEnforcementService

    var activePermissionReminder: PermissionReminderKind? {
        guard deviceRole != nil, permissionStatusesReady, hasCompletedOnboarding, !permissionBannerSuppressedAfterCTA else { return nil }
        if deviceRole == .child, !screenTimeService.isAuthorized { return .screenTime }
        if !isNotificationAuthorized { return .notifications }
        return nil
    }

    func permissionBannerPrimaryButtonKey(for kind: PermissionReminderKind) -> String {
        switch kind {
        case .notifications where isNotificationAuthorizationDenied:
            return "permission.banner.open_settings"
        default:
            return "permission.banner.allow"
        }
    }

    func openAppSettingsURL() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    private let storage: AppGroupStore
    private let rewardEngine = RewardEngine()
    private let notificationService: Notifying
    private let focusLiveActivityService = FocusLiveActivityService()
    private let stepsSyncCoordinator = StepsSyncCoordinator()
    private let remoteSyncService: ParentalRemoteSyncService
    private let locationService: LocationProviding
    private var childLocationUploadTask: Task<String?, Never>?
    private var childLocationUploadID: UUID?
    private var locationCommandTasks: [UUID: Task<Void, Never>] = [:]
    // A bounded cache prevents repeated delivery from restarting GPS or changing a failed ACK to success.
    private var locationCommandResults: [(id: UUID, errorCode: String?, acknowledged: Bool)] = []
    private var isLoadingChildLocation = false
    private var parentLocationRevision = 0
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
    /// Короткоживущий цикл на стороне родителя: пока код связки сгенерирован, но ребёнок ещё не
    /// присоединился (`isLinked == false`), опрашиваем backend, чтобы поймать момент связки и
    /// обновить UI без перезапуска приложения. Останавливается, как только связались.
    private var parentPairingWaitTask: Task<Void, Never>?
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
    /// Интервал «ожидающего» опроса связки у родителя (пока ребёнок не присоединился). Цикл живёт
    /// только пока пользователь на экране ожидания связки, поэтому опрос чаще базового (3 сек) —
    /// чтобы UI родителя моментально отреагировал на присоединение ребёнка.
    private static let parentPairingWaitIntervalNanos: UInt64 = 3_000_000_000
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
        let notificationService: Notifying = NotificationService()
        let remoteSyncService = ParentalRemoteSyncService(storage: storage)
        let locationService: LocationProviding = LocationService()

        self.storage = storage
        self.notificationService = notificationService
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
        self.childTasks = storage.loadChildTasks()
        // Поднимаем актуальный статус PIN из Keychain (если в прошлой сессии родитель уже задавал
        // PIN или ребёнок уже получил его с backend — он сразу видим в UI без сетевого роунд-трипа).
        self.parentPinIsSet = parentPinService.isPinConfigured()
        self.parentPinLockoutEnd = parentPinService.currentLockoutEnd()
        self.isParentChildStateResolved = !(self.deviceRole == .parent && self.pairingState?.isLinked == true)
        self.parentResolvedFocusActive = nil
        self.isHealthAuthorized = false
        self.isCameraAuthorized = AVCaptureDevice.authorizationStatus(for: .video) == .authorized
        restoreParentBudgetCache()
        configureMainAppActivityTracking()
        configurePushObservers()

        screenTimeService.refreshAuthorizationStatus()
        storage.saveMainAppIsActive(true)
        resetDailyBalanceIfNeeded()
        ensureSpentBaselineForToday()
        if !DailyBudgetStore.shared.isEnabled { screenTimeService.stopDeviceActivityMonitoring() }
        // The monitoring-pause control no longer exists. Restore normal allowance
        // enforcement rather than leaving an invisible, permanent bypass enabled.
        if deviceRole == .child, isMonitoringPaused {
            isMonitoringPaused = false
            storage.saveDeviceActivityMonitoringPaused(false)
        }
        restoreFocusSessionIfNeeded()
        restoreLocalManualBlockIntent()
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
        parentPairingWaitTask?.cancel()
        parentCommandWatchTask?.cancel()
        lifecycleCancellables.removeAll()
    }

    func requestPermissions() async {
        await requestNotificationAccessOnly()
        if deviceRole == .child { await requestScreenTimeAccessOnly() }
    }

    func refreshPermissionStatuses() async {
        // HealthKit is no longer required.
        isNotificationAuthorized = await notificationService.isAuthorizedForAlerts()
        let notifStatus = await notificationService.currentAuthorizationStatus()
        isNotificationAuthorizationDenied = notifStatus == .denied
        screenTimeService.refreshAuthorizationStatus()
        isCameraAuthorized = AVCaptureDevice.authorizationStatus(for: .video) == .authorized
        if deviceRole == .child { refreshChildLocationAuthorizationStatus() }
        permissionStatusesReady = true
    }

    func requestNotificationAccessOnly() async {
        guard deviceRole != nil else { return }
        await notificationService.resolveNotificationAccess { [weak self] in
            self?.openAppSettingsURL()
        }
        isNotificationAuthorized = await notificationService.isAuthorizedForAlerts()
        isNotificationAuthorizationDenied = await notificationService.currentAuthorizationStatus() == .denied
    }

    func requestScreenTimeAccessOnly() async {
        guard deviceRole == .child else { return }
        await screenTimeService.requestAuthorization()
        screenTimeService.refreshAuthorizationStatus()
        syncScreenTimeEnforcement(notifyOnUnlock: false)
    }

    func enableRemovalProtectionFromParentMode() async throws {
        guard deviceRole == .child, isParentModeActive else {
            throw RemovalProtectionError.parentRequired
        }
        do {
            try await screenTimeService.enableRemovalProtection()
            AppAnalytics.report("removal_protection_enable", parameters: ["result": "success"])
        } catch {
            AppAnalytics.report("removal_protection_enable", parameters: [
                "result": "failed", "reason": RemovalProtectionError.messageKey(for: error)
            ])
            throw error
        }
        // Keep budget, pairing and selection intact; reapply existing restrictions.
        if deviceRole == .child {
            syncScreenTimeEnforcement(notifyOnUnlock: false)
            blockScheduleEnforcement.refreshFromStoredSchedules()
        }
    }

    func allowRemovalFromParentMode() async throws {
        guard deviceRole == .child, isParentModeActive else {
            throw RemovalProtectionError.parentRequired
        }
        try await screenTimeService.revokeForRemoval()
        AppAnalytics.report("removal_protection_disable")
        // Do not clear the family's data or silently request individual access.
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
            if deviceRole == .child {
                await refreshStepsAndRewards()
                await syncChildStatsSnapshotIfNeeded()
            }
        }
    }

    func chooseDeviceRole(_ role: DeviceRole) {
        guard deviceRole != role else { return }
        pendingParentManualBlock = nil
        clearLocalManualBlockIntent()
        storage.saveDeviceRole(role)
        deviceRole = role
        restoreParentBudgetCache()
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
        // Only a deliberate role choice starts setup. Existing installations keep
        // their completion flag and do not repeat onboarding after an update.
        storage.saveHasCompletedOnboarding(false)
        storage.saveDidRequestInitialPermissions(false)
        hasCompletedOnboarding = false
        if role == .parent { seedDefaultBlockSchedulesIfNeeded() }
        Task {
            await bootstrapRemoteIfNeeded()
        }
    }

    func clearPairing() {
        childLocationUploadTask?.cancel()
        childLocationUploadTask = nil
        childLocationUploadID = nil
        for task in locationCommandTasks.values { task.cancel() }
        locationCommandTasks.removeAll()
        locationCommandResults.removeAll()
        pendingParentManualBlock = nil
        clearLocalManualBlockIntent()
        if let family = pairingState?.familyID {
            UserDefaults.standard.removeObject(forKey: parentBudgetCacheKey(family))
            UserDefaults.standard.removeObject(forKey: focusRevisionKey(family))
        }
        let hadDailyBudget = DailyBudgetStore.shared.isEnabled
        do {
            try DailyBudgetStore.shared.unlink()
            if hadDailyBudget {
                balance = .empty
                storage.saveBalance(balance)
            }
        }
        catch { budgetError = L10n.tr("budget.apply_error") }
        dailyBudget = nil
        parentBudgetStatus = nil
        hasLoadedParentBudget = false
        budgetChangeIntent = nil
        budgetMonitorReady = false
        _ = screenTimeService.ensureDailyBudgetMonitoring()
        parentPairingWaitTask?.cancel()
        parentPairingWaitTask = nil
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
        // Чистим возможную сырую backend-ошибку (напр. «Device is not paired»), которая могла
        // прилететь от фонового синка в момент отвязки (локально ещё «связаны», на сервере уже нет).
        // Иначе она зависнет на карточке связки как непонятное служебное сообщение.
        remoteStatusMessage = nil
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
            restoreParentBudgetCache()
            parentPairingCode = state.pairingCode
            remoteStatusMessage = nil
            storage.savePairingState(state)
            // Начинаем ждать присоединения ребёнка, чтобы UI обновился без перезапуска.
            startParentPairingWaitPollingIfNeeded()
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

    func sendParentFocusCommand(start: Bool) {
        let commandType: RemoteFocusCommandType = start ? .startFocus : .endFocus
        // Commit the disabled control's new position in the same MainActor turn
        // as the drag reset, before scheduling network work.
        guard beginParentCommand(commandType: commandType) else { return }
        Task {
            await performParentCommand(commandType: commandType, durationSeconds: nil)
        }
    }

    private func localFocusIntentKey(_ family: UUID) -> String {
        "parentalcontrol.localManualBlock." + family.uuidString.lowercased()
    }

    private func focusRevisionKey(_ family: UUID) -> String {
        "parentalcontrol.focusRevision." + family.uuidString.lowercased()
    }

    private var childFocusRevision: Int {
        guard let family = pairingState?.familyID else { return 0 }
        return UserDefaults.standard.integer(forKey: focusRevisionKey(family))
    }

    private func clearLocalManualBlockIntent() {
        if let family = pairingState?.familyID {
            UserDefaults.standard.removeObject(forKey: localFocusIntentKey(family))
        }
        pendingLocalFocusChange = nil
        localManualBlockNotice = nil
    }

    private func restoreLocalManualBlockIntent() {
        pendingLocalFocusChange = nil
        guard deviceRole == .child, let family = pairingState?.familyID,
              let data = UserDefaults.standard.data(forKey: localFocusIntentKey(family)),
              let intent = try? JSONDecoder().decode(LocalManualBlockIntent.self, from: data),
              intent.familyID == family else { return }
        pendingLocalFocusChange = intent
        applyLocalManualBlock(intent.isActive)
    }

    /// Only the PIN-unlocked parent mode may create a local action. Persist it
    /// BEFORE changing shields; a restart/offline launch must not lose the intent.
    func setLocalManualBlock(active: Bool) {
        guard deviceRole == .child, isParentModeActive, pairingState?.isLinked == true,
              !isLocalManualBlockSyncing, let family = pairingState?.familyID,
              let metadata = parentPinService.loadMetadata() else { return }
        let intent = LocalManualBlockIntent(id: UUID(), familyID: family, isActive: active,
            expectedRevision: childFocusRevision, pinVersion: metadata.salt.base64EncodedString())
        guard let data = try? JSONEncoder().encode(intent) else { return }
        UserDefaults.standard.set(data, forKey: localFocusIntentKey(family))
        pendingLocalFocusChange = intent
        localManualBlockNotice = nil
        applyLocalManualBlock(active)
        AppAnalytics.report("blocklist_manual_block", parameters: ["action": active ? "block" : "unblock"])
        Task {
            _ = await flushLocalManualBlockIntent()
            await syncChildStatsSnapshotIfNeeded()
        }
    }

    private func applyLocalManualBlock(_ active: Bool) {
        // This replaces the old monitoring pause, not the daily allowance or schedules.
        if isMonitoringPaused {
            isMonitoringPaused = false
            storage.saveDeviceActivityMonitoringPaused(false)
        }
        if active {
            if !isFocusSessionActive || focusSessionEndsAt != nil { startIndefiniteFocusSession() }
        } else {
            endFocusSession()
        }
        syncScreenTimeEnforcement(notifyOnUnlock: false)
    }

    @discardableResult
    private func flushLocalManualBlockIntent() async -> Bool {
        guard let intent = pendingLocalFocusChange else { return true }
        guard deviceRole == .child, pairingState?.familyID == intent.familyID,
              !isLocalManualBlockSyncing else { return false }
        isLocalManualBlockSyncing = true
        defer { isLocalManualBlockSyncing = false }
        do {
            let result = try await remoteSyncService.setLocalManualBlock(intent)
            guard deviceRole == .child, pairingState?.familyID == intent.familyID,
                  pendingLocalFocusChange?.id == intent.id else { return false }
            guard ["accepted", "conflict", "pin_changed"].contains(result.outcome) else { return false }
            clearLocalManualBlockIntent()
            await applyDesiredFocusState(result.desired)
            if result.outcome != "accepted" {
                localManualBlockNotice = L10n.tr("blocklist.manual_block.changed")
            }
            if result.outcome == "pin_changed" {
                exitParentMode()
                await refreshChildParentPinIfNeeded()
            }
            return true
        } catch {
            // Keep the local result and persisted intent. Foreground/background sync
            // retries the SAME id; no raw server errors or fake remote confirmation.
            return false
        }
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
        guard deltaMinutes != 0, parentBudgetStatus?.policy != nil else { return }
        _ = await saveDailyBudgetChange(kind: "adjustment", seconds: deltaMinutes * 60)
    }

    func saveParentDailyLimit(minutes: Int, weeklyMinutes: [Int]? = nil) async -> Bool {
        guard (0...1440).contains(minutes), weeklyMinutes.map({
            $0.count == 7 && $0.allSatisfy { (0...1440).contains($0) }
        }) ?? true else { return false }
        if weeklyMinutes != nil, parentBudgetStatus?.weeklyChildReady != true {
            budgetError = L10n.tr("budget.weekly.update_child")
            return false
        }
        return await saveDailyBudgetChange(kind: "limit", seconds: minutes * 60,
                                          weekly: weeklyMinutes?.map { $0 * 60 })
    }

    private func parentBudgetCacheKey(_ family: UUID) -> String {
        "parentalcontrol.parentDailyBudget." + family.uuidString.lowercased()
    }

    private func restoreParentBudgetCache() {
        parentBudgetStatus = nil
        hasLoadedParentBudget = false
        guard deviceRole == .parent, let family = pairingState?.familyID,
              let data = UserDefaults.standard.data(forKey: parentBudgetCacheKey(family)),
              let cached = try? JSONDecoder().decode(DailyBudgetStatus.self, from: data),
              cached.policy?.familyID.lowercased() == family.uuidString.lowercased() else { return }
        // Never present yesterday's cached usage as today's live balance.
        parentBudgetStatus = DailyBudgetStatus(policy: cached.policy, childReady: cached.childReady,
            appliedRevision: cached.appliedRevision, state: nil,
            weeklyChildReady: cached.weeklyChildReady, childTimeZone: cached.childTimeZone)
    }

    private func receiveParentBudget(_ status: DailyBudgetStatus) {
        guard let family = pairingState?.familyID,
              status.policy == nil || status.policy?.familyID.lowercased() == family.uuidString.lowercased() else { return }
        guard (status.policy?.revision ?? 0) >= (parentBudgetStatus?.policy?.revision ?? 0) else { return }
        parentBudgetStatus = status
        hasLoadedParentBudget = true
        let cached = DailyBudgetStatus(policy: status.policy, childReady: status.childReady,
            appliedRevision: status.appliedRevision, state: nil,
            weeklyChildReady: status.weeklyChildReady, childTimeZone: status.childTimeZone)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        if let data = try? encoder.encode(cached) {
            let key = parentBudgetCacheKey(family)
            if UserDefaults.standard.data(forKey: key) != data {
                UserDefaults.standard.set(data, forKey: key)
            }
        }
    }

    private func saveDailyBudgetChange(kind: String, seconds: Int, weekly: [Int]? = nil) async -> Bool {
        guard deviceRole == .parent, pairingState?.isLinked == true, !isBudgetSaving else { return false }
        let requestedFamily = pairingState?.familyID
        isBudgetSaving = true
        budgetError = nil
        defer { isBudgetSaving = false }
        let day = parentBudgetStatus?.currentDay ?? DailyBudgetState.dayKey()
        if budgetChangeIntent?.kind != kind || budgetChangeIntent?.seconds != seconds
            || budgetChangeIntent?.weekly != weekly || budgetChangeIntent?.day != day {
            budgetChangeIntent = (kind, seconds, weekly, day, parentBudgetStatus?.policy?.revision ?? 0, UUID())
        }
        guard let intent = budgetChangeIntent else { return false }
        do {
            let saved = try await remoteSyncService.changeDailyBudget(
                kind: kind, seconds: seconds, expectedRevision: intent.revision, intentID: intent.id,
                weeklyLimitsSeconds: weekly)
            guard pairingState?.familyID == requestedFamily else { return false }
            receiveParentBudget(saved)
            budgetChangeIntent = nil
            AppAnalytics.report("daily_budget_saved", parameters: ["kind": kind, "seconds": seconds,
                "limit_mode": saved.policy?.weeklyLimitsSeconds == nil ? "every_day" : "weekdays"])
            return true
        } catch {
            if error.localizedDescription.contains("budget_changed_refresh") { budgetChangeIntent = nil }
            budgetError = L10n.tr(error.localizedDescription.contains("weekly_child_update_required")
                                 ? "budget.weekly.update_child" : "budget.save_error")
            await refreshParentChildState()
            return false
        }
    }

    private func applyDailyBudgetPolicy(_ policy: DailyBudgetPolicy?) {
        guard deviceRole == .child, let policy,
              pairingState?.familyID.uuidString.lowercased() == policy.familyID.lowercased() else { return }
        do {
            let baseline = storage.loadSpentBaselineTotalSpentSeconds()
            let administrative = dayLedgerEntries(for: Date())
                .filter { $0.source == .parentAdjustment && $0.deltaSeconds < 0 }
                .reduce(0) { $0 + abs($1.deltaSeconds) }
            let previous = dailyBudget
            dailyBudget = try DailyBudgetStore.shared.apply(policy,
                legacyUsedToday: max(0, balance.totalSpentSeconds - baseline - administrative))
            balance = storage.loadBalance()
            if previous?.budgetSeconds != dailyBudget?.budgetSeconds || previous?.day != dailyBudget?.day {
                screenTimeService.stopDeviceActivityMonitoring()
            }
            syncScreenTimeEnforcement(notifyOnUnlock: false)
        } catch {
            budgetError = L10n.tr("budget.apply_error")
            budgetMonitorReady = false
            screenTimeService.applyShield()
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
    /// Publish/cache only after the server accepts the PIN, so failed setup is never shown as complete.
    @discardableResult
    func setParentPinFromUI(_ pin: String) async -> Bool {
        guard deviceRole == .parent, pairingState?.isLinked == true,
              let familyID = pairingState?.familyID else { return false }
        guard pin.count == 4, pin.allSatisfy({ $0.isNumber }) else { return false }
        let salt = parentPinService.generateSalt()
        let hash = parentPinService.hashPin(pin, salt: salt)
        let updatedAt = Date()
        let metadata = ParentPinMetadata(hash: hash, salt: salt, updatedAt: updatedAt)
        do {
            try await remoteSyncService.setParentPin(
                hashBase64: metadata.hashBase64,
                saltBase64: metadata.saltBase64,
                updatedAt: updatedAt
            )
            guard deviceRole == .parent, pairingState?.familyID == familyID else { return false }
            parentPinService.saveMetadata(metadata)
            parentPinIsSet = true
            remoteStatusMessage = nil
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

    /// Explicit setup refresh, not another polling loop. Normal push/polling remains the source of updates.
    func refreshSetupStatus() async {
        guard pairingState?.isLinked == true, !isRefreshingSetup else { return }
        isRefreshingSetup = true
        defer { isRefreshingSetup = false }
        if deviceRole == .child {
            await pollChildAndApply(includeParentSettings: true)
        } else if deviceRole == .parent {
            await refreshParentChildState()
        }
    }

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
        case .screenTime:
            await requestScreenTimeAccessOnly()
        case .notifications:
            await requestNotificationAccessOnly()
        }
        await refreshPermissionStatuses()
        permissionBannerSuppressedAfterCTA = true
    }

    func refreshStepsAndRewards() async {
        resetDailyBalanceIfNeeded()
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
        // Only associate this build's environment with a freshly registered APNs
        // token. Bootstrap may still hold a token from the previous installation.
        let environment = APNsEnvironment.current()
        Task {
            do {
                try await remoteSyncService.updateAPNSToken(token, environment: environment)
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

        // 2.6) Родитель получает alert-пуш `tasks_updated`, когда ребёнок отправил отчёт по заданию.
        // У этого пуша нет `command_id` (он не идёт через focus_commands) — просто перетягиваем список.
        if deviceRole == .parent,
           let userInfo = initialPayload,
           (userInfo["command_type"] as? String) == "tasks_updated" {
            await refreshChildTasksFromServer()
        }

        // 3) Backend sweep — pull anything the push payload may have missed (collapsed / lost).
        if deviceRole == .child {
            await pollChildAndApply(includeParentSettings: false)
            await syncChildStatsSnapshotIfNeeded()
        }
    }

    private func bootstrapRemoteIfNeeded() async {
        guard let role = deviceRole else { return }
        do {
            let bootstrap = try await remoteSyncService.registerDevice(role: role)
            if let serverPair = bootstrap.pairingState {
                let familyChanged = pairingState?.familyID != serverPair.familyID
                pairingState = serverPair
                if familyChanged {
                    restoreParentBudgetCache()
                    restoreLocalManualBlockIntent()
                }
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
        // Если родитель стартовал с уже сгенерированным, но ещё не связанным кодом — продолжаем
        // ждать присоединения ребёнка (метод сам себя гейтит на pending-состоянии).
        startParentPairingWaitPollingIfNeeded()
    }

    /// Возвращает `true`, если с момента `last` прошло не меньше `interval` (или `last == nil`).
    /// Используется для троттлинга некритичных фоновых вызовов в polling-цикле.
    private static func shouldRunThrottled(last: Date?, interval: TimeInterval, now: Date) -> Bool {
        guard let last else { return true }
        return now.timeIntervalSince(last) >= interval
    }

    /// Запускает «ожидающий» опрос связки у родителя: пока код сгенерирован, но ребёнок ещё не
    /// присоединился, периодически тянем авторитетное состояние с backend (`register_device`
    /// возвращает текущий `pairingState`). Как только `isLinked == true` — обновляем локальное
    /// состояние, сохраняем и переключаемся на штатный polling. Без этого родитель узнавал о
    /// связке только после перезапуска приложения.
    private func startParentPairingWaitPollingIfNeeded() {
        guard deviceRole == .parent else { return }
        guard let state = pairingState, state.isLinked == false else { return }
        parentPairingWaitTask?.cancel()
        parentPairingWaitTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: Self.parentPairingWaitIntervalNanos)
                if Task.isCancelled { return }
                // Состояние могло измениться (отвязка/связка из другого места) — перепроверяем.
                guard self.deviceRole == .parent, self.pairingState?.isLinked == false else { return }
                do {
                    let bootstrap = try await self.remoteSyncService.registerDevice(role: .parent)
                    guard !Task.isCancelled else { return }
                    guard let serverPair = bootstrap.pairingState else { continue }
                    self.pairingState = serverPair
                    self.storage.savePairingState(serverPair)
                    self.parentPairingCode = serverPair.pairingCode
                    if serverPair.isLinked {
                        self.remoteStatusMessage = nil
                        self.isParentChildStateResolved = false
                        self.parentResolvedFocusActive = nil
                        self.startRemotePollingIfNeeded()
                        return
                    }
                } catch {
                    // Сетевые сбои в фоне ожидания игнорируем — повторим на следующем тике.
                }
            }
        }
    }

    private func startRemotePollingIfNeeded() {
        guard pairingState?.isLinked == true else { return }
        parentPairingWaitTask?.cancel()
        parentPairingWaitTask = nil
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

        // tasks_updated — пассивный «перетяни список заданий» (как schedules_updated).
        let taskCmds = sorted.filter { $0.commandType == .tasksUpdated }
        if !taskCmds.isEmpty {
            await refreshChildTasksFromServer()
            for cmd in taskCmds {
                try? await remoteSyncService.ackCommand(id: cmd.id, status: .applied, errorMessage: nil)
            }
        }

        let nonSchedule = sorted.filter {
            $0.commandType != .schedulesUpdated
                && $0.commandType != .scheduleStarted
                && $0.commandType != .scheduleEnded
                && $0.commandType != .tasksUpdated
        }
        // Only the backend supersedes focus commands. Location/budget work must
        // not disappear just because a manual block arrived in the same poll.
        // GPS can take seconds. Apply control commands before waiting for location.
        for command in nonSchedule where command.commandType != .requestLocation {
            await applyRemoteCommandIfNeeded(id: command.id, type: command.commandType,
                durationSeconds: command.durationSeconds)
        }
        let locationTasks = nonSchedule.filter { $0.commandType == .requestLocation }.map { command in
            Task { await self.applyRemoteCommandIfNeeded(id: command.id, type: .requestLocation, durationSeconds: nil) }
        }
        for task in locationTasks { await task.value }
    }

    private func syncChildWithDesiredStateIfNeeded() async {
        guard deviceRole == .child, pairingState?.isLinked == true else { return }
        guard await flushLocalManualBlockIntent() else { return }
        let requestedFamily = pairingState?.familyID
        do {
            let desired = try await remoteSyncService.fetchDesiredFocusState()
            guard pairingState?.familyID == requestedFamily else { return }
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
        // Continue fetching PIN, budget and schedules even if focus sync is offline.
        _ = await flushLocalManualBlockIntent()
        let requestedFamily = pairingState?.familyID
        do {
            let poll = try await remoteSyncService.childPoll(includeParentSettings: includeParentSettings)
            guard pairingState?.familyID == requestedFamily else { return }
            applyDailyBudgetPolicy(poll.budget?.policy)
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
        guard deviceRole == .child, pairingState?.isLinked == true,
              pendingLocalFocusChange == nil, let family = pairingState?.familyID,
              let revision = desired.revision, revision >= childFocusRevision else { return }
        if revision != childFocusRevision {
            UserDefaults.standard.set(revision, forKey: focusRevisionKey(family))
        }
        do {
            let localIsActive: Bool = {
                guard isFocusSessionActive else { return false }
                if let end = focusSessionEndsAt { return end > Date() }
                return true
            }()
            let needsIndefiniteBlock = desired.shouldFocusActive
                && (desired.durationSeconds ?? 0) <= 0 && focusSessionEndsAt != nil
            guard desired.shouldFocusActive != localIsActive || needsIndefiniteBlock else { return }

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
            try await remoteSyncService.updateChildRuntimeState(runtime, focusRevision: revision)
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
        guard deviceRole == .child else { return locationService.authorizationStatus }
        let status = await locationService.requestWhenInUseAuthorization()
        childLocationAuthorizationStatus = status
        return status
    }

    /// Ask for Always after When In Use. iOS may defer or suppress the prompt;
    /// return the current status without blocking onboarding. Background execution
    /// and push delivery remain controlled by iOS, even with Always authorization.
    @discardableResult
    func requestChildLocationAlwaysAuthorizationIfNeeded() async -> CLAuthorizationStatus {
        guard deviceRole == .child else { return locationService.authorizationStatus }
        let status = await locationService.requestAlwaysAuthorization()
        childLocationAuthorizationStatus = status
        return status
    }

    /// Обновить значение `childLocationAuthorizationStatus` (нужно после возврата из Settings).
    func refreshChildLocationAuthorizationStatus() {
        childLocationAuthorizationStatus = locationService.authorizationStatus
    }

    /// One command per refresh; poll its outcome rather than repeatedly fetching an old location.
    func refreshChildLocationFromParent() async {
        guard !Task.isCancelled, !isParentRefreshingChildLocation,
              deviceRole == .parent, let familyID = pairingState?.familyID,
              pairingState?.isLinked == true else { return }
        isParentRefreshingChildLocation = true
        parentLocationRevision += 1
        parentLocationStatusMessage = nil
        defer { isParentRefreshingChildLocation = false }

        do {
            let command = try await remoteSyncService.requestChildLocation()
            let deadline = ContinuousClock.now.advanced(by: .seconds(30))
            while ContinuousClock.now < deadline {
                try await Task.sleep(nanoseconds: 2_000_000_000)
                guard deviceRole == .parent, pairingState?.familyID == familyID else { return }
                guard let result = try await remoteSyncService.fetchCommandStatus(commandID: command.id, timeout: 8) else { continue }
                try Task.checkCancellation()
                guard pairingState?.familyID == familyID else { return }
                if result.status == .failed {
                    parentLocationStatusMessage = locationFailureMessage(code: result.errorMessage)
                    return
                }
                if result.status == .applied {
                    // The child now acknowledges only after upload. Older builds may falsely ACK:
                    // read once, but never present their previous point as a successful refresh.
                    let snapshot = try await remoteSyncService.fetchChildLocation()
                    try Task.checkCancellation()
                    guard pairingState?.familyID == familyID else { return }
                    guard let snapshot, snapshot.updatedAt >= command.createdAt,
                          snapshot.capturedAt >= command.createdAt.addingTimeInterval(-30) else {
                        parentLocationStatusMessage = L10n.tr("map.refresh.unavailable")
                        return
                    }
                    childLocationSnapshot = snapshot
                    storage.saveChildLocationSnapshot(snapshot)
                    return
                }
            }
            parentLocationStatusMessage = L10n.tr("map.refresh.timeout")
        } catch {
            guard !Task.isCancelled, pairingState?.familyID == familyID else { return }
            parentLocationStatusMessage = L10n.tr("map.refresh.connection_error")
        }
    }

    private func locationFailureMessage(code: String?) -> String {
        switch code {
        case "location_always_required":
            return L10n.tr("map.refresh.always_required")
        case "location_services_disabled":
            return L10n.tr("map.refresh.services_disabled")
        case "location_timeout", "max_retry_exceeded", "expired_ttl":
            return L10n.tr("map.refresh.timeout")
        case "location_upload_failed":
            return L10n.tr("map.refresh.connection_error")
        default:
            return L10n.tr("map.refresh.unavailable")
        }
    }

    func loadChildLocationIfNeeded() async {
        guard !Task.isCancelled, deviceRole == .parent, pairingState?.isLinked == true,
              !isLoadingChildLocation, !isParentRefreshingChildLocation else { return }
        if childLocationSnapshot == nil, let cached = storage.loadChildLocationSnapshot() {
            childLocationSnapshot = cached
        }
        let familyID = pairingState?.familyID
        let revision = parentLocationRevision
        isLoadingChildLocation = true
        defer { isLoadingChildLocation = false }
        do {
            let snapshot = try await remoteSyncService.fetchChildLocation()
            try Task.checkCancellation()
            guard pairingState?.familyID == familyID, revision == parentLocationRevision,
                  !isParentRefreshingChildLocation else { return }
            if let snapshot, snapshot.updatedAt >= (childLocationSnapshot?.updatedAt ?? .distantPast) {
                childLocationSnapshot = snapshot
                storage.saveChildLocationSnapshot(snapshot)
            }
        } catch {
            guard !Task.isCancelled, pairingState?.familyID == familyID, revision == parentLocationRevision,
                  !isParentRefreshingChildLocation else { return }
            parentLocationStatusMessage = L10n.tr("map.refresh.connection_error")
        }
    }

    /// Duplicate push/foreground-poll handlers await the same operation, including its ACK.
    /// A failed ACK is retried on redelivery, without performing another capture/upload.
    private func applyLocationCommand(id: UUID) async {
        if let task = locationCommandTasks[id] {
            await task.value
            return
        }
        guard let familyID = pairingState?.familyID else { return }
        let task = Task { @MainActor in
            let errorCode: String?
            if let previous = self.locationCommandResults.first(where: { $0.id == id }) {
                if previous.acknowledged { return }
                errorCode = previous.errorCode
            } else {
                errorCode = await self.captureAndUploadChildLocation()
                guard self.pairingState?.familyID == familyID, self.deviceRole == .child else { return }
                self.locationCommandResults.append((id, errorCode, false))
                if self.locationCommandResults.count > 20 { self.locationCommandResults.removeFirst() }
            }
            guard !Task.isCancelled, self.pairingState?.familyID == familyID, self.deviceRole == .child else { return }
            do {
                try await self.remoteSyncService.ackCommand(
                    id: id, status: errorCode == nil ? .applied : .failed, errorMessage: errorCode, timeout: 5)
                if let index = self.locationCommandResults.firstIndex(where: { $0.id == id }) {
                    self.locationCommandResults[index].acknowledged = true
                }
            } catch {
                os_log("Location command acknowledgement failed", log: appStateLog, type: .error)
            }
        }
        locationCommandTasks[id] = task
        await task.value
        locationCommandTasks[id] = nil
    }

    /// Concurrent distinct location commands share one GPS capture and one upload.
    /// Errors are returned as stable codes, not swallowed and acknowledged as success.
    private func captureAndUploadChildLocation() async -> String? {
        if let task = childLocationUploadTask { return await task.value }
        let familyID = pairingState?.familyID
        let uploadID = UUID()
        let task = Task<String?, Never> { @MainActor in
            do {
                let location = try await self.locationService.captureCurrentLocation(timeout: 18)
                try Task.checkCancellation()
                guard self.deviceRole == .child, self.pairingState?.familyID == familyID else {
                    return "location_cancelled"
                }
                let snapshot = ChildLocationSnapshot(
                    latitude: location.coordinate.latitude,
                    longitude: location.coordinate.longitude,
                    horizontalAccuracy: location.horizontalAccuracy,
                    capturedAt: location.timestamp,
                    updatedAt: Date())
                do {
                    try await self.remoteSyncService.updateChildLocation(snapshot)
                    try Task.checkCancellation()
                } catch {
                    return "location_upload_failed"
                }
                guard self.pairingState?.familyID == familyID else { return "location_cancelled" }
                self.storage.saveChildLocationSnapshot(snapshot)
                return nil
            } catch let error as LocationServiceError {
                return error.commandErrorCode
            } catch {
                return "location_unavailable"
            }
        }
        childLocationUploadTask = task
        childLocationUploadID = uploadID
        let result = await task.value
        if childLocationUploadID == uploadID {
            childLocationUploadTask = nil
            childLocationUploadID = nil
        }
        return result
    }

    private func applyRemoteCommandIfNeeded(id: UUID, type: RemoteFocusCommandType, durationSeconds: Int?) async {
        guard deviceRole == .child, pairingState?.isLinked == true else { return }
        if type == .requestLocation {
            await applyLocationCommand(id: id)
            return
        }
        if type == .startFocus || type == .endFocus {
            guard await flushLocalManualBlockIntent() else { return }
            let requestedFamily = pairingState?.familyID
            do {
                // A delayed APNs/NSE payload is only a wake-up hint. Fetch current
                // desired state instead of replaying a superseded start/end action.
                let desired = try await remoteSyncService.fetchDesiredFocusState()
                guard pairingState?.familyID == requestedFamily,
                      pendingLocalFocusChange == nil,
                      let revision = desired.revision, revision >= childFocusRevision else { return }
                await applyDesiredFocusState(desired)
                guard pairingState?.familyID == requestedFamily,
                      pendingLocalFocusChange == nil, revision == childFocusRevision else { return }
                let matches = desired.shouldFocusActive == (type == .startFocus)
                try await remoteSyncService.ackCommand(id: id, status: matches ? .applied : .failed,
                    errorMessage: matches ? nil : "superseded_by_newer_command")
            } catch {
                remoteStatusMessage = error.localizedDescription
            }
            return
        }
        if DailyBudgetStore.shared.isEnabled,
           type == .addEarnedSeconds || type == .subtractEarnedSeconds || type == .resetEarnedBalance {
            try? await remoteSyncService.ackCommand(id: id, status: .failed, errorMessage: "replaced_by_daily_budget")
            return
        }
        if storage.loadLastHandledRemoteCommandID() == id.uuidString {
            try? await remoteSyncService.ackCommand(id: id, status: .applied, errorMessage: nil)
            return
        }
        // Visible banner is now produced by the APNs alert push itself (formed on the backend
        // with localized title/body via `commandLocalizedAlert`). We must NOT post a local
        // UNUserNotification here — otherwise the user gets two notifications for one command:
        // one from the server push and another from this local notify call.
        switch type {
        case .startFocus, .endFocus:
            return // Handled above using authoritative, revisioned desired state.
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
            return // Handled separately, including failed capture/upload and duplicate delivery.
        case .schedulesUpdated:
            await refreshChildBlockSchedulesFromServerAndApplyEnforcement()
        case .scheduleStarted, .scheduleEnded:
            // Бэкенд-cron детектировал переход start/end окна расписания. Просто перезапускаем
            // enforcement — внутренняя логика `isScheduleActiveNow` сама применит/снимет
            // именованный shield для нужного расписания. Список расписаний не изменился,
            // поэтому fetch делать не нужно.
            blockScheduleEnforcement.refreshFromStoredSchedules()
        case .tasksUpdated:
            await pollChildAndApply(includeParentSettings: false)
            // Обычно tasks_updated отфильтровывается в applyPendingCommands; ветка здесь —
            // защита от случая, если команда дойдёт сюда как «последняя» (просто перетягиваем список).
            await refreshChildTasksFromServer()
        }
        storage.saveLastHandledRemoteCommandID(id.uuidString)
        do {
            try await remoteSyncService.ackCommand(id: id, status: .applied, errorMessage: nil)
            if pendingLocalFocusChange == nil {
                // Capture state AND revision after the await: a local toggle may
                // have completed while the acknowledgement was in flight.
                let newState = RemoteChildRuntimeState(isFocusActive: isFocusSessionActive,
                    focusEndsAt: focusSessionEndsAt, lastUpdatedAt: Date())
                remoteChildState = newState
                try await remoteSyncService.updateChildRuntimeState(newState, focusRevision: childFocusRevision)
            }
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
        let requestedFamily = pairingState?.familyID
        var lastError: Error?
        for attempt in 0..<2 {
            do {
                // Один combined-вызов вместо desired + snapshot + linkHealth + childBalance.
                let poll = try await remoteSyncService.parentPoll()
                guard pairingState?.familyID == requestedFamily else { return }
                if let status = poll.budget { receiveParentBudget(status) }
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
        // The local parent may have changed the block AFTER this command applied.
        // Do not replace a newer confirmed runtime with an old command's projection.
        if let runtime = lastNormalizedParentChildRuntime, let delivery = parentCommandDelivery,
           runtime.lastUpdatedAt > (delivery.appliedAt ?? delivery.updatedAt) {
            parentResolvedFocusActive = isFocusActiveNowOnParentUI(runtime)
            remoteChildState = runtime
            isParentChildStateResolved = true
            finishParentCommandWatch(commandID: commandID)
            return
        }
        // No newer runtime: retain the acknowledged command while the snapshot catches up.
        parentResolvedFocusActive = (commandType == .startFocus)
        remoteChildState = runtimeFromDesiredFallback(commandType == .startFocus, current: remoteChildState)
        isParentChildStateResolved = true
        finishParentCommandWatch(commandID: commandID)
    }

    private func finishParentCommandWatch(commandID: UUID) {
        guard activeParentCommandID == commandID else { return }
        activeParentCommandID = nil
        pendingParentManualBlock = nil
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
             .requestLocation, .schedulesUpdated, .scheduleStarted, .scheduleEnded,
             .tasksUpdated:
            return true
        }
    }

    private func sendParentCommand(commandType: RemoteFocusCommandType, durationSeconds: Int?) async {
        guard beginParentCommand(commandType: commandType) else { return }
        await performParentCommand(commandType: commandType, durationSeconds: durationSeconds)
    }

    private func beginParentCommand(commandType: RemoteFocusCommandType) -> Bool {
        guard deviceRole == .parent, pairingState?.isLinked == true, !remoteCommandInFlight else { return false }
        pendingParentManualBlock = commandType == .startFocus ? true : (commandType == .endFocus ? false : nil)
        remoteCommandInFlight = true
        remoteStatusMessage = L10n.tr("parent.command.processing")
        if commandType == .startFocus {
            parentDesiredFocusActive = true
        } else if commandType == .endFocus {
            parentDesiredFocusActive = false
        }
        return true
    }

    private func performParentCommand(commandType: RemoteFocusCommandType, durationSeconds: Int?) async {
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
            pendingParentManualBlock = nil
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

    func dailyStats(for date: Date, steps: Int) -> DailyStats {
        let calendar = Calendar.current
        if let saved = try? DailyBudgetStore.shared.history(for: date) {
            let focus = dayLedgerEntries(for: date).filter { $0.source == .focusSession }
                .reduce(0) { $0 + max(0, $1.focusDurationSeconds ?? 0) }
            return DailyStats(date: date, steps: 0, earnedSeconds: saved.budgetSeconds,
                spentSeconds: saved.usedSeconds, pushUps: 0, squats: 0, focusSessionTotalSeconds: focus)
        }
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
        guard await flushLocalManualBlockIntent() else { return }
        resetDailyBalanceIfNeeded()
        let today = dailyStats(for: Date(), steps: todaySteps)
        let history = (try? DailyBudgetStore.shared.pendingHistory()) ?? []
        do {
            // Один combined-вызов вместо трёх (upsert_child_day_stats + update_child_runtime
            // + update_child_balance). Runtime и balance пишутся в одну строку child_runtime_state.
            try await remoteSyncService.upsertChildRuntimeBundle(
                stats: today,
                isFocusActive: isFocusSessionActive,
                focusEndsAt: focusSessionEndsAt,
                focusRevision: childFocusRevision,
                availableSeconds: balance.availableSeconds,
                budgetState: budgetMonitorReady ? dailyBudget : nil,
                budgetHistory: history
            )
            try DailyBudgetStore.shared.markHistoryUploaded(history)
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
        guard source != .steps, source != .squat, source != .pushUp,
              !DailyBudgetStore.shared.isEnabled else { return }
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
        if !DailyBudgetStore.shared.isEnabled { screenTimeService.stopDeviceActivityMonitoring() }
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
            await refreshChildTasksFromServer()
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
            parentPairingWaitTask?.cancel()
            parentPairingWaitTask = nil
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
        // No step-based earning.
    }

    private func reloadBalanceFromSharedStore() {
        dailyBudget = try? DailyBudgetStore.shared.current()
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
        if deviceRole == .child, DailyBudgetStore.shared.isEnabled {
            dailyBudget = try? DailyBudgetStore.shared.current()
            balance = storage.loadBalance()
            budgetMonitorReady = screenTimeService.ensureDailyBudgetMonitoring()
            if !budgetMonitorReady || dailyBudget == nil {
                budgetError = L10n.tr("budget.apply_error")
                screenTimeService.stopDeviceActivityMonitoring()
                screenTimeService.applyShield()
                return
            }
            if budgetError == L10n.tr("budget.apply_error") { budgetError = nil }
        }
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
                let started = screenTimeService.startDeviceActivityMonitoring(availableSeconds: balance.availableSeconds)
                if DailyBudgetStore.shared.isEnabled && !started {
                    budgetMonitorReady = false
                    budgetError = L10n.tr("budget.apply_error")
                    screenTimeService.applyShield()
                    return
                }
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
        if DailyBudgetStore.shared.isEnabled {
            dailyBudget = try? DailyBudgetStore.shared.current()
            balance = storage.loadBalance()
        } else {
            // Preserve legacy balance until explicit parent activation.
            ensureSpentBaselineForToday()
        }
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

    // MARK: - Child tasks (задания для ребёнка)

    /// Дефолтная награда нового задания — 15 минут.
    static let defaultChildTaskRewardSeconds = 15 * 60

    /// Тянет актуальный список заданий с бэкенда (для parent и child). `list_child_tasks`
    /// доступен обеим ролям, поэтому метод универсален. Ошибки сети глотаем — остаётся кэш.
    func refreshChildTasksFromServer() async {
        guard pairingState?.isLinked == true else { return }
        if isUpdatingChildTasks {
            childTasksRefreshPending = true
            return
        }
        let family = pairingState?.familyID
        let generation = childTasksGeneration
        childTasksRequest += 1
        let request = childTasksRequest
        do {
            let dtos = try await remoteSyncService.fetchChildTasks()
            guard pairingState?.familyID == family, pairingState?.isLinked == true,
                  childTasksGeneration == generation, childTasksRequest == request,
                  !isUpdatingChildTasks else { return }
            let now = Date()
            let merged = dtos.map { ChildTask(remoteDTO: $0) }.filter { $0.isVisible(at: now) }
            childTasks = merged
            storage.saveChildTasks(merged)
        } catch {
            os_log("refreshChildTasks: %{public}@", log: appStateLog, type: .error, error.localizedDescription)
        }
    }

    /// Пустой черновик задания (роль parent). Не попадает в список до `commitChildTask`.
    func makeDraftChildTask() -> ChildTask {
        ChildTask(title: "", details: "", rewardSeconds: Self.defaultChildTaskRewardSeconds)
    }

    /// UI меняется только после ответа сервера. Ошибка не удаляет локальное задание.
    func commitChildTask(_ task: ChildTask, isNew: Bool) async -> Bool {
        guard deviceRole == .parent else { return false }
        return await changeChildTask(task.id) {
            let dto = try await self.remoteSyncService.upsertChildTask(task, isNew: isNew)
            return ChildTask(remoteDTO: dto)
        }
    }

    func deleteChildTask(_ taskID: UUID) async -> Bool {
        guard deviceRole == .parent else { return false }
        return await changeChildTask(taskID) {
            try await self.remoteSyncService.deleteChildTask(id: taskID)
            return nil
        }
    }

    func approveChildTask(_ taskID: UUID) async -> Bool {
        guard deviceRole == .parent else { return false }
        return await changeChildTask(taskID) {
            let dto = try await self.remoteSyncService.approveChildTask(id: taskID)
            return ChildTask(remoteDTO: dto)
        }
    }

    func submitChildTask(_ taskID: UUID) async -> Bool {
        guard deviceRole == .child else { return false }
        return await changeChildTask(taskID) {
            let dto = try await self.remoteSyncService.submitChildTask(id: taskID)
            return ChildTask(remoteDTO: dto)
        }
    }

    private func changeChildTask(
        _ id: UUID,
        operation: () async throws -> ChildTask?
    ) async -> Bool {
        guard pairingState?.isLinked == true, !isUpdatingChildTasks else { return false }
        let family = pairingState?.familyID
        isUpdatingChildTasks = true
        childTasksGeneration += 1
        defer {
            childTasksGeneration += 1
            isUpdatingChildTasks = false
            // Не теряем push-обновление, полученное во время сохранения.
            if childTasksRefreshPending {
                childTasksRefreshPending = false
                Task { await self.refreshChildTasksFromServer() }
            }
        }
        do {
            let result = try await operation()
            guard pairingState?.familyID == family, pairingState?.isLinked == true else { return false }
            childTasks.removeAll { $0.id == id }
            if let result, result.isVisible(at: Date()) { childTasks.insert(result, at: 0) }
            storage.saveChildTasks(childTasks)
            return true
        } catch {
            os_log("changeChildTask: %{public}@", log: appStateLog, type: .error, error.localizedDescription)
            return false
        }
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
    let revision: Int?
}

private struct LocalManualBlockIntent: Codable {
    let id: UUID
    let familyID: UUID
    let isActive: Bool
    let expectedRevision: Int
    let pinVersion: String
}

private struct LocalManualBlockResult: Decodable {
    let outcome: String
    let desired: DesiredFocusStateDTO
}

/// Ответ combined-экшена `child_poll`: всё, что ребёнок тянет за один тик.
/// `parentPin`/`parentPro` присутствуют только когда клиент запросил `includeParentSettings`.
private struct ChildPollDTO: Decodable {
    let budget: DailyBudgetStatus?
    let desired: DesiredFocusStateDTO
    let pendingCommands: [PendingCommandDTO]
    let parentPin: ParentPinSyncDTO?
    let parentPro: ParentProSyncDTO?
}

/// Ответ combined-экшена `parent_poll`: объединяет desired + snapshot + linkHealth + childBalance.
private struct ParentPollDTO: Decodable {
    let budget: DailyBudgetStatus?
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
        static let focusBaseURL = URL(string: "https://tttwrzgjddalgiwmgmyz.supabase.co/functions/v1/parental-control-sync")!
        static let balanceBaseURL = URL(string: "https://tttwrzgjddalgiwmgmyz.supabase.co/functions/v1/parental-control-balance-sync")!
        static let anonKey = "sb_publishable_urT7eQPRIxyXso8VKA2tHQ_-U0I0CsO"
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
        // Persist credentials BEFORE registration. A lost response must not
        // make an existing installation recoverable using only its public ID.
        if storage.loadDeviceSecret()?.isEmpty != false {
            storage.saveDeviceSecret(UUID().uuidString + UUID().uuidString)
        }
        let response: RegisterDeviceResponseDTO = try await call(
            action: "register_device",
            payload: Payload(installID: installID, role: role.rawValue)
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

    func updateAPNSToken(_ token: String, environment: String? = nil) async throws {
        struct Payload: Encodable {
            let installID: String
            let apnsToken: String
            let apnsEnvironment: String?
        }
        let _: EmptyResponse = try await call(
            action: "update_apns_token",
            payload: Payload(installID: installID, apnsToken: token, apnsEnvironment: environment)
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

    func fetchCommandStatus(commandID: UUID, timeout: TimeInterval? = nil) async throws -> CommandStatusDTO? {
        struct Payload: Encodable {
            let installID: String
            let commandID: String
        }
        return try await call(
            action: "fetch_command_status",
            payload: Payload(installID: installID, commandID: commandID.uuidString),
            timeout: timeout
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

    func ackCommand(id: UUID, status: RemoteFocusCommandStatus, errorMessage: String?, timeout: TimeInterval? = nil) async throws {
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
            ),
            timeout: timeout
        )
    }

    func updateChildRuntimeState(_ state: RemoteChildRuntimeState, focusRevision: Int) async throws {
        struct Payload: Encodable {
            let installID: String
            let isFocusActive: Bool
            let focusEndsAt: String?
            let focusRevision: Int
        }
        let endISO = state.focusEndsAt.map { ISO8601DateFormatter().string(from: $0) }
        let _: EmptyResponse = try await call(
            action: "update_child_runtime",
            payload: Payload(installID: installID, isFocusActive: state.isFocusActive,
                focusEndsAt: endISO, focusRevision: focusRevision)
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

    func setLocalManualBlock(_ intent: LocalManualBlockIntent) async throws -> LocalManualBlockResult {
        struct Payload: Encodable {
            let intentID: UUID
            let familyID: UUID
            let isActive: Bool
            let expectedRevision: Int
            let pinVersion: String
        }
        return try await call(action: "set_local_manual_block", payload: Payload(
            intentID: intent.id, familyID: intent.familyID, isActive: intent.isActive,
            expectedRevision: intent.expectedRevision, pinVersion: intent.pinVersion))
    }

    // MARK: - Combined polling endpoints (экономия Edge Function Invocations)

    /// Child → backend: один вызов вместо `fetch_desired_focus_state` + `fetch_pending_commands`
    /// (+ `fetch_parent_pin` + `fetch_parent_pro`, если `includeParentSettings == true`).
    func changeDailyBudget(kind: String, seconds: Int, expectedRevision: Int, intentID: UUID,
                           weeklyLimitsSeconds: [Int]? = nil) async throws -> DailyBudgetStatus {
        struct Payload: Encodable {
            let kind: String
            let seconds: Int
            let expectedRevision: Int
            let intentID: UUID
            let weeklyLimitsSeconds: [Int]?
            let weeklyBudgetProtocol = 1
        }
        return try await call(action: "change_daily_budget", payload: Payload(
            kind: kind, seconds: seconds, expectedRevision: expectedRevision, intentID: intentID,
            weeklyLimitsSeconds: weeklyLimitsSeconds))
    }

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
        focusRevision: Int,
        availableSeconds: Int,
        budgetState: DailyBudgetState?,
        budgetHistory: [DailyBudgetState]
    ) async throws {
        struct Payload: Encodable {
            let installID: String
            let dayStartISO: String
            let earnedSeconds: Int
            let spentSeconds: Int
            let isFocusActive: Bool
            let focusEndsAt: String?
            let focusRevision: Int
            let availableSeconds: Int
            let budgetState: DailyBudgetState?
            let budgetHistory: [DailyBudgetState]
            let budgetProtocol = 1
            let weeklyBudgetProtocol = 1
            let budgetTimezone = TimeZone.current.identifier
        }
        let dayStart = Calendar.current.startOfDay(for: stats.date)
        let dayISO = ISO8601DateFormatter().string(from: dayStart)
        let endISO = focusEndsAt.map { ISO8601DateFormatter().string(from: $0) }
        let _: EmptyResponse = try await call(
            action: "upsert_child_runtime_bundle",
            payload: Payload(
                installID: installID,
                dayStartISO: dayISO,
                earnedSeconds: stats.earnedSeconds,
                spentSeconds: stats.spentSeconds,
                isFocusActive: isFocusActive,
                focusEndsAt: endISO,
                focusRevision: focusRevision,
                availableSeconds: max(0, availableSeconds),
                budgetState: budgetState,
                budgetHistory: budgetHistory
            )
        )
    }

    /// Parent → backend: попросить ребёнка прислать свежую координату.
    /// Сервер ставит focus_command типа request_location и шлёт alert push на ребёнка.
    func requestChildLocation() async throws -> PendingCommandDTO {
        struct Payload: Encodable { let installID: String }
        return try await call(
            action: "request_child_location",
            payload: Payload(installID: installID),
            timeout: 10
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
            ),
            timeout: 5
        )
    }

    /// Parent → backend: достать последнюю известную координату ребёнка для своей семьи.
    func fetchChildLocation() async throws -> ChildLocationSnapshot? {
        struct Payload: Encodable { let installID: String }
        let dto: ChildLocationDTO? = try await call(
            action: "fetch_child_location",
            payload: Payload(installID: installID),
            timeout: 8
        )
        guard let dto else { return nil }
        guard let captured = decodeISO8601Fractional.date(from: dto.capturedAtISO)
                ?? decodeISO8601.date(from: dto.capturedAtISO),
              let updated = decodeISO8601Fractional.date(from: dto.updatedAtISO)
                ?? decodeISO8601.date(from: dto.updatedAtISO) else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Invalid location timestamp"))
        }
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

    // MARK: Child tasks

    func fetchChildTasks() async throws -> [RemoteChildTaskDTO] {
        struct Payload: Encodable { let installID: String }
        struct Response: Decodable { let tasks: [RemoteChildTaskDTO] }
        let response: Response = try await call(
            action: "list_child_tasks",
            payload: Payload(installID: installID)
        )
        return response.tasks
    }

    private struct TaskMutationResponse: Decodable {
        let task: RemoteChildTaskDTO
    }

    func upsertChildTask(_ task: ChildTask, isNew: Bool) async throws -> RemoteChildTaskDTO {
        struct Payload: Encodable {
            let installID: String
            let id: String
            let title: String
            let details: String
            let rewardSeconds: Int
            let isNew: Bool
        }
        let payload = Payload(
            installID: installID,
            id: task.id.uuidString,
            title: task.title,
            details: task.details,
            rewardSeconds: max(0, task.rewardSeconds),
            isNew: isNew
        )
        let response: TaskMutationResponse = try await call(action: "upsert_child_task", payload: payload)
        return response.task
    }

    func deleteChildTask(id: UUID) async throws {
        struct Payload: Encodable {
            let installID: String
            let id: String
        }
        let _: EmptyResponse = try await call(
            action: "delete_child_task",
            payload: Payload(installID: installID, id: id.uuidString)
        )
    }

    func submitChildTask(id: UUID) async throws -> RemoteChildTaskDTO {
        struct Payload: Encodable {
            let installID: String
            let id: String
        }
        let response: TaskMutationResponse = try await call(
            action: "submit_child_task",
            payload: Payload(installID: installID, id: id.uuidString)
        )
        return response.task
    }

    func approveChildTask(id: UUID) async throws -> RemoteChildTaskDTO {
        struct Payload: Encodable {
            let installID: String
            let id: String
        }
        let response: TaskMutationResponse = try await call(
            action: "approve_child_task",
            payload: Payload(installID: installID, id: id.uuidString)
        )
        return response.task
    }

    private func call<T: Decodable, P: Encodable>(
        action: String,
        payload: P,
        includeSecret: Bool = true,
        endpoint: URL? = nil,
        timeout: TimeInterval? = nil
    ) async throws -> T {
        let endpointURL = endpoint ?? Endpoint.focusBaseURL
        var request = URLRequest(url: endpointURL)
        if let timeout { request.timeoutInterval = timeout }
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
