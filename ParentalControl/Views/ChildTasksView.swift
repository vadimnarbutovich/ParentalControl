import AVFoundation
import PhotosUI
import SwiftUI

/// Задания на главной ребёнка. Использует NavigationStack главного экрана.
struct ChildTasksSection: View {
    @EnvironmentObject private var appState: AppState
    @State private var showsAll = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let visible = appState.childTasks.filter { $0.isVisible(at: context.date) }
            let active = visible.filter(\.isActive).sorted {
                if $0.status != $1.status { return $0.status == .pending }
                return $0.createdAt > $1.createdAt
            }
            let completed = visible.filter { !$0.isActive }.sorted {
                ($0.approvedAt ?? $0.updatedAt) > ($1.approvedAt ?? $1.updatedAt)
            }
            VStack(alignment: .leading, spacing: 12) {
                Text("tab.tasks")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
                if active.isEmpty && completed.isEmpty {
                    emptyState
                } else {
                    if !active.isEmpty {
                        Text(appState.isFamilyAccessAllowed ? "tasks.child.subtitle" : "tasks.child.access_paused")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        ForEach(showsAll ? active : Array(active.prefix(3))) { task in
                            taskLink(task)
                        }
                        if active.count > 3 {
                            Button(showsAll ? "tasks.show_less" : "tasks.show_all") {
                                showsAll.toggle()
                            }
                            .font(.subheadline.weight(.semibold))
                            .tint(AppTheme.neonBlue)
                        }
                    }
                    ForEach(completed) { task in taskLink(task) }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task { await appState.refreshChildTasksFromServer() }
    }

    private func taskLink(_ task: ChildTask) -> some View {
        NavigationLink {
            ChildTaskDetailView(taskID: task.id)
        } label: {
            ChildTaskRowView(task: task)
        }
        .buttonStyle(.plain)
    }

    private var emptyState: some View {
        HStack(spacing: 12) {
            Image(systemName: "checklist").foregroundStyle(AppTheme.neonBlue)
            Text("tasks.child.empty.subtitle")
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.65))
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
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
                    Text(L10n.f("tasks.detail.reward", task.rewardMinutes))
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.7))
                        .fixedSize(horizontal: false, vertical: true)
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
    @State private var showMutationError = false
    /// Диалог выбора источника фото: «Сделать фото» (камера) или «Выбрать из галереи».
    @State private var showSourceDialog = false
    @State private var showCamera = false
    @State private var showLibrary = false
    @State private var showCameraPermissionAlert = false

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
                            if appState.isFamilyAccessAllowed {
                                sendReportButton(task)
                            } else {
                                Label("tasks.child.access_paused", systemImage: "pause.circle")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
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
        .alert("tasks.change_failed", isPresented: $showMutationError) {
            Button("tasks.detail.send_report") { submit() }
            Button("tasks.editor.cancel", role: .cancel) {}
        } message: {
            Text("tasks.change_failed.message")
        }
        .confirmationDialog("tasks.detail.report_source.title", isPresented: $showSourceDialog, titleVisibility: .visible) {
            if UIImagePickerController.isSourceTypeAvailable(.camera) {
                Button("tasks.detail.report_source.camera") { Task { await openTaskCamera() } }
            }
            Button("tasks.detail.report_source.library") {
                guard canContinueReport() else { return }
                showLibrary = true
            }
            Button("tasks.editor.cancel", role: .cancel) {}
        }
        .alert("permission.camera.title", isPresented: $showCameraPermissionAlert) {
            Button("settings.open.settings") { appState.openAppSettingsURL() }
            Button("tasks.editor.cancel", role: .cancel) {}
        } message: {
            Text("permission.camera.body")
        }
        .photosPicker(isPresented: $showLibrary, selection: $photoItem, matching: .images, photoLibrary: .shared())
        .fullScreenCover(isPresented: $showCamera) {
            CameraPicker { image in
                showCamera = false
                if let image { handlePickedImage(image) }
            }
            .ignoresSafeArea()
        }
        .onChange(of: photoItem) { _, newItem in
            guard let newItem else { return }
            loadPhoto(newItem)
        }
        .onChange(of: appState.isFamilyAccessAllowed) { _, allowed in
            if !allowed { dismissReportFlow() }
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

            Button {
                guard canContinueReport() else { return }
                showSourceDialog = true
            } label: {
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

    @MainActor
    private func openTaskCamera() async {
        guard canContinueReport() else { return }
        let allowed: Bool
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: allowed = true
        case .notDetermined: allowed = await AVCaptureDevice.requestAccess(for: .video)
        case .denied, .restricted: allowed = false
        @unknown default: allowed = false
        }
        guard canContinueReport() else { return }
        if allowed { showCamera = true } else { showCameraPermissionAlert = true }
    }

    private func loadPhoto(_ item: PhotosPickerItem) {
        guard canContinueReport() else { return }
        isLoadingPhoto = true
        Task {
            defer { isLoadingPhoto = false; photoItem = nil }
            if let data = try? await item.loadTransferable(type: Data.self),
               let image = UIImage(data: data) {
                handlePickedImage(image)
            }
        }
    }

    /// Общий обработчик выбранного/снятого фото: показываем системный share sheet.
    private func handlePickedImage(_ image: UIImage) {
        guard canContinueReport() else { return }
        shareImage = image
        isShareSheetPresented = true
    }

    private func submit() {
        guard !isSubmitting, canContinueReport() else { return }
        isSubmitting = true
        Task {
            defer { isSubmitting = false }
            if !(await appState.submitChildTask(taskID)) {
                // Access may expire while a photo/share sheet or request is open.
                // Show the paused state, not a mutation error or a retry prompt.
                guard canContinueReport() else { return }
                await appState.refreshChildTasksFromServer()
                guard canContinueReport() else { return }
                showMutationError = true
            }
        }
    }

    private func canContinueReport() -> Bool {
        guard FamilyAccessStore.allowed else {
            appState.adoptFamilyAccess()
            dismissReportFlow()
            return false
        }
        return appState.deviceRole == .child && task?.status == .pending
    }

    private func dismissReportFlow() {
        showSourceDialog = false
        showCamera = false
        showLibrary = false
        isShareSheetPresented = false
        showMutationError = false
        showCameraPermissionAlert = false
        shareImage = nil
        photoItem = nil
    }
}

// MARK: - Camera picker

/// Обёртка над `UIImagePickerController` (sourceType .camera) — SwiftUI не имеет нативного
/// пикера камеры. Требует `NSCameraUsageDescription` (в проекте уже задан). Возвращает снятое
/// фото в `onImage` (или `nil`, если пользователь отменил).
struct CameraPicker: UIViewControllerRepresentable {
    let onImage: (UIImage?) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onImage: onImage) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        private let onImage: (UIImage?) -> Void

        init(onImage: @escaping (UIImage?) -> Void) {
            self.onImage = onImage
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            let image = (info[.editedImage] as? UIImage) ?? (info[.originalImage] as? UIImage)
            onImage(image)
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            onImage(nil)
        }
    }
}
