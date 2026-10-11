import Foundation
import Darwin

nonisolated struct DailyBudgetStatus: Codable {
    let policy: DailyBudgetPolicy?
    let childReady: Bool
    let appliedRevision: Int
    let state: DailyBudgetState?
    var isPending: Bool { policy.map { appliedRevision < $0.revision } ?? false }
    var hasCurrentDayState: Bool { policy == nil || state?.day == policy?.extraDay }
}

/// Shared by the app and DeviceActivity extension. No UI / MainActor dependency.
nonisolated struct DailyBudgetPolicy: Codable, Equatable {
    let familyID: String
    let limitSeconds: Int
    let revision: Int
    let extraDay: String
    let extraSeconds: Int
    // Optional for compatibility with budgets saved before the breakdown was added.
    // extraSeconds is the legacy signed net amount. New clients enforce ordered operations
    // against the local balance, storing only the actually applied amount in the state.
    let earnedSeconds: Int?
    let grantedSeconds: Int?
    let dayStartLimitSeconds: Int?
    let operations: [DailyBudgetOperation]?
}

nonisolated struct DailyBudgetOperation: Codable, Equatable {
    let revision: Int
    let kind: String
    let seconds: Int
}

nonisolated struct DailyBudgetState: Codable, Equatable {
    var policy: DailyBudgetPolicy
    var day: String
    var dayStartISO: String = ISO8601DateFormatter().string(from: Calendar.current.startOfDay(for: Date()))
    var usedSeconds: Int
    var extraSeconds: Int
    var lastConsumptionAt: TimeInterval = 0
    var monitorEvent: String?
    var monitorThreshold: Int = 0
    var monitorStartedAt: TimeInterval = 0
    var cappedAdjustmentsVersion: Int?
    var budgetSeconds: Int { max(0, policy.limitSeconds + extraSeconds) }
    var availableSeconds: Int { max(0, budgetSeconds - usedSeconds) }
    var earnedSeconds: Int? { policy.extraDay == day ? policy.earnedSeconds : 0 }
    var grantedSeconds: Int? { policy.extraDay == day ? policy.grantedSeconds : 0 }

    static func dayKey(_ date: Date = Date()) -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    mutating func advance(to today: String) {
        // Moving the clock backwards must not grant another daily allowance.
        guard today > day else { return }
        day = today
        dayStartISO = ISO8601DateFormatter().string(from: Calendar.current.startOfDay(for: Date()))
        usedSeconds = 0
        extraSeconds = 0
        lastConsumptionAt = 0
        monitorEvent = nil
        monitorThreshold = 0
    }

    mutating func apply(_ next: DailyBudgetPolicy) {
        guard next.familyID == policy.familyID, next.revision >= policy.revision else { return }
        if next.extraDay == day, let operations = next.operations {
            // Migrate an old signed balance once, without altering usage or replaying
            // already-applied rewards. Only the debt attributable to withdrawals is removed.
            if cappedAdjustmentsVersion == nil {
                extraSeconds = max(extraSeconds, min(0, usedSeconds - policy.limitSeconds))
            }
            let startingLimit = policy.extraDay == day ? policy.limitSeconds : (next.dayStartLimitSeconds ?? next.limitSeconds)
            applyOperations(operations.filter { $0.revision > policy.revision }, startingLimit: startingLimit)
            cappedAdjustmentsVersion = 1
        } else if next.extraDay == day, cappedAdjustmentsVersion == nil {
            // Compatibility with a server response from before operation delivery.
            extraSeconds = next.extraSeconds
        }
        policy = next
    }

    mutating func initializeOperations() {
        guard policy.extraDay == day, let operations = policy.operations else { return }
        extraSeconds = 0
        applyOperations(operations, startingLimit: policy.dayStartLimitSeconds ?? policy.limitSeconds)
        cappedAdjustmentsVersion = 1
    }

    private mutating func applyOperations(_ operations: [DailyBudgetOperation], startingLimit: Int) {
        var limit = startingLimit
        for operation in operations.sorted(by: { $0.revision < $1.revision }) {
            switch operation.kind {
            case "limit": limit = operation.seconds
            case "adjustment" where operation.seconds < 0:
                let available = max(0, limit + extraSeconds - usedSeconds)
                extraSeconds -= min(-operation.seconds, available)
            case "adjustment", "reward": extraSeconds += operation.seconds
            default: break
            }
        }
    }
}

