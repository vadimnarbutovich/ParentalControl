import AVFoundation
import SwiftUI
import UIKit

struct ExerciseSessionView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var appState: AppState

    @StateObject private var vm: ExerciseSessionViewModel
    @State private var didSubmit = false
    @State private var showHelp = false
    @State private var cameraAccessBlocked = false

    init(type: ExerciseType) {
        _vm = StateObject(wrappedValue: ExerciseSessionViewModel(selectedType: type))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button {
                    finalizeSession(shouldDismiss: true)
                } label: {
                    Image(systemName: "chevron.backward")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(width: 40, height: 40)
                        .background(
                            Circle()
                                .fill(Color.white.opacity(0.10))
                                .overlay(
                                    Circle()
                                        .stroke(AppTheme.glassBorder.opacity(0.5), lineWidth: 1)
                                )
                        )
                }
                Text(vm.selectedType.title)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.white)
                Spacer()

                Button("exercise.help.button") {
                    showHelp = true
                }
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .foregroundStyle(AppTheme.neonGreen)
                .background(
                    Capsule(style: .continuous)
                        .fill(Color.white.opacity(0.08))
                        .overlay(
                            Capsule(style: .continuous)
                                .stroke(AppTheme.neonGreen.opacity(0.45), lineWidth: 1)
                        )
                )
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 10)
            .background {
                ZStack(alignment: .bottom) {
                    LinearGradient(
                        colors: [
                            Color(red: 0.07, green: 0.12, blue: 0.24),
                            Color(red: 0.03, green: 0.05, blue: 0.12)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    RadialGradient(
                        colors: [AppTheme.neonBlue.opacity(0.22), .clear],
                        center: .topTrailing,
                        startRadius: 10,
                        endRadius: 160
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    Rectangle()
                        .fill(Color.black.opacity(0.35))
                        .frame(height: 1)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                }
            }

            ZStack(alignment: .bottom) {
                Group {
                    if cameraAccessBlocked {
                        cameraAccessDeniedPlaceholder
                    } else {
                        CameraPreviewView(session: vm.cameraSession)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                VStack(spacing: 12) {
                    // Калибровочный оверлей (Дистанция / Опускание / Подъём) — только DEBUG-сборка.
                    #if DEBUG && !HIDE_DEBUG_UI
                    VStack(alignment: .leading, spacing: 8) {
                        debugRow(vm.debugDistanceText, isOK: vm.debugDistanceOK)
                        debugRow(vm.debugDownText, isOK: vm.debugDownOK)
                        debugRow(vm.debugUpText, isOK: vm.debugUpOK)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity)
                    .background(Color.black.opacity(0.62), in: RoundedRectangle(cornerRadius: 10))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(Color.white.opacity(0.22), lineWidth: 1)
                    )
                    .padding(.horizontal, 12)
                    #endif

                    Text(L10n.tr(vm.guidanceTextKey))
                        .font(.system(size: 46, weight: .heavy, design: .rounded))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(vm.guidanceColor)
                        .lineLimit(2)
                        .minimumScaleFactor(0.6)
                        .shadow(color: .black.opacity(0.6), radius: 8, x: 0, y: 3)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 10)
                        .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
                        .padding(.horizontal, 12)

                    HStack {
                        Spacer(minLength: 0)
                        Text("\(vm.currentReps)")
                            .font(.system(size: 68, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(.white)
                            .contentTransition(.numericText())
                            .padding(.horizontal, 14)
                            .padding(.vertical, 6)
                            .background(Color(white: 0.22), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 20)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color.black.ignoresSafeArea())
        .task {
            UIApplication.shared.isIdleTimerDisabled = true
            await runCameraAccessFlow()
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task {
                await runCameraAccessFlow()
            }
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            submitAndStop()
        }
        .sheet(isPresented: $showHelp) {
            ExerciseHelpView(type: vm.selectedType)
                .presentationDragIndicator(.hidden)
        }
    }

    private var cameraAccessDeniedPlaceholder: some View {
        ZStack(alignment: .top) {
            Color.black
            VStack(spacing: 20) {
                Image(systemName: "video.slash.fill")
                    .font(.system(size: 52, weight: .medium))
                    .foregroundStyle(AppTheme.neonOrange.opacity(0.9))
                Text("exercise.camera.denied.title")
                    .font(.title2.weight(.bold))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white)
                Text("exercise.camera.denied.body")
                    .font(.body)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white.opacity(0.88))
                    .padding(.horizontal, 12)
                Button {
                    appState.openAppSettingsURL()
                } label: {
                    Text(LocalizedStringKey("permission.banner.open_settings"))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(NeonPrimaryButtonStyle(tint: AppTheme.neonBlue))
                .padding(.horizontal, 24)
                .padding(.top, 8)
            }
            .padding(24)
        }
    }

    private func runCameraAccessFlow() async {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        switch status {
        case .denied, .restricted:
            vm.stopSession()
            cameraAccessBlocked = true
        case .notDetermined:
            cameraAccessBlocked = false
            let granted = await vm.requestCameraAccess()
            appState.refreshCameraAuthorizationFromSystem()
            if granted {
                await vm.prepareIfNeeded()
                appState.refreshCameraAuthorizationFromSystem()
                vm.startSessionIfNeeded()
            } else if AVCaptureDevice.authorizationStatus(for: .video) == .denied {
                vm.stopSession()
                cameraAccessBlocked = true
            }
        case .authorized:
            cameraAccessBlocked = false
            await vm.prepareIfNeeded()
            appState.refreshCameraAuthorizationFromSystem()
            vm.startSessionIfNeeded()
        @unknown default:
            vm.stopSession()
            cameraAccessBlocked = true
        }
    }

    private func finalizeSession(shouldDismiss: Bool) {
        submitAndStop()
        if shouldDismiss {
            dismiss()
        }
    }

    private func submitAndStop() {
        guard !didSubmit else { return }
        didSubmit = true
        vm.stopSession()
        appState.addExerciseReps(type: vm.selectedType, reps: vm.currentReps)
    }

    #if DEBUG && !HIDE_DEBUG_UI
    private func debugRow(_ text: String, isOK: Bool) -> some View {
        Text(text)
            .font(.system(size: 24, weight: .heavy, design: .rounded))
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .foregroundStyle(isOK ? Color.green : Color.red)
    }
    #endif
}

private struct ExerciseHelpView: View {
    let type: ExerciseType

    var body: some View {
        VStack(spacing: 0) {
            Capsule(style: .continuous)
                .fill(Color.white.opacity(0.30))
                .frame(width: 40, height: 5)
                .padding(.top, 8)
                .padding(.bottom, 10)

            Text("exercise.help.title")
                .font(.headline.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.bottom, 10)

            VStack(alignment: .leading, spacing: 16) {
                Image(helpImageAssetName)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(AppTheme.glassBorder.opacity(0.65), lineWidth: 1)
                    )

                Text(helpText)
                    .font(.body)
                    .foregroundStyle(.white.opacity(0.92))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal)
            .padding(.bottom, 20)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .appScreenBackground()
    }

    private var helpImageAssetName: String {
        switch type {
        case .squat:
            return "squatHelp"
        case .pushUp:
            return "pushupsHelp"
        }
    }

    private var helpText: String {
        switch type {
        case .squat:
            return L10n.tr("exercise.help.squat")
        case .pushUp:
            return L10n.tr("exercise.help.pushup")
        }
    }
}

#Preview {
    ExerciseSessionView(type: .squat)
        .environmentObject(AppState())
}
