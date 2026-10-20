import Foundation

@main
struct ScheduleTests {
    static func main() throws {
        var checks = 0
        func check(_ value: Bool, _ message: String) {
            precondition(value, message)
            checks += 1
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        func date(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
            calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
        }
        func entry(_ sh: Int, _ sm: Int, _ eh: Int, _ em: Int, days: [Int] = [1,2,3,4,5,6,7],
                   enabled: Bool = true) -> ScheduleControlPlan.Entry {
            .init(id: UUID(), startTime: .init(hour: sh, minute: sm), endTime: .init(hour: eh, minute: em),
                  weekdays: days, isEnabled: enabled)
        }
        let day = entry(10, 0, 11, 0, days: [2]) // Oct 20, 2026 = Tuesday.
        check(!day.isActive(at: date(20, 9, 59), calendar: calendar), "Before start")
        check(day.isActive(at: date(20, 10), calendar: calendar), "Inclusive start")
        check(day.isActive(at: date(20, 10, 59), calendar: calendar), "Inside interval")
        check(!day.isActive(at: date(20, 11), calendar: calendar), "Exclusive end")
        check(!day.isActive(at: date(21, 10), calendar: calendar), "Unselected weekday")
        let night = entry(23, 55, 7, 0, days: [2])
        check(night.isActive(at: date(20, 23, 59), calendar: calendar), "Overnight start day")
        check(night.isActive(at: date(21, 0), calendar: calendar), "Midnight retains yesterday's day")
        check(night.isActive(at: date(21, 6, 59), calendar: calendar), "Morning belongs to previous day")
        check(!night.isActive(at: date(20, 6), calendar: calendar), "No early block on selected evening's morning")
        check(!night.isActive(at: date(21, 7), calendar: calendar), "Overnight end")
        check(night.monitoredEnd == night.endTime && night.warningMinutes == nil, "Overnight is one valid interval, not a 4-minute segment")
        let sunday = entry(22, 0, 7, 0, days: [7])
        check(sunday.isActive(at: date(19, 6), calendar: calendar), "Sunday -> Monday")
        let short = entry(10, 0, 10, 3)
        check(short.duration == 3 && short.monitoredEnd.minutes == 615, "Pad short monitor to the 15-minute OS minimum")
        check(short.warningMinutes == 12, "End warning at actual 10:03")
        check(!short.isActive(at: date(20, 10, 3), calendar: calendar), "Padding never extends the actual restriction")
        let shortNight = entry(23, 58, 0, 2)
        check(shortNight.monitoredEnd == .init(hour: 0, minute: 13), "Short monitor wraps midnight")
        check(shortNight.warningMinutes == 11, "Short midnight warning at actual end")
        check(!entry(10, 0, 11, 0, enabled: false).isActive(at: date(20, 10), calendar: calendar), "Disabled schedule")
        check(ScheduleControlPlan.scheduleID(activityName: day.activityName) == day.id, "Current activity parsing")
        check(ScheduleControlPlan.scheduleID(activityName: "pcsched_\(day.id)_e") == day.id, "Old evening monitor migrates")
        check(ScheduleControlPlan.scheduleID(activityName: "pcsched_\(day.id)_m") == day.id, "Old morning monitor migrates")
        check(ScheduleControlPlan.scheduleID(activityName: "parentalcontrol.activity") == nil, "Usage monitor never cleaned up as a schedule")
        check(ScheduleControlPlan.scheduleID(activityName: "parentalcontrol.dailyBudget") == nil, "Daily budget stays independent")
        check(ScheduleControlPlan.scheduleID(activityName: "pcsched_garbage_s") == nil, "Reject malformed names")
        let encoder = JSONEncoder()
        let plan = try ScheduleControlPlan(data: encoder.encode([day, night]))
        check(plan.entries.count == 2, "Multiple schedules coexist")
        let empty = try ScheduleControlPlan(data: Data("[]".utf8))
        check(empty.entries.isEmpty, "Delete last schedule is a valid complete snapshot")
        let zero = entry(10, 0, 10, 0)
        check(!zero.isActive(at: date(20, 10), calendar: calendar), "Equal times never become a 24-hour block")
        let withZero = try ScheduleControlPlan(data: encoder.encode([day, zero]))
        check(withZero.enabledEntries.count == 1, "Empty interval does not prevent other schedules")
        func rejects(_ entries: [ScheduleControlPlan.Entry]) -> Bool {
            do { _ = try ScheduleControlPlan(data: encoder.encode(entries)); return false }
            catch { return true }
        }
        check(rejects([day, day]), "Duplicate IDs rejected")
        check(rejects([entry(25, 0, 11, 0)]), "Invalid time rejected")
        check(rejects([entry(10, 0, 11, 0, days: [8])]), "Invalid weekday rejected")
        check(rejects([entry(10, 0, 11, 0, days: [])]), "Empty weekdays rejected")
        check(rejects((0..<19).map { _ in entry(10, 0, 11, 0) }), "Capacity failure is not silent partial success")
        let wire: [String: Any] = ["schedules": [[
            "id": day.id.uuidString.lowercased(), "name": "Учёба", "icon": "book.closed.fill", "accent": "blue",
            "startHour": 10, "startMinute": 0, "endHour": 11, "endMinute": 0, "weekdays": [3, 2, 2],
            "isEnabled": true, "createdAtISO": "2026-10-20T08:00:00.123Z", "updatedAtISO": "2026-10-20T09:00:00Z"
        ]]]
        let cache = try ScheduleControlPlan.cacheFromResponse(JSONSerialization.data(withJSONObject: wire))
        let decoded = try ScheduleControlPlan(data: cache)
        check(decoded.entries[0].id == day.id && decoded.entries[0].weekdays == [2,3], "Server -> canonical shared cache")
        let rows = try JSONSerialization.jsonObject(with: cache) as! [[String: Any]]
        check(rows[0]["name"] as? String == "Учёба", "Keep user-facing schedule name")
        check(rows[0]["createdAt"] as? String == "2026-10-20T08:00:00Z", "Host ISO8601 date compatibility")
        check(try ScheduleControlPlan.canonicalCache(cache) == cache, "Repeated delivery keeps stable cache bytes")
        let deletion = try ScheduleControlPlan.cacheFromResponse(Data(#"{"schedules":[]}"#.utf8))
        check(deletion == Data("[]".utf8), "Deletion response is not mistaken for fetch failure")
        do {
            _ = try ScheduleControlPlan.cacheFromResponse(Data(#"{"error":"offline"}"#.utf8))
            preconditionFailure("Invalid response must not erase cached schedules")
        } catch { check(true, "Malformed response fails closed") }
        let fetch = ScheduleControlStore.Fetch(generation: "new-fetch", pairing: Data("family-A".utf8))
        check(fetch.isCurrent(generation: "new-fetch", pairing: Data("family-A".utf8), role: "child"), "Current authenticated fetch can commit")
        check(!fetch.isCurrent(generation: "newer-fetch", pairing: Data("family-A".utf8), role: "child"), "Older response cannot overwrite a newer fetch")
        check(!fetch.isCurrent(generation: "new-fetch", pairing: Data("family-B".utf8), role: "child"), "Re-pairing invalidates old data")
        check(!fetch.isCurrent(generation: "new-fetch", pairing: nil, role: "child"), "Unlink invalidates response")
        check(!fetch.isCurrent(generation: "new-fetch", pairing: Data("family-A".utf8), role: "parent"), "Role change invalidates response")
        print("Schedule control: \(checks) checks passed")
    }
}
