import Foundation
import Darwin

/// Serializes short shared-data transactions across the host and notification extension.
/// Never keep a lease across DeviceActivity / ManagedSettings IPC.
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
    private static let threadKey = "parentalcontrol.dataLockHeld"
    static var isHoldingDataLock: Bool { Thread.current.threadDictionary[threadKey] != nil }
    static func assertOutsideDataLock() {
        precondition(!isHoldingDataLock,
                     "System IPC must never run while holding the shared data lock")
    }
    // Only used inside synchronous withLock closures, on the owning thread.
    nonisolated(unsafe) private static var depth = 0
    @discardableResult
    static func withLock(directory: URL? = nil, _ action: () -> Void) -> Bool {
        localLock.lock()
        defer { localLock.unlock() }
        if depth > 0 { action(); return true }
        guard let lease = Lease(directory: directory) else { return false }
        return withExtendedLifetime(lease) {
            depth += 1
            Thread.current.threadDictionary[threadKey] = true
            defer {
                depth -= 1
                Thread.current.threadDictionary.removeObject(forKey: threadKey)
            }
            action()
            return true
        }
    }
}
