import Foundation

/// Delivery and cancellation must not wait for MainActor / synchronous Screen Time IPC.
/// All mutable state is protected by lock; no callbacks execute while holding it.
nonisolated final class NotificationDeliveryLifetime: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false
    private var completion: (@Sendable (String) -> Void)?
    private var cancellations: [@Sendable () -> Void] = []
    private var timer: DispatchSourceTimer?

    init(timeout: TimeInterval = 24, completion: @escaping @Sendable (String) -> Void) {
        self.completion = completion
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .userInitiated))
        self.timer = timer
        timer.setEventHandler { [weak self] in self?.finish(reason: "deadline") }
        timer.schedule(deadline: .now() + timeout)
        timer.resume()
    }

    var isFinished: Bool {
        lock.lock()
        defer { lock.unlock() }
        return completed
    }

    func checkCancellation() throws {
        if isFinished { throw CancellationError() }
    }

    func onCancel(_ action: @escaping @Sendable () -> Void) {
        lock.lock()
        if completed {
            lock.unlock()
            action()
        } else {
            cancellations.append(action)
            lock.unlock()
        }
    }

    func finish(reason: String) {
        lock.lock()
        guard !completed else { lock.unlock(); return }
        completed = true
        let callback = completion
        completion = nil
        let actions = cancellations
        cancellations.removeAll()
        let timer = self.timer
        self.timer = nil
        lock.unlock()
        timer?.cancel()
        // Return original notification before any potentially slow cancellation/logging.
        callback?(reason)
        actions.forEach { $0() }
    }

    deinit { timer?.cancel() }
}
