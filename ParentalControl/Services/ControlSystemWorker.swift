import Foundation

/// Bounded caller lifetime around an UNINTERRUPTIBLE synchronous system call.
/// Expiry resumes the caller, but never starts another thread to bypass a stuck
/// operation. A late operation must check its context before further side effects.
nonisolated final class ControlSystemWorker: @unchecked Sendable {
    static let shared = ControlSystemWorker()
    private let queue = DispatchQueue(label: "parentalcontrol.system-enforcement", qos: .userInitiated)
    private let admissionLock = NSLock()
    private var admitted = 0

    private func reserve() -> Bool {
        admissionLock.lock()
        defer { admissionLock.unlock() }
        // At most one running and one queued request. Repeated pushes must not
        // accumulate closures indefinitely behind an unresponsive system service.
        guard admitted < 2 else { return false }
        admitted += 1
        return true
    }
    private func release() {
        admissionLock.lock()
        admitted -= 1
        admissionLock.unlock()
    }

    enum Failure: Error { case expired, stale, busy }

    final class Context: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        func cancel() { lock.lock(); cancelled = true; lock.unlock() }
        func check() throws {
            lock.lock()
            defer { lock.unlock() }
            if cancelled { throw Failure.expired }
        }
        func perform(validate: () throws -> Void, _ action: () throws -> Void) throws {
            try check()
            try validate()
            try action()
            try check()
            try validate()
        }
    }

    private final class Completion<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Value, Error>?
        private var result: Result<Value, Error>?
        func attach(_ continuation: CheckedContinuation<Value, Error>) {
            lock.lock()
            if let result {
                lock.unlock()
                continuation.resume(with: result)
            } else {
                self.continuation = continuation
                lock.unlock()
            }
        }
        func finish(_ result: Result<Value, Error>) {
            lock.lock()
            guard self.result == nil else { lock.unlock(); return }
            self.result = result
            let continuation = self.continuation
            self.continuation = nil
            lock.unlock()
            continuation?.resume(with: result)
        }
    }

    func run<Value: Sendable>(timeout: TimeInterval = 12, context: Context = Context(),
                             _ operation: @escaping @Sendable (Context) throws -> Value) async throws -> Value {
        guard reserve() else { throw Failure.busy }
        let completion = Completion<Value>()
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .userInitiated))
        timer.setEventHandler {
            context.cancel()
            completion.finish(.failure(Failure.expired))
        }
        timer.schedule(deadline: .now() + timeout)
        timer.resume()
        defer { timer.cancel() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                completion.attach(continuation)
                queue.async {
                    defer { self.release() }
                    do {
                        try context.check()
                        let value = try operation(context)
                        try context.check()
                        completion.finish(.success(value))
                    } catch {
                        completion.finish(.failure(error))
                    }
                }
            }
        } onCancel: {
            context.cancel()
            completion.finish(.failure(CancellationError()))
        }
    }
}
