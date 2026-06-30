import Foundation

/// Один день недели в наборе расписания. Используем понятную нумерацию 1...7
/// (1 = понедельник ... 7 = воскресенье), чтобы упорядочивать чипы строго в этом порядке
/// независимо от `Calendar.current.firstWeekday`.
enum ScheduleWeekday: Int, Codable, CaseIterable, Identifiable, Hashable {
    case monday = 1
    case tuesday = 2
    case wednesday = 3
    case thursday = 4
    case friday = 5
    case saturday = 6
    case sunday = 7

    var id: Int { rawValue }

    /// Соответствие `Calendar.component(.weekday, ...)` (там 1 = воскресенье).
    var calendarWeekday: Int {
        switch self {
        case .sunday: return 1
        case .monday: return 2
        case .tuesday: return 3
        case .wednesday: return 4
        case .thursday: return 5
        case .friday: return 6
        case .saturday: return 7
        }
    }

    /// Короткий локализованный заголовок для чипа («Пн», «Mon»).
    var shortTitle: String {
        switch self {
        case .monday: return L10n.tr("schedule.weekday.short.mon")
        case .tuesday: return L10n.tr("schedule.weekday.short.tue")
        case .wednesday: return L10n.tr("schedule.weekday.short.wed")
        case .thursday: return L10n.tr("schedule.weekday.short.thu")
        case .friday: return L10n.tr("schedule.weekday.short.fri")
        case .saturday: return L10n.tr("schedule.weekday.short.sat")
        case .sunday: return L10n.tr("schedule.weekday.short.sun")
        }
    }

    static let everyday: Set<ScheduleWeekday> = Set(ScheduleWeekday.allCases)
    static let workdays: Set<ScheduleWeekday> = [.monday, .tuesday, .wednesday, .thursday, .friday]
    static let weekends: Set<ScheduleWeekday> = [.saturday, .sunday]
}

/// Простое представление времени-в-сутках без даты. Хранится как `hour * 60 + minute`,
/// что позволяет легко сравнивать диапазоны и переходить через полночь.
struct ScheduleTimeOfDay: Codable, Equatable, Hashable {
    var hour: Int
    var minute: Int

    init(hour: Int, minute: Int) {
        self.hour = max(0, min(23, hour))
        self.minute = max(0, min(59, minute))
    }

    var totalMinutes: Int { hour * 60 + minute }

    /// Возвращает `Date` сегодня в это время (используется для пикера и форматирования).
    func dateToday(calendar: Calendar = .current, reference: Date = Date()) -> Date {
        var components = calendar.dateComponents([.year, .month, .day], from: reference)
        components.hour = hour
        components.minute = minute
        components.second = 0
        return calendar.date(from: components) ?? reference
    }

    static func from(date: Date, calendar: Calendar = .current) -> ScheduleTimeOfDay {
        let components = calendar.dateComponents([.hour, .minute], from: date)
        return ScheduleTimeOfDay(hour: components.hour ?? 0, minute: components.minute ?? 0)
    }

    var formattedShort: String {
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: dateToday())
    }
}

/// Цветовой акцент карточки расписания. Кодируется как строковый rawValue, чтобы было
/// удобно сериализовать и не зависеть от `SwiftUI` на уровне модели.
enum ScheduleAccent: String, Codable, CaseIterable {
    case purple
    case blue
    case green
    case orange
}

/// Иконки SF Symbols, которые используются для типов расписаний. Хранится как rawValue,
/// поэтому модель остаётся полностью UI-независимой.
enum ScheduleIcon: String, Codable, CaseIterable {
    case sleep = "moon.stars.fill"
    case school = "graduationcap.fill"
    case homework = "book.closed.fill"
    case dinner = "fork.knife"
    case generic = "calendar"
}

