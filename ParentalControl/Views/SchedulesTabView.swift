import SwiftUI

/// Вкладка «Расписание» для роли parent. Содержит:
/// - список уже созданных расписаний с тогл вкл/выкл и переходом в редактор по тапу;
/// - секцию «Предложения» с готовыми шаблонами (одно нажатие `+` добавляет в список и открывает редактор);
/// - кнопку «Создать новое расписание» внизу.
///
/// На текущем этапе всё работает локально через `AppState`; реальное применение блокировки на ребёнке —
/// следующими итерациями (бэкенд-таблица + scheduler в child-приложении).
struct SchedulesTabView: View {
    @EnvironmentObject private var appState: AppState
    @State private var editingSchedule: BlockSchedule?
    @State private var draftSchedule: BlockSchedule?

    var body: some View {
        NavigationStack {
            ZStack {
                AppBackgroundView()
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        header

                        if appState.blockSchedules.isEmpty {
                            emptyState
                        } else {
                            VStack(spacing: 12) {
                                ForEach(appState.blockSchedules) { schedule in
                                    ScheduleRowView(
                                        schedule: schedule,
                                        onToggle: { newValue in
                                            appState.setBlockSchedule(schedule.id, enabled: newValue)
                                        },
                                        onTap: { editingSchedule = schedule }
                                    )
                                }
                            }
                        }

                        suggestionsSection

                        createNewButton
                            .padding(.top, 4)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 28)
                }
                .scrollIndicators(.hidden)
            }
            .navigationTitle("schedule.title")
            .navigationBarTitleDisplayMode(.large)
            .sheet(item: $editingSchedule) { schedule in
                ScheduleEditorView(
                    initialSchedule: schedule,
                    isNew: false,
                    onSave: { updated in
                        appState.commitBlockSchedule(updated)
                    },
                    onDelete: {
                        appState.deleteBlockSchedule(schedule.id)
                    }
                )
                .environmentObject(appState)
            }
            .sheet(item: $draftSchedule) { draft in
                ScheduleEditorView(
                    initialSchedule: draft,
                    isNew: true,
                    onSave: { updated in
                        appState.commitBlockSchedule(updated)
                    },
                    onDelete: nil
                )
                .environmentObject(appState)
            }
        }
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("schedule.subtitle")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.7))
                .multilineTextAlignment(.leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "calendar.badge.exclamationmark")
                .font(.system(size: 40, weight: .semibold))
                .foregroundStyle(.white.opacity(0.7))
            Text("schedule.empty.title")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
            Text("schedule.empty.subtitle")
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.65))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .padding(.horizontal, 16)
        .glassCard(cornerRadius: 20, glowColor: AppTheme.neonPurple)
    }

    private var suggestionsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("schedule.suggestions.title")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white.opacity(0.85))
                .padding(.leading, 2)

            VStack(spacing: 12) {
                ForEach(BlockScheduleTemplate.suggested) { template in
                    SuggestionRowView(
                        template: template,
                        onAdd: {
                            let added = appState.addBlockSchedule(from: template)
                            editingSchedule = added
                        }
                    )
                }
            }
        }
    }

    private var createNewButton: some View {
        Button {
            let draft = appState.makeDraftBlockSchedule()
            draftSchedule = draft
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "plus.circle.fill")
                Text("schedule.create_new")
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(NeonPrimaryButtonStyle(tint: AppTheme.neonPurple))
    }
}

// MARK: - Row of an existing schedule

struct ScheduleRowView: View {
    let schedule: BlockSchedule
    let onToggle: (Bool) -> Void
    let onTap: () -> Void

    @State private var localEnabled: Bool

    init(schedule: BlockSchedule, onToggle: @escaping (Bool) -> Void, onTap: @escaping () -> Void) {
        self.schedule = schedule
        self.onToggle = onToggle
        self.onTap = onTap
        _localEnabled = State(initialValue: schedule.isEnabled)
    }

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    ZStack {
                        Circle()
                            .fill(schedule.accent.color.opacity(0.18))
                            .frame(width: 44, height: 44)
                        Image(systemName: schedule.icon.rawValue)
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(schedule.accent.color)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text(schedule.name)
                            .font(.headline)
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)

