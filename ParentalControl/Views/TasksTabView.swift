import SwiftUI

/// Вкладка «Задания» для роли parent. Родитель создаёт задания с наградой во времени,
/// видит статусы (новое / на проверке / выполнено) и подтверждает отправленные ребёнком отчёты.
/// При подтверждении бэкенд атомарно начисляет награду ребёнку (`add_earned_seconds`).
struct TasksTabView: View {
    @EnvironmentObject private var appState: AppState
    @State private var editingTask: ChildTask?
    @State private var draftTask: ChildTask?
    @State private var approvingTaskID: UUID?

    var body: some View {
        NavigationStack {
            ZStack {
                AppBackgroundView()
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        header

                        if appState.childTasks.isEmpty {
                            emptyState
                        } else {
                            VStack(spacing: 12) {
                                ForEach(appState.childTasks) { task in
                                    TaskParentRowView(
                                        task: task,
                                        isApproving: approvingTaskID == task.id,
                                        onApprove: { approve(task) },
                                        onTap: {
                                            // Редактировать можно только не подтверждённое задание.
                                            if task.status != .approved { editingTask = task }
                                        }
                                    )
                                }
                            }
                        }

                        createNewButton
                            .padding(.top, 4)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 28)
                }
                .scrollIndicators(.hidden)
            }
            .sheet(item: $editingTask) { task in
                TaskEditorView(
                    initialTask: task,
                    isNew: false,
                    onSave: { updated in appState.commitChildTask(updated) },
                    onDelete: { appState.deleteChildTask(task.id) }
                )
                .environmentObject(appState)
            }
            .sheet(item: $draftTask) { draft in
                TaskEditorView(
                    initialTask: draft,
                    isNew: true,
                    onSave: { updated in appState.commitChildTask(updated) },
                    onDelete: nil
                )
                .environmentObject(appState)
            }
        }
        .preferredColorScheme(.dark)
        .task { await appState.refreshChildTasksFromServer() }
    }

    private func approve(_ task: ChildTask) {
        approvingTaskID = task.id
        Task {
            await appState.approveChildTask(task.id)
            approvingTaskID = nil
        }
    }

    private var header: some View {
        VStack(alignment: .center, spacing: 6) {
            Text("tasks.parent.subtitle")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.7))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.top, 6)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "checklist")
                .font(.system(size: 40, weight: .semibold))
                .foregroundStyle(.white.opacity(0.7))
            Text("tasks.empty.title")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
            Text("tasks.parent.empty.subtitle")
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.65))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .padding(.horizontal, 16)
        .glassCard(cornerRadius: 20, glowColor: AppTheme.neonBlue)
        .padding(36)
        .drawingGroup()
        .padding(-36)
    }

    private var createNewButton: some View {
        Button {
            draftTask = appState.makeDraftChildTask()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "plus.circle.fill")
                Text("tasks.create_new")
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(NeonPrimaryButtonStyle(tint: AppTheme.neonBlue))
    }
}

// MARK: - Parent task row

private struct TaskParentRowView: View {
    let task: ChildTask
    let isApproving: Bool
    let onApprove: () -> Void
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    ZStack {
                        Circle()
                            .fill(task.status.accentColor.opacity(0.18))
                            .frame(width: 44, height: 44)
                        Image(systemName: task.status.iconName)
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(task.status.accentColor)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text(task.title)
                            .font(.headline)
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)

