import DeviceActivity
import FamilyControls
import Foundation
import ManagedSettings
import os.log

private let blockScheduleEnforcementLog = OSLog(
    subsystem: "mycompny.ParentalControl",
    category: "BlockScheduleEnforcement"
)

/// Регистрирует `DeviceActivitySchedule` для включённых расписаний (только child / применение на ребёнке)
/// и сразу применяет/снимает shield для расписаний, чьё время уже наступило/закончилось на момент
/// перерегистрации (immediate enforcement). Без этого `intervalDidStart` приходит только в момент
/// пересечения границы интервала и расписание не сработает, если родитель включил его уже внутри
/// активного окна.
///
/// Каждое расписание получает собственный именованный `ManagedSettingsStore`
/// (`pcsched_store_<uuid>`) — это позволяет независимо включать/снимать блокировку каждого
/// расписания, не задевая основной shield (баланс минут / удалённый «Заблокировать»).
@MainActor
final class BlockScheduleEnforcementService {
    private let center = DeviceActivityCenter()
    private let appStore: AppGroupStore
    /// Максимум сегментов расписаний (вечер+утро = 2), остальное — баланс/фокус.
    private let maxScheduleSegments = 18

    init(appStore: AppGroupStore) {
        self.appStore = appStore
    }

    /// Перечитать расписания из App Group и перерегистрировать мониторы.
    /// Дополнительно сразу применить/снять shield по реальному времени, чтобы расписание
    /// срабатывало даже если момент его активности уже наступил.
    func refreshFromStoredSchedules() {
        let auth = AuthorizationCenter.shared.authorizationStatus
        if auth != .approved {
            os_log(
                "Расписание: Family Controls не approved (статус=%{public}@) — до выбора приложений в «Экранное время» startMonitoring чаще всего падает.",
                log: blockScheduleEnforcementLog,
                type: .error,
                String(describing: auth)
            )
        }

        let allSchedules = appStore.loadBlockSchedules()
        let enabledSchedules = allSchedules.filter(\.isEnabled)
        let selection = loadSelectionIfAny()
        let hasSelection = selection.map(selectionHasItems) ?? false

        // Перед очисткой запоминаем предыдущие activityNames, чтобы корректно остановить мониторинг
        // и одновременно снять shield для всех расписаний, которых больше нет/выключены.
        stopPreviousSchedules()

        // Снять shield для расписаний, которые сейчас выключены или удалены (всех неактивных).
        let enabledIDs = Set(enabledSchedules.map { $0.id })
        for schedule in allSchedules where !enabledIDs.contains(schedule.id) {
            clearNamedScheduleShield(scheduleID: schedule.id)
        }

        var names: [String] = []
        var used = 0
        let now = Date()

        for schedule in enabledSchedules {
            if used >= maxScheduleSegments { break }
            if schedule.startTime.totalMinutes == schedule.endTime.totalMinutes {
                continue
            }

            // Регистрируем DeviceActivitySchedule сегмент(ы) для пограничных переходов.
            if schedule.crossesMidnight {
                if used + 2 > maxScheduleSegments { break }
                let eveningName = "pcsched_\(schedule.id.uuidString)_e"
                let morningName = "pcsched_\(schedule.id.uuidString)_m"
                let eveningSchedule = DeviceActivitySchedule(
                    intervalStart: DateComponents(
                        hour: schedule.startTime.hour,
                        minute: schedule.startTime.minute
                    ),
                    intervalEnd: DateComponents(hour: 23, minute: 59),
                    repeats: true
                )
                let morningSchedule = DeviceActivitySchedule(
                    intervalStart: DateComponents(hour: 0, minute: 0),
                    intervalEnd: DateComponents(hour: schedule.endTime.hour, minute: schedule.endTime.minute),
                    repeats: true
                )
                startMonitoringIfNeeded(name: eveningName, schedule: eveningSchedule, names: &names)
                startMonitoringIfNeeded(name: morningName, schedule: morningSchedule, names: &names)
                used += 2
            } else {
                let name = "pcsched_\(schedule.id.uuidString)_s"
                let daySchedule = DeviceActivitySchedule(
                    intervalStart: DateComponents(
                        hour: schedule.startTime.hour,
                        minute: schedule.startTime.minute
                    ),
                    intervalEnd: DateComponents(hour: schedule.endTime.hour, minute: schedule.endTime.minute),
                    repeats: true
                )
                startMonitoringIfNeeded(name: name, schedule: daySchedule, names: &names)
                used += 1
            }

            // Immediate enforcement: применяем/снимаем shield ВРУЧНУЮ по текущему времени.
            // Это критично, потому что DeviceActivitySchedule.intervalDidStart вызывается ТОЛЬКО
            // в момент пересечения границы; если родитель включил расписание внутри активного окна —
            // без этого shield не появится до следующего наступления startTime.
            if let selection, hasSelection, isScheduleActiveNow(schedule, now: now) {
                applyNamedScheduleShield(selection: selection, scheduleID: schedule.id)
                os_log(
                    "Расписание %{public}@: shield применён немедленно (внутри активного окна).",
                    log: blockScheduleEnforcementLog, type: .info,
                    schedule.id.uuidString
                )
            } else {
                clearNamedScheduleShield(scheduleID: schedule.id)
            }
        }

        appStore.saveBlockScheduleActivityNames(names)
        if used >= maxScheduleSegments, enabledSchedules.count > 0 {
            os_log(
                "Блок по расписанию: достигнут лимит сегментов (%{public}d), часть расписаний не зарегистрирована",
                log: blockScheduleEnforcementLog,
                type: .error,
                maxScheduleSegments
            )
        }
    }

