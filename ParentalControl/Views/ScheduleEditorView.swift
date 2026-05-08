import SwiftUI

/// Редактор расписания. Используется в двух режимах:
/// - редактирование существующего (`isNew = false`) — показывает кнопку «Удалить»;
/// - создание нового (`isNew = true`) — кнопки «Удалить» нет.
///
/// На сохранение вызывает `onSave(updated)`. На удаление вызывает `onDelete()`.
/// Закрытие без сохранения — обычный свайп вниз/Cancel.
struct ScheduleEditorView: View {
    @Environment(\.dismiss) private var dismiss

    let isNew: Bool
    let onSave: (BlockSchedule) -> Void
    let onDelete: (() -> Void)?

    @State private var name: String
    @State private var startDate: Date
    @State private var endDate: Date
    @State private var weekdays: Set<ScheduleWeekday>
    @State private var icon: ScheduleIcon
    @State private var accent: ScheduleAccent
    @State private var isEnabled: Bool
    @State private var showDeleteConfirm = false
    /// Показывает красный хинт «Укажите название» под полем имени.
    /// Взводится только когда пользователь нажал «Сохранить» при пустом имени,
    /// сбрасывается при любом изменении ввода — чтобы не маячил постоянно.
    @State private var showNameRequiredHint = false

    private let id: UUID
    private let createdAt: Date