/// The JSON file is authoritative; legacy UserDefaults balance is a compatibility mirror only.
/// A process-shared lock protects read/modify/write from app/extension races.
nonisolated final class DailyBudgetStore {
    static let shared = DailyBudgetStore()
    static let enabledKey = "parentalcontrol.dailyBudget.enabled"
    private let group = "group.mycompny.parentalcontrol"
    private var defaults: UserDefaults? { UserDefaults(suiteName: group) }
    var isEnabled: Bool {
        if defaults?.bool(forKey: Self.enabledKey) == true { return true }
        guard let root = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) else { return false }
        return FileManager.default.fileExists(atPath: root.appendingPathComponent("DailyBudget/current.json").path)
    }
    private enum StoreError: Error { case unavailable, corrupt }

    private func directory() throws -> URL {
        guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) else {
            throw StoreError.unavailable
        }
        let directory = container.appendingPathComponent("DailyBudget", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func locked<T>(_ operation: (URL) throws -> T) throws -> T {
        let dir = try directory()
        let fd = open(dir.appendingPathComponent("state.lock").path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw StoreError.unavailable }
        defer { close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw StoreError.unavailable }
        defer { flock(fd, LOCK_UN) }
        return try operation(dir)
    }

    private func read(_ dir: URL) throws -> DailyBudgetState? {
        let url = dir.appendingPathComponent("current.json")
        guard FileManager.default.fileExists(atPath: url.path) else {
            if isEnabled { throw StoreError.corrupt }
            return nil
        }
        let state = try JSONDecoder().decode(DailyBudgetState.self, from: Data(contentsOf: url))
        guard UUID(uuidString: state.policy.familyID) != nil,
              (0...86400).contains(state.policy.limitSeconds),
              (-604800...604800).contains(state.extraSeconds),
              (0...691200).contains(state.usedSeconds),
              (0...30).contains(state.monitorThreshold) else { throw StoreError.corrupt }
        return state
    }

    private func write(_ state: DailyBudgetState, in dir: URL) throws {
        let data = try JSONEncoder().encode(state)
        try data.write(to: dir.appendingPathComponent("current.json"), options: .atomic)
        defaults?.set(true, forKey: Self.enabledKey)
        // Older presentation code reads this mirror. It never owns the new budget.
        defaults?.set(state.budgetSeconds, forKey: "parentalcontrol.deviceActivityMirrorEarnedSeconds")
        defaults?.set(state.usedSeconds, forKey: "parentalcontrol.deviceActivityMirrorSpentSeconds")
        defaults?.synchronize()
    }

    private func archive(_ state: DailyBudgetState, in dir: URL) throws {
        let folder = dir.appendingPathComponent(state.policy.familyID, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try JSONEncoder().encode(state).write(to: folder.appendingPathComponent(state.day + ".json"), options: .atomic)
    }

    func current() throws -> DailyBudgetState? {
        try locked { dir in
            guard var state = try read(dir) else { return nil }
            let today = DailyBudgetState.dayKey()
            if today > state.day {
                try archive(state, in: dir)
                state.advance(to: today)
                try write(state, in: dir)
            }
            return state
        }
    }

    @discardableResult
    func apply(_ policy: DailyBudgetPolicy, legacyUsedToday: Int) throws -> DailyBudgetState {
        guard UUID(uuidString: policy.familyID) != nil,
              (0...86400).contains(policy.limitSeconds), policy.revision > 0,
              (-604800...604800).contains(policy.extraSeconds) else { throw StoreError.corrupt }
        return try locked { dir in
            let today = DailyBudgetState.dayKey()
            var state: DailyBudgetState
            if var existing = try read(dir) {
                guard existing.policy.familyID == policy.familyID else { throw StoreError.corrupt }
                if today > existing.day { try archive(existing, in: dir) }
                existing.advance(to: today)
                existing.apply(policy)
                state = existing
            } else {
                // The parent explicitly activated the limit. Old data remains recoverable.
                if let data = defaults?.data(forKey: "parentalcontrol.balance") {
                    try data.write(to: dir.appendingPathComponent(policy.familyID + "-legacy-balance.json"), options: .atomic)
                }
                state = DailyBudgetState(policy: policy, day: today, usedSeconds: max(0, legacyUsedToday),
                    extraSeconds: policy.extraDay == today ? policy.extraSeconds : 0)
                state.initializeOperations()
            }
            try write(state, in: dir)
            return state
        }
    }

    /// Each monitor generation has its own event name: delayed callbacks cannot spend twice.
    func arm(threshold: Int) throws -> String {
        try locked { dir in
            guard var state = try read(dir), state.availableSeconds > 0 else { throw StoreError.unavailable }
            let event = "parentalcontrol.usageBudget." + UUID().uuidString
            state.monitorEvent = event
            state.monitorThreshold = min(max(1, threshold), state.availableSeconds)
            state.monitorStartedAt = Date().timeIntervalSince1970
            try write(state, in: dir)
            return event
        }
    }

    /// Only actual DeviceActivity usage can increment usedSeconds.
    func consume(event: String, now: Date = Date()) throws -> DailyBudgetState? {
        try locked { dir in
            guard var state = try read(dir) else { return nil }
            let today = DailyBudgetState.dayKey(now)
            if today > state.day {
                try archive(state, in: dir)
                state.advance(to: today)
                // A delayed callback from yesterday must not consume today's allowance.
                try write(state, in: dir)
                return state
            }
            guard event == state.monitorEvent else { return state }
            let seconds = state.monitorThreshold
            guard seconds > 0, now.timeIntervalSince1970 - state.monitorStartedAt >= Double(seconds) * 0.7 else { return state }
            state.usedSeconds += min(seconds, state.availableSeconds)
            state.lastConsumptionAt = now.timeIntervalSince1970
            state.monitorEvent = nil
            state.monitorThreshold = 0
            try write(state, in: dir)
            return state
        }
    }

    func history(for date: Date) throws -> DailyBudgetState? {
        try locked { dir in
            guard let state = try read(dir) else { return nil }
            let day = DailyBudgetState.dayKey(date)
            if day == state.day { return state }
            let url = dir.appendingPathComponent(state.policy.familyID).appendingPathComponent(day + ".json")
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            return try JSONDecoder().decode(DailyBudgetState.self, from: Data(contentsOf: url))
        }
    }

    /// Completed days are uploaded in small batches, within the existing runtime request.
    func pendingHistory() throws -> [DailyBudgetState] {
        try locked { dir in
            guard let state = try read(dir) else { return [] }
            let folder = dir.appendingPathComponent(state.policy.familyID, isDirectory: true)
            guard FileManager.default.fileExists(atPath: folder.path) else { return [] }
            let marker = folder.appendingPathComponent("uploaded.json")
            let uploaded = (try? JSONDecoder().decode(Set<String>.self, from: Data(contentsOf: marker))) ?? []
            return try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "json" && $0.lastPathComponent != "uploaded.json" && !uploaded.contains($0.deletingPathExtension().lastPathComponent) }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }.prefix(30)
                .map { try JSONDecoder().decode(DailyBudgetState.self, from: Data(contentsOf: $0)) }
        }
    }

    func markHistoryUploaded(_ history: [DailyBudgetState]) throws {
        guard !history.isEmpty else { return }
        try locked { dir in
            guard let state = try read(dir) else { return }
            let family = state.policy.familyID
            let url = dir.appendingPathComponent(family).appendingPathComponent("uploaded.json")
            var days = (try? JSONDecoder().decode(Set<String>.self, from: Data(contentsOf: url))) ?? []
            days.formUnion(history.filter { $0.policy.familyID == family }.map(\.day))
            try JSONEncoder().encode(days).write(to: url, options: .atomic)
        }
    }

    func unlink() throws {
        try locked { dir in
            if let state = try read(dir) {
                try archive(state, in: dir)
                try FileManager.default.removeItem(at: dir.appendingPathComponent("current.json"))
            }
            defaults?.set(false, forKey: Self.enabledKey)
            defaults?.synchronize()
        }
    }
}