                        Text(scheduleTimeText(schedule))
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.7))
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Toggle("", isOn: $localEnabled)
                        .labelsHidden()
                        .tint(schedule.accent.color)
                        .onChange(of: localEnabled) { _, newValue in
                            onToggle(newValue)
                        }
                }

                WeekdayChipsView(selected: schedule.weekdays, isCompact: true)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassCard(cornerRadius: 20, glowColor: schedule.accent.color)
            .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .buttonStyle(.plain)
        .onChange(of: schedule.isEnabled) { _, newValue in
            // Если внешнее состояние изменилось (например через бэкенд-синк) — обновляем тогл.
            if localEnabled != newValue { localEnabled = newValue }
        }
    }
}

// MARK: - Suggestion row (template)

private struct SuggestionRowView: View {
    let template: BlockScheduleTemplate
    let onAdd: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(template.accent.color.opacity(0.18))
                        .frame(width: 44, height: 44)
                    Image(systemName: template.icon.rawValue)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(template.accent.color)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(template.localizedName)
                        .font(.headline)
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)

                    Text(templateTimeText(template))
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.7))
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Button(action: onAdd) {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(AppTheme.neonPurple)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("schedule.suggestions.add_accessibility"))
            }

            WeekdayChipsView(selected: template.weekdays, isCompact: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(cornerRadius: 20, glowColor: template.accent.color)
    }
}

// MARK: - Weekday chips (read-only or interactive)

/// Адаптивный ряд из 7 чипов дней недели. Каждый чип равномерно делит доступную ширину
/// (через `frame(maxWidth: .infinity)`), чтобы 7 чипов всегда помещались в строку
/// независимо от ширины устройства и масштаба шрифта.
struct WeekdayChipsView: View {
    let selected: Set<ScheduleWeekday>
    var isCompact: Bool = false
    var onTap: ((ScheduleWeekday) -> Void)?

    var body: some View {
        HStack(spacing: isCompact ? 4 : 6) {
            ForEach(ScheduleWeekday.allCases) { day in
                chip(for: day)
            }
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func chip(for day: ScheduleWeekday) -> some View {
        let isOn = selected.contains(day)
        let label = Text(day.shortTitle)
            .font(isCompact ? .caption2.weight(.semibold) : .footnote.weight(.semibold))
            .foregroundStyle(isOn ? AppTheme.neonPurple : Color.white.opacity(0.35))
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .frame(maxWidth: .infinity)
            .frame(height: isCompact ? 22 : 30)
            .background(
                Capsule()
                    .fill(isOn
                          ? AppTheme.neonPurple.opacity(0.18)
                          : Color.white.opacity(0.05))
            )
            .overlay(
                Capsule()
                    .stroke(isOn
                            ? AppTheme.neonPurple.opacity(0.6)
                            : Color.white.opacity(0.12),
                            lineWidth: 1)
            )

        if let onTap {
            Button { onTap(day) } label: { label }
                .buttonStyle(.plain)
        } else {
            label
        }
    }
}

// MARK: - Helpers

private func scheduleTimeText(_ schedule: BlockSchedule) -> String {
    "\(schedule.startTime.formattedShort) - \(schedule.endTime.formattedShort)"
}

private func templateTimeText(_ template: BlockScheduleTemplate) -> String {
    "\(template.startTime.formattedShort) - \(template.endTime.formattedShort)"
}

extension ScheduleAccent {
    var color: Color {
        switch self {
        case .purple: return AppTheme.neonPurple
        case .blue: return AppTheme.neonBlue
        case .green: return AppTheme.neonGreen
        case .orange: return AppTheme.neonOrange
        }
    }
}