    // MARK: - Helpers

    /// Возвращает `true`, если текущий момент попадает внутрь окна расписания
    /// с учётом перехода через полночь и выбранных дней недели.
    private func isScheduleActiveNow(_ schedule: BlockSchedule, now: Date) -> Bool {
        let calendar = Calendar.current
        let nowComponents = calendar.dateComponents([.hour, .minute, .weekday], from: now)
        let nowHour = nowComponents.hour ?? 0
        let nowMinute = nowComponents.minute ?? 0
        let nowMinutesOfDay = nowHour * 60 + nowMinute

        // 1 = воскресенье (Calendar) → переводим в нашу нумерацию (1 = понедельник).
        let calendarWeekday = nowComponents.weekday ?? 1
        let scheduleWeekdayToday = (calendarWeekday == 1) ? 7 : (calendarWeekday - 1)
        guard let todayWD = ScheduleWeekday(rawValue: scheduleWeekdayToday) else { return false }

        let start = schedule.startTime.totalMinutes
        let end = schedule.endTime.totalMinutes

        if !schedule.crossesMidnight {
            // Однодневный интервал, например 18:00–20:00. Активен только если день в weekdays.
            guard schedule.weekdays.contains(todayWD) else { return false }
            return nowMinutesOfDay >= start && nowMinutesOfDay < end
        }

        // Переход через полночь (например 22:30 → 07:30).
        // Окно активно, если: текущее время >= start (вечерняя часть) — и день расписания совпадает с СЕГОДНЯ.
        // ИЛИ: текущее время < end (утренняя часть) — и день совпадает со ВЧЕРА (это «вчерашняя ночь»).
        if nowMinutesOfDay >= start {
            return schedule.weekdays.contains(todayWD)
        }
        if nowMinutesOfDay < end {
            // Утро: смотрим, был ли активен «вчерашний» день в weekdays.
            let yesterday = calendar.date(byAdding: .day, value: -1, to: now) ?? now
            let yCal = calendar.component(.weekday, from: yesterday)
            let yScheduleWD = (yCal == 1) ? 7 : (yCal - 1)
            guard let yesterdayWD = ScheduleWeekday(rawValue: yScheduleWD) else { return false }
            return schedule.weekdays.contains(yesterdayWD)
        }
        return false
    }

    private func loadSelectionIfAny() -> FamilyActivitySelection? {
        guard let data = appStore.loadFamilySelectionData() else { return nil }
        return try? JSONDecoder().decode(FamilyActivitySelection.self, from: data)
    }

    private func selectionHasItems(_ selection: FamilyActivitySelection) -> Bool {
        !selection.applicationTokens.isEmpty ||
            !selection.categoryTokens.isEmpty ||
            !selection.webDomainTokens.isEmpty
    }

    private func applyNamedScheduleShield(selection: FamilyActivitySelection, scheduleID: UUID) {
        let storeName = ManagedSettingsStore.Name(rawValue: "pcsched_store_\(scheduleID.uuidString)")
        let store = ManagedSettingsStore(named: storeName)
        store.shield.applications = selection.applicationTokens.isEmpty ? nil : selection.applicationTokens
        store.shield.applicationCategories = selection.categoryTokens.isEmpty ? nil : .specific(selection.categoryTokens)
        store.shield.webDomains = selection.webDomainTokens.isEmpty ? nil : selection.webDomainTokens
    }

    private func clearNamedScheduleShield(scheduleID: UUID) {
        let storeName = ManagedSettingsStore.Name(rawValue: "pcsched_store_\(scheduleID.uuidString)")
        ManagedSettingsStore(named: storeName).clearAllSettings()
    }

    private func stopPreviousSchedules() {
        let previous = appStore.loadBlockScheduleActivityNames()
        guard !previous.isEmpty else { return }
        let activities = previous.map { DeviceActivityName($0) }
        center.stopMonitoring(activities)
        appStore.saveBlockScheduleActivityNames([])
    }

    private func startMonitoringIfNeeded(
        name: String,
        schedule: DeviceActivitySchedule,
        names: inout [String]
    ) {
        let activity = DeviceActivityName(name)
        do {
            try center.startMonitoring(activity, during: schedule, events: [:])
            names.append(name)
        } catch {
            os_log(
                "startMonitoring расписания не удался: %{public}@ — %{public}@",
                log: blockScheduleEnforcementLog,
                type: .error,
                name,
                error.localizedDescription
            )
        }
    }
}
