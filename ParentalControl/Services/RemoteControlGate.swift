import Foundation
import Darwin

/// Serializes local enforcement across the host and notification extension.
/// Never waits for another process: the existing poll/push retry will try again.
nonisolated enum RemoteControlGate {
    static let group = "group.mycompny.parentalcontrol"
    static let snapshotKey = "parentalcontrol.focusSessionSnapshot"
    static var defaults: UserDefaults? { UserDefaults(suiteName: group) }
    static func revisionKey(_ family: UUID) -> String {
        "parentalcontrol.focusRevision." + family.uuidString.lowercased()
    }
    static func pendingKey(_ family: UUID) -> String {
        "parentalcontrol.localManualBlock." + family.uuidString.lowercased()
    }

    final class Lease {
        private var descriptor: Int32 = -1
        init?(directory: URL? = nil) {
            guard let root = directory ?? FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) else { return nil }
            let fd = open(root.appendingPathComponent("remote-control.lock").path,
                          O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
            guard fd >= 0 else { return nil }
            guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
                close(fd)
                return nil
            }
            descriptor = fd
        }
        deinit {
            if descriptor >= 0 { flock(descriptor, LOCK_UN); close(descriptor) }
        }
    }

    private static let localLock = NSRecursiveLock()
    // Only used inside synchronous withLock closures, on the owning thread.
    nonisolated(unsafe) private static var depth = 0
    @discardableResult
    static func withLock(_ action: () -> Void) -> Bool {
        localLock.lock()
        defer { localLock.unlock() }
        if depth > 0 { action(); return true }
        guard let lease = Lease() else { return false }
        return withExtendedLifetime(lease) {
            depth += 1
            defer { depth -= 1 }
            action()
            return true
        }
    }
}
