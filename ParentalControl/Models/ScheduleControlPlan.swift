import Foundation

/// Foundation-only contract shared by the host, notification and monitor extensions.
nonisolated struct ScheduleControlPlan {
    enum Failure: Error { case invalidSchedule, capacity }
    static let cacheKey = "parentalcontrol.blockSchedules"
    static let commandTypes = ["schedules_updated", "schedule_started", "schedule_ended"]

    struct Time: Codable, Equatable, Sendable {
        let hour: Int
        let minute: Int
        var minutes: Int { hour * 60 + minute }
        var isValid: Bool { (0..<24).contains(hour) && (0..<60).contains(minute) }
    }
    struct Entry: Codable, Equatable, Sendable {
        let id: UUID
        let startTime: Time
        let endTime: Time
        let weekdays: [Int]
        let isEnabled: Bool
        var duration: Int { (endTime.minutes - startTime.minutes + 1440) % 1440 }
        var activityName: String { "pcsched_\(id.uuidString)_s" }
        // iOS requires >=15 minutes. For a shorter window the end warning
        // reconciles the shield at the REAL end; intervalDidEnd is a fallback.
        var monitoredEnd: Time {
            let minutes = (startTime.minutes + max(15, duration)) % 1440
            return Time(hour: minutes / 60, minute: minutes % 60)
        }
        var warningMinutes: Int? { duration < 15 ? 15 - duration : nil }

        func isActive(at date: Date, calendar: Calendar = .current) -> Bool {
            guard isEnabled, duration > 0 else { return false }
            let parts = calendar.dateComponents([.hour, .minute, .weekday], from: date)
            let minute = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
            let weekday = ((parts.weekday ?? 1) + 5) % 7 + 1
            if startTime.minutes < endTime.minutes {
                return weekdays.contains(weekday) && minute >= startTime.minutes && minute < endTime.minutes
            }
            if minute >= startTime.minutes { return weekdays.contains(weekday) }
            if minute < endTime.minutes { return weekdays.contains(weekday == 1 ? 7 : weekday - 1) }
            return false
        }
    }

    let entries: [Entry]
    init(data: Data) throws {
        entries = try JSONDecoder().decode([Entry].self, from: data)
        guard Set(entries.map(\.id)).count == entries.count,
              entries.allSatisfy({ $0.startTime.isValid && $0.endTime.isValid &&
                  !$0.weekdays.isEmpty && $0.weekdays.allSatisfy { (1...7).contains($0) } }) else { throw Failure.invalidSchedule }
        guard enabledEntries.count <= 18 else { throw Failure.capacity }
    }

    // Match the existing registrar: equal times mean no active interval,
    // not a 24-hour block. Such an old entry must not disable all other schedules.
    var enabledEntries: [Entry] { entries.filter { $0.isEnabled && $0.duration > 0 } }

    func activeIDs(at date: Date = Date()) -> Set<UUID> {
        Set(entries.filter { $0.isActive(at: date) }.map(\.id))
    }

    /// Accept only our own schedule names, including the previous split format.
    static func scheduleID(activityName: String) -> UUID? {
        guard activityName.hasPrefix("pcsched_"),
              ["_s", "_e", "_m"].contains(String(activityName.suffix(2))) else { return nil }
        return UUID(uuidString: String(activityName.dropFirst(8).dropLast(2)))
    }

    static func canonicalCache(_ data: Data) throws -> Data {
        _ = try Self(data: data)
        guard var rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw Failure.invalidSchedule
        }
        for index in rows.indices {
            guard let id = rows[index]["id"] as? String, let uuid = UUID(uuidString: id),
                  let days = rows[index]["weekdays"] as? [Int] else { throw Failure.invalidSchedule }
            rows[index]["id"] = uuid.uuidString
            rows[index]["weekdays"] = Array(Set(days)).sorted()
        }
        rows.sort { ($0["id"] as? String ?? "") < ($1["id"] as? String ?? "") }
        return try JSONSerialization.data(withJSONObject: rows, options: [.sortedKeys])
    }

    /// Preserve the existing host cache format, not a notification-specific schema.
    static func cacheFromResponse(_ data: Data) throws -> Data {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = object["schedules"] as? [[String: Any]] else { throw Failure.invalidSchedule }
        let plain = ISO8601DateFormatter()
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        func date(_ value: Any?) throws -> String {
            guard let value, !(value is NSNull) else { return plain.string(from: Date(timeIntervalSince1970: 0)) }
            guard let text = value as? String, let date = fractional.date(from: text) ?? plain.date(from: text)
            else { throw Failure.invalidSchedule }
            return plain.string(from: date)
        }
        let cache = try rows.map { row -> [String: Any] in
            guard let id = row["id"] as? String, UUID(uuidString: id) != nil,
                  let name = row["name"] as? String, let enabled = row["isEnabled"] as? Bool,
                  let sh = row["startHour"] as? Int, let sm = row["startMinute"] as? Int,
                  let eh = row["endHour"] as? Int, let em = row["endMinute"] as? Int,
                  let weekdays = row["weekdays"] as? [Int] else { throw Failure.invalidSchedule }
            let icons = ["moon.stars.fill", "graduationcap.fill", "book.closed.fill", "fork.knife", "calendar"]
            let accents = ["purple", "blue", "green", "orange"]
            let icon = row["icon"] as? String ?? ""
            let accent = row["accent"] as? String ?? ""
            return ["id": id, "name": name, "isEnabled": enabled,
                "icon": icons.contains(icon) ? icon : "calendar", "accent": accents.contains(accent) ? accent : "purple",
                "startTime": ["hour": sh, "minute": sm], "endTime": ["hour": eh, "minute": em],
                "weekdays": weekdays, "createdAt": try date(row["createdAtISO"]),
                "updatedAt": try date(row["updatedAtISO"] ?? row["createdAtISO"])]
        }
        return try canonicalCache(JSONSerialization.data(withJSONObject: cache))
    }
}