    init(
        initialSchedule: BlockSchedule,
        isNew: Bool,
        onSave: @escaping (BlockSchedule) -> Void,
        onDelete: (() -> Void)?
    ) {
        self.isNew = isNew
        self.onSave = onSave
        self.onDelete = onDelete
        self.id = initialSchedule.id
        self.createdAt = initialSchedule.createdAt
        _name = State(initialValue: initialSchedule.name)
        _startDate = State(initialValue: initialSchedule.startTime.dateToday())
        _endDate = State(initialValue: initialSchedule.endTime.dateToday())
        _weekdays = State(initialValue: initialSchedule.weekdays)
        _icon = State(initialValue: initialSchedule.icon)
        _accent = State(initialValue: initialSchedule.accent)
        _isEnabled = State(initialValue: initialSchedule.isEnabled)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AppBackgroundView()
                ScrollView {
                    VStack(spacing: 16) {
                        nameCard
                        timeCard
                        weekdaysCard
                        toggleCard
                        if !isNew, onDelete != nil {
                            deleteButton
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 24)
                }
                .scrollIndicators(.hidden)
                // При свайпе скролла — мгновенно прячем клавиатуру и снимаем фокус с TextField.
                // Стандартный SwiftUI API (iOS 16+), не требует ручного отслеживания focus state.
                .scrollDismissesKeyboard(.immediately)
            }
            .navigationTitle(isNew ? "schedule.editor.title.new" : "schedule.editor.title.edit")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("schedule.editor.cancel") { dismiss() }
                        .tint(.white)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    // Кнопка остаётся «активной» для тапа, даже когда форма невалидна,
                    // чтобы можно было показать красный хинт «Укажите название».
                    // Когда форма невалидна — визуально выглядит приглушённой (opacity 0.5).
                    Button("schedule.editor.save") { saveAndDismiss() }
                        .tint(AppTheme.neonPurple)
                        .opacity(isFormValid ? 1 : 0.5)
                }
            }
            .alert("schedule.editor.delete.confirm.title", isPresented: $showDeleteConfirm) {
                Button("schedule.editor.delete.confirm.delete", role: .destructive) {
                    onDelete?()
                    dismiss()
                }
                Button("schedule.editor.cancel", role: .cancel) {}
            } message: {
                Text("schedule.editor.delete.confirm.message")
            }
        }
        .preferredColorScheme(.dark)
    }

    private var isFormValid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !weekdays.isEmpty
    }

    private var nameCard: some View {
        // Хинт показывается только если пользователь нажал «Сохранить» с пустым именем.
        // Цвет border-а тоже подсвечиваем красным, чтобы поле явно было выделено как ошибка.
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let nameError = showNameRequiredHint && trimmedName.isEmpty

        return VStack(alignment: .leading, spacing: 10) {
            Text("schedule.editor.name.label")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white.opacity(0.85))

            TextField("", text: $name, prompt: Text("schedule.editor.name.placeholder")
                .foregroundColor(.white.opacity(0.4)))
                .font(.body)
                .foregroundStyle(.white)
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.white.opacity(0.06))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(
                            nameError ? Color.red.opacity(0.85) : Color.white.opacity(0.12),
                            lineWidth: 1
                        )
                )
                .submitLabel(.done)
                .onChange(of: name) { _, _ in
                    // Любое изменение строки скрывает ошибку — пользователь начал исправлять.
                    if showNameRequiredHint { showNameRequiredHint = false }
                }

            if nameError {
                Text("schedule.editor.name.required")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .transition(.opacity)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(cornerRadius: 20, glowColor: accent.color)
    }

    private var timeCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("schedule.editor.time.label")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white.opacity(0.85))

            timeRow(titleKey: "schedule.editor.time.start", selection: $startDate)
            timeRow(titleKey: "schedule.editor.time.end", selection: $endDate)

            if endDate <= startDate {
                HStack(spacing: 6) {
                    Image(systemName: "moon.stars.fill")
                        .font(.caption2)
                    Text("schedule.editor.time.crosses_midnight")
                        .font(.caption)
                        .lineLimit(2)
                        .minimumScaleFactor(0.85)
                }
                .foregroundStyle(.white.opacity(0.7))
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(cornerRadius: 20, glowColor: accent.color)
    }

    /// Один ряд: слева подпись («Начало» / «Конец»), справа компактный DatePicker.
    /// Раздельные строки исключают сплющивание двух DatePicker'ов в `HStack` на узких устройствах.
    private func timeRow(titleKey: LocalizedStringKey, selection: Binding<Date>) -> some View {
        HStack(spacing: 12) {
            Text(titleKey)
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.85))
                .frame(maxWidth: .infinity, alignment: .leading)

            DatePicker("", selection: selection, displayedComponents: .hourAndMinute)
                .labelsHidden()
                .datePickerStyle(.compact)
                .tint(accent.color)
                .colorScheme(.dark)
                .fixedSize()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
        )
    }

    private var weekdaysCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("schedule.editor.weekdays.label")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white.opacity(0.85))

            WeekdayChipsView(
                selected: weekdays,
                isCompact: false,
                onTap: { day in toggleWeekday(day) }
            )

            quickPresetButtons

            if weekdays.isEmpty {
                Text("schedule.editor.weekdays.required")
                    .font(.caption)
                    .foregroundStyle(AppTheme.neonOrange)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(cornerRadius: 20, glowColor: accent.color)
    }

    private var quickPresetButtons: some View {
        HStack(spacing: 6) {
            presetButton(titleKey: "schedule.editor.weekdays.preset.workdays") {
                weekdays = ScheduleWeekday.workdays
            }
            presetButton(titleKey: "schedule.editor.weekdays.preset.weekends") {
                weekdays = ScheduleWeekday.weekends
            }
            presetButton(titleKey: "schedule.editor.weekdays.preset.everyday") {
                weekdays = ScheduleWeekday.everyday
            }
        }
    }

    private func presetButton(titleKey: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(titleKey)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(AppTheme.neonPurple)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .padding(.horizontal, 6)
                .background(
                    Capsule().fill(AppTheme.neonPurple.opacity(0.12))
                )
                .overlay(
                    Capsule().stroke(AppTheme.neonPurple.opacity(0.4), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }

    private var toggleCard: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("schedule.editor.enabled.label")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                Text("schedule.editor.enabled.hint")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.6))
            }
            Spacer()
            Toggle("", isOn: $isEnabled)
                .labelsHidden()
                .tint(accent.color)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(cornerRadius: 20, glowColor: accent.color)
    }

    private var deleteButton: some View {
        Button(role: .destructive) {
            showDeleteConfirm = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "trash.fill")
                Text("schedule.editor.delete")
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(NeonPrimaryButtonStyle(tint: AppTheme.neonOrange))
    }

    private func toggleWeekday(_ day: ScheduleWeekday) {
        if weekdays.contains(day) {
            weekdays.remove(day)
        } else {
            weekdays.insert(day)
        }
    }

    private func saveAndDismiss() {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        // Если форма невалидна — показываем хинты и не сохраняем.
        // Сейчас это только пустое имя; для пустых дней недели уже есть отдельный
        // оранжевый хинт в `weekdaysCard`, который показывается всегда при пустом наборе.
        guard isFormValid else {
            withAnimation(.easeOut(duration: 0.15)) {
                showNameRequiredHint = trimmedName.isEmpty
            }
            return
        }
        let updated = BlockSchedule(
            id: id,
            name: trimmedName,
            icon: icon,
            accent: accent,
            startTime: ScheduleTimeOfDay.from(date: startDate),
            endTime: ScheduleTimeOfDay.from(date: endDate),
            weekdays: weekdays,
            isEnabled: isEnabled,
            createdAt: createdAt,
            updatedAt: Date()
        )
        onSave(updated)
        dismiss()
    }
}
