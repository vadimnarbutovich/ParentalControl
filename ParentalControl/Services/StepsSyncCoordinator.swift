import Foundation

@MainActor
final class StepsSyncCoordinator {
    private var pollingTask: Task<Void, Never>?

    func start(pollEvery seconds: UInt64 = 30, action: @escaping @MainActor () async -> Void) {
        stop()
        pollingTask = Task {
            while !Task.isCancelled {
                await action()
                try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
            }
        }
    }

    func stop() {
        pollingTask?.cancel()
        pollingTask = nil
    }
}
