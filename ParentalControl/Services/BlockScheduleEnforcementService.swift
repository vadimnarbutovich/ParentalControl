import Foundation
import OSLog

/// Host adapter. Host/NSE use the same bounded, non-main system worker.
@MainActor
final class BlockScheduleEnforcementService {
    private let logger = Logger(subsystem: "mycompny.ParentalControl", category: "BlockScheduleEnforcement")
    private let appStore: AppGroupStore
    private var task: Task<ScheduleControlEnforcer.Receipt?, Never>?

    init(appStore: AppGroupStore) { self.appStore = appStore }

    func refreshFromStoredSchedules() {
        guard appStore.loadDeviceRole() == .child, task == nil else { return }
        task = Task { @MainActor [weak self] in
            guard let self else { return nil }
            defer { self.task = nil }
            let context = ControlSystemWorker.Context()
            let background = ControlBackgroundExecution(context: context)
            defer { background.end() }
            guard background.canRun else { return nil }
            do {
                let receipt = try await ScheduleControlEnforcer.apply(context: context)
                return receipt.isCurrent() ? receipt : nil
            } catch {
                self.logger.error("Schedule enforcement unfinished code=\((error as NSError).code)")
                return nil
            }
        }
    }

    func enforceAndConfirm() async -> ScheduleControlEnforcer.Receipt? {
        refreshFromStoredSchedules()
        guard let task, let receipt = await task.value,
              !Task.isCancelled, receipt.isCurrent() else { return nil }
        return receipt
    }
}
