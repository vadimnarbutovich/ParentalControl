import Foundation

/// Shares only simultaneous identical requests. No response cache or debounce:
/// after a write/push, the next read must be a fresh request.
@MainActor
final class SyncRequestCoalescer {
    private struct Entry {
        let id: UUID
        let task: Task<Data, Error>
    }
    private var pending: [String: Entry] = [:]

    func invalidate() {
        // Existing callers still receive their response. Do not cancel delivery.
        pending.removeAll()
    }

    func perform(key: String, operation: @escaping @MainActor () async throws -> Data) async throws -> Data {
        if let entry = pending[key] { return try await entry.task.value }
        let id = UUID()
        let task = Task { @MainActor in try await operation() }
        pending[key] = Entry(id: id, task: task)
        defer { if pending[key]?.id == id { pending.removeValue(forKey: key) } }
        return try await task.value
    }
}

/// APNs registration is serialized so an older bootstrap cannot overwrite a
/// freshly delivered token/environment. Acknowledgements live only in memory:
/// a new process always registers again, and failures remain retryable.
@MainActor
final class APNSRegistrationCoordinator {
    struct Registration: Equatable {
        let token: String
        let environment: String?
    }
    private var observed: Registration?
    private var acknowledged: Registration?
    private var acknowledgedAt: TimeInterval?
    private var tail: Task<Void, Error>?
    private var generation = 0

    func invalidate() {
        generation += 1
        acknowledged = nil
        acknowledgedAt = nil
    }

    func register(token: String, environment: String?, isFresh: Bool = false,
                  uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
                  send: @escaping @MainActor (Registration) async throws -> Void) async throws {
        if isFresh || environment != nil { observed = Registration(token: token, environment: environment) }
        let fallback = Registration(token: token, environment: environment)
        let previous = tail
        let task = Task { @MainActor [self] in
            _ = try? await previous?.value
            let value = observed ?? fallback
            if acknowledged == value, let at = acknowledgedAt,
               uptime() >= at, uptime() - at < 86_400 { return }
            let version = generation
            try await send(value)
            if generation == version {
                acknowledged = value
                acknowledgedAt = uptime()
            }
        }
        tail = task
        try await task.value
    }
}
