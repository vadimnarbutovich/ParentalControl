import Foundation

struct ParentStatisticsReport: Decodable {
    let today: String
    let timezone: String
    let days: [ParentStatisticsDay]

    /// Reuse the normal parent poll. Live usage updates do not trigger another report request.
    func merging(_ status: DailyBudgetStatus?) -> ParentStatisticsReport {
        guard let status, let state = status.state, state.day == today,
              status.hasCurrentDayState,
              let index = days.firstIndex(where: { $0.day == today }) else { return self }
        let policy = status.policy?.extraDay == today ? status.policy : nil
        let old = days[index]
        guard state.policy.revision >= (old.budgetRevision ?? 0) else { return self }
        // Gross grants and approved rewards only grow within a day. The report can
        // already include a parent action that an older poll has not received yet.
        let rewards = [policy?.earnedSeconds, state.earnedSeconds, old.rewardSeconds].compactMap { $0 }.max()
        let granted = [policy?.grantedSeconds, state.grantedSeconds, old.grantedSeconds].compactMap { $0 }.max()
        let policyTasks = policy?.operations.map { $0.filter { $0.kind == "reward" }.count }
        let tasks = [policyTasks, old.approvedTasks].compactMap { $0 }.max()
        // Ignore an out-of-order usage sample; an administrative change never reduces usage.
        let used = max(state.usedSeconds, old.usedSeconds ?? 0)
        guard old.legacy || old.budgetRevision != state.policy.revision || old.usedSeconds != used || old.limitSeconds != state.policy.limitSeconds
            || old.rewardSeconds != rewards || old.grantedSeconds != granted || old.approvedTasks != tasks else { return self }
        var updated = days
        updated[index] = ParentStatisticsDay(day: today, usedSeconds: used, limitSeconds: state.policy.limitSeconds,
            rewardSeconds: rewards, grantedSeconds: granted, approvedTasks: tasks,
            updatedAt: ISO8601DateFormatter().string(from: Date()), legacy: false, budgetRevision: state.policy.revision)
        return ParentStatisticsReport(today: today, timezone: timezone, days: updated)
    }
}

struct ParentStatisticsDay: Decodable, Identifiable {
    let day: String
    let usedSeconds: Int?
    let limitSeconds: Int?
    let rewardSeconds: Int?
    let grantedSeconds: Int?
    let approvedTasks: Int?
    let updatedAt: String?
    let legacy: Bool
    let budgetRevision: Int?
    var id: String { day }
    var date: Date { Self.date(day) ?? .distantPast }

    // Keep child's calendar dates independent of the parent's timezone.
    static func date(_ key: String) -> Date? {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: key)
    }
}
