import SwiftUI

/// Универсальная карточка-индикатор «Активное расписание» / «Следующее расписание».
/// Работает на самом TimelineView и переоценивает состояние раз в 30 секунд, чтобы UI
/// корректно реагировал на пересечение границ окна без ручных Timer/RunLoop и retain-циклов.
///
/// Используется на дашборде Родителя (`ParentDashboardView`). Решение жить в собственном
/// компоненте, а не во вложенных приватных view, удобно тем, что:
///   - тесты-Preview можно делать изолированно;
///   - в будущем проще переиспользовать на других экранах (статистика, расписания);
///   - изменения логики «активно/следующее» не размазаны по нескольким файлам.
struct ActiveBlockScheduleCard: View {
    @ObservedObject var appState: AppState

    var body: some View {
        // Показываем карточку только когда есть включённые расписания. Для корректной авто-
        // переоценки используем TimelineView(.periodic by: 30) — это идиоматичный SwiftUI-
        // способ переоценивать содержимое без ручных таймеров.
        if appState.blockSchedules.contains(where: { $0.isEnabled }) {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                let active = appState.activeBlockSchedules(at: context.date)
                if !active.isEmpty {
                    activeContent(active)
                } else if let next = appState.nextScheduledBlock(after: context.date) {
                    nextContent(schedule: next.schedule, startDate: next.startDate, now: context.date)
                }
            }
        }
    }

    // MARK: - Active

    private func activeContent(_ schedules: [BlockSchedule]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(L10n.tr("dashboard.active_schedule.title"), systemImage: "calendar.badge.clock")
                .font(.headline.bold())
                .foregroundStyle(.white.opacity(0.9))

            VStack(alignment: .leading, spacing: 10) {
                ForEach(schedules) { schedule in
                    activeRow(schedule)
                }
            }

            Text("dashboard.active_schedule.hint")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding()
        .glassCard(cornerRadius: 22, glowColor: AppTheme.neonOrange)
    }

    private func activeRow(_ schedule: BlockSchedule) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: schedule.icon.rawValue)
                .font(.title3.weight(.semibold))
                .foregroundStyle(AppTheme.neonOrange)
                .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(schedule.name)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(schedule.formattedTimeRange)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(AppTheme.neonOrange)
                Text(schedule.formattedWeekdaysShort)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - Next

    private func nextContent(schedule: BlockSchedule, startDate: Date, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(L10n.tr("dashboard.next_schedule.title"), systemImage: "calendar")
                .font(.headline.bold())
                .foregroundStyle(.white.opacity(0.9))

            HStack(alignment: .center, spacing: 12) {
                Image(systemName: schedule.icon.rawValue)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(AppTheme.neonGreen)
                    .frame(width: 28, height: 28)

                VStack(alignment: .leading, spacing: 2) {
                    Text(schedule.name)
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(schedule.formattedTimeRange)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(AppTheme.neonGreen)
                    Text(formattedRelativeStart(startDate: startDate, from: now))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
        }
        .padding()
        .glassCard(cornerRadius: 22, glowColor: AppTheme.neonGreen)
    }

    /// Локализованная относительная подпись «через 1 ч 23 мин» / «in 1 h 23 min».
    /// Static-форматтер чтобы не пересоздавать NSFormatter на каждом тике TimelineView.
    private func formattedRelativeStart(startDate: Date, from now: Date) -> String {
        ActiveBlockScheduleCard.relativeFormatter.localizedString(for: startDate, relativeTo: now)
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()
}
