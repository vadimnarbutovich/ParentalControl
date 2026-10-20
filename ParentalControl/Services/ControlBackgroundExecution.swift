import UIKit

/// End the UIKit assertion on expiry as well as on normal completion.
/// Cancelling a Swift task alone does not end background execution.
@MainActor
final class ControlBackgroundExecution {
    private var identifier: UIBackgroundTaskIdentifier = .invalid
    private let context: ControlSystemWorker.Context

    init(context: ControlSystemWorker.Context) {
        self.context = context
        identifier = UIApplication.shared.beginBackgroundTask(withName: "Apply child controls") { [weak self] in
            Task { @MainActor in
                self?.context.cancel()
                self?.end()
            }
        }
    }
    var canRun: Bool {
        identifier != .invalid || UIApplication.shared.applicationState == .active
    }
    func end() {
        guard identifier != .invalid else { return }
        let old = identifier
        identifier = .invalid
        UIApplication.shared.endBackgroundTask(old)
    }
}
