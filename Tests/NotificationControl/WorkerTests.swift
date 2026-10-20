import Foundation

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func increment() { lock.lock(); value += 1; lock.unlock() }
    func read() -> Int { lock.lock(); defer { lock.unlock() }; return value }
}

@main
struct WorkerTests {
    static func main() async throws {
        if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--lock-probe" {
            let lease = RemoteControlGate.Lease(directory: URL(fileURLWithPath: CommandLine.arguments[2]))
            exit(lease == nil ? 42 : 0)
        }
        var count = 0
        func check(_ condition: Bool, _ message: String) {
            precondition(condition, message)
            count += 1
        }
        let worker = ControlSystemWorker()
        func barrier() async throws {
            for _ in 0..<100 {
                do { _ = try await worker.run { _ in 0 }; return }
                catch ControlSystemWorker.Failure.busy { try await Task.sleep(nanoseconds: 10_000_000) }
            }
            preconditionFailure("Worker did not recover after the fake IPC returned")
        }
        let result = try await worker.run { _ in 42 }
        check(result == 42, "Normal operation returns its result")

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pc-worker-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: root.appendingPathComponent("remote-control.lock"))
            try? FileManager.default.removeItem(at: root)
        }
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let laterWrites = Counter()
        let startedAt = Date()
        let blocked = Task {
            try await worker.run(timeout: 0.3) { context in
                try context.perform(validate: {
                    guard RemoteControlGate.withLock(directory: root, {}) else {
                        throw ControlSystemWorker.Failure.busy
                    }
                }) {
                    RemoteControlGate.assertOutsideDataLock()
                    started.signal()
                    release.wait() // Fake uninterruptible DeviceActivity IPC.
                }
                laterWrites.increment()
                return 1
            }
        }
        // Wait off the cooperative pool for the fake IPC to begin.
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                precondition(started.wait(timeout: .now() + 3) == .success)
                continuation.resume()
            }
        }
        let probe = Process()
        probe.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        probe.arguments = ["--lock-probe", root.path]
        try probe.run()
        probe.waitUntilExit()
        check(probe.terminationStatus == 0, "Another process can use shared data while IPC is blocked")

        let queuedWrites = Counter()
        do {
            _ = try await worker.run(timeout: 0.05) { _ in queuedWrites.increment(); return 2 }
            preconditionFailure("Queued work must expire, not bypass the blocked operation")
        } catch ControlSystemWorker.Failure.expired {
            check(queuedWrites.read() == 0, "No second concurrent system operation")
        }
        do {
            _ = try await worker.run { _ in queuedWrites.increment(); return 3 }
            preconditionFailure("A blocked queue must have bounded capacity")
        } catch ControlSystemWorker.Failure.busy {
            check(queuedWrites.read() == 0, "Repeated pushes cannot accumulate behind blocked IPC")
        }
        do {
            _ = try await blocked.value
            preconditionFailure("Blocked operation cannot report success")
        } catch ControlSystemWorker.Failure.expired {
            check(Date().timeIntervalSince(startedAt) < 3, "Deadline resumes caller without waiting for IPC")
        }
        release.signal()
        try await barrier()
        check(laterWrites.read() == 0, "Late completion cannot unlock or ACK")
        check(queuedWrites.read() == 0, "Expired queued work never runs even after the queue unblocks")

        let context = ControlSystemWorker.Context()
        context.cancel()
        do {
            _ = try await worker.run(context: context) { _ in laterWrites.increment(); return 0 }
            preconditionFailure("Cancelled context cannot execute")
        } catch ControlSystemWorker.Failure.expired {
            check(laterWrites.read() == 0, "Pre-cancelled operation has no side effects")
        }
        do {
            let revision = Counter()
            _ = try await worker.run { context in
                try context.perform(validate: {
                    guard revision.read() == 0 else { throw ControlSystemWorker.Failure.stale }
                }) { revision.increment() }
                laterWrites.increment()
                return 0
            }
            preconditionFailure("Newer revision must invalidate an in-flight result")
        } catch ControlSystemWorker.Failure.stale {
            check(laterWrites.read() == 0, "Revision change after IPC prevents subsequent writes and ACK")
        }
        let cancellationStarted = DispatchSemaphore(value: 0)
        let cancellationRelease = DispatchSemaphore(value: 0)
        let cancelled = Task {
            try await worker.run(timeout: 3) { context in
                try context.perform(validate: {}) {
                    cancellationStarted.signal()
                    cancellationRelease.wait()
                }
                laterWrites.increment()
                return 0
            }
        }
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                precondition(cancellationStarted.wait(timeout: .now() + 3) == .success)
                continuation.resume()
            }
        }
        cancelled.cancel()
        do {
            _ = try await cancelled.value
            preconditionFailure("Cancellation must resume the caller")
        } catch is CancellationError {
            check(true, "Cancellation is independent of the synchronous operation")
        }
        cancellationRelease.signal()
        try await barrier()
        check(laterWrites.read() == 0, "Cancelled operation cannot continue when IPC eventually returns")
        print("ControlSystemWorker: \(count) checks passed")
    }
}