/// Пользовательское расписание блокировки приложений. Синхронизируется с бэкендом в паре
/// parent → `family_block_schedules` и применяется на устройстве ребёнка через
/// `DeviceActivitySchedule` + именованные `ManagedSettingsStore`.
struct BlockSchedule: Codable, Equatable, Identifiable {
    let id: UUID
    var name: String
    var icon: ScheduleIcon
    var accent: ScheduleAccent
    var startTime: ScheduleTimeOfDay
    var endTime: ScheduleTimeOfDay
    var weekdays: Set<ScheduleWeekday>
    var isEnabled: Bool
    let createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        icon: ScheduleIcon = .generic,
        accent: ScheduleAccent = .purple,
        startTime: ScheduleTimeOfDay,
        endTime: ScheduleTimeOfDay,
        weekdays: Set<ScheduleWeekday> = ScheduleWeekday.everyday,
        isEnabled: Bool = false,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.icon = icon
        self.accent = accent
        self.startTime = startTime
        self.endTime = endTime
        self.weekdays = weekdays
        self.isEnabled = isEnabled
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// `true`, если расписание переходит через полночь (например 22:30 → 07:30).
    var crossesMidnight: Bool {
        endTime.totalMinutes <= startTime.totalMinutes
    }

    /// Отсортированный массив выбранных дней — для стабильного UI-рендеринга.
    var orderedWeekdays: [ScheduleWeekday] {
        weekdays.sorted { $0.rawValue < $1.rawValue }
    }

    /// Возвращает `true`, если расписание сейчас должно быть активно (с учётом
    /// дней недели и переходов через полночь). Используется и парентом для UI
    /// «активно сейчас», и совпадает по логике с бэкендом `isScheduleActiveAt`.
    /// Параметр `now` — текущий момент в локальной таймзоне устройства.
    func isActive(at now: Date = Date(), calendar: Calendar = .current) -> Bool {
        guard isEnabled else { return false }
        let components = calendar.dateComponents([.hour, .minute, .weekday], from: now)
        let hour = components.hour ?? 0
        let minute = components.minute ?? 0
        let minutesOfDay = hour * 60 + minute
        let start = startTime.totalMinutes
        let end = endTime.totalMinutes

        // calendar.weekday: 1 = воскресенье ... 7 = суббота → переводим в нашу нумерацию (1 = Пн ... 7 = Вс).
        let calWeekday = components.weekday ?? 1
        let todayWD = calWeekday == 1 ? 7 : calWeekday - 1
        guard let todayEnum = ScheduleWeekday(rawValue: todayWD) else { return false }

        if !crossesMidnight {
            guard weekdays.contains(todayEnum) else { return false }
            return minutesOfDay >= start && minutesOfDay < end
        }

        // Окно через полночь: вечер сегодня от start..00:00 и утро завтра 00:00..end.
        if minutesOfDay >= start {
            return weekdays.contains(todayEnum)
        }
        if minutesOfDay < end {
            // Утро — окно принадлежит вчерашнему дню недели.
            let yesterdayWD = todayWD == 1 ? 7 : todayWD - 1
            guard let yesterdayEnum = ScheduleWeekday(rawValue: yesterdayWD) else { return false }
            return weekdays.contains(yesterdayEnum)
        }
        return false
    }

    /// Локализованная короткая строка диапазона: «HH:MM — HH:MM».
    var formattedTimeRange: String {
        "\(startTime.formattedShort) — \(endTime.formattedShort)"
    }

    /// Краткая строка из выбранных дней («Пн, Ср, Пт» / «Каждый день» / «Будни» / «Выходные»).
    var formattedWeekdaysShort: String {
        if weekdays == ScheduleWeekday.everyday {
            return L10n.tr("schedule.weekdays.everyday")
        }
        if weekdays == ScheduleWeekday.workdays {
            return L10n.tr("schedule.weekdays.workdays")
        }
        if weekdays == ScheduleWeekday.weekends {
            return L10n.tr("schedule.weekdays.weekends")
        }
        return orderedWeekdays.map { $0.shortTitle }.joined(separator: ", ")
    }
}

/// Готовый шаблон расписания, который пользователь может добавить одним нажатием.
struct BlockScheduleTemplate: Identifiable, Equatable {
    let id: String
    let nameKey: String
    let icon: ScheduleIcon
    let accent: ScheduleAccent
    let startTime: ScheduleTimeOfDay
    let endTime: ScheduleTimeOfDay
    let weekdays: Set<ScheduleWeekday>

