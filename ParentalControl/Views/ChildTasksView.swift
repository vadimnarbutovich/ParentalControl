import PhotosUI
import SwiftUI

/// Вкладка «Задания» на устройстве ребёнка (обычный режим). Ребёнок видит задания от родителя,
/// открывает детально и отправляет фото-отчёт через системное «Поделиться» (мессенджер).
/// Фото у нас не хранится — после успешного шеринга задание переходит в статус «На проверке».
struct ChildTasksView: View {
    @EnvironmentObject private var appState: AppState

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
                                    NavigationLink {
                                        ChildTaskDetailView(taskID: task.id)
                                            .environmentObject(appState)
                                    } label: {
                                        ChildTaskRowView(task: task)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 28)
                }
                .scrollIndicators(.hidden)
            }
            .navigationTitle("tab.tasks")
            .navigationBarTitleDisplayMode(.inline)
        }
        .preferredColorScheme(.dark)
        .task { await appState.refreshChildTasksFromServer() }
    }

    private var header: some View {
        Text("tasks.child.subtitle")
            .font(.subheadline)
            .foregroundStyle(.white.opacity(0.7))
            .multilineTextAlignment(.center)
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
            Text("tasks.child.empty.subtitle")
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
}

// MARK: - Child task row

private struct ChildTaskRowView: View {
    let task: ChildTask

    var body: some View {
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
}

// MARK: - Child task detail

/// Детальный экран задания. Ребёнок выполняет задание и жмёт «Отправить отчёт»:
/// выбирает фото (библиотека), делится им через системный share sheet (мессенджер),
/// и после успешного шеринга задание уходит «На проверку» (`submitChildTask`).
private struct ChildTaskDetailView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    let taskID: UUID

    @State private var photoItem: PhotosPickerItem?
    @State private var shareImage: UIImage?
    @State private var isShareSheetPresented = false
    @State private var isLoadingPhoto = false
    @State private var isSubmitting = false

    private var task: ChildTask? {
        appState.childTasks.first { $0.id == taskID }
    }

    var body: some View {
        ZStack {
            AppBackgroundView()
            if let task {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        infoCard(task)
                        if task.status == .pending {
                            sendReportButton(task)
                        } else {
                            statusCard(task)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 24)
                }
                .scrollIndicators(.hidden)
            } else {
                // Задание исчезло (удалено родителем) — закрываем экран.
                Color.clear.onAppear { dismiss() }
            }
        }
        .navigationTitle("tasks.detail.title")
        .navigationBarTitleDisplayMode(.inline)
        .preferredColorScheme(.dark)
        .onChange(of: photoItem) { _, newItem in
            guard let newItem else { return }
            loadPhoto(newItem)
        }
        .sheet(isPresented: $isShareSheetPresented, onDismiss: { shareImage = nil }) {
            if let shareImage, let task {
                TaskActivityShareSheet(
                    items: [shareImage, L10n.f("tasks.share.caption", task.title)],
                    onComplete: { completed in
                        if completed { submit() }
                    }
                )
            }
        }
    }

    private func infoCard(_ task: ChildTask) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(task.title)
                .font(.title3.weight(.bold))
                .foregroundStyle(.white)

            HStack(spacing: 8) {
                Image(systemName: "clock.fill")
                    .foregroundStyle(AppTheme.neonGreen)
                Text(L10n.f("tasks.detail.reward", task.rewardMinutes))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.85))
            }

            if !task.details.isEmpty {
                Text(task.details)
                    .font(.body)
                    .foregroundStyle(.white.opacity(0.8))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(cornerRadius: 20, glowColor: AppTheme.neonBlue)
    }

    @ViewBuilder
    private func sendReportButton(_ task: ChildTask) -> some View {
        VStack(spacing: 12) {
            Text("tasks.detail.send_hint")
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.65))
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)

            PhotosPicker(selection: $photoItem, matching: .images, photoLibrary: .shared()) {
                HStack(spacing: 8) {
                    if isLoadingPhoto || isSubmitting {
                        ProgressView().tint(.white)
                    } else {
                        Image(systemName: "paperplane.fill")
                    }
                    Text("tasks.detail.send_report")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(NeonPrimaryButtonStyle(tint: AppTheme.neonGreen))
            .disabled(isLoadingPhoto || isSubmitting)
        }
    }

    private func statusCard(_ task: ChildTask) -> some View {
        HStack(spacing: 10) {
            Image(systemName: task.status.iconName)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(task.status.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(task.status.localizedTitle)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                Text(task.status == .submitted
                     ? "tasks.detail.submitted_hint"
                     : "tasks.detail.approved_hint")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.65))
            }
            Spacer()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(cornerRadius: 20, glowColor: task.status.accentColor)
    }

    private func loadPhoto(_ item: PhotosPickerItem) {
        isLoadingPhoto = true
        Task {
            defer { isLoadingPhoto = false; photoItem = nil }
            if let data = try? await item.loadTransferable(type: Data.self),
               let image = UIImage(data: data) {
                shareImage = image
                isShareSheetPresented = true
            }
        }
    }

    private func submit() {
        isSubmitting = true
        Task {
            await appState.submitChildTask(taskID)
            isSubmitting = false
        }
    }
}
