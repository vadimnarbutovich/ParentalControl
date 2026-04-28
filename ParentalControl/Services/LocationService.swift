import Foundation
import CoreLocation
import os.log

protocol LocationProviding {
    var authorizationStatus: CLAuthorizationStatus { get }
    func requestWhenInUseAuthorization() async -> CLAuthorizationStatus
    /// Запросить апгрейд до Always. Apple требует, чтобы перед этим был уже выдан When-in-Use.
    /// Возвращает финальный статус.
    func requestAlwaysAuthorization() async -> CLAuthorizationStatus
    /// Снять одну координату. Реализация использует startUpdatingLocation() и берёт первый
    /// fix, удовлетворяющий минимальным критериям свежести/точности — это значительно быстрее
    /// и надёжнее чем requestLocation() при пробуждении приложения из push-фона.
    func captureCurrentLocation(timeout: TimeInterval) async throws -> CLLocation
}

enum LocationServiceError: LocalizedError {
    case permissionDenied
    case servicesDisabled
    case timeout
    case underlying(Error)

    var errorDescription: String? {
        switch self {
        case .permissionDenied: return "Location permission denied"
        case .servicesDisabled: return "Location services are disabled"
        case .timeout: return "Location capture timed out"
        case .underlying(let error): return error.localizedDescription
        }
    }
}

final class LocationService: NSObject, LocationProviding, CLLocationManagerDelegate {

    private static let log = OSLog(subsystem: "mycompny.ParentalControl", category: "LocationService")