                        Text(rewardText(task.rewardMinutes))
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.7))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    TaskStatusBadge(status: task.status)
                }

                if !task.details.isEmpty {
                    Text(task.details)
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                if task.status == .submitted {
                    Button(action: onApprove) {
                        HStack(spacing: 8) {
                            if isApproving {
                                ProgressView().tint(.white)
                            } else {
                                Image(systemName: "checkmark.seal.fill")
                            }
                            Text("tasks.parent.approve")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(NeonPrimaryButtonStyle(tint: AppTheme.neonGreen))
                    .disabled(isApproving)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                Color.clear
                    .glassCard(cornerRadius: 20, glowColor: task.status.accentColor)
                    .padding(36)
                    .drawingGroup()
                    .padding(-36)
            )
            .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Task editor (parent)

/// Редактор задания. `isNew == true` — создание (без кнопки «Удалить»); закрытие свайпом/«Отмена»
/// ничего не сохраняет. Сохранение только по «Сохранить» при валидной форме (непустой заголовок).
struct TaskEditorView: View {
    @Environment(\.dismiss) private var dismiss

    let isNew: Bool
    let onSave: (ChildTask) -> Void
    let onDelete: (() -> Void)?

    @State private var title: String
    @State private var details: String
    @State private var rewardMinutes: Int
    @State private var showDeleteConfirm = false
    @State private var showTitleRequiredHint = false

    private let id: UUID
    private let createdAt: Date
    private let status: ChildTaskStatus
    private let submittedAt: Date?
    private let approvedAt: Date?

    /// Доступные значения награды (минуты): 5…120 с шагом 5.
    private let rewardOptions: [Int] = Array(stride(from: 5, through: 120, by: 5))

    init(
        initialTask: ChildTask,
        isNew: Bool,
        onSave: @escaping (ChildTask) -> Void,
        onDelete: (() -> Void)?
    ) {
        self.isNew = isNew
        self.onSave = onSave
        self.onDelete = onDelete
        self.id = initialTask.id
        self.createdAt = initialTask.createdAt
        self.status = initialTask.status
        self.submittedAt = initialTask.submittedAt
        self.approvedAt = initialTask.approvedAt
        _title = State(initialValue: initialTask.title)
        _details = State(initialValue: initialTask.details)
        let minutes = max(5, initialTask.rewardMinutes)
        _rewardMinutes = State(initialValue: min(120, minutes - (minutes % 5 == 0 ? 0 : minutes % 5)))
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AppBackgroundView()
                ScrollView {
                    VStack(spacing: 16) {
                        titleCard
                        detailsCard
                        rewardCard
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
                .scrollDismissesKeyboard(.immediately)
            }
            .navigationTitle(isNew ? "tasks.editor.title.new" : "tasks.editor.title.edit")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("tasks.editor.cancel") { dismiss() }
                        .tint(.white)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("tasks.editor.save") { saveAndDismiss() }
                        .tint(AppTheme.neonBlue)
                        .opacity(isFormValid ? 1 : 0.5)
                }
            }
            .alert("tasks.editor.delete.confirm.title", isPresented: $showDeleteConfirm) {
                Button("tasks.editor.delete.confirm.delete", role: .destructive) {
                    onDelete?()
                    dismiss()
                }
                Button("tasks.editor.cancel", role: .cancel) {}
            } message: {
                Text("tasks.editor.delete.confirm.message")
            }
        }
        .preferredColorScheme(.dark)
    }

    private var isFormValid: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var titleCard: some View {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let titleError = showTitleRequiredHint && trimmed.isEmpty
        return VStack(alignment: .leading, spacing: 10) {
            Text("tasks.editor.title.label")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white.opacity(0.85))

            TextField("", text: $title, prompt: Text("tasks.editor.title.placeholder")
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
                            titleError ? Color.red.opacity(0.85) : Color.white.opacity(0.12),
                            lineWidth: 1
                        )
                )
                .submitLabel(.done)
                .onChange(of: title) { _, _ in
                    if showTitleRequiredHint { showTitleRequiredHint = false }
                }

            if titleError {
                Text("tasks.editor.title.required")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .transition(.opacity)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(cornerRadius: 20, glowColor: AppTheme.neonBlue)
    }

    private var detailsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("tasks.editor.details.label")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white.opacity(0.85))

            ZStack(alignment: .topLeading) {
                if details.isEmpty {
                    Text("tasks.editor.details.placeholder")
                        .font(.body)
                        .foregroundStyle(.white.opacity(0.4))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 16)
                }
                TextEditor(text: $details)
                    .font(.body)
                    .foregroundStyle(.white)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 90)
                    .padding(6)
            }
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.white.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.white.opacity(0.12), lineWidth: 1)
            )
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(cornerRadius: 20, glowColor: AppTheme.neonBlue)
    }

    private var rewardCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("tasks.editor.reward.label")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white.opacity(0.85))

            Text("tasks.editor.reward.hint")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.6))

            Picker("tasks.editor.reward.label", selection: $rewardMinutes) {
                ForEach(rewardOptions, id: \.self) { minutes in
                    Text(rewardText(minutes)).tag(minutes)
                }
            }
            .pickerStyle(.wheel)
            .frame(height: 120)
            .colorScheme(.dark)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(cornerRadius: 20, glowColor: AppTheme.neonBlue)
    }

    private var deleteButton: some View {
        Button(role: .destructive) {
            showDeleteConfirm = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "trash.fill")
                Text("tasks.editor.delete")
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(NeonPrimaryButtonStyle(tint: AppTheme.neonOrange))
    }

    private func saveAndDismiss() {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isFormValid else {
            withAnimation(.easeOut(duration: 0.15)) {
                showTitleRequiredHint = trimmed.isEmpty
            }
            return
        }
        let updated = ChildTask(
            id: id,
            title: trimmed,
            details: details.trimmingCharacters(in: .whitespacesAndNewlines),
            rewardSeconds: max(0, rewardMinutes) * 60,
            status: status,
            createdAt: createdAt,
            updatedAt: Date(),
            submittedAt: submittedAt,
            approvedAt: approvedAt
        )
        onSave(updated)
        dismiss()
    }
}

// MARK: - Shared status UI

struct TaskStatusBadge: View {
    let status: ChildTaskStatus

    var body: some View {
        Text(status.localizedTitle)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(status.accentColor)
            .lineLimit(1)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(status.accentColor.opacity(0.16)))
            .overlay(Capsule().stroke(status.accentColor.opacity(0.5), lineWidth: 1))
    }
}

extension ChildTaskStatus {
    var localizedTitle: String {
        switch self {
        case .pending: return L10n.tr("tasks.status.pending")
        case .submitted: return L10n.tr("tasks.status.submitted")
        case .approved: return L10n.tr("tasks.status.approved")
        }
    }

    var accentColor: Color {
        switch self {
        case .pending: return AppTheme.neonBlue
        case .submitted: return AppTheme.neonOrange
        case .approved: return AppTheme.neonGreen
        }
    }

    var iconName: String {
        switch self {
        case .pending: return "checklist"
        case .submitted: return "hourglass"
        case .approved: return "checkmark.seal.fill"
        }
    }
}

/// Локализованная строка награды «N мин».
func rewardText(_ minutes: Int) -> String {
    L10n.f("tasks.reward.minutes", minutes)
}

/// Системный share sheet (UIActivityViewController) с колбэком завершения — используется ребёнком
/// для отправки фото-отчёта в мессенджер. После успешного шеринга вызывается `onComplete`.
struct TaskActivityShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    var onComplete: ((Bool) -> Void)?

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        controller.completionWithItemsHandler = { _, completed, _, _ in
            onComplete?(completed)
        }
        if let popover = controller.popoverPresentationController,
           let window = (UIApplication.shared.connectedScenes.first as? UIWindowScene)?.windows.first {
            popover.sourceView = window
            popover.sourceRect = CGRect(x: window.bounds.midX, y: window.bounds.midY, width: 0, height: 0)
            popover.permittedArrowDirections = []
        }
        return controller
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
