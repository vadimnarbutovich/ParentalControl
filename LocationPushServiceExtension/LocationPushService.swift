import CoreLocation
import Foundation
import OSLog

/// Deliberately independent of SwiftUI/AppState, Screen Time, analytics and subscriptions.
@MainActor
final class LocationPushService: NSObject, CLLocationPushServiceExtension {
    private final class Completion: @unchecked Sendable {
        let call: () -> Void
        init(_ call: @escaping () -> Void) { self.call = call }
    }
    // iOS constructs the principal object on its extension queue, despite the
    // Swift @MainActor annotation. Create CLLocationManager only when accessed
    // from the MainActor work task, so its delegate has a running main run loop.
    private lazy var location = LocationService(mode: .locationPush)
    private var serviceSession: CLServiceSession?
    private var work: Task<Void, Never>?
    private var deadline: Task<Void, Never>?
    private var requestID: String?
    private var generation: UUID?
    private var completions: [Completion] = []
    private let logger = Logger(subsystem: "mycompny.ParentalControl", category: "LocationPush")

    nonisolated func didReceiveLocationPushPayload(_ payload: [String: Any], completion: @escaping () -> Void) {
        let id = payload["request_id"] as? String
        let done = Completion(completion)
        Task { @MainActor in self.begin(id: id, completion: done) }
    }

    nonisolated func serviceExtensionWillTerminate() {
        Task { @MainActor in self.finish() }
    }

    private func begin(id: String?, completion: Completion) {
        guard let id, UUID(uuidString: id) != nil else { completion.call(); return }
        if requestID == id { completions.append(completion); return }
        guard requestID == nil else { completion.call(); return }
        guard let defaults = UserDefaults(suiteName: "group.mycompny.parentalcontrol"),
              defaults.string(forKey: "parentalcontrol.deviceRole") == "child",
              defaults.data(forKey: "parentalcontrol.pairingState") != nil,
              let installID = defaults.string(forKey: "parentalcontrol.deviceInstallID"),
              let secret = defaults.string(forKey: "parentalcontrol.deviceSecret"), !secret.isEmpty else {
            completion.call(); return
        }
        requestID = id
        let generation = UUID()
        self.generation = generation
        completions = [completion]
        logger.info("Location push received")
        deadline = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(26)) } catch { return }
            self?.logger.notice("Location push deadline reached")
            self?.finish(generation: generation)
        }
        work = Task { [weak self] in
            guard let self else { return }
            defer { self.finish(generation: generation) }
            let client = LocationPushClient(installID: installID, secret: secret)
            do {
                // Reject expired, duplicated or unlinked requests before accessing GPS.
                let response = try await client.call("begin_location_push", payload: ["commandID": id], timeout: 4)
                guard response["capture"] as? Bool == true else { return }
                if self.location.authorizationStatus == .authorizedAlways {
                    self.serviceSession = CLServiceSession(authorization: .always)
                }
                let fix = try await self.location.captureCurrentLocation(timeout: 12)
                try Task.checkCancellation()
                self.logger.info("Location captured; uploading")
                let payload: [String: Any] = ["commandID": id, "result": [
                    "latitude": fix.coordinate.latitude, "longitude": fix.coordinate.longitude,
                    "horizontalAccuracy": fix.horizontalAccuracy,
                    "capturedAtISO": ISO8601DateFormatter().string(from: fix.timestamp)
                ]]
                // Retry only the SAME result, never another push or another GPS capture.
                // Server atomically stores the coordinates and ACKs; repeat upload is idempotent.
                do { _ = try await client.call("finish_location_push", payload: payload, timeout: 4) }
                catch {
                    try Task.checkCancellation()
                    let nsError = error as NSError
                    let transient = (error as? URLError).map { $0.code != .cancelled } == true
                        || (nsError.domain == "LocationPushHTTP" && nsError.code >= 500)
                    if transient {
                        _ = try await client.call("finish_location_push", payload: payload, timeout: 4)
                    } else { throw error }
                }
                self.logger.info("Location result accepted")
            } catch let error as LocationServiceError {
                if !Task.isCancelled {
                    _ = try? await client.call("finish_location_push", payload: [
                        "commandID": id, "result": ["errorCode": error.commandErrorCode]
                    ], timeout: 3)
                }
                self.logger.notice("Location capture failed: \(error.commandErrorCode, privacy: .public)")
            } catch {
                // No coordinates, credentials or full server payloads in logs.
                self.logger.error("Location request unfinished; error code=\((error as NSError).code)")
            }
        }
    }

    private func finish(generation: UUID? = nil) {
        if let generation, self.generation != generation { return }
        guard requestID != nil else { return }
        requestID = nil
        self.generation = nil
        work?.cancel()
        work = nil
        deadline?.cancel()
        deadline = nil
        serviceSession?.invalidate()
        serviceSession = nil
        let callbacks = completions
        completions.removeAll()
        callbacks.forEach { $0.call() }
    }
}

private struct LocationPushClient {
    let installID: String
    let secret: String
    private let key = "sb_publishable_urT7eQPRIxyXso8VKA2tHQ_-U0I0CsO"

    func call(_ action: String, payload: [String: Any], timeout: TimeInterval) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: "https://tttwrzgjddalgiwmgmyz.supabase.co/functions/v1/parental-control-sync")!)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(key, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue(installID, forHTTPHeaderField: "x-device-install-id")
        request.setValue(secret, forHTTPHeaderField: "x-device-secret")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["action": action, "payload": payload])
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.timeoutIntervalForResource = timeout
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw NSError(domain: "LocationPushHTTP", code: (response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        return (try JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }
}