    private let manager: CLLocationManager
    /// Очередь активных «одноразовых» запросов координат. Каждый ожидающий получит первый
    /// fix, удовлетворяющий критериям, после чего мы остановим обновления.
    private var pendingLocationContinuations: [CheckedContinuation<CLLocation, Error>] = []
    private var pendingAuthorizationContinuations: [CheckedContinuation<CLAuthorizationStatus, Never>] = []
    private var captureTimeoutTask: Task<Void, Never>?
    private var isUpdatingLocation: Bool = false
    /// Кешируем последний известный статус, полученный из delegate-callback.
    /// `manager.authorizationStatus` на main thread в iOS 17+ выдаёт диагностическое
    /// предупреждение «UI unresponsiveness», поэтому используем закэшированное значение.
    private var cachedAuthorizationStatus: CLAuthorizationStatus = .notDetermined
    /// Минимально допустимая точность fix'а в метрах. Если первый fix хуже — ждём следующий.
    private let acceptableHorizontalAccuracyMeters: CLLocationAccuracy = 200
    /// Сколько максимум ждём «лучший» fix даже если уже пришёл «приемлемый», но не идеальный.
    /// Это экономит трафик и батарею: не висим до полного timeout, если уже есть достойный fix.
    private let goodEnoughGraceSeconds: TimeInterval = 4.0
    private var firstAcceptableFixDate: Date?
    /// Закэшированное значение «есть ли в Info.plist UIBackgroundModes=location».
    /// Включать `allowsBackgroundLocationUpdates=true` без этой записи — гарантированный краш
    /// (`CLClientIsBackgroundable` assertion). Проверяем РОВНО ОДИН РАЗ при старте сервиса,
    /// чтобы не платить за чтение Info.plist в hot path.
    private let isBackgroundLocationModeDeclared: Bool = {
        guard let modes = Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String] else {
            return false
        }
        return modes.contains("location")
    }()

    override init() {
        self.manager = CLLocationManager()
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        manager.activityType = .other
        manager.pausesLocationUpdatesAutomatically = false
        // Подтягиваем стартовое значение асинхронно, чтобы не блокировать main.
        // CoreLocation в любом случае пришлёт `locationManagerDidChangeAuthorization` сразу после
        // назначения делегата — вот там мы и обновим cachedAuthorizationStatus.
    }

    deinit {
        captureTimeoutTask?.cancel()
        if isUpdatingLocation {
            manager.stopUpdatingLocation()
            isUpdatingLocation = false
        }
        for continuation in pendingLocationContinuations {
            continuation.resume(throwing: LocationServiceError.underlying(NSError(
                domain: "LocationService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Service deinit"]
            )))
        }
        pendingLocationContinuations.removeAll()
        for continuation in pendingAuthorizationContinuations {
            continuation.resume(returning: .notDetermined)
        }
        pendingAuthorizationContinuations.removeAll()
    }

    var authorizationStatus: CLAuthorizationStatus {
        cachedAuthorizationStatus
    }

    func requestWhenInUseAuthorization() async -> CLAuthorizationStatus {
        let current = cachedAuthorizationStatus
        if current != .notDetermined {
            return current
        }
        return await withCheckedContinuation { continuation in
            pendingAuthorizationContinuations.append(continuation)
            manager.requestWhenInUseAuthorization()
        }
    }

    func requestAlwaysAuthorization() async -> CLAuthorizationStatus {
        let current = cachedAuthorizationStatus
        // Если пользователь уже выбрал .denied/.restricted/.always — повторный запрос не покажет диалог.
        if current == .denied || current == .restricted || current == .authorizedAlways {
            return current
        }
        // Apple требует, чтобы When-in-Use был выдан до запроса Always. Если статус notDetermined —
        // SDK покажет When-in-Use, а Always запросим повторно после того, как он станет authorizedWhenInUse.
        return await withCheckedContinuation { continuation in
            pendingAuthorizationContinuations.append(continuation)
            manager.requestAlwaysAuthorization()
        }
    }

    func captureCurrentLocation(timeout: TimeInterval) async throws -> CLLocation {
        let status = cachedAuthorizationStatus
        switch status {
        case .denied, .restricted:
            os_log("captureCurrentLocation: permission denied (status=%{public}d)", log: Self.log, type: .error, status.rawValue)
            throw LocationServiceError.permissionDenied
        case .notDetermined:
            os_log("captureCurrentLocation: status notDetermined", log: Self.log, type: .error)
            throw LocationServiceError.permissionDenied
        default:
            break
        }
        guard CLLocationManager.locationServicesEnabled() else {
            os_log("captureCurrentLocation: locationServicesEnabled=false", log: Self.log, type: .error)
            throw LocationServiceError.servicesDisabled
        }

        os_log("captureCurrentLocation: starting updates (timeout=%.1fs, status=%{public}d)",
               log: Self.log, type: .info, timeout, status.rawValue)

        return try await withCheckedThrowingContinuation { continuation in
            pendingLocationContinuations.append(continuation)
            firstAcceptableFixDate = nil
            captureTimeoutTask?.cancel()
            captureTimeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(max(1.0, timeout) * 1_000_000_000))
                guard let self else { return }
                await self.failPendingWithTimeoutIfNeeded()
            }
            if !isUpdatingLocation {
                // Включаем фоновые апдейты ТОЛЬКО если выполнены ВСЕ условия:
                //   1. Есть Always-разрешение.
                //   2. В Info.plist бандла действительно объявлено UIBackgroundModes=location.
                // Иначе CLLocationManager бросит NSInternalInconsistencyException и приложение крешится.
                // Это особенно частый кейс при инкрементальной сборке Xcode — добавили запись в pbxproj,
                // но Info.plist в бандле остался старым. Защищаемся явно.
                if status == .authorizedAlways && isBackgroundLocationModeDeclared {
                    manager.allowsBackgroundLocationUpdates = true
                    manager.showsBackgroundLocationIndicator = false
                } else if status == .authorizedAlways && !isBackgroundLocationModeDeclared {
                    os_log("captureCurrentLocation: Always granted but UIBackgroundModes lacks 'location' — skipping background updates",
                           log: Self.log, type: .error)
                }
                manager.startUpdatingLocation()
                isUpdatingLocation = true
            }
        }
    }

    @MainActor
    private func failPendingWithTimeoutIfNeeded() {
        guard !pendingLocationContinuations.isEmpty else { return }
        os_log("captureCurrentLocation: timed out, resolving with cached best fix or error",
               log: Self.log, type: .error)
        // Если за время ожидания пришёл хотя бы один fix — отдаём последний известный кэш менеджера.
        if let cached = manager.location, cached.horizontalAccuracy >= 0 {
            let continuations = pendingLocationContinuations
            pendingLocationContinuations.removeAll()
            stopUpdatesIfNoListeners()
            for continuation in continuations {
                continuation.resume(returning: cached)
            }
            return
        }
        let continuations = pendingLocationContinuations
        pendingLocationContinuations.removeAll()
        stopUpdatesIfNoListeners()
        for continuation in continuations {
            continuation.resume(throwing: LocationServiceError.timeout)
        }
    }

    private func stopUpdatesIfNoListeners() {
        guard pendingLocationContinuations.isEmpty, isUpdatingLocation else { return }
        manager.stopUpdatingLocation()
        // Сразу гасим фоновые апдейты — мы используем их строго on-demand на время одного capture.
        // Setter в `false` безопасен даже без записи UIBackgroundModes=location, но трогаем его
        // только если ранее выставляли в true.
        if isBackgroundLocationModeDeclared && manager.allowsBackgroundLocationUpdates {
            manager.allowsBackgroundLocationUpdates = false
        }
        isUpdatingLocation = false
        captureTimeoutTask?.cancel()
        captureTimeoutTask = nil
        firstAcceptableFixDate = nil
    }

    // MARK: - CLLocationManagerDelegate

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        // Это callback CoreLocation — здесь читать authorizationStatus безопасно (не main).
        cachedAuthorizationStatus = status
        os_log("authorization changed: status=%{public}d", log: Self.log, type: .info, status.rawValue)
        guard status != .notDetermined else { return }
        let continuations = pendingAuthorizationContinuations
        pendingAuthorizationContinuations.removeAll()
        for continuation in continuations {
            continuation.resume(returning: status)
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        // Отбрасываем заведомо мусорные / устаревшие fix'ы.
        let age = -location.timestamp.timeIntervalSinceNow
        if location.horizontalAccuracy < 0 || age > 30 {
            os_log("didUpdateLocations: ignoring stale/invalid fix (age=%.1f, acc=%.1f)",
                   log: Self.log, type: .debug, age, location.horizontalAccuracy)
            return
        }
        os_log("didUpdateLocations: fix received (acc=%.1fm, age=%.1fs)",
               log: Self.log, type: .info, location.horizontalAccuracy, age)

        let isAcceptable = location.horizontalAccuracy <= acceptableHorizontalAccuracyMeters
        if !isAcceptable {
            // Запоминаем, что хоть какой-то fix уже был — пригодится для timeout-фолбека.
            return
        }

        // Первый «приемлемый» fix — даём небольшое окно на улучшение точности и резолвим.
        if firstAcceptableFixDate == nil {
            firstAcceptableFixDate = Date()
            // Если первый же fix очень точный — резолвим сразу.
            if location.horizontalAccuracy <= 65 {
                resolveAllPending(with: location)
                return
            }
            // Иначе ждём короткое окно ещё одного, потенциально более точного, fix'а.
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(self?.goodEnoughGraceSeconds ?? 4.0) * 1_000_000_000)
                guard let self else { return }
                await self.resolveWithBestAvailableFix()
            }
            return
        }

        // Внутри окна — если стало точнее, резолвим сразу.
        resolveAllPending(with: location)
    }

    @MainActor
    private func resolveWithBestAvailableFix() {
        guard !pendingLocationContinuations.isEmpty else { return }
        if let location = manager.location, location.horizontalAccuracy >= 0 {
            resolveAllPending(with: location)
        }
    }

    private func resolveAllPending(with location: CLLocation) {
        guard !pendingLocationContinuations.isEmpty else { return }
        let continuations = pendingLocationContinuations
        pendingLocationContinuations.removeAll()
        stopUpdatesIfNoListeners()
        os_log("resolveAllPending: success (acc=%.1fm)", log: Self.log, type: .info, location.horizontalAccuracy)
        for continuation in continuations {
            continuation.resume(returning: location)
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        os_log("locationManager didFailWithError: %{public}@", log: Self.log, type: .error,
               error.localizedDescription)
        // CLLocationManager может прислать transient-ошибку (kCLErrorLocationUnknown) — НЕ отдаём её
        // вверх сразу, продолжаем ждать таймаут. Иначе в подвале/при слабом GPS получим мгновенный fail.
        if let clError = error as? CLError, clError.code == .locationUnknown {
            return
        }
        let continuations = pendingLocationContinuations
        pendingLocationContinuations.removeAll()
        stopUpdatesIfNoListeners()
        for continuation in continuations {
            continuation.resume(throwing: LocationServiceError.underlying(error))
        }
    }
}
