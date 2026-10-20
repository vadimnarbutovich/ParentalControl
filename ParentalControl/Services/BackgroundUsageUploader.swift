import Foundation
import OSLog

/// Observes the shared budget; never consumes, grants or changes screen time.
/// The monitor owns this background session. The app reconnects ONLY when iOS
/// delivers its events, not on an ordinary foreground launch.
nonisolated final class BackgroundUsageUploader: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    static let shared = BackgroundUsageUploader()
    static let sessionIdentifier = "mycompny.ParentalControl.monitorUsageUpload"
    private static let group = "group.mycompny.parentalcontrol"
    private static let endpoint = URL(string: "https://tttwrzgjddalgiwmgmyz.supabase.co/functions/v1/parental-control-sync")!
    // Public project key, identical to the main app. Device secret authenticates requests.
    private static let publicKey = "sb_publishable_urT7eQPRIxyXso8VKA2tHQ_-U0I0CsO"
    private static let logger = Logger(subsystem: "mycompny.ParentalControl", category: "BackgroundUsage")
    private let queue = DispatchQueue(label: "parentalcontrol.usageUpload")
    // All mutable properties and delegate callbacks are confined to queue.
    private var session: URLSession?
    private var checkingTasks = false
    private var uploadInFlight = false
    private var finishingSession = false
    private var backgroundCompletion: Completion?

    nonisolated private final class Completion: @unchecked Sendable {
        let callback: () -> Void
        init(_ callback: @escaping () -> Void) { self.callback = callback }
    }
    nonisolated private struct Pairing: Decodable {
        let familyID: UUID
        let parentDeviceID: UUID?
        let childDeviceID: UUID?
    }
    nonisolated private struct Payload: Codable {
        let budgetState: DailyBudgetState
        let budgetHistory: [DailyBudgetState]
        let budgetTimezone: String
    }
    nonisolated private struct Envelope: Codable {
        let action: String
        let capturedAt: Date
        let payload: Payload
    }
    nonisolated private struct Receipt: Codable {
        let familyID: String
        let day: String
        let revision: Int
        let usedSeconds: Int
        let extraSeconds: Int
        let sentAt: Date
    }

    /// Called after local enforcement. Returns immediately; no wait for the network.
    func scheduleFromMonitor() {
        queue.async { self.enqueueIfNeeded() }
    }

    func handleBackgroundEvents(completionHandler: @escaping () -> Void) {
        let completion = Completion(completionHandler)
        queue.async {
            self.backgroundCompletion = completion
            _ = self.uploadSession()
        }
    }

    private func uploadSession() -> URLSession {
        if let session { return session }
        let config = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        config.sharedContainerIdentifier = Self.group
        config.sessionSendsLaunchEvents = true
        config.isDiscretionary = false
        config.waitsForConnectivity = true
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 24 * 60 * 60
        let delegateQueue = OperationQueue()
        delegateQueue.maxConcurrentOperationCount = 1
        delegateQueue.underlyingQueue = queue
        let created = URLSession(configuration: config, delegate: self, delegateQueue: delegateQueue)
        session = created
        return created
    }

    private func directory() throws -> URL {
        guard let root = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: Self.group) else {
            throw CocoaError(.fileNoSuchFile)
        }
        var folder = root.appendingPathComponent("BackgroundUsageUploads", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try folder.setResourceValues(values)
        return folder
    }

    private func enqueueIfNeeded() {
        // The host only drains delegate events. Its existing foreground sync is separate.
        guard backgroundCompletion == nil, !checkingTasks, !finishingSession, !uploadInFlight else { return }
        checkingTasks = true
        uploadSession().getAllTasks { tasks in
            self.queue.async {
                defer { self.checkingTasks = false }
                // Bound the offline queue to one transfer; later callbacks read the latest
                // authoritative state instead of accumulating one request per threshold.
                guard tasks.isEmpty, self.backgroundCompletion == nil, !self.uploadInFlight else { return }
                do { try self.createUpload() }
                catch { Self.logger.error("Cannot prepare usage upload; code=\((error as NSError).code)") }
            }
        }
    }

    private func createUpload() throws {
        guard !uploadInFlight, !finishingSession else { return }
        guard let defaults = UserDefaults(suiteName: Self.group),
              defaults.string(forKey: "parentalcontrol.deviceRole") == "child",
              let installID = defaults.string(forKey: "parentalcontrol.deviceInstallID"),
              let secret = defaults.string(forKey: "parentalcontrol.deviceSecret"), !secret.isEmpty,
              let pairingData = defaults.data(forKey: "parentalcontrol.pairingState"),
              let pairing = try? JSONDecoder().decode(Pairing.self, from: pairingData),
              pairing.parentDeviceID != nil, pairing.childDeviceID != nil,
              let state = try DailyBudgetStore.shared.current(),
              UUID(uuidString: state.policy.familyID) == pairing.familyID else { return }

        defaults.synchronize()
        guard DailyBudgetStore.mayReport(revision: state.policy.revision,
            pending: defaults.integer(forKey: DailyBudgetStore.pendingEnforcementKey(state.policy.familyID)),
            confirmed: defaults.integer(forKey: DailyBudgetStore.confirmedEnforcementKey(state.policy.familyID)))
        else { return }

        let folder = try directory()
        let now = Date()
        let receiptURL = folder.appendingPathComponent("receipt.json")
        if let data = try? Data(contentsOf: receiptURL),
           let receipt = try? JSONDecoder().decode(Receipt.self, from: data),
           receipt.familyID == state.policy.familyID, receipt.day == state.day {
            let changed = receipt.usedSeconds != state.usedSeconds || receipt.revision != state.policy.revision
                || receipt.extraSeconds != state.extraSeconds
            guard changed else { return }
            // At most one regular report per minute, with a final report at exhaustion.
            if state.availableSeconds > 0, now.timeIntervalSince(receipt.sentAt) < 60 { return }
        }
        // Back off errors without retry loops. A later monitor callback / foreground sync
        // catches up; a pending background transfer itself waits for connectivity.
        let retryURL = folder.appendingPathComponent("retry-after.json")
        if let data = try? Data(contentsOf: retryURL), let date = try? JSONDecoder().decode(Date.self, from: data),
           now < date { return }

        // Only our own abandoned transfer files; never budget/history or credentials.
        for file in try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            where file.lastPathComponent.hasPrefix("transfer-") && file.pathExtension == "json" {
            try? FileManager.default.removeItem(at: file)
        }
        let history = (try? DailyBudgetStore.shared.pendingHistory()) ?? []
        let envelope = Envelope(action: "report_child_usage", capturedAt: now, payload: Payload(
            budgetState: state, budgetHistory: history, budgetTimezone: TimeZone.current.identifier))
        let file = folder.appendingPathComponent("transfer-\(UUID().uuidString).json")
        try JSONEncoder().encode(envelope).write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Self.publicKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(Self.publicKey)", forHTTPHeaderField: "Authorization")
        request.setValue(installID, forHTTPHeaderField: "x-device-install-id")
        request.setValue(secret, forHTTPHeaderField: "x-device-secret")
        let task = uploadSession().uploadTask(with: request, fromFile: file)
        task.taskDescription = file.lastPathComponent
        uploadInFlight = true
        task.resume()
        Self.logger.debug("Usage upload handed to background URLSession")
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        uploadInFlight = false
        guard let folder = try? directory(), let name = task.taskDescription,
              name.hasPrefix("transfer-"), name.hasSuffix(".json"), !name.contains("/") else { return }
        let file = folder.appendingPathComponent(name)
        defer { try? FileManager.default.removeItem(at: file) }
        if error == nil, (task.response as? HTTPURLResponse)?.statusCode == 200,
           let data = try? Data(contentsOf: file), let envelope = try? JSONDecoder().decode(Envelope.self, from: data) {
            let state = envelope.payload.budgetState
            let receipt = Receipt(familyID: state.policy.familyID, day: state.day, revision: state.policy.revision,
                usedSeconds: state.usedSeconds, extraSeconds: state.extraSeconds, sentAt: envelope.capturedAt)
            if let encoded = try? JSONEncoder().encode(receipt) {
                try? encoded.write(to: folder.appendingPathComponent("receipt.json"), options: .atomic)
            }
            try? DailyBudgetStore.shared.markHistoryUploaded(envelope.payload.budgetHistory)
            Self.logger.debug("Usage upload accepted")
            // While the queued request was offline the budget may have reached zero or
            // advanced to another day. Hand off that latest snapshot before going idle.
            // This is still handling this session's events, not a foreground connection.
            try? createUpload()
        } else {
            let status = (task.response as? HTTPURLResponse)?.statusCode ?? 0
            let code = (error as NSError?)?.code ?? 0
            Self.logger.error("Usage upload deferred; HTTP=\(status), error=\(code)")
            if let encoded = try? JSONEncoder().encode(Date(timeIntervalSinceNow: 60)) {
                try? encoded.write(to: folder.appendingPathComponent("retry-after.json"), options: .atomic)
            }
        }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        guard let completion = backgroundCompletion else { return }
        backgroundCompletion = nil
        if !finishingSession {
            finishingSession = true
            session.finishTasksAndInvalidate()
        }
        DispatchQueue.main.async { completion.callback() }
    }

    func urlSession(_ session: URLSession, didBecomeInvalidWithError error: Error?) {
        self.session = nil
        finishingSession = false
        uploadInFlight = false
        if let completion = backgroundCompletion {
            backgroundCompletion = nil
            DispatchQueue.main.async { completion.callback() }
        }
    }
}