    /// Создаёт новый `BlockSchedule` на основе шаблона. По умолчанию — включённое расписание,
    /// чтобы при добавлении из «Предложений» родителю не нужно было дополнительно включать тогл.
    func makeSchedule(isEnabled: Bool = true) -> BlockSchedule {
        BlockSchedule(
            name: L10n.tr(nameKey),
            icon: icon,
            accent: accent,
            startTime: startTime,
            endTime: endTime,
            weekdays: weekdays,
            isEnabled: isEnabled
        )
    }

    /// Локализованное имя для отображения в карточке шаблона.
    var localizedName: String { L10n.tr(nameKey) }
}

extension BlockScheduleTemplate {
    static let schoolHours = BlockScheduleTemplate(
        id: "schoolHours",
        nameKey: "schedule.template.school.title",
        icon: .school,
        accent: .green,
        startTime: ScheduleTimeOfDay(hour: 8, minute: 0),
        endTime: ScheduleTimeOfDay(hour: 15, minute: 0),
        weekdays: ScheduleWeekday.workdays
    )

    static let homework = BlockScheduleTemplate(
        id: "homework",
        nameKey: "schedule.template.homework.title",
        icon: .homework,
        accent: .green,
        startTime: ScheduleTimeOfDay(hour: 18, minute: 30),
        endTime: ScheduleTimeOfDay(hour: 19, minute: 30),
        weekdays: [.monday, .tuesday, .wednesday, .thursday]
    )

    static let dinner = BlockScheduleTemplate(
        id: "dinner",
        nameKey: "schedule.template.dinner.title",
        icon: .dinner,
        accent: .blue,
        startTime: ScheduleTimeOfDay(hour: 19, minute: 0),
        endTime: ScheduleTimeOfDay(hour: 20, minute: 0),
        weekdays: ScheduleWeekday.everyday
    )

    static let suggested: [BlockScheduleTemplate] = [.schoolHours, .homework, .dinner]
}

extension BlockSchedule {
    /// Дефолтное расписание «Время спать», которое сидируется при первом запуске роли parent.
    /// Создаётся выключённым и со всеми днями недели — пользователь дальше может включить и переименовать.
    static func defaultSleepSchedule() -> BlockSchedule {
        BlockSchedule(
            name: L10n.tr("schedule.default.sleep.title"),
            icon: .sleep,
            accent: .purple,
            startTime: ScheduleTimeOfDay(hour: 22, minute: 30),
            endTime: ScheduleTimeOfDay(hour: 7, minute: 30),
            weekdays: ScheduleWeekday.everyday,
            isEnabled: false
        )
    }

    /// Маппинг DTO с бэкенда (`list_block_schedules`).
    init(remoteDTO: RemoteBlockScheduleDTO) {
        let parsedIcon = ScheduleIcon(rawValue: remoteDTO.icon) ?? .generic
        let parsedAccent = ScheduleAccent(rawValue: remoteDTO.accent) ?? .purple
        let wd = Set(remoteDTO.weekdays.compactMap { ScheduleWeekday(rawValue: $0) })
        let weekdaysResolved = wd.isEmpty ? ScheduleWeekday.everyday : wd
        let isoFrac = ISO8601DateFormatter()
        isoFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoPlain = ISO8601DateFormatter()
        let created = remoteDTO.createdAtISO.flatMap { isoFrac.date(from: $0) ?? isoPlain.date(from: $0) } ?? Date()
        let updated = remoteDTO.updatedAtISO.flatMap { isoFrac.date(from: $0) ?? isoPlain.date(from: $0) } ?? created
        self.init(
            id: remoteDTO.id,
            name: remoteDTO.name,
            icon: parsedIcon,
            accent: parsedAccent,
            startTime: ScheduleTimeOfDay(hour: remoteDTO.startHour, minute: remoteDTO.startMinute),
            endTime: ScheduleTimeOfDay(hour: remoteDTO.endHour, minute: remoteDTO.endMinute),
            weekdays: weekdaysResolved,
            isEnabled: remoteDTO.isEnabled,
            createdAt: created,
            updatedAt: updated
        )
    }
}
