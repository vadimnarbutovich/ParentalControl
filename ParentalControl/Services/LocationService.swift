import Foundation
import CoreLocation

@MainActor
protocol LocationProviding {
    var authorizationStatus: CLAuthorizationStatus { get }
    func requestWhenInUseAuthorization() async -> CLAuthorizationStatus
    /// iOS may defer/suppress the upgrade prompt. This does not wait for a choice.
    func requestAlwaysAuthorization() async -> CLAuthorizationStatus
    func captureCurrentLocation(timeout: TimeInterval) async throws -> CLLocation
}

enum LocationServiceError: Error {
    case alwaysAuthorizationRequired
    case servicesDisabled
    case timeout
    case underlying(Error)

    /// Stable, non-sensitive codes for the parent. Never transmit coordinates in errors.
    var commandErrorCode: String {
        switch self {
        case .alwaysAuthorizationRequired: return "location_always_required"
        case .servicesDisabled: return "location_services_disabled"
        case .timeout: return "location_timeout"
        case .underlying: return "location_unavailable"
        }
    }
}

@MainActor
final class LocationService: NSObject, LocationProviding, CLLocationManagerDelegate {
    private let manager: CLLocationManager
    private var pendingLocations: [UUID: CheckedContinuation<CLLocation, Error>] = [:]
    private var pendingAuthorizations: [CheckedContinuation<CLAuthorizationStatus, Never>] = []
    private var captureTimeoutTask: Task<Void, Never>?
    private var graceTask: Task<Void, Never>?
    private var captureID: UUID?
    private var captureStartedAt: Date?
    private var bestFix: CLLocation?
    private let acceptableAccuracy: CLLocationAccuracy = 200
    private let backgroundLocationDeclared: Bool = {
        let modes = Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String]
        return modes?.contains("location") == true
    }()

    override init() {
        manager = CLLocationManager()
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        manager.activityType = .other
        manager.pausesLocationUpdatesAutomatically = false
    }

    deinit {
        captureTimeoutTask?.cancel()
        graceTask?.cancel()
        for continuation in pendingLocations.values {
            continuation.resume(throwing: CancellationError())
        }
        for continuation in pendingAuthorizations {
            continuation.resume(returning: .notDetermined)
        }
    }

    // Read the actual status on explicit requests, not a .notDetermined placeholder
    // waiting for the first delegate callback after a cold launch.
    var authorizationStatus: CLAuthorizationStatus { manager.authorizationStatus }

    func requestWhenInUseAuthorization() async -> CLAuthorizationStatus {
        let current = authorizationStatus
        guard current == .notDetermined else { return current }
        return await withCheckedContinuation { continuation in
            pendingAuthorizations.append(continuation)
            if pendingAuthorizations.count == 1 { manager.requestWhenInUseAuthorization() }
        }
    }

    func requestAlwaysAuthorization() async -> CLAuthorizationStatus {
        guard authorizationStatus == .authorizedWhenInUse else { return authorizationStatus }
        manager.requestAlwaysAuthorization()
        return authorizationStatus
    }

    func captureCurrentLocation(timeout: TimeInterval) async throws -> CLLocation {
        try Task.checkCancellation()
        guard CLLocationManager.locationServicesEnabled() else {
            throw LocationServiceError.servicesDisabled
        }
        // This service answers remote requests, including when the app is not in use.
        // Do not report successful setup for a permission that only works in foreground.
        guard authorizationStatus == .authorizedAlways else {
            throw LocationServiceError.alwaysAuthorizationRequired
        }

        let waiterID = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                pendingLocations[waiterID] = continuation
                // Join the current capture. A second caller must not reset its deadline.
                guard captureID == nil else { return }
                let generation = UUID()
                captureID = generation
                captureStartedAt = Date()
                bestFix = nil
                captureTimeoutTask = Task { [weak self] in
                    do {
                        try await Task.sleep(nanoseconds: UInt64(max(1, timeout) * 1_000_000_000))
                    } catch { return }
                    guard !Task.isCancelled, let self, self.captureID == generation else { return }
                    if let fix = self.bestFix, self.isFresh(fix) {
                        self.finish(.success(fix))
                    } else {
                        self.finish(.failure(LocationServiceError.timeout))
                    }
                }
                if backgroundLocationDeclared {
                    manager.allowsBackgroundLocationUpdates = true
                    manager.showsBackgroundLocationIndicator = false
                }
                manager.startUpdatingLocation()
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self, let continuation = self.pendingLocations.removeValue(forKey: waiterID) else { return }
                continuation.resume(throwing: CancellationError())
                if self.pendingLocations.isEmpty { self.stopCapture() }
            }
        }
    }

    private func isFresh(_ location: CLLocation) -> Bool {
        guard let startedAt = captureStartedAt else { return false }
        let age = Date().timeIntervalSince(location.timestamp)
        return CLLocationCoordinate2DIsValid(location.coordinate)
            && location.horizontalAccuracy.isFinite && location.horizontalAccuracy >= 0 && age >= -5 && age <= 30
            && location.timestamp >= startedAt.addingTimeInterval(-5)
    }

    private func stopCapture() {
        captureID = nil
        captureTimeoutTask?.cancel()
        captureTimeoutTask = nil
        graceTask?.cancel()
        graceTask = nil
        manager.stopUpdatingLocation()
        if backgroundLocationDeclared { manager.allowsBackgroundLocationUpdates = false }
        captureStartedAt = nil
        bestFix = nil
    }

    private func finish(_ result: Result<CLLocation, Error>) {
        let continuations = Array(pendingLocations.values)
        pendingLocations.removeAll()
        stopCapture()
        for continuation in continuations { continuation.resume(with: result) }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        if status != .notDetermined {
            let continuations = pendingAuthorizations
            pendingAuthorizations.removeAll()
            for continuation in continuations { continuation.resume(returning: status) }
        }
        if captureID != nil && status != .authorizedAlways {
            finish(.failure(LocationServiceError.alwaysAuthorizationRequired))
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let generation = captureID else { return }
        for fix in locations where isFresh(fix) {
            if let current = bestFix, isFresh(current), current.horizontalAccuracy <= fix.horizontalAccuracy {
                continue
            }
            bestFix = fix
        }
        guard let fix = bestFix, isFresh(fix) else { return }
        if fix.horizontalAccuracy <= 65 {
            finish(.success(fix))
        } else if fix.horizontalAccuracy <= acceptableAccuracy && graceTask == nil {
            graceTask = Task { [weak self] in
                do { try await Task.sleep(nanoseconds: 4_000_000_000) } catch { return }
                guard !Task.isCancelled, let self, self.captureID == generation else { return }
                self.graceTask = nil
                if let fix = self.bestFix, self.isFresh(fix) { self.finish(.success(fix)) }
            }
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        guard captureID != nil else { return }
        if let error = error as? CLError {
            if error.code == .locationUnknown { return }
            if error.code == .denied {
                finish(.failure(LocationServiceError.alwaysAuthorizationRequired))
                return
            }
        }
        finish(.failure(LocationServiceError.underlying(error)))
    }
}
